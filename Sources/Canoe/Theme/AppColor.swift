import AppKit
import SwiftUI

/// Semantic color tokens used across the app, aligned with the GitHub Primer
/// visual language: a blue accent, green primary actions, and scale-based
/// status/method colors that adapt between light and dark appearances.
enum AppColor {
    // MARK: - Brand (Primer accent)

    /// Primary brand blue for links, the active tab underline, and key icons.
    /// Primer `accent.fg`: #0969da in light mode, #1f6feb in dark mode.
    static let accent = dynamic(light: RGB(red: 9, green: 105, blue: 218), dark: RGB(red: 31, green: 111, blue: 235))

    /// Deeper brand blue for the bottom edge of brand gradients.
    static let accentDark = dynamic(light: RGB(red: 5, green: 80, blue: 174), dark: RGB(red: 17, green: 88, blue: 199))

    // MARK: - Actions

    /// Bright green for the top edge of primary-button gradients.
    /// Primer `success.emphasis` hover step: #2da44e (light) / #2ea043 (dark).
    static let successBright = dynamic(light: RGB(red: 45, green: 164, blue: 78), dark: RGB(red: 46, green: 160, blue: 67))

    // MARK: - Status

    /// Primer `success.fg`: #1a7f37 (light) / #3fb950 (dark).
    static let success = dynamic(light: RGB(red: 26, green: 127, blue: 55), dark: RGB(red: 63, green: 185, blue: 80))

    /// Primer `danger.fg`: #d1242c (light) / #f85149 (dark).
    static let error = dynamic(light: RGB(red: 209, green: 36, blue: 44), dark: RGB(red: 248, green: 81, blue: 73))

    /// Primer `attention.fg`: #9a6700 (light) / #d29922 (dark).
    static let warning = dynamic(light: RGB(red: 154, green: 103, blue: 0), dark: RGB(red: 210, green: 153, blue: 34))

    /// Primer `done.fg`: #8250df (light) / #bc8cff (dark).
    static let done = dynamic(light: RGB(red: 130, green: 80, blue: 223), dark: RGB(red: 188, green: 140, blue: 255))

    /// Primer `neutral.emphasis`: #59636e (light) / #818b98 (dark).
    static let neutral = dynamic(light: RGB(red: 89, green: 99, blue: 110), dark: RGB(red: 129, green: 139, blue: 152))

    static let info: Color = accent

    // MARK: - Syntax highlighting (JSON first, more languages later)

    /// Object keys.
    static let syntaxKey = dynamic(light: RGB(red: 5, green: 80, blue: 174), dark: RGB(red: 121, green: 192, blue: 255))

    /// String values.
    static let syntaxString = dynamic(light: RGB(red: 10, green: 48, blue: 105), dark: RGB(red: 165, green: 214, blue: 255))

    /// Numbers.
    static let syntaxNumber = dynamic(light: RGB(red: 130, green: 80, blue: 223), dark: RGB(red: 210, green: 168, blue: 255))

    /// `true` / `false` / `null`.
    static let syntaxKeyword = dynamic(light: RGB(red: 207, green: 34, blue: 46), dark: RGB(red: 255, green: 123, blue: 114))

    // MARK: - Backgrounds

    static let codeBackground: Color = Color(nsColor: .textBackgroundColor)
    static let controlBackground: Color = Color(nsColor: .controlBackgroundColor)
    /// Postman-style sidebar fill: light gray in light mode, charcoal in
    /// dark mode - always a visible step away from the center content.
    static let sidebarBackground: Color = dynamic(
        light: RGB(red: 245, green: 245, blue: 245),
        dark: RGB(red: 37, green: 37, blue: 38)
    )
    static let subtleBackground: Color = Color.secondary.opacity(0.10)
    static let selectionBackground: Color = Color.accentColor.opacity(0.14)

    /// Border/hairline tokens for cards, tables, and popups. One scale so
    /// strokes stay consistent across appearances instead of scattering
    /// ad-hoc `Color.primary.opacity(...)` values through views.
    static let borderStrong: Color = Color.primary.opacity(0.16)
    static let border: Color = Color.primary.opacity(0.12)
    static let hairline: Color = Color.primary.opacity(0.08)

    /// Tab-strip fills. The selected tab is a hueless neutral gray one step
    /// stronger than hover, so selection never tints the method colors inside
    /// the tab and stays independent of the user's system accent color.
    static let tabActiveBackground: Color = Color.primary.opacity(0.08)
    static let tabHoverBackground: Color = Color.primary.opacity(0.05)

    /// Hairline for the sidebar tree indent guides (adapts to appearance).
    static let treeGuide: Color = Color(nsColor: .separatorColor)

    static func badgeBackground(_ color: Color) -> Color {
        color.opacity(0.12)
    }

    // MARK: - Status code buckets

    static func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: success
        case 300..<400: accent
        case 400..<500: warning
        case 500..<600: error
        default: .secondary
        }
    }

    // MARK: - Helpers

    /// An sRGB triple in the 0...255 range.
    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int

        var nsColor: NSColor {
            NSColor(
                red: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        }
    }

    private static func dynamic(light: RGB, dark: RGB) -> Color {
        let lightColor = light.nsColor
        let darkColor = dark.nsColor
        let dynamic = NSColor(
            name: nil,
            dynamicProvider: { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor }
        )
        return Color(nsColor: dynamic)
    }
}
