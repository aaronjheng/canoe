import AppKit
import SwiftUI

/// Semantic color tokens used across the app, aligned with the GitHub Primer
/// visual language: a blue accent, Primer status/method colors, and scale-
/// based fills that adapt between light and dark appearances.
///
/// Light/dark correspondence
/// =========================
/// Every surface token carries a light and a dark value, and the two sides
/// mirror each other. Surface map: `primaryBackground` is the window chrome
/// (top bar, sidebar, tab strip, side inspectors); `controlBackground` is the
/// content layer (center panes, status bar, boxed fields, popup cards);
/// `pillBackground`-style elements and the field lift tiers sit above the
/// surface they belong to.
///
/// - Polarity mirrors: light content is white against the #F9F9F9 chrome;
///   dark content is #212121 under the #262626 chrome. A surface steps away
///   from the content on the side its appearance dictates - the table header
///   is darker than white content in light and lighter than dark content in
///   dark.
/// - Compare steps in perceptual lightness (CIE L*), not RGB distance: the
///   same RGB delta reads several times stronger at the dark end. Current
///   bands (dark/light ΔL* ratio): the shared-alpha wash family ~1.1-1.2,
///   the field lift steps and table header ~1.1-1.5. Keep new values inside
///   that band or one appearance will feel foreign.
/// - Reuse the rungs: chrome #F9F9F9 / #262626 (the table header shares it by
///   design), content #FFFFFF / #212121, dark field lift #2E2E2E (hover) and
///   #303030 (focus).
/// - Primer brand/status/syntax colors are fixed light/dark pairs. Their
///   per-appearance contrast differs by design - that is Primer's palette,
///   not a tuning mistake; don't hand-tune them toward equal contrast.
/// - Text tiers mirror the same way: `textPrimary` (#212121 / #E8E8E8) and
///   `textSecondary` (#6B6B6B / #9E9E9E) hold roughly equal contrast steps
///   against the content layer in both appearances.
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

    // MARK: - Text

    /// Primary text tier, for body copy, names, and values.
    static let textPrimary = dynamic(
        light: RGB(red: 33, green: 33, blue: 33),
        dark: RGB(red: 232, green: 232, blue: 232)
    )
    /// Secondary text tier, for descriptions, meta, and placeholders.
    static let textSecondary = dynamic(
        light: RGB(red: 107, green: 107, blue: 107),
        dark: RGB(red: 158, green: 158, blue: 158)
    )

    // MARK: - Syntax highlighting (JSON first, more languages later)

    /// Object keys.
    static let syntaxKey = dynamic(light: RGB(red: 5, green: 80, blue: 174), dark: RGB(red: 121, green: 192, blue: 255))

    /// String values.
    static let syntaxString = dynamic(light: RGB(red: 10, green: 48, blue: 105), dark: RGB(red: 165, green: 214, blue: 255))

    /// Numbers.
    static let syntaxNumber = dynamic(light: RGB(red: 130, green: 80, blue: 223), dark: RGB(red: 210, green: 168, blue: 255))

    /// `true` / `false` / `null`.
    static let syntaxKeyword = dynamic(light: RGB(red: 207, green: 34, blue: 46), dark: RGB(red: 255, green: 123, blue: 114))

    /// Plain (untokenized) source in a highlighted body. Aliases
    /// `textSecondary`, so unhighlighted text reads as exactly the same
    /// text tier as the rest of the app - the AppKit editors and the
    /// highlighter used to pick their own label colors per leaf.
    static let syntaxPlain: Color = textSecondary

    /// AppKit twin of `textPrimary` for the custom `NSTextView` editors (the
    /// highlighter and the text view must agree). Token-mediated so a
    /// retheme reaches the editors too; dynamic, so it follows the
    /// appearance like every other color here.
    static let textPrimaryNS: NSColor = dynamicNS(
        light: RGB(red: 33, green: 33, blue: 33),
        dark: RGB(red: 232, green: 232, blue: 232)
    )

    // MARK: - Backgrounds

    /// Code / response-body surfaces. Tracks `controlBackground`: both are
    /// the app's content layer.
    static let codeBackground = dynamic(
        light: RGB(red: 255, green: 255, blue: 255),
        dark: RGB(red: 33, green: 33, blue: 33)
    )
    /// The app's content layer: center panes, the status bar, boxed fields,
    /// and floating popup cards. White in light mode; the fixed #212121 in
    /// dark - one neutral step below the window chrome.
    static let controlBackground = dynamic(
        light: RGB(red: 255, green: 255, blue: 255),
        dark: RGB(red: 33, green: 33, blue: 33)
    )
    /// Barely-there wash for borderless input fields (the variable editors).
    static let fieldBackground: Color = Color.primary.opacity(0.03)
    /// Hover fill for inputs: one luminance step brighter than the idle
    /// wash (toward white in light mode, a charcoal step up in dark).
    static let fieldHoverBackground: Color = dynamic(
        light: RGB(red: 255, green: 255, blue: 255),
        dark: RGB(red: 46, green: 46, blue: 46)
    )
    static let fieldHoverBorder: Color = Color.primary.opacity(0.24)
    /// Focus fill for inputs: the brightest raised surface - every focused
    /// field reads the same whether it started as a wash or a clear pill.
    /// The dark values keep the lift steps in the same perceptual band as
    /// light's (~3 L* points), with the accent border carrying the emphasis.
    static let fieldFocusBackground: Color = dynamic(
        light: RGB(red: 255, green: 255, blue: 255),
        dark: RGB(red: 48, green: 48, blue: 48)
    )
    /// Column-header fill for the variables tables: the chrome tone in both
    /// appearances - #F9F9F9 in light, #262626 in dark - so the header reads
    /// as the same subtle step above the content layer in either mode.
    static let tableHeaderBackground: Color = dynamic(
        light: RGB(red: 249, green: 249, blue: 249),
        dark: RGB(red: 38, green: 38, blue: 38)
    )
    /// Primary window-chrome fill (#F9F9F9 in light mode): the fixed gray
    /// surface every framing panel shares - top bar, sidebar, tab strip,
    /// and the side inspectors - so the app reads as one continuous frame
    /// a visible step away from the center content. Neutral #262626 dark.
    static let primaryBackground: Color = dynamic(
        light: RGB(red: 249, green: 249, blue: 249),
        dark: RGB(red: 38, green: 38, blue: 38)
    )
    /// AppKit twin of `controlBackground` for `NSWindow.backgroundColor`:
    /// the detail/content column has no background of its own and shows the
    /// window fill, so an explicit content-layer color keeps the system's
    /// desktop-tinted window background from bleeding through in dark mode.
    static let controlBackgroundNS: NSColor = dynamicNS(
        light: RGB(red: 255, green: 255, blue: 255),
        dark: RGB(red: 33, green: 33, blue: 33)
    )
    /// Hover wash for inline rows / text controls (tree rows, method
    /// picker, link labels). Icon chrome uses `tabHoverBackground` instead
    /// - see the hover-language note at the top of `Components/Buttons.swift`.
    static let subtleBackground: Color = Color.secondary.opacity(0.10)

    /// Quietest text tier: zero counts and placeholder meta that should
    /// recede behind `.secondary` without vanishing (the label tier's
    /// third emphasis step).
    static let tertiaryText: Color = Color(nsColor: .tertiaryLabelColor)

    /// Selected-row fill. A hueless neutral (not the app accent, not the
    /// system accentColor) so selection never competes with the method colors
    /// inside the row. Light #E6E6E6; the dark #333333 holds the same
    /// perceptual step above the #262626 chrome.
    static let selectionBackground: Color = dynamic(
        light: RGB(red: 230, green: 230, blue: 230),
        dark: RGB(red: 51, green: 51, blue: 51)
    )

    /// Selected-row fill under the pointer: one further L* step than
    /// `selectionBackground`, so a selected row still deepens on hover.
    static let selectionHoverBackground: Color = dynamic(
        light: RGB(red: 223, green: 223, blue: 223),
        dark: RGB(red: 56, green: 56, blue: 56)
    )

    /// Border/hairline tokens for cards, tables, and popups. One scale so
    /// strokes stay consistent across appearances instead of scattering
    /// ad-hoc `Color.primary.opacity(...)` values through views.
    static let borderStrong: Color = Color.primary.opacity(0.16)
    static let border: Color = Color.primary.opacity(0.12)
    static let hairline: Color = Color.primary.opacity(0.08)

    /// URL bar rest outline: fixed #A6A6A6 in both appearances, stronger
    /// than `borderStrong` so the bar reads as one unit on the content
    /// surface now that its idle fill is clear.
    static let urlBarBorder = Color(red: 166 / 255, green: 166 / 255, blue: 166 / 255)

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

    /// Border for a destructive control: the error hue stepped well back,
    /// so a "Delete" button reads as an alert edge rather than a filled
    /// alert. Derived from the dynamic `error`, so it follows the
    /// appearance like every other token here.
    static let destructiveBorder: Color = error.opacity(0.55)

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

    /// Fill for a selectable row in a hand-drawn list (the sidebar's
    /// collection / folder / request / environment rows and the workspaces
    /// list): selected wins, a selected row still lifts one step on hover,
    /// an idle row gets the subtle hover wash, otherwise nothing.
    static func rowFill(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected {
            return isHovering ? selectionHoverBackground : selectionBackground
        }
        return isHovering ? subtleBackground : .clear
    }

    private static func dynamic(light: RGB, dark: RGB) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark))
    }

    private static func dynamicNS(light: RGB, dark: RGB) -> NSColor {
        let lightColor = light.nsColor
        let darkColor = dark.nsColor
        return NSColor(
            name: nil,
            dynamicProvider: { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor }
        )
    }
}
