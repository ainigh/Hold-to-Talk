import Foundation

/// What Settings holds. Stored as JSON by the app; defaults are the spec's.
public struct Settings: Codable, Equatable, Sendable {
    public enum Hotkey: String, Codable, CaseIterable, Sendable {
        /// The Fn (globe) key.
        case fn
        /// The right Option key (for keyboards whose Fn sends no event).
        case rightOption
        /// Control-Option-Space (any keyboard).
        case controlOptionSpace

        public var title: String {
            switch self {
            case .fn: "Fn (globe) key"
            case .rightOption: "Right Option key"
            case .controlOptionSpace: "⌃⌥Space"
            }
        }

        /// How the HUD and the empty state name it.
        public var glyph: String {
            switch self {
            case .fn: "fn"
            case .rightOption: "⌥"
            case .controlOptionSpace: "⌃⌥␣"
            }
        }
    }

    public var hotkey: Hotkey = .fn
    public var launchAtLogin = false
    public var sounds = true
    /// The whisper model's name (ggml-<name>.bin).
    public var model = "large-v3-turbo"
    /// ISO language code, or "auto".
    public var language = "auto"
    /// Names, products and terms the transcriber should spell your way.
    public var vocabulary: [String] = []
    public var removeFillers = false
    /// Copy all puts a date line above each transcript.
    public var copyAllHeaders = true
    /// Audio older than this many days is deleted (0: kept).
    public var deleteAudioAfterDays = 0
    /// The input device's unique ID, or nil for the system default.
    public var inputDeviceID: String?
    /// Long audio is transcribed in this many parts at once: 0 for automatic, 1 for never.
    public var parallelParts = 0
    /// How the list is ordered: by date in day sections, or in the order you dragged it into.
    public enum ListOrder: String, Codable, CaseIterable, Sendable { case newestFirst, custom }
    public var listOrder: ListOrder = .newestFirst

    public init() {}

    /// A settings file from an older version has no key for anything added since; each missing
    /// one keeps its default rather than failing the whole file (which would reset everything).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? hotkey
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? sounds
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? vocabulary
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? removeFillers
        copyAllHeaders = try c.decodeIfPresent(Bool.self, forKey: .copyAllHeaders) ?? copyAllHeaders
        deleteAudioAfterDays = try c.decodeIfPresent(Int.self, forKey: .deleteAudioAfterDays) ?? deleteAudioAfterDays
        inputDeviceID = try c.decodeIfPresent(String.self, forKey: .inputDeviceID)
        parallelParts = try c.decodeIfPresent(Int.self, forKey: .parallelParts) ?? parallelParts
        listOrder = (try? c.decodeIfPresent(ListOrder.self, forKey: .listOrder)) ?? listOrder
    }

    /// Models the app offers, with what to expect of each (sizes from whisper.cpp's downloads).
    public static let models: [(name: String, title: String)] = [
        ("large-v3-turbo", "Large v3 turbo · best accuracy, 1.6 GB"),
        ("medium.en", "Medium (English) · 1.5 GB"),
        ("small", "Small · quick, 0.5 GB"),
        ("base.en", "Base (English) · 0.15 GB, for a first try"),
    ]

    /// Languages for the pin list (whisper's codes).
    public static let languages: [(code: String, title: String)] = [
        ("auto", "Detect automatically"), ("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("sv", "Swedish"), ("da", "Danish"), ("nb", "Norwegian"),
        ("fi", "Finnish"), ("pl", "Polish"), ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("ar", "Arabic"),
        ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]
}

/// What macOS does with the Fn key (System Settings → Keyboard → "Press 🌐 key to"), read from
/// `com.apple.HIToolbox AppleFnUsageType`. The app needs "Do Nothing", else the key also opens
/// the emoji picker or starts Dictation.
public enum FnUsage: Int, Sendable {
    case doNothing = 0
    case changeInputSource = 1
    case showEmoji = 2
    case startDictation = 3

    public init(raw: Int?) {
        // Unset means macOS's default, which on recent versions is the emoji picker.
        self = raw.flatMap(FnUsage.init(rawValue:)) ?? .showEmoji
    }

    public var title: String {
        switch self {
        case .doNothing: "Do Nothing"
        case .changeInputSource: "Change Input Source"
        case .showEmoji: "Show Emoji & Symbols"
        case .startDictation: "Start Dictation"
        }
    }

    public var isFine: Bool { self == .doNothing }
}
