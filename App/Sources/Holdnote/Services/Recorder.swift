import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Records the microphone: the audio goes to a WAV file in the mic's own format as it comes
/// (what plays back, and what a later model can transcribe again), and is kept in memory as
/// 16 kHz mono samples (what whisper reads) so the transcript starts the moment the key is
/// released, with no decoding. Nothing leaves the Mac.
@MainActor
final class Recorder {
    nonisolated static let modelRate = 16000

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private let engine = AVAudioEngine()
    private var sink: AudioSink?
    let url: URL
    private(set) var stopped = false
    /// The input the audio came from, for the recording's record.
    private(set) var deviceName: String?
    /// Something stopped the audio (the device went away, the Mac slept).
    var onInterruption: (() -> Void)?
    private var observer: NSObjectProtocol?

    init(url: URL) {
        self.url = url
    }

    /// Asks for the microphone the first time; false when the user said no (or said no before).
    nonisolated static func permission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    nonisolated static var isAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Starts recording from `deviceUID` (nil: the system's default input).
    func start(deviceUID: String?) throws {
        let input = engine.inputNode
        if let deviceUID, let id = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var device = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { throw Problem("That microphone can't be opened (\(status)). Pick another in the menu.") }
        }
        deviceName = deviceUID.flatMap { AudioDevices.name(forUID: $0) } ?? AudioDevices.defaultInputName()
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Problem("No microphone is connected.") }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.modelRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw Problem("The microphone's audio can't be read.") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let sink = AudioSink(converter: converter, target: target, file: file)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(sink))
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.sink = sink
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInterruption?() }
        }
    }

    /// Stops recording and closes the file.
    func stop() {
        guard !stopped else { return }
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink?.close()
    }

    /// Made outside the main actor: the tap runs on an audio thread.
    private nonisolated static func tap(_ sink: AudioSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.receive(buffer) }
    }

    /// How loud the last moment was, 0 to 1, for the HUD's bars.
    var level: Float { sink?.level ?? 0 }
    /// Seconds recorded so far.
    var seconds: TimeInterval { TimeInterval(sink?.count ?? 0) / TimeInterval(Self.modelRate) }
    /// Everything recorded, as 16 kHz mono samples.
    func allSamples() -> [Float] { sink?.allSamples() ?? [] }
    /// Seconds since any sound above a whisper reached the mic (nil: none yet).
    var secondsOfSilence: TimeInterval { sink?.secondsOfSilence ?? 0 }
}

/// Where the tap's audio goes: written to the file as it is, converted to 16 kHz mono and kept.
/// The tap calls it on the audio thread and the app reads it on the main one, hence the lock.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private var file: AVAudioFile?
    private var kept: [Float] = []
    private var total = 0
    private var lastLevel: Float = 0
    private var silentSamples = 0

    init(converter: AVAudioConverter, target: AVAudioFormat, file: AVAudioFile) {
        self.converter = converter
        self.target = target
        self.file = file
    }

    func receive(_ input: AVAudioPCMBuffer) {
        let ratio = target.sampleRate / input.format.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 64) else { return }
        var fed = false
        var error: NSError?
        // `noDataNow` (not end of stream) keeps the converter's state from one buffer to the next.
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: input)
        guard error == nil, output.frameLength > 0, let data = output.floatChannelData else { return }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))
        kept.append(contentsOf: samples)
        total += samples.count
        let rms = Self.rms(samples)
        lastLevel = min(1, rms * 6)
        if rms < 0.002 { silentSamples += samples.count } else { silentSamples = 0 }
    }

    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }

    var level: Float { lock.lock(); defer { lock.unlock() }; return lastLevel }
    var count: Int { lock.lock(); defer { lock.unlock() }; return total }
    var secondsOfSilence: TimeInterval { lock.lock(); defer { lock.unlock() }; return TimeInterval(silentSamples) / TimeInterval(Recorder.modelRate) }

    func allSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// The microphones on this Mac, by CoreAudio.
enum AudioDevices {
    struct Device: Identifiable, Equatable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// Every input device, the default first.
    static func inputs() -> [Device] {
        var devices: [Device] = []
        for id in allDeviceIDs() where inputChannels(id) > 0 {
            if let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioDevicePropertyDeviceNameCFString) {
                devices.append(Device(uid: uid, name: name))
            }
        }
        return devices
    }

    static func defaultInputName() -> String? {
        guard let id = defaultInputID() else { return nil }
        return string(id, kAudioDevicePropertyDeviceNameCFString)
    }

    static func name(forUID uid: String) -> String? {
        guard let id = deviceID(forUID: uid) else { return nil }
        return string(id, kAudioDevicePropertyDeviceNameCFString)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
