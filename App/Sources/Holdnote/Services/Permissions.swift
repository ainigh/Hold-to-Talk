import AppKit
import Foundation
import Harness
import ServiceManagement

/// What the app needs from macOS before the hotkey works, and where to turn each on.
enum Permissions {
    /// The Fn key's job in System Settings → Keyboard ("Press 🌐 key to"). Read from the
    /// HIToolbox domain; nothing set means macOS's default.
    static func fnUsage() -> FnUsage {
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        let raw = defaults?.object(forKey: "AppleFnUsageType") as? Int
        return FnUsage(raw: raw)
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    /// Launch at login, through SMAppService (macOS 13+). Only an installed app can register.
    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Free space on the volume the store is on, in bytes.
    static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Under 2 GB free: no new recording (the spec's limit).
    static let minimumFreeSpace: Int64 = 2_000_000_000
}
