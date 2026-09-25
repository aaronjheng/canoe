import AppKit
import SwiftUI

/// Semantic color tokens used across the app, aligned with the GitHub Primer
/// visual language: a blue accent, Primer status/method colors, and scale-
/// based fills that adapt between light and dark appearances.
enum AppColor {
    // MARK: - Brand (Primer accent)

    /// Primary brand blue for links, the active tab underline, and key icons.
    /// Primer `accent.fg`: #0969da in light mode, #1f6feb in dark mode.
    static let accent = dynamic(light: RGB(red: 9, green: 105, blue: 218), dark: RGB(red: 31, green: 111, blue: 235))

    /// Deeper brand blue for the bottom edge of brand gradients.
    static let accentDark = dynamic(light: RGB(red: 5, green: 80, blue: 174), dark: RGB(red: 17, green: 88, blue: 199))

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

    /// Content drawn on the brand accent (button labels, badges): always
    /// white in both appearances so accent fills stay readable.
    static let onAccent = Color.white

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
    /// Barely-there wash for borderless input fields (the variable editors).
    static let fieldBackground: Color = Color.primary.opacity(0.03)
    /// Hover fill for inputs: one luminance step brighter than the idle
    /// wash (toward white in light mode, a charcoal step up in dark).
    static let fieldHoverBackground: Color = dynamic(
        light: RGB(red: 255, green: 255, blue: 255),
        dark: RGB(red: 50, green: 50, blue: 52)
    )
    static let fieldHoverBorder: Color = Color.primary.opacity(0.24)
    /// Focus fill for inputs: the brightest raised surface - every focused
    /// field reads the same whether it started as a wash or a clear pill.
    static let fieldFocusBackground: Color = dynamic(
        light: RGB(red: 255, green: 255, blue: 255),
        dark: RGB(red: 58, green: 58, blue: 60)
    )
    /// Column-header fill for the variables tables: a fixed light gray in
    /// light mode (#F9F9F9), a matching charcoal step in dark mode.
    static let tableHeaderBackground: Color = dynamic(
        light: RGB(red: 249, green: 249, blue: 249),
        dark: RGB(red: 44, green: 44, blue: 46)
    )
    /// Primary window-chrome fill (#F9F9F9 in light mode): the fixed gray
    /// surface every framing panel shares - top bar, sidebar, tab strip,
    /// and the side inspectors - so the app reads as one continuous frame
    /// a visible step away from the center content.
    static let primaryBackground: Color = dynamic(
        light: RGB(red: 249, green: 249, blue: 249),
        dark: RGB(red: 37, green: 37, blue: 38)
    )
    /// Hover wash for inline rows / text controls (tree rows, method
    /// picker, link labels). Icon chrome uses `tabHoverBackground` instead
    /// - see the hover-language note at the top of `Components/Buttons.swift`.
    static let subtleBackground: Color = Color.secondary.opacity(0.10)

    /// Selected-row fill. Uses the app accent (not the system accentColor)
    /// so selection stays deterministic across user accent choices and
    /// never competes with the method colors inside the row.
    static let selectionBackground: Color = accent.opacity(0.14)

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
    /// Hover wash for icon chrome (toolbar glyphs, icon buttons, tab
    /// toggles). Row/text controls use `subtleBackground` instead.
    static let tabHoverBackground: Color = Color.primary.opacity(0.05)

    /// Soft shadow for floating popup cards (method dropdown, URL editor).
    static let popupShadow: Color = Color.primary.opacity(0.22)

    /// Hairline for the sidebar tree indent guides (adapts to appearance).
    static let treeGuide: Color = Color(nsColor: .separatorColor)

    static func badgeBackground(_ color: Color) -> Color {
        color.opacity(AppOpacity.badgeBackground)
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
