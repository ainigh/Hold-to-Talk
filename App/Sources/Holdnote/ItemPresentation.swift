import Harness
import SwiftUI

/// How an item of the stream is presented, whatever it came from. An item is text with a date;
/// some items also have audio. Where an item came from (a hold, voice detection, an imported
/// file, a paste, a drop, a spoken answer) is kept in the data and is a decision of its own
/// here: the axes below are the only place the window asks. See VFD.md, group "Items".
enum ItemPresentation {
    /// Axis `item.origin-mark`: whether the row and header say where an item came from.
    /// `silent`°: nothing anywhere. `tooltip` (shipped): nothing in sight; the header's tooltip
    /// names it. `word`: a quiet word after the time ("heard", "imported", "pasted") as well.
    enum OriginMark: String, CaseIterable { case silent, tooltip, word }
    static let originMark: OriginMark = .tooltip

    /// Axis `item.edited-mark`: "edited" after the time when your text differs from the
    /// machine's. `word` (shipped), `silent`°.
    enum EditedMark: String, CaseIterable { case word, silent }
    static let editedMark: EditedMark = .word
    static func editedWord(of r: Recording) -> String? { editedMark == .word && r.isEdited ? "edited" : nil }

    /// Axis `item.measure`: what the row and header say about an item's size.
    /// `durationOrWords` (shipped): the audio's length when there is audio, else the word
    /// count, so every item has one measure in the same place. `both`: duration and words.
    /// `none`.
    enum Measure: String, CaseIterable { case durationOrWords, both, none }
    static let measure: Measure = .durationOrWords

    /// The measure for `r`, by the `item.measure` axis; nil for none. Keys on `hadAudio`: a
    /// recording whose audio was deleted still has a length, and that is still its measure.
    static func measure(of r: Recording) -> String? {
        let words = TranscriptText.wordCount(r.text)
        let wordText = "\(words.formatted()) word\(words == 1 ? "" : "s")"
        switch measure {
        case .none: return nil
        case .durationOrWords: return r.hadAudio ? TranscriptText.duration(r.duration) : wordText
        case .both: return r.hadAudio ? "\(TranscriptText.duration(r.duration)) · \(wordText)" : wordText
        }
    }

    /// The origin words for `r`, by the `item.origin-mark` axis; empty when silent.
    static func originWords(of r: Recording) -> [String] {
        guard originMark == .word else { return [] }
        var out: [String] = []
        if r.sessionID != nil { out.append("heard") }
        if r.sourceDevice?.hasPrefix("Imported") == true { out.append("imported") }
        else if !r.hadAudio { out.append("pasted") }
        return out
    }

    /// Where it came from, for the header's tooltip; nil when the axis is `silent`.
    static func origin(of r: Recording) -> String? {
        guard originMark != .silent else { return nil }
        if let device = r.sourceDevice { return device }
        return r.hasAudio ? "Recorded" : "Text"
    }
}
