import Foundation

/// The app-level configuration schema, persisted as a whole in `settings.json`.
/// UI state (split positions, panel sizes) is deliberately not here — that
/// stays in `UserDefaults`, owned by AppKit.
struct AppSettings: Codable, Equatable {
    /// `AppAppearance` raw value. The enum mapping lives with the callers so
    /// `Theme` never depends on this area.
    var appearance: Int = 0
}
