import Foundation
import Observation

/// File-backed gateway for app-level configuration.
///
/// Owns `settings.json` next to the vault in Application Support, so
/// `AppDelegate` and the Settings panel only map between `AppSettings` and
/// live properties. Missing or corrupt files fall back to defaults; the file
/// is written on every change.
///
/// Machine-local file storage with no sync today. If sync is ever needed it
/// must be designed explicitly per item.
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var settings = AppSettings()
    private let fileURL: URL

    private init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("settings.json")
            return
        }
        let dir = appSupport.appendingPathComponent("Canoe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        load()
    }

    func load() {
        // A missing file is normal on first launch - only failures after
        // that point are worth logging.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            AppLogger.error("Failed to read settings file, using defaults", category: "Settings")
            return
        }
        do {
            settings = try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            AppLogger.error("Failed to decode settings, using defaults: \(error)", category: "Settings")
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.error("Failed to save settings: \(error)", category: "Settings")
        }
    }
}
