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
        /// The run was stopped on purpose (Stop in the window).
        static let cancelled = Problem("Stopped before it finished. Retry to transcribe it.")
        var isCancelled: Bool { errorDescription == Problem.cancelled.errorDescription }
    }

    struct Result: Sendable {
        let segments: [Recording.Segment]
        let language: String
        let model: String
    }

    /// How far a transcription is: the fraction of the audio done, weighted by chunk, and the
    /// chunks finished of the chunks there are (1 of 1 for audio that wasn't split).
    struct Progress: Sendable {
        /// What the transcriber is at: cutting the audio into chunks, or transcribing them.
        enum Phase: Sendable { case cutting, transcribing }
        var phase: Phase = .transcribing
        var fraction: Double
        var chunksDone: Int
        var chunks: Int
        /// Every chunk, in order of the audio, with where it stands.
        var parts: [ChunkProgress] = []
        /// How many run at once.
        var atOnce = 1
    }

    /// One chunk of the audio as the transcriber works through it.
    struct ChunkProgress: Sendable, Equatable, Identifiable {
        var id: Int
        /// Where it starts in the audio, and how long it is.
        var start: TimeInterval
        var seconds: TimeInterval
        enum State: Sendable, Equatable { case waiting, running, done }
        var state: State = .waiting
        var fraction: Double = 0
    }

    struct Options: Sendable {
        var language = "auto"
        var prompt = ""
        /// Long audio's chunks, this many at once (the setting): 0 automatic, 1 never split.
        var parallelParts = 0
    }

    let modelsFolder: URL
    private let lock = NSLock()
    private var loaded: (url: URL, ctx: OpaquePointer)?
    /// Set by `cancel()` from any thread while a run is going; whisper checks it between steps.
    private let cancelFlag = Flag()

    /// Stops the transcription in progress as soon as whisper reaches its next step; the run
    /// then fails with `Problem.cancelled`. Safe from any thread. A stop asked for while the
    /// file is still being decoded holds until `beginRun()` is called again.
    func cancel() { cancelFlag.set(true) }
    /// Whether a stop was asked for since `beginRun()`.
    var isCancelled: Bool { cancelFlag.isOn }
    /// Called before each recording's run (before its file is decoded), so a stop asked for
    /// during the decode still counts.
    func beginRun() { cancelFlag.set(false) }

    /// A thread-safe switch.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
        func set(_ v: Bool) { lock.lock(); on = v; lock.unlock() }
    }

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
    /// Long audio is cut at quiet moments into chunks of about five minutes (`AudioSplit`); a
    /// few workers, each with its own whisper state on the one loaded model, take the next
    /// chunk as they finish one, and the chunks' segments are joined back in order with their
    /// times offset. A chunk that fails is tried once more before the whole is given up.
    func transcribe(_ samples: [Float], model name: String, options: Options, progress: @escaping @Sendable (Progress) -> Void) throws -> Result {
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

        let seconds = Double(audio.count) / Double(Recorder.modelRate)
        let workers = AudioSplit.workers(requested: options.parallelParts)
        if seconds >= AudioSplit.minimumToSplit, workers > 1 { progress(Progress(phase: .cutting, fraction: 0, chunksDone: 0, chunks: 0)) }
        let ranges = AudioSplit.ranges(audio, rate: Recorder.modelRate, parts: AudioSplit.parts(seconds: seconds, workers: workers))
        let atOnce = min(workers, ranges.count)
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
        params.n_threads = Int32(max(2, cores / atOnce))
        params.progress_callback = { _, _, percent, data in
            guard let data else { return }
            Unmanaged<PartProgress>.fromOpaque(data).takeUnretainedValue().report(Double(percent) / 100)
        }
        // Stop: whisper asks between steps whether to give up, and does when this says so.
        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<Flag>.fromOpaque(data).takeUnretainedValue().isOn
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(cancelFlag).toOpaque()
        // "nb" was this app's old code for Norwegian; whisper.cpp knows it as "no".
        let language = options.language.isEmpty ? "auto" : (options.language == "nb" ? "no" : options.language)
        let prompt = options.prompt
        let tally = ProgressTally(ranges: ranges, rate: Recorder.modelRate, atOnce: atOnce, report: progress)
        tally.announce()
        let collector = PartCollector(count: ranges.count)
        let next = ChunkCounter()
        // The C strings live for the whole run: every chunk's params point at them.
        language.withCString { lang in
            prompt.withCString { p in
                params.language = lang
                params.detect_language = false
                params.initial_prompt = prompt.isEmpty ? nil : p
                let base = params
                // Each worker keeps one state (whisper's working memory for a run; its cost is
                // paid once per worker, not per chunk) and takes chunks until there are none.
                DispatchQueue.concurrentPerform(iterations: atOnce) { _ in
                    guard let state = whisper_init_state(ctx) else {
                        while let i = next.take(ranges.count) { collector.set(i, .failed(-1)) }
                        return
                    }
                    defer { whisper_free_state(state) }
                    while let i = next.take(ranges.count) {
                        if collector.stopped || cancelFlag.isOn { collector.set(i, .failed(-1)); continue }
                        let range = ranges[i]
                        let offset = Double(range.lowerBound) / Double(Recorder.modelRate)
                        let part = PartProgress(tally: tally, index: i)
                        tally.started(i)
                        var mine = base
                        mine.progress_callback_user_data = Unmanaged.passUnretained(part).toOpaque()
                        let chunk = Array(audio[range])
                        let outcome: PartCollector.Outcome = withExtendedLifetime(part) { () -> PartCollector.Outcome in
                            var status: Int32 = -1
                            // A chunk can fail on its own (whisper's buffers under memory
                            // pressure, say); once more with the same state before giving up.
                            for _ in 0..<2 {
                                status = chunk.withUnsafeBufferPointer { whisper_full_with_state(ctx, state, mine, $0.baseAddress, Int32($0.count)) }
                                if status == 0 || cancelFlag.isOn { break }
                            }
                            guard status == 0 else { return .failed(status) }
                            var segments: [Recording.Segment] = []
                            for s in 0..<whisper_full_n_segments_from_state(state) {
                                let t0 = Double(whisper_full_get_segment_t0_from_state(state, s)) / 100
                                let t1 = Double(whisper_full_get_segment_t1_from_state(state, s)) / 100
                                let text = String(cString: whisper_full_get_segment_text_from_state(state, s)).trimmingCharacters(in: .whitespaces)
                                guard !text.isEmpty, !Self.isNoise(text) else { continue }
                                segments.append(Recording.Segment(start: offset + t0, end: offset + t1, text: text))
                            }
                            let found = whisper_lang_str(whisper_full_lang_id_from_state(state)).map { String(cString: $0) } ?? language
                            return .done(segments, language: found)
                        }
                        collector.set(i, outcome)
                        tally.finished(i)
                    }
                }
            }
        }
        if cancelFlag.isOn { throw Problem.cancelled }
        var parts: [[Recording.Segment]] = []
        var detected = ""
        for (i, outcome) in collector.outcomes.enumerated() {
            switch outcome {
            case .some(.done(let segs, let lang)):
                parts.append(segs)
                if detected.isEmpty { detected = lang }
            case .some(.failed(let status)):
                let at = Double(ranges[i].lowerBound) / Double(Recorder.modelRate)
                throw Problem(ranges.count > 1 ? "whisper failed (\(status)) on the part starting at \(Self.clock(at))." : "whisper failed (\(status)).")
            case .none:
                throw Problem("whisper failed.")
            }
        }
        progress(Progress(fraction: 1, chunksDone: ranges.count, chunks: ranges.count, parts: tally.allDone, atOnce: atOnce))
        return Result(segments: AudioSplit.joined(parts), language: detected, model: name)
    }

    /// "1:07:05" for 4025 s; "7:05" under an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Hands out chunk indexes in order, one to whichever worker asks next.
    final class ChunkCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        func take(_ count: Int) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            guard next < count else { return nil }
            next += 1
            return next - 1
        }
    }

    /// One part's progress, weighted into the whole's.
    final class PartProgress: @unchecked Sendable {
        let tally: ProgressTally
        let index: Int
        init(tally: ProgressTally, index: Int) { self.tally = tally; self.index = index }
        func report(_ fraction: Double) { tally.set(index, fraction) }
    }

    /// The chunks' progress: each one's own, added up by their share of the audio, and how
    /// many are finished. Reported on every change, so the window can show every chunk.
    final class ProgressTally: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [ChunkProgress]
        private var done = 0
        private let weights: [Double]
        private let atOnce: Int
        private let report: @Sendable (Progress) -> Void
        init(ranges: [Range<Int>], rate: Int, atOnce: Int, report: @escaping @Sendable (Progress) -> Void) {
            let total = Double(ranges.last?.upperBound ?? 1)
            weights = ranges.map { Double($0.count) / total }
            parts = ranges.enumerated().map { i, r in
                ChunkProgress(id: i, start: Double(r.lowerBound) / Double(rate), seconds: Double(r.count) / Double(rate))
            }
            self.atOnce = atOnce
            self.report = report
        }
        /// Every chunk marked done (the end).
        var allDone: [ChunkProgress] { lock.lock(); defer { lock.unlock() }; return parts.map { var c = $0; c.state = .done; c.fraction = 1; return c } }
        /// The layout before anything runs: every chunk waiting.
        func announce() { lock.lock(); let p = current; lock.unlock(); report(p) }
        func started(_ i: Int) {
            lock.lock()
            parts[i].state = .running
            let p = current
            lock.unlock()
            report(p)
        }
        func set(_ i: Int, _ fraction: Double) {
            lock.lock()
            parts[i].fraction = max(parts[i].fraction, min(1, fraction))
            if parts[i].state == .waiting { parts[i].state = .running }
            let p = current
            lock.unlock()
            report(p)
        }
        func finished(_ i: Int) {
            lock.lock()
            parts[i].fraction = 1
            parts[i].state = .done
            done += 1
            let p = current
            lock.unlock()
            report(p)
        }
        private var current: Progress {
            Progress(fraction: zip(parts, weights).reduce(0) { $0 + $1.0.fraction * $1.1 }, chunksDone: done, chunks: parts.count, parts: parts, atOnce: atOnce)
        }
    }

    /// Each part's result, written from its own thread.
    final class PartCollector: @unchecked Sendable {
        enum Outcome { case done([Recording.Segment], language: String), failed(Int32) }
        private let lock = NSLock()
        private var slots: [Outcome?]
        private var failed = false
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ outcome: Outcome) {
            lock.lock()
            slots[i] = outcome
            if case .failed = outcome { failed = true }
            lock.unlock()
        }
        var outcomes: [Outcome?] { lock.lock(); defer { lock.unlock() }; return slots }
        /// Once a chunk has failed for good the whole will be given up: the rest are skipped
        /// rather than run for nothing.
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return failed }
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
/// imported files, and recordings recovered after a crash).
enum AudioDecoder {
    /// Read and converted a block at a time, so a two-hour file costs the memory of its 16 kHz
    /// mono samples (about 460 MB) and one block, not of the whole file as recorded (a 48 kHz
    /// stereo WAV of two hours is 2.7 GB as floats).
    static let blockFrames: AVAudioFrameCount = 1 << 16

