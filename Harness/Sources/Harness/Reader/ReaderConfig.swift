import Foundation

/// The reader's model and budgets. Every prompt is measured against `windowTokens` before it is sent.
public struct ReaderConfig: Codable, Equatable, Sendable {
    public var base = "http://localhost:11434"
    public var model = ""
    /// Prompt window, tokens (W).
    public var windowTokens = 6000
    /// Notebook cap per lens, tokens (M).
    public var notebookTokens = 800
    public var digestTokens = 700
    /// The most the model may write in one reply. Several lenses share one reply, so this also
    /// limits how many go into one call.
    public var outputTokens = 3000
    /// Questions about your goals the reader keeps answered.
    public var questionCount = 12
    /// Tool steps the model may take before it must answer a question.
    public var askSteps = 8
    public var pageTokens = 1500
    public var charsPerToken = 3.6
    /// A rest after every model call while reading, so a larger model runs at a sustainable temperature.
    public var coolOffSec = 20
    public var think = false
    /// Sentences read at a time (0: as many as fit). Small chunks mean new words are read soon after they are said.
    public var chunkSentences = 16
    /// Lenses in one call (0: as many as fit the window and the output cap; 1: one call per lens).
    public var lensesPerCall = 0
    public var keepAwake = true
    /// Holdnote's own transcripts join the stream by themselves once they settle.
    public var feedTranscripts = true
    /// A transcript joins once it has been final and unedited for this long.
    public var settleSeconds = 60
    /// Read by itself whenever there is something new (and nothing is being recorded or transcribed).
    public var autoRead = true
    /// A question's answer is refreshed once the stream has grown by this many sentences since.
    public var questionRefresh = 60

    public init() {}

    enum Legacy: String, CodingKey { case morningSteps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: Legacy.self)
        var d = ReaderConfig()
        d.base = try c.decodeIfPresent(String.self, forKey: .base) ?? d.base
        d.model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        d.windowTokens = try c.decodeIfPresent(Int.self, forKey: .windowTokens) ?? d.windowTokens
        d.notebookTokens = try c.decodeIfPresent(Int.self, forKey: .notebookTokens) ?? d.notebookTokens
        d.digestTokens = try c.decodeIfPresent(Int.self, forKey: .digestTokens) ?? d.digestTokens
        d.outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? d.outputTokens
        d.questionCount = try c.decodeIfPresent(Int.self, forKey: .questionCount) ?? d.questionCount
        d.askSteps = try c.decodeIfPresent(Int.self, forKey: .askSteps) ?? legacy.decodeIfPresent(Int.self, forKey: .morningSteps) ?? d.askSteps
        d.pageTokens = try c.decodeIfPresent(Int.self, forKey: .pageTokens) ?? d.pageTokens
        d.charsPerToken = try c.decodeIfPresent(Double.self, forKey: .charsPerToken) ?? d.charsPerToken
        d.coolOffSec = try c.decodeIfPresent(Int.self, forKey: .coolOffSec) ?? d.coolOffSec
        d.think = try c.decodeIfPresent(Bool.self, forKey: .think) ?? d.think
        d.chunkSentences = try c.decodeIfPresent(Int.self, forKey: .chunkSentences) ?? d.chunkSentences
        d.lensesPerCall = try c.decodeIfPresent(Int.self, forKey: .lensesPerCall) ?? d.lensesPerCall
        d.keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
        d.feedTranscripts = try c.decodeIfPresent(Bool.self, forKey: .feedTranscripts) ?? d.feedTranscripts
        d.settleSeconds = try c.decodeIfPresent(Int.self, forKey: .settleSeconds) ?? d.settleSeconds
        d.autoRead = try c.decodeIfPresent(Bool.self, forKey: .autoRead) ?? d.autoRead
        d.questionRefresh = try c.decodeIfPresent(Int.self, forKey: .questionRefresh) ?? d.questionRefresh
        self = d.clamped()
    }

    /// Ollama's context size: W plus the output cap plus a margin, so it never silently truncates.
    public var numCtx: Int { windowTokens + outputTokens + 512 }

    /// The minimums, applied.
    public func clamped() -> ReaderConfig {
        var c = self
        c.base = Self.normalizeBase(c.base)
        c.windowTokens = max(1000, c.windowTokens)
        c.notebookTokens = max(100, c.notebookTokens)
        c.digestTokens = max(0, c.digestTokens)
        c.outputTokens = max(200, c.outputTokens)
        c.questionCount = max(0, c.questionCount)
        c.askSteps = max(1, c.askSteps)
        c.pageTokens = max(200, c.pageTokens)
        c.charsPerToken = min(5, max(2, c.charsPerToken.isFinite ? c.charsPerToken : 3.6))
        c.coolOffSec = max(0, c.coolOffSec)
        c.chunkSentences = max(0, c.chunkSentences)
        c.lensesPerCall = max(0, c.lensesPerCall)
        c.settleSeconds = max(0, c.settleSeconds)
        c.questionRefresh = max(1, c.questionRefresh)
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
}
