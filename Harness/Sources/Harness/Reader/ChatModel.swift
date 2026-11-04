import Foundation

/// One streamed reply from the model.
public struct ChatReply: Sendable {
    public var text: String
    public var thinking: String
    public var promptTokens: Int
    public var outTokens: Int
    public var estTokens: Int
    public var ms: Int
    public var tokensPerSecond: Double
    /// The reply hit the output cap.
    public var truncated: Bool
    public init(text: String, thinking: String = "", promptTokens: Int = 0, outTokens: Int = 0, estTokens: Int = 0, ms: Int = 0, tokensPerSecond: Double = 0, truncated: Bool = false) {
        self.text = text; self.thinking = thinking; self.promptTokens = promptTokens; self.outTokens = outTokens
        self.estTokens = estTokens; self.ms = ms; self.tokensPerSecond = tokensPerSecond; self.truncated = truncated
    }
}

/// What one call needs. `onToken(content, thinking)` is told the whole reply so far as it streams.
public struct ChatRequest: Sendable {
    public var system: String
    public var user: String
    public var label: String
    public var onToken: (@Sendable (String, String) -> Void)?
    public init(system: String, user: String, label: String = "", onToken: (@Sendable (String, String) -> Void)? = nil) {
        self.system = system; self.user = user; self.label = label; self.onToken = onToken
    }
}

/// The model behind the night and the morning. The app's `OllamaClient` is one; tests use a fake.
/// Throws `ReaderError` (with `cancelled` set when the task was cancelled, `fatal` when retrying is pointless).
public protocol ChatModel: Sendable {
    func chat(_ request: ChatRequest, config: ReaderConfig) async throws -> ChatReply
}

/// Measures the prompt before sending and refuses if it is over the budget: the harness, not
/// Ollama, is what enforces W. Calibrates the estimator from the real prompt token count after.
public struct MeasuredChat: Sendable {
    public let model: ChatModel
    public let tokens: TokenEstimator
    public init(model: ChatModel, tokens: TokenEstimator) { self.model = model; self.tokens = tokens }

    public func call(_ request: ChatRequest, config: ReaderConfig, budget: Int) async throws -> ChatReply {
        let est = tokens.estimate(request.system) + tokens.estimate(request.user)
        if est > budget { throw ReaderError("\(request.label): prompt \(est) tokens exceeds budget \(budget)", fatal: false) }
        if Task.isCancelled { throw ReaderError.cancelled }
        var reply = try await model.chat(request, config: config)
        tokens.calibrate(chars: request.system.utf16.count + request.user.utf16.count, actualTokens: reply.promptTokens, estimatedTokens: est)
        reply.estTokens = est
        if reply.promptTokens == 0 { reply.promptTokens = est }
        reply.text = Self.stripThinking(reply.text)
        return reply
    }

    /// A thinking model whose template ignores `think: false` can still leak its reasoning into the content.
    public static func stripThinking(_ s: String) -> String {
        var out = s
        while let open = out.range(of: "<think>"), let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let close = out.range(of: "</think>") { out.removeSubrange(out.startIndex..<close.upperBound) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
