import Foundation

/// Cuts long audio into parts that can be transcribed at the same time. The cuts land on the
/// quietest moment near each even boundary, so no word is split; parts are transcribed on their
/// own and their segments put back in order with their times offset. Pure, so it is tested here.
public enum AudioSplit {
    /// Audio shorter than this is never split.
    public static let minimumToSplit: TimeInterval = 120
    /// Each part is at least this long: whisper works in 30 s windows, and a boundary costs a
    /// little context on either side.
    public static let minimumPart: TimeInterval = 60
    /// Parts run at once; past this the GPU is shared too thinly to gain.
    public static let maximumParts = 8
    public static let automaticParts = 4

    /// How many parts to make of `seconds` of audio. `requested` is the setting: 0 for automatic
    /// (up to four, once there's two minutes of audio), 1 for never, else that many at most.
    public static func parts(seconds: TimeInterval, requested: Int = 0) -> Int {
        let ceiling = requested <= 0 ? automaticParts : min(maximumParts, requested)
        guard ceiling > 1, seconds >= minimumToSplit else { return 1 }
        return max(1, min(ceiling, Int(seconds / minimumPart)))
    }

    /// `samples` cut into `parts` ranges that cover it all, in order, each boundary moved to the
    /// quietest `frame`-long stretch within `search` seconds of where an even cut would fall.
    public static func ranges(_ samples: [Float], rate: Int, parts: Int, search: TimeInterval = 8, frame: TimeInterval = 0.1) -> [Range<Int>] {
        let n = samples.count
        guard parts > 1, n > 0 else { return [0..<n] }
        let frameLen = max(1, Int(frame * Double(rate)))
        let reach = max(frameLen, Int(search * Double(rate)))
        var cuts: [Int] = [0]
        for k in 1..<parts {
            let ideal = n * k / parts
            let lo = max(cuts[k - 1] + frameLen, ideal - reach)
            let hi = min(n - frameLen, ideal + reach)
            var best = ideal, bestLevel = Float.greatestFiniteMagnitude
            if lo < hi {
                var start = lo
                while start + frameLen <= hi {
                    let level = loudness(samples, start..<(start + frameLen))
                    // Nearer the ideal wins a tie, so cuts spread evenly through silence.
                    if level < bestLevel || (level == bestLevel && abs(start - ideal) < abs(best - ideal)) { bestLevel = level; best = start }
                    start += frameLen
                }
                // The cut sits in the middle of the quiet stretch.
                best = min(hi, best + frameLen / 2)
            }
            cuts.append(max(cuts[k - 1], min(n, best)))
        }
        cuts.append(n)
        return (0..<parts).map { cuts[$0]..<cuts[$0 + 1] }.filter { !$0.isEmpty }
    }

    /// Root mean square of a stretch: how loud it is.
    static func loudness(_ samples: [Float], _ range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Float = 0
        for i in range { sum += samples[i] * samples[i] }
        return (sum / Float(range.count)).squareRoot()
    }
}
