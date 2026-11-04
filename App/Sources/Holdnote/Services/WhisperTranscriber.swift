import AVFoundation
import Foundation
import Harness
import whisper

/// Transcribes on this Mac with whisper.cpp (Metal). The model is downloaded once, with your
/// consent on the setup window, into the store's Models folder, and stays loaded after first
/// use so the next transcript starts at once.
final class WhisperTranscriber: @unchecked Sendable {
    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Result: Sendable {
        let segments: [Recording.Segment]
        let language: String
        let model: String
    }

    struct Options: Sendable {
        var language = "auto"
        var prompt = ""
        /// Long audio in this many parts at once (the setting): 0 automatic, 1 never.
        var parallelParts = 0
    }

    let modelsFolder: URL
    private let lock = NSLock()
    private var loaded: (url: URL, ctx: OpaquePointer)?

    init(modelsFolder: URL) {
        self.modelsFolder = modelsFolder
    }

    deinit {
        if let loaded { whisper_free(loaded.ctx) }
    }

    func modelURL(_ name: String) -> URL { modelsFolder.appendingPathComponent("ggml-\(name).bin") }
    func hasModel(_ name: String) -> Bool { FileManager.default.fileExists(atPath: modelURL(name).path) }

    static func remoteURL(_ name: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")!
    }

    /// Downloads `ggml-<name>.bin` from Hugging Face, reporting how far along it is (nil while
    /// the size is unknown). The one time the app touches the network besides its updates.
    func download(_ name: String, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let url = modelURL(name)
        if FileManager.default.fileExists(atPath: url.path) { return }
        progress(nil)
        let watcher = DownloadWatcher(progress)
        let (temp, response) = try await URLSession.shared.download(from: Self.remoteURL(name), delegate: watcher)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Problem("Couldn't download the \(name) model from huggingface.co.")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        progress(1)
    }

    /// Forgets a loaded model (to free its memory, or after the file was replaced).
    func unload() {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { whisper_free(loaded.ctx) }
        loaded = nil
    }