    /// `stopped` is asked between blocks; when it says so the decode ends with `Problem.cancelled`.
    static func pcm16k(_ url: URL, stopped: () -> Bool = { false }) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Recorder.modelRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw WhisperTranscriber.Problem("The audio file's format can't be read.")
        }
        guard file.length > 0 else { throw WhisperTranscriber.Problem("The audio file is empty.") }
        let ratio = Double(Recorder.modelRate) / file.processingFormat.sampleRate
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * ratio) + 1024)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(blockFrames) * ratio) + 1024) else {
            throw WhisperTranscriber.Problem("The audio file is empty.")
        }
        var atEnd = false
        while !atEnd {
            if stopped() { throw WhisperTranscriber.Problem.cancelled }
            try file.read(into: input, frameCount: blockFrames)
            if input.frameLength == 0 { break }
            atEnd = file.framePosition >= file.length
            // The converter pulls the block once, then is told to wait for the next (or that
            // the file has ended, so it lets out what its resampler still holds). It is asked
            // again while it fills the output to the brim, in case a block makes more than fits.
            var consumed = false
            var status = AVAudioConverterOutputStatus.haveData
            repeat {
                var error: NSError?
                output.frameLength = 0
                status = converter.convert(to: output, error: &error) { _, outStatus in
                    if consumed { outStatus.pointee = atEnd ? .endOfStream : .noDataNow; return nil }
                    consumed = true
                    outStatus.pointee = .haveData
                    return input
                }
                if let error { throw error }
                if let data = output.floatChannelData, output.frameLength > 0 {
                    out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
                }
                if status == .error { throw WhisperTranscriber.Problem("The audio file's format can't be read.") }
            } while status == .haveData && output.frameLength == output.frameCapacity
            if status == .endOfStream { break }
        }
        return out
    }

    /// The file's length in seconds.
    static func duration(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
