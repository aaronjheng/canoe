import AppKit
import SwiftUI

/// Plume's chrome seam: the ONLY place the editor files (`Editor*`,
/// `SyntaxHighlight`, `EditorFont`, `EditorButtons`) read the host's theme.
/// Every token is a settable static with a neutral system default; a host
/// assigns its own values once at app launch (before any editor renders)
/// and never touches them again. The tokens are dynamic colors throughout,
/// so light/dark switching keeps working after the one-time install.
///
/// Keep the set closed: a token missing from this list is a boundary
/// violation, not a reason to reach for the host's theme types directly.
public enum EditorTheme {
    // MARK: Semantic colors

    nonisolated(unsafe) public static var accent: Color = .accentColor
    nonisolated(unsafe) public static var success: Color = .green
    nonisolated(unsafe) public static var error: Color = .red
    nonisolated(unsafe) public static var warning: Color = .orange
    nonisolated(unsafe) public static var textPrimary: Color = .primary
    nonisolated(unsafe) public static var textSecondary: Color = .secondary
    nonisolated(unsafe) public static var tertiaryText: Color = Color(nsColor: .tertiaryLabelColor)
    nonisolated(unsafe) public static var border: Color = .primary.opacity(0.15)
    nonisolated(unsafe) public static var borderStrong: Color = .primary.opacity(0.20)
    nonisolated(unsafe) public static var destructiveBorder: Color = .red.opacity(0.55)
    nonisolated(unsafe) public static var controlBackground: Color = Color(nsColor: .controlBackgroundColor)
    nonisolated(unsafe) public static var fieldBackground: Color = .primary.opacity(0.03)
    nonisolated(unsafe) public static var subtleBackground: Color = .secondary.opacity(0.10)
    nonisolated(unsafe) public static var tabHoverBackground: Color = .primary.opacity(0.05)
    nonisolated(unsafe) public static var tabActiveBackground: Color = .primary.opacity(0.08)
    nonisolated(unsafe) public static var popupShadow: Color = .primary.opacity(0.22)

    // MARK: AppKit fills (the text view and gutter draw through NSColor)

    nonisolated(unsafe) public static var textPrimaryNS: NSColor = .labelColor
    nonisolated(unsafe) public static var codeBackgroundNS: NSColor = .textBackgroundColor

    // MARK: Syntax colors (the paint walks)

    nonisolated(unsafe) public static var syntaxKey: Color = .accentColor
    nonisolated(unsafe) public static var syntaxString: Color = .red
    nonisolated(unsafe) public static var syntaxNumber: Color = .purple
    nonisolated(unsafe) public static var syntaxKeyword: Color = .pink
    nonisolated(unsafe) public static var syntaxPlain: Color = .secondary

    // MARK: Fonts (SwiftUI side; `EditorFont` derives the NSFont pair)

    nonisolated(unsafe) public static var fontSmall: Font = .system(size: 12)
    nonisolated(unsafe) public static var fontMonoSubheadline: Font = .system(size: 12, design: .monospaced)
    nonisolated(unsafe) public static var fontMonoBody: Font = .system(size: 13, design: .monospaced)
    nonisolated(unsafe) public static var fontMonoURLBar: Font = .system(size: 12, design: .monospaced)
    nonisolated(unsafe) public static var fontMonoCaption: Font = .system(size: 11, design: .monospaced)
    nonisolated(unsafe) public static var fontIconCompact: Font = .system(size: 12)

    // MARK: Metrics

    nonisolated(unsafe) public static var spaceXSmall: CGFloat = 4
    nonisolated(unsafe) public static var spaceSmall: CGFloat = 8
    nonisolated(unsafe) public static var spaceCompact: CGFloat = 6
    nonisolated(unsafe) public static var spaceMedium: CGFloat = 12
    nonisolated(unsafe) public static var radiusSmall: CGFloat = 6
    nonisolated(unsafe) public static var radiusMedium: CGFloat = 8
    nonisolated(unsafe) public static var lineField: CGFloat = 1
    nonisolated(unsafe) public static var lineFocusedField: CGFloat = 2
    nonisolated(unsafe) public static var toggleControlSize: CGFloat = 26
    nonisolated(unsafe) public static var opacityDisabled: Double = 0.45
    nonisolated(unsafe) public static var motionQuick: Animation = .easeOut(duration: 0.12)
}
