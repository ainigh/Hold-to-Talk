import Foundation

/// The reader's model and budgets. Every prompt is measured against `windowTokens` before it is sent.
public struct ReaderConfig: Codable, Equatable, Sendable {
    public var base = "http://localhost:11434"
    public var model = ""
    /// Prompt window, tokens (W).
    public var windowTokens = 6000
    /// Notebook cap, tokens (M).
    public var notebookTokens = 800
    public var digestTokens = 700
    public var outputTokens = 1500
    public var questionCount = 30
    public var morningSteps = 8
    public var pageTokens = 1500
    public var charsPerToken = 3.6
    public var coolOffSec = 60
    public var think = false
    /// Sentences per window (0: as many as fit).
    public var maxSentences = 0
    public var keepAwake = true
    /// Holdnote's own transcripts join the stream when a night starts.
    public var feedTranscripts = true
    /// Start a night by itself at this time of day (minutes after midnight), when set.
    public var scheduleEnabled = false
    public var scheduleMinute = 60

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = ReaderConfig()
        d.base = try c.decodeIfPresent(String.self, forKey: .base) ?? d.base
        d.model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        d.windowTokens = try c.decodeIfPresent(Int.self, forKey: .windowTokens) ?? d.windowTokens
        d.notebookTokens = try c.decodeIfPresent(Int.self, forKey: .notebookTokens) ?? d.notebookTokens
        d.digestTokens = try c.decodeIfPresent(Int.self, forKey: .digestTokens) ?? d.digestTokens
        d.outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? d.outputTokens
        d.questionCount = try c.decodeIfPresent(Int.self, forKey: .questionCount) ?? d.questionCount
        d.morningSteps = try c.decodeIfPresent(Int.self, forKey: .morningSteps) ?? d.morningSteps
        d.pageTokens = try c.decodeIfPresent(Int.self, forKey: .pageTokens) ?? d.pageTokens
        d.charsPerToken = try c.decodeIfPresent(Double.self, forKey: .charsPerToken) ?? d.charsPerToken
        d.coolOffSec = try c.decodeIfPresent(Int.self, forKey: .coolOffSec) ?? d.coolOffSec
        d.think = try c.decodeIfPresent(Bool.self, forKey: .think) ?? d.think
        d.maxSentences = try c.decodeIfPresent(Int.self, forKey: .maxSentences) ?? d.maxSentences
        d.keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
        d.feedTranscripts = try c.decodeIfPresent(Bool.self, forKey: .feedTranscripts) ?? d.feedTranscripts
        d.scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? d.scheduleEnabled
        d.scheduleMinute = try c.decodeIfPresent(Int.self, forKey: .scheduleMinute) ?? d.scheduleMinute
        self = d.clamped()
    }

    /// Ollama's context size: W plus the output cap plus a margin, so it never silently truncates.
    public var numCtx: Int { windowTokens + outputTokens + 512 }

    /// The minimums the extension enforced, applied.
    public func clamped() -> ReaderConfig {
        var c = self
        c.base = Self.normalizeBase(c.base)
        c.windowTokens = max(1000, c.windowTokens)
        c.notebookTokens = max(100, c.notebookTokens)
        c.digestTokens = max(0, c.digestTokens)
        c.outputTokens = max(200, c.outputTokens)
        c.questionCount = max(0, c.questionCount)
        c.morningSteps = max(1, c.morningSteps)
        c.pageTokens = max(200, c.pageTokens)
        c.charsPerToken = min(5, max(2, c.charsPerToken.isFinite ? c.charsPerToken : 3.6))
        c.coolOffSec = max(0, c.coolOffSec)
        c.maxSentences = max(0, c.maxSentences)
        c.scheduleMinute = min(24 * 60 - 1, max(0, c.scheduleMinute))
        return c
    }

    /// "localhost:11434/" → "http://localhost:11434".
    public static func normalizeBase(_ b: String) -> String {
        var s = b.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api") { s.removeLast(4) }
        if s.isEmpty { return "http://localhost:11434" }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        return s
    }

    /// progress.json is only valid for the window and notebook sizes it was written under.
    public var progressKey: String { "\(windowTokens):\(notebookTokens)" }
}
