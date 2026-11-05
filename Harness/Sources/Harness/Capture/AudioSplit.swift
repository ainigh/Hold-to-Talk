import Foundation

/// Cuts long audio into chunks of about five minutes that are transcribed a few at a time. The
/// cuts land on the quietest moment near each even boundary, so no word is split; chunks are
/// transcribed on their own, by a small pool of workers that each take the next chunk when
/// they finish one, and their segments are put back in order with their times offset. Pure,
/// so it is tested here.
///
/// Why chunks and workers are two numbers: a two-hour file in four long parts is only as fast
/// as its slowest part, and progress crawls; the same file in 24 five-minute chunks on four
/// workers keeps every worker busy to the end, shows progress that moves, and costs the memory
/// of four whisper states rather than 24. The GPU is one device: past a few workers, more only
/// share it more thinly.
public enum AudioSplit {
    /// Audio shorter than this is never split.
    public static let minimumToSplit: TimeInterval = 120
    /// Each chunk is at least this long: whisper works in 30 s windows, and a boundary costs a
    /// little context on either side.
    public static let minimumPart: TimeInterval = 60
    /// Chunks aim for this length; a 2 h file makes 24 of them.
    public static let targetPart: TimeInterval = 300
    /// Chunks transcribed at once; past this the GPU is shared too thinly to gain.
    public static let maximumAtOnce = 8
    public static let automaticAtOnce = 4

    /// How many chunks run at once. `requested` is the setting: 0 for automatic (four), 1 for
    /// never splitting, else that many at most.
    public static func workers(requested: Int = 0) -> Int {
        requested <= 0 ? automaticAtOnce : min(maximumAtOnce, requested)
    }

    /// How many chunks to make of `seconds` of audio for `workers` running at once: enough that
    /// none is longer than `targetPart`, and at least enough to keep every worker busy, as long
    /// as each stays at least `minimumPart`. One for short audio, or when splitting is off.
    public static func parts(seconds: TimeInterval, workers: Int = automaticAtOnce) -> Int {
        guard workers > 1, seconds >= minimumToSplit else { return 1 }
        let mostAllowed = max(1, Int(seconds / minimumPart))
        let forLength = Int((seconds / targetPart).rounded(.up))
        return max(1, min(mostAllowed, max(forLength, workers)))
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

    /// The chunks' segments, in order, as one transcript. Whisper tends to hear the words at a
    /// cut twice, once at the end of one chunk and once at the start of the next, or to repeat a
    /// chunk's last line into the silence after it: a segment that says what the one before it
    /// said (bar case and punctuation) is dropped. Segments' times are already offset.
    public static func joined(_ parts: [[Recording.Segment]]) -> [Recording.Segment] {
        var out: [Recording.Segment] = []
        for part in parts {
            for segment in part {
                if let last = out.last, key(last.text) == key(segment.text), !key(segment.text).isEmpty {
                    // The same words again straddling a cut, or an echo: keep the first, but let
                    // it reach to where the repeat ended so no time goes unaccounted for.
                    out[out.count - 1].end = max(last.end, segment.end)
                    continue
                }
                out.append(segment)
            }
        }
        return out
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Root mean square of a stretch: how loud it is.
    static func loudness(_ samples: [Float], _ range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Float = 0
        for i in range { sum += samples[i] * samples[i] }
        return (sum / Float(range.count)).squareRoot()
    }
}
