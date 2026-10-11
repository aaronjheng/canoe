import AppKit

/// One side (light or dark) of a color theme: a complete set of surface
/// colors, wash strengths, and syntax hues.
///
/// `AppColor` resolves each semantic token by reading the slot from the
/// palette matching the active appearance, so introducing an additional theme
/// means adding another `Palette` instance and pointing the per-side lookup
/// at it — no token or call site changes. Themes organize light and dark
/// independently: a theme may declare a palette for either side.
///
/// Washes (translucent fills for hover/press/track/banner states) are stored
/// as alpha strengths over shared dynamic bases (`labelColor`, `systemRed`,
/// `systemOrange`) rather than resolved colors: the bases must keep
/// re-resolving per appearance, so `AppColor` applies the alpha at resolution
/// time. Everything else is a concrete `NSColor`.
///
/// Light/dark correspondence
/// =========================
/// The two palettes mirror each other. Surface map: `windowBackground` is the
/// window frame (titlebar strip, status bars, sheets, settings and connection
/// forms); `secondaryBackground` is the content layer (workspace sections and
/// the connection hub, tables, lists, shell history); `sidebarBackground` plus
/// `sidebarTint` is the sidebar; `pillBackground` covers pills, secondary
/// buttons and cards.
///
/// - Polarity mirrors: light content (#FFFFFF) is *lighter* than its frame
///   (#F9F9F9); dark content (#212121) is *darker* than its frame (#262626).
///   Every surface that steps "up" in light steps "down" in dark.
/// - Compare steps in perceptual lightness (CIE L*), not RGB distance: the
///   same RGB delta reads about six times stronger at the dark end. Current
///   bands: surface ladder 1.0-1.2, washes 1.5-1.9 (dark/light ΔL* ratio).
///   A wash that lands outside its band will feel foreign to one appearance.
/// - Prefer existing rungs: #F9F9F9 / #EFEFEF / #EDEDED / #FFFFFF in light,
///   #212121 / #262626 / #2C2C2C / #2E2E2E in dark. Sidebar and pill
///   deliberately share a rung in both appearances.
/// - When changing one value, check all three: its ΔL* to neighbours on the
///   same side, the dark/light ratio of the matching step, and that no two
///   surfaces collapse onto the same color (sidebar vs pill did exactly
///   that once).
/// - Deliberately *not* themed here: status/chart/TTL/shell colors and
///   `onSelection` - they stay system semantic colors, identical in both
///   appearances.
///
/// Evolution roadmap
/// =================
/// This type is step one of the theming refactor: palettes are data, tokens
/// are lookups. The remaining steps, to take when a second theme actually
/// lands:
///
/// - Theme model: a `Theme` bundles an id/name with optional per-side
///   palettes (`light: Palette?`, `dark: Palette?`); a nil side falls back to
///   the system colors that `systemLight` wraps today. Appearance
///   (system/light/dark, see `AppAppearance`) and theme stay independent
///   axes — the active side picks that side's theme palette.
/// - Settings: `AppSettings` gains per-side theme selection alongside the
///   existing `appearance` field; the View menu and the settings pane expose it.
/// - Distribution: `AppColor`'s private `paletteColor`/`paletteNSColor`/
///   `paletteWash` helpers are the only place hardwiring `systemLight` and
///   `neutralDark` — they are the seam to redirect at a theme registry. The
///   switch itself needs a re-resolution channel; the candidates, in rough
///   order of preference:
///   1. Register a custom `NSAppearance` per active light/dark pair and let
///      the dynamic providers identify the theme from the appearance they
///      receive. Reuses the machinery that already re-resolves every token
///      on light/dark switches; zero call-site changes. Cost: obscure AppKit.
///   2. Move token reads behind an observable theme object injected in the
///      environment. SwiftUI-native, but every view gains a dependency.
///   3. Rebuild window content on switch. Trivial, but resets scroll,
///      focus, and other transient state.
///
/// Adding a palette slot later is additive: extend this struct, fill both
/// existing instances, and add one token line in `AppColor`.
struct Palette {
    // MARK: Surfaces

    /// Main window/content background.
    let windowBackground: NSColor
    /// Secondary surfaces: sidebars, headers, tables, fields.
    let secondaryBackground: NSColor
    /// Raised pill/track surfaces: segmented pickers, refresh pills,
    /// dropdown labels, secondary buttons. A step above `secondaryBackground`
    /// so unselected segments stay legible instead of sinking into the track.
    let pillBackground: NSColor
    /// Code and monospace text surfaces.
    let codeBackground: NSColor
    /// Sidebar base.
    let sidebarBackground: NSColor

    // MARK: Washes (alpha strength over a shared base)

