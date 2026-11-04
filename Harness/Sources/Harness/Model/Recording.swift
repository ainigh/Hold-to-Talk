import Foundation

/// One voice note: its audio file, the machine's transcript and yours.
public struct Recording: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Being recorded now.
        case recording
        /// Recorded; the transcript is being made.
        case transcribing
        /// The transcript is in.
        case final
        /// The transcript could not be made (the audio is kept; Retry runs it again).
        case failed
    }

    /// A stretch of speech with its time in the audio, for playback highlighting.
    public struct Segment: Codable, Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String

        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public let id: UUID
    public var createdAt: Date
    public var duration: TimeInterval
    /// The audio file's name inside the store's Audio folder (nil once the audio was deleted).
    public var audioFile: String?
    public var sourceDevice: String?
    /// The language the transcriber found (ISO code), or nil before it ran.
    public var language: String?
    /// The transcriber's text, never edited by hand. Re-transcribing replaces it.
    public var machineText: String
    /// What the window shows and Copy copies: `machineText` plus your edits.
    public var text: String
    public var segments: [Segment]
    public var status: Status
    /// Why the transcript failed, when it did.
    public var failure: String?
    public var model: String?
    /// Set for a segment voice detection recorded (the listening session it came from).
    public var sessionID: UUID?

    public init(id: UUID = UUID(), createdAt: Date = Date(), duration: TimeInterval = 0, audioFile: String? = nil,
                sourceDevice: String? = nil, language: String? = nil, machineText: String = "", text: String = "",
                segments: [Segment] = [], status: Status = .recording, failure: String? = nil, model: String? = nil, sessionID: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.audioFile = audioFile
        self.sourceDevice = sourceDevice
        self.language = language
        self.machineText = machineText
        self.text = text
        self.segments = segments
        self.status = status
        self.failure = failure
        self.model = model
        self.sessionID = sessionID
    }

    /// Whether the text differs from what the machine wrote.
    public var isEdited: Bool { text != machineText }

    /// The list's title: the first line of the text, cut to 60 characters.
    public var title: String { TranscriptText.title(text, status: status) }

    /// Puts a new machine transcript in, keeping your edits on top of it.
    public mutating func replaceMachineText(_ newText: String, segments: [Segment], language: String?, model: String?) {
        text = isEdited ? TranscriptMerge.reapply(edits: text, from: machineText, onto: newText) : newText
        machineText = newText
        self.segments = segments
        self.language = language
        self.model = model
        status = .final
        failure = nil
    }
}
