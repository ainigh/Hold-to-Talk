import Foundation

/// Turns presses of the hotkey into recordings, with the timing the spec fixes:
///
/// - A press held for 250 ms starts a recording; releasing stops it. Shorter presses are the
///   key's normal use (Fn+arrow, right-Option+letter) and do nothing.
/// - A recording shorter than 1.5 s from the press is an accident: it stops and is discarded.
/// - Two quick taps (the second press within 350 ms of the first release) lock a recording on,
///   hands-free; the next tap stops it. A locked recording stops itself at the lock limit.
///
/// Feed it `pressed`, `released` and `tick` with the clock's time; each gives back what to do.
/// Pure and synchronous, so the timings are tested without a keyboard.
public struct HoldGesture: Sendable {
    public enum Action: Equatable, Sendable {
        /// Open the microphone and start recording (`locked`: hands-free, no key held).
        case start(locked: Bool)
        /// Stop recording. `keep` is false for an accidental press: discard what was recorded.
        case stop(keep: Bool)
    }

    public enum State: Equatable, Sendable {
        case idle
        /// The key is down; not long enough yet to be a hold.
        case pressed(since: TimeInterval)
        /// Recording while the key is held.
        case holding(since: TimeInterval)
        /// Recording hands-free. `stopping`: the tap that stops it has been pressed, not yet released.
        case locked(since: TimeInterval, stopping: Bool)
    }

    public struct Timing: Equatable, Sendable {
        /// How long a press must last before it is a hold.
        public var holdDelay: TimeInterval = 0.25
        /// A recording shorter than this (from the press) is discarded.
        public var minimumLength: TimeInterval = 1.5
        /// A second press within this of the first release locks the recording on.
        public var doubleTap: TimeInterval = 0.35
        /// A locked recording stops itself here.
        public var lockLimit: TimeInterval = 2 * 3600

        public init() {}
    }

    public private(set) var state: State = .idle
    public let timing: Timing
    /// When the last short tap ended (the first half of a possible double tap).
    private var lastTapRelease: TimeInterval?

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    public var isRecording: Bool {
        switch state {
        case .holding, .locked: true
        default: false
        }
    }

    public var isLocked: Bool {
        if case .locked = state { return true }
        return false
    }

    /// When the recording started, if one is going.
    public var recordingSince: TimeInterval? {
        switch state {
        case let .holding(since), let .locked(since, _): since
        default: nil
        }
    }

    public mutating func pressed(at t: TimeInterval) -> [Action] {
        switch state {
        case .idle:
            if let last = lastTapRelease, t - last <= timing.doubleTap {
                // The second tap of a double tap: locked from its press. Its release is not a stop.
                lastTapRelease = nil
                state = .locked(since: t, stopping: false)
                return [.start(locked: true)]
            }
            state = .pressed(since: t)
            return []
        case let .locked(since, _):
            state = .locked(since: since, stopping: true)
            return []
        case .pressed, .holding:
            return []
        }
    }

    public mutating func released(at t: TimeInterval) -> [Action] {
        switch state {
        case .idle:
            return []
        case let .pressed(since):
            lastTapRelease = nil
            state = .idle
            // A hold the tick had not yet noticed still counts as one.
            if t - since >= timing.holdDelay {
                return [.start(locked: false), .stop(keep: t - since >= timing.minimumLength)]
            }
            lastTapRelease = t
            return []
        case let .holding(since):
            state = .idle
            return [.stop(keep: t - since >= timing.minimumLength)]
        case let .locked(since, stopping):
            guard stopping else { return [] }
            state = .idle
            return [.stop(keep: t - since >= timing.minimumLength)]
        }
    }

    /// Call often (every 50 ms or so) while a key is down: a press that has lasted long enough
    /// becomes a hold, and a locked recording that has reached its limit stops.
    public mutating func tick(at t: TimeInterval) -> [Action] {
        switch state {
        case let .pressed(since) where t - since >= timing.holdDelay:
            state = .holding(since: since)
            lastTapRelease = nil
            return [.start(locked: false)]
        case let .locked(since, _) where t - since >= timing.lockLimit:
            state = .idle
            return [.stop(keep: true)]
        default:
            return []
        }
    }

    /// Something else stopped the recording (the Mac slept, the microphone went away): back to idle.
    public mutating func reset() {
        state = .idle
        lastTapRelease = nil
    }
}