    /// Transcribes 16 kHz mono samples. One recording at a time; call off the main thread.
    /// Long audio is cut at quiet moments into parts (`AudioSplit`) that run at the same time,
    /// each with its own whisper state on the one loaded model, and their segments are joined
    /// back in order with their times offset.
    func transcribe(_ samples: [Float], model name: String, options: Options, progress: @escaping @Sendable (Double) -> Void) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        let url = modelURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Problem("The \(name) model isn't downloaded yet (Settings → Transcription).")
        }
        let ctx: OpaquePointer
        if let loaded, loaded.url == url {
            ctx = loaded.ctx
        } else {
            if let loaded { whisper_free(loaded.ctx) }
            loaded = nil
            var cparams = whisper_context_default_params()
            cparams.use_gpu = true
            // Flash attention: the same result, noticeably faster on Metal.
            cparams.flash_attn = true
            guard let c = whisper_init_from_file_with_params(url.path, cparams) else {
                throw Problem("whisper couldn't load \(url.lastPathComponent). Delete it in Settings → Transcription and download it again.")
            }
            loaded = (url, c)
            ctx = c
        }
        // Whisper hears nothing in under a second of audio; pad so it doesn't fail outright.
        let audio = samples.count < Recorder.modelRate ? samples + [Float](repeating: 0, count: Recorder.modelRate - samples.count) : samples

        let parts = AudioSplit.parts(seconds: Double(audio.count) / Double(Recorder.modelRate), requested: options.parallelParts)
        let ranges = AudioSplit.ranges(audio, rate: Recorder.modelRate, parts: parts)
        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true
        params.n_threads = Int32(max(2, cores / ranges.count))
        params.progress_callback = { _, _, percent, data in
            guard let data else { return }
            Unmanaged<PartProgress>.fromOpaque(data).takeUnretainedValue().report(Double(percent) / 100)
        }
        let language = options.language.isEmpty ? "auto" : options.language
        let prompt = options.prompt
        let tally = ProgressTally(weights: ranges.map { Double($0.count) / Double(audio.count) }, report: progress)
        let collector = PartCollector(count: ranges.count)
        // The C strings live for the whole run: every part's params point at them.
        language.withCString { lang in
            prompt.withCString { p in
                params.language = lang
                params.detect_language = false
                params.initial_prompt = prompt.isEmpty ? nil : p
                let base = params
                DispatchQueue.concurrentPerform(iterations: ranges.count) { i in
                    let range = ranges[i]
                    let offset = Double(range.lowerBound) / Double(Recorder.modelRate)
                    let part = PartProgress(tally: tally, index: i)
                    var mine = base
                    mine.progress_callback_user_data = Unmanaged.passUnretained(part).toOpaque()
                    let chunk = Array(audio[range])
                    let outcome: PartCollector.Outcome = withExtendedLifetime(part) { () -> PartCollector.Outcome in
                        guard let state = whisper_init_state(ctx) else { return .failed(-1) }
                        defer { whisper_free_state(state) }
                        let status = chunk.withUnsafeBufferPointer { whisper_full_with_state(ctx, state, mine, $0.baseAddress, Int32($0.count)) }
                        guard status == 0 else { return .failed(status) }
                        var segments: [Recording.Segment] = []
                        for s in 0..<whisper_full_n_segments_from_state(state) {
                            let t0 = Double(whisper_full_get_segment_t0_from_state(state, s)) / 100
                            let t1 = Double(whisper_full_get_segment_t1_from_state(state, s)) / 100
                            let text = String(cString: whisper_full_get_segment_text_from_state(state, s)).trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty, !Self.isNoise(text) else { continue }
                            segments.append(Recording.Segment(start: offset + t0, end: offset + t1, text: text))
                        }
                        let found = String(cString: whisper_lang_str(whisper_full_lang_id_from_state(state)))
                        return .done(segments, language: found)
                    }
                    collector.set(i, outcome)
                }
            }
        }
        var segments: [Recording.Segment] = []
        var detected = ""
        for outcome in collector.outcomes {
            switch outcome {
            case .some(.done(let segs, let lang)):
                segments += segs
                if detected.isEmpty { detected = lang }
            case .some(.failed(let status)):
                throw Problem("whisper failed (\(status)).")
            case .none:
                throw Problem("whisper failed.")
            }
        }
        progress(1)
        return Result(segments: segments, language: detected, model: name)
    }

    /// One part's progress, weighted into the whole's.
    final class PartProgress: @unchecked Sendable {
        let tally: ProgressTally
        let index: Int
        init(tally: ProgressTally, index: Int) { self.tally = tally; self.index = index }
        func report(_ fraction: Double) { tally.set(index, fraction) }
    }

    /// The parts' progress added up by their share of the audio.
    final class ProgressTally: @unchecked Sendable {
        private let lock = NSLock()
        private var fractions: [Double]
        private let weights: [Double]
        private let report: @Sendable (Double) -> Void
        init(weights: [Double], report: @escaping @Sendable (Double) -> Void) {
            self.weights = weights
            fractions = Array(repeating: 0, count: weights.count)
            self.report = report
        }
        func set(_ i: Int, _ fraction: Double) {
            lock.lock()
            fractions[i] = max(fractions[i], min(1, fraction))
            let total = zip(fractions, weights).reduce(0) { $0 + $1.0 * $1.1 }
            lock.unlock()
            report(total)
        }
    }

    /// Each part's result, written from its own thread.
    final class PartCollector: @unchecked Sendable {
        enum Outcome { case done([Recording.Segment], language: String), failed(Int32) }
        private let lock = NSLock()
        private var slots: [Outcome?]
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ outcome: Outcome) { lock.lock(); slots[i] = outcome; lock.unlock() }
        var outcomes: [Outcome?] { lock.lock(); defer { lock.unlock() }; return slots }
    }

    /// Whisper's markers for silence and sounds ("[BLANK_AUDIO]", "(wind blowing)") aren't words.
    static func isNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) || (t.hasPrefix("*") && t.hasSuffix("*"))
    }

    /// Watches a download task's progress (the async download call has no progress of its own).
    final class DownloadWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double?) -> Void
        private var observation: NSKeyValueObservation?

        init(_ report: @escaping @Sendable (Double?) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [report] p, _ in
                report(p.totalUnitCount > 0 ? p.fractionCompleted : nil)
            }
        }
    }
}

/// Decodes any audio file AVFoundation reads into 16 kHz mono float samples (Re-transcribe,
/// and recordings recovered after a crash).
enum AudioDecoder {
    static func pcm16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Recorder.modelRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw WhisperTranscriber.Problem("The audio file's format can't be read.")
        }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw WhisperTranscriber.Problem("The audio file is empty.")
        }
        try file.read(into: input)
        let ratio = Double(Recorder.modelRate) / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 1024) else {
            throw WhisperTranscriber.Problem("The audio file is empty.")
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// The file's length in seconds.
    static func duration(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
