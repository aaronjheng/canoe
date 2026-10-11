import AppKit

/// The appearance axis of theming: follow the system, or force light/dark.
///
/// Appearance is one of two independent theming axes — it decides *which side
/// is active*; the `Palette` for that side (see `Theme/Palette.swift`) decides
/// what it looks like. Today the palettes are fixed; when selectable themes
/// land, this type keeps its role unchanged.
enum AppAppearance: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    var name: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func applyToWindow(_ window: NSWindow) {
        window.appearance = nsAppearance
    }
}
