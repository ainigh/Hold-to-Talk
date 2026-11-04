import Foundation

/// Voice detection for listening mode: fed the loudness of each short stretch of microphone
/// audio, it says when speech starts and when it has stopped, with the spec's timing: a segment
/// starts after 300 ms of speech, ends after 2 s of silence, and one shorter than 1.5 s is
/// discarded. The threshold follows the room: a slow estimate of the background level, with
/// speech being a few times louder than that. Pure and cheap, so it runs on the audio thread.
public struct VoiceActivity: Sendable {
    public struct Tuning: Equatable, Sendable {
        /// Speech must last this long before a segment starts.
        public var startAfter: TimeInterval = 0.3
        /// Silence this long ends the segment.
        public var endAfter: TimeInterval = 2.0
        /// A segment shorter than this (speech start to the silence) is discarded.
        public var minimumLength: TimeInterval = 1.5
        /// A segment is cut here whatever is happening (a long monologue becomes several).
        public var maximumLength: TimeInterval = 10 * 60
        /// Speech is at least this loud (RMS of float samples), however quiet the room.
        public var floor: Float = 0.006
        /// Speech is this many times the background level.
        public var ratio: Float = 3

        public init() {}
    }

    public enum Event: Equatable, Sendable {
        /// Speech began at `at` (a little before now: the start had to last `startAfter` first).
        case started(at: TimeInterval)
        /// The segment that began at `from` ended at `at`; `keep` is false when it was too short.
        case ended(from: TimeInterval, at: TimeInterval, keep: Bool)
    }

    public enum State: Equatable, Sendable {
        case idle
        case maybeSpeech(since: TimeInterval)
        case speech(since: TimeInterval, quietSince: TimeInterval?)
    }

    public private(set) var state: State = .idle
    /// The background level, followed slowly (quickly downwards, so a loud start doesn't hide quiet speech).
    public private(set) var background: Float?
    public let tuning: Tuning

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    public var isSpeaking: Bool {
        if case .speech = state { return true }
        return false
    }

    /// What counts as speech right now.
    public var threshold: Float { max(tuning.floor, (background ?? 0) * tuning.ratio) }

    /// Feed the RMS of the latest stretch of samples (20–100 ms of audio) at time `t`.
    public mutating func feed(rms: Float, at t: TimeInterval) -> Event? {
        let loud = rms > threshold
        // The background follows what isn't speech, and anything quieter than it at once.
        if let b = background {
            if rms < b { background = b + (rms - b) * 0.2 } else if !loud { background = b + (rms - b) * 0.02 }
        } else {
            background = rms
        }
        switch state {
        case .idle:
            if loud { state = .maybeSpeech(since: t) }
            return nil
        case let .maybeSpeech(since):
            if !loud {
                state = .idle
                return nil
            }
            if t - since >= tuning.startAfter {
                state = .speech(since: since, quietSince: nil)
                return .started(at: since)
            }
            return nil
        case let .speech(since, quietSince):
            if t - since >= tuning.maximumLength {
                state = .idle
                return .ended(from: since, at: t, keep: true)
            }
            if loud {
                state = .speech(since: since, quietSince: nil)
                return nil
            }
            let quiet = quietSince ?? t
            if t - quiet >= tuning.endAfter {
                state = .idle
                return .ended(from: since, at: quiet, keep: quiet - since >= tuning.minimumLength)
            }
            state = .speech(since: since, quietSince: quiet)
            return nil
        }
    }

    /// Listening stopped: whatever was going is over.
    public mutating func reset() {
        state = .idle
    }
}
