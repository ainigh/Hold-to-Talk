import AVFoundation
import Foundation
import Harness

/// Voice-detection mode: listens to the microphone all the time and keeps audio only while
/// someone is speaking. Nothing touches the disk until speech starts; a segment becomes a
/// recording when it ends. The tap runs the voice detector on the audio thread and holds a
/// second of audio before speech was noticed, so the first word isn't cut.
@MainActor
final class Listener {
    struct Segment {
        let id = UUID()
        let startedAt: Date
        let duration: TimeInterval
        /// The audio in the microphone's format, to write as the WAV.
        let buffers: [AVAudioPCMBuffer]
        let format: AVAudioFormat
        /// The same as 16 kHz mono, for the transcriber.
        let samples: [Float]
    }

    private let engine = AVAudioEngine()
    private var sink: ListeningSink?
    private var poll: Timer?
    private(set) var isListening = false
    /// Speech is being heard right now.
    var isSpeaking: Bool { sink?.isSpeaking ?? false }
    var level: Float { sink?.level ?? 0 }
    /// A segment ended and is ready to become a recording.
    var onSegment: ((Segment) -> Void)?
    var onError: ((String) -> Void)?
    private var observer: NSObjectProtocol?

    func start(deviceUID: String?) throws {
        guard !isListening else { return }
        let input = engine.inputNode
        if let deviceUID, let id = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            var device = id
            _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Recorder.Problem("No microphone is connected.") }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Recorder.modelRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw Recorder.Problem("The microphone's audio can't be read.") }
        let sink = ListeningSink(converter: converter, target: target, format: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(sink))
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.sink = sink
        isListening = true
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The device changed: start over on the new one.
                guard let self, self.isListening else { return }
                self.stop()
                do { try self.start(deviceUID: deviceUID) } catch { self.onError?(error.localizedDescription) }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        poll?.invalidate()
        poll = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // A segment going when listening stops is kept.
        sink?.finishNow()
        drain()
        sink = nil
    }

    private nonisolated static func tap(_ sink: ListeningSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.receive(buffer) }
    }

    private func drain() {
        guard let sink else { return }
        for segment in sink.takeFinished() { onSegment?(segment) }
    }
}

/// The tap's side: converts, measures, runs the voice detector, keeps a pre-roll ring and the
/// segment's audio while speech lasts. Finished segments wait for the main thread.
final class ListeningSink: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    let format: AVAudioFormat
    private var vad = VoiceActivity()
    private var time: TimeInterval = 0
    /// The last second or so of audio, in case speech is about to be noticed.
    private var ring: [(buffer: AVAudioPCMBuffer, samples: [Float])] = []
    private var ringSeconds: TimeInterval = 0
    private var active: (startedAt: Date, buffers: [AVAudioPCMBuffer], samples: [Float])?
    private var finished: [Listener.Segment] = []
    private var lastLevel: Float = 0

    init(converter: AVAudioConverter, target: AVAudioFormat, format: AVAudioFormat) {
        self.converter = converter
        self.target = target
        self.format = format
    }

    var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return active != nil }
    var level: Float { lock.lock(); defer { lock.unlock() }; return lastLevel }

    func receive(_ input: AVAudioPCMBuffer) {
        let ratio = target.sampleRate / input.format.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 64) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let data = output.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
        let seconds = Double(input.frameLength) / input.format.sampleRate
        // The tap hands over its buffer for reuse: keep a copy.
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return }
        copy.frameLength = input.frameLength
        if let src = input.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<Int(input.format.channelCount) { dst[ch].update(from: src[ch], count: Int(input.frameLength)) }
        } else if let src = input.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<Int(input.format.channelCount) { dst[ch].update(from: src[ch], count: Int(input.frameLength)) }
        } else if let src = input.int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<Int(input.format.channelCount) { dst[ch].update(from: src[ch], count: Int(input.frameLength)) }
        }

        lock.lock()
        defer { lock.unlock() }
        time += seconds
        let rms = samples.withUnsafeBufferPointer { AudioSink.rms($0) }
        lastLevel = min(1, rms * 6)
        if active != nil {
            active?.buffers.append(copy)
            active?.samples.append(contentsOf: samples)
        } else {
            ring.append((copy, samples))
            ringSeconds += seconds
            while ringSeconds > 1.2, let first = ring.first {
                ringSeconds -= Double(first.buffer.frameLength) / input.format.sampleRate
                ring.removeFirst()
            }
        }
        switch vad.feed(rms: rms, at: time) {
        case .started:
            // Speech began about `startAfter` ago: the ring holds it.
            active = (Date().addingTimeInterval(-ringSeconds), ring.map(\.buffer), ring.flatMap(\.samples))
            ring = []
            ringSeconds = 0
        case let .ended(_, _, keep):
            finish(keep: keep)
        case nil:
            break
        }
    }

    /// Listening stopped mid-speech: the segment so far is kept (if long enough).
    func finishNow() {
        lock.lock()
        defer { lock.unlock() }
        if let a = active {
            finish(keep: Double(a.samples.count) / Double(Recorder.modelRate) >= vad.tuning.minimumLength)
        }
        vad.reset()
    }

    /// With the lock held.
    private func finish(keep: Bool) {
        guard let a = active else { return }
        active = nil
        guard keep else { return }
        let duration = Double(a.samples.count) / Double(Recorder.modelRate)
        finished.append(Listener.Segment(startedAt: a.startedAt, duration: duration, buffers: a.buffers, format: format, samples: a.samples))
    }

    func takeFinished() -> [Listener.Segment] {
        lock.lock()
        defer { lock.unlock() }
        let done = finished
        finished = []
        return done
    }
}