    /// Light fill for badges and secondary chrome (over `labelColor`).
    let subtleBackground: Double
    /// Track background for distribution bars and similar meters (over `labelColor`).
    let trackBackground: Double
    /// Hairline stroke for custom control chrome, button borders, panel
    /// outlines (over `labelColor`).
    let subtleBorder: Double
    /// Tint layered over the sidebar's opaque base (over `labelColor`), so the
    /// sidebar keeps a step of its own instead of echoing another surface:
    /// darker than the page in light, lighter than the content in dark.
    let sidebarTint: Double
    /// Hover wash for custom rows (over `labelColor`).
    let hoverBackground: Double
    /// Hover wash for icon buttons — stronger than `hoverBackground` so small
    /// hit areas read clearly (over `labelColor`).
    let iconHoverBackground: Double
    /// Pressed/selected fill that must stay clearly stronger than hover:
    /// toolbar button press, segmented toggle selection, unemphasized rows
    /// (over `labelColor`).
    let controlFillBackground: Double
    /// Shell output block background (over `labelColor`).
    let shellOutputBackground: Double
    /// Wash behind destructive hover/press feedback, delete buttons
    /// (over `systemRed`).
    let destructiveBackground: Double
    /// Error banner fill (over `systemRed`).
    let errorBannerBackground: Double
    /// Warning banner fill (over `systemOrange`).
    let warningBannerBackground: Double

    // MARK: Syntax highlighting

    /// Keywords: `local`, `function`, `return`, `if`
    let syntaxKey: NSColor
    /// Built-in functions & API members: `pairs`, `redis.call`
    let syntaxBuiltin: NSColor
    /// String literals
    let syntaxString: NSColor
    /// Numeric literals
    let syntaxNumber: NSColor
    /// Boolean literals & named constants: `true`, `LOG_DEBUG`
    let syntaxBool: NSColor
    /// Type-like tokens & JSON object keys
    let syntaxType: NSColor
}

extension Palette {
    /// The light side in use today: the soft #F9F9F9 page with white raised
    /// surfaces, the airy wash defaults, and lower-luminance syntax hues.
    static let systemLight = Palette(
        windowBackground: NSColor(srgbRed: 249.0 / 255.0, green: 249.0 / 255.0, blue: 249.0 / 255.0, alpha: 1),
        secondaryBackground: NSColor(srgbRed: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),
        // A step below both surfaces so pills stay readable on the #F9F9F9
        // page and on white cards alike. Tune here if the step ever reads too
        // subtle or too strong.
        pillBackground: NSColor(srgbRed: 239.0 / 255.0, green: 239.0 / 255.0, blue: 239.0 / 255.0, alpha: 1),
        codeBackground: NSColor(srgbRed: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),
        sidebarBackground: NSColor(srgbRed: 249.0 / 255.0, green: 249.0 / 255.0, blue: 249.0 / 255.0, alpha: 1),
        subtleBackground: 0.08,
        trackBackground: 0.12,
        subtleBorder: 0.12,
        sidebarTint: 0.05,
        hoverBackground: 0.06,
        iconHoverBackground: 0.08,
        controlFillBackground: 0.12,
        shellOutputBackground: 0.08,
        destructiveBackground: 0.12,
        errorBannerBackground: 0.12,
        warningBannerBackground: 0.12,
        syntaxKey: hsb(0.750, 0.50, 0.55),
        syntaxBuiltin: hsb(0.514, 0.65, 0.45),
        syntaxString: hsb(0.375, 0.55, 0.42),
        syntaxNumber: hsb(0.078, 0.70, 0.65),
        syntaxBool: hsb(0.931, 0.50, 0.60),
        syntaxType: hsb(0.597, 0.60, 0.55)
    )

    /// The dark side in use today: the flat neutral set — #262626 main,
    /// #212121 secondary, #2E2E2E pills — with stronger washes for legibility
    /// and lifted syntax hues.
    static let neutralDark = Palette(
        windowBackground: NSColor(srgbRed: 38.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0, alpha: 1),
        secondaryBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        pillBackground: NSColor(srgbRed: 46.0 / 255.0, green: 46.0 / 255.0, blue: 46.0 / 255.0, alpha: 1),
        codeBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        sidebarBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        subtleBackground: 0.12,
        trackBackground: 0.18,
        subtleBorder: 0.18,
        // White over the #212121 base lands the sidebar on ~#2C2C2C, two
        // points below the #2E2E2E pill rung - mirroring light, where the
        // sidebar sits two points below the pill too.
        sidebarTint: 0.05,
        hoverBackground: 0.10,
        iconHoverBackground: 0.13,
        controlFillBackground: 0.16,
        shellOutputBackground: 0.12,
        destructiveBackground: 0.20,
        errorBannerBackground: 0.18,
        warningBannerBackground: 0.18,
        syntaxKey: hsb(0.750, 0.40, 0.82),
        syntaxBuiltin: hsb(0.514, 0.50, 0.78),
        syntaxString: hsb(0.375, 0.42, 0.75),
        syntaxNumber: hsb(0.078, 0.58, 0.88),
        syntaxBool: hsb(0.931, 0.38, 0.82),
        syntaxType: hsb(0.597, 0.48, 0.82)
    )

    private static func hsb(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }
}
