import Foundation

/// Ollama has no stable tokenize endpoint, so tokens are estimated from characters and
/// calibrated against the real prompt token count after each call.
public final class TokenEstimator: @unchecked Sendable {
    private let lock = NSLock()
    private var _cpt: Double

    public init(charsPerToken: Double = 3.6) { _cpt = charsPerToken }

    /// Characters per token, as currently believed.
    public var charsPerToken: Double {
        get { lock.lock(); defer { lock.unlock() }; return _cpt }
        set { lock.lock(); _cpt = max(2, min(5, newValue)); lock.unlock() }
    }

    public func estimate(_ text: String) -> Int {
        Int((Double(text.utf16.count) / charsPerToken).rounded(.up))
    }

    /// Moves toward the observed ratio, cautiously; a cached prefix can make Ollama undercount.
    public func calibrate(chars: Int, actualTokens: Int, estimatedTokens: Int) {
        guard actualTokens > 0, chars > 0, Double(actualTokens) >= Double(estimatedTokens) * 0.5 else { return }
        let observed = Double(chars) / Double(actualTokens)
        guard observed.isFinite else { return }
        lock.lock()
        _cpt = max(2.5, min(5, _cpt * 0.8 + observed * 0.2))
        lock.unlock()
    }

    /// The text cut to fit `budget` tokens.
    public func clip(_ text: String, _ budget: Int) -> (text: String, clipped: Bool) {
        let max = Swift.max(0, Int((Double(budget) * charsPerToken).rounded(.down)))
        guard text.utf16.count > max else { return (text, false) }
        let end = text.utf16.index(text.utf16.startIndex, offsetBy: max)
        // Never cut inside a character.
        var cut = String(text.utf16[..<end]) ?? ""
        if cut.isEmpty, max > 0 { cut = String(text.prefix(max / 2)) }
        return (cut, true)
    }
}
