import AppKit
import Harness
import SwiftUI

/// What can sit beside a text (KINDS.md, the Text kind): the reader's take on it, its questions
/// for you, what the lenses noticed in it, the conversation about it, its words, or nothing.
/// One choice, remembered across every text; a text that cannot offer the choice shows the
/// first it can.
enum SidePanel: String, CaseIterable, Identifiable {
    case reader, forYou, noticed, ask, words, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reader: "Reader"
        case .forYou: "For you"
        case .noticed: "Noticed"
        case .ask: "Ask"
        case .words: "Words"
        case .none: "Text only"
        }
    }
    var symbol: String {
        switch self {
        case .reader: "eyeglasses"
        case .forYou: "questionmark.bubble"
        case .noticed: "text.magnifyingglass"
        case .ask: "bubble.left.and.text.bubble.right"
        case .words: "textformat.abc"
        case .none: "rectangle"
        }
    }
    var help: String {
        switch self {
        case .reader: "Everything the reader made of it: where it stands, its questions for you, what each lens noticed, and asking about it"
        case .forYou: "The questions the reader could not answer from the words alone, to answer by voice or by typing"
        case .noticed: "What each lens wrote about it"
        case .ask: "The conversation about it"
        case .words: "The words that carry its meaning (names, nouns, verbs, adjectives, adverbs), counted"
        case .none: "The text by itself"
        }
    }

    static let key = "textSidePanel"

    /// The panel a text shows for the remembered choice: the choice when the text offers it,
    /// `none` when that was chosen, else the first the text offers.
    static func shown(for stored: String, offered: [SidePanel]) -> SidePanel {
        guard let s = SidePanel(rawValue: stored) else { return offered.first ?? .none }
        return s == .none || offered.contains(s) ? s : (offered.first ?? .none)
    }
}

/// The header line every side panel starts with: its name, a meta on the right, a divider.
struct PanelHeader<Meta: View>: View {
    let panel: SidePanel
    @ViewBuilder let meta: () -> Meta

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(panel.title, systemImage: panel.symbol).font(.system(size: 13, weight: .semibold))
                Spacer()
                meta()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
        }
    }
}

/// Append, as every text you can edit has it: a new paragraph at the end, with the cursor there.
struct AppendButton: View {
    @Binding var text: String
    var editing: FocusState<Bool>.Binding

    var body: some View {
        Button {
            if !text.hasSuffix("\n\n") { text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" }
            editing.wrappedValue = true
            // The editor takes focus on the next turn of the run loop; the cursor moves then.
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSTextView.moveToEndOfDocument(_:)), to: nil, from: nil) }
        } label: { Label("Append", systemImage: "text.append") }
        .help("Add a paragraph at the end. Or hold ⌥ with the hotkey to add by voice.")
    }
}

/// The chrome every text gets, whatever the text is: a header line (what it is, its measure, the
/// side chooser), the text full width, a footer with Copy first and then the actions the data
/// allows, and the chosen side panel beside the text when there is room, under it when not.
struct TextFrame<Header: View, Content: View, Footer: View, Side: View>: View {
    /// Which side panels this text can offer, in the chooser's order.
    let offered: [SidePanel]
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let side: (SidePanel) -> Side
    @AppStorage(SidePanel.key) private var stored = SidePanel.reader.rawValue

    /// The side panel shown: the remembered one when this text offers it, else the first it does.
    private var chosen: SidePanel { SidePanel.shown(for: stored, offered: offered) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 660
            let panel = chosen
            if panel != .none, wide {
                HStack(spacing: 0) {
                    text
                    Divider()
                    side(panel).frame(width: min(360, max(280, geo.size.width * 0.35)))
                }
            } else if panel != .none {
                VSplitView {
                    text.frame(minHeight: 200)
                    side(panel).frame(minHeight: 160, idealHeight: 280)
                }
            } else {
                text
            }
        }
    }

    private var text: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                header()
                Spacer(minLength: 8)
                SideChooser(offered: offered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            content()
            Divider()
            HStack(spacing: 10) { footer() }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The side chooser: a menu naming what is beside the text now, listing what this text offers.
struct SideChooser: View {
    let offered: [SidePanel]
    @AppStorage(SidePanel.key) private var stored = SidePanel.reader.rawValue

    private var current: SidePanel { SidePanel.shown(for: stored, offered: offered) }

    var body: some View {
        Menu {
            ForEach(offered + [.none]) { p in
                Button {
                    stored = p.rawValue
                } label: {
                    if p == current { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                }
            }
        } label: {
            Label(current == .none ? "Beside: nothing" : "Beside: \(current.title)", systemImage: current.symbol)
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("What sits beside the text: \((offered + [.none]).map { "\($0.title) (\($0.help.prefix(1).lowercased() + $0.help.dropFirst()))" }.joined(separator: "; ")). The same choice for every text; one that can't offer it shows the first it can.")
    }
}

/// Copy, as every text's footer starts with it: the text to the clipboard, and "Copied" for a moment.
struct CopyButton: View {
    let text: String
    /// The shortcut named in the help, e.g. "⌘⇧C".
    var shortcut = ""
    let copy: (String) -> Void
    @State private var copied = false
    @State private var generation = 0

    var body: some View {
        Button {
            copy(text)
            copied = true
            generation += 1
            let g = generation
            Task { try? await Task.sleep(for: .milliseconds(1200)); if generation == g { copied = false } }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .help("Copy the text\(shortcut.isEmpty ? "" : " (\(shortcut))")")
        .disabled(text.isEmpty)
    }
}

/// Every open question the reader has, for ALL: the For you view's list, beside the text.
struct OpenQuestionsPanel: View {
    let model: AppModel
    @StateObject private var flash = FlashState()

    private var reader: ReaderController { model.reader }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(panel: .forYou) {
                Flash(text: flash.text)
                if let gaps = reader.gaps {
                    Text(gaps.open.isEmpty ? "\(gaps.answered) answered" : "\(gaps.open.count) open").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let gap = reader.voiceAnswer { VoiceAnswerBanner(model: model, gap: gap) }
                    if let gaps = reader.gaps, !gaps.open.isEmpty {
                        ForEach(gaps.open) { gap in
                            VStack(alignment: .leading, spacing: 4) {
                                if let r = reader.origin(of: gap) {
                                    Button { model.openRecording(r.id) } label: {
                                        Label(r.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: r.hasAudio ? "waveform" : "doc.text").font(.system(size: 11))
                                    }
                                    .buttonStyle(.link)
                                }
                                GapRow(gap: gap, model: model, compact: true) { msg in if let msg { flash.show(msg) } }
                            }
                        }
                    } else {
                        Text("Nothing to ask you right now. As the reader reads, it asks here about whatever it can't place.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

/// The questions the reader keeps answered about your goals, beside the Goals text.
struct StandingQuestionsPanel: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(panel: .reader) {
                Text(model.reader.goalsState).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView {
                KeptQuestions(model: model, heading: false)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}
