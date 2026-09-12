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
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return }
        settings = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
