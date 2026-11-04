import Foundation
import Harness
import Observation

/// The harness's settings, not SwiftUI's `Settings` scene.
typealias Settings = Harness.Settings

/// The settings, kept as JSON in UserDefaults and saved on every change.
@MainActor
@Observable
final class SettingsStore {
    private static let key = "settings"

    var settings: Settings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        } else {
            settings = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
