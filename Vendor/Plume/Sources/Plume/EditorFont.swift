import AppKit
import SwiftUI

/// Font slots for the generic editor's AppKit surfaces: `NSFont` for the
/// text views, SwiftUI `Font` for the placeholder overlay. Sizes mirror the
/// host's monospaced tokens (small 12, body 13, URL bar 12) through the
/// `EditorTheme` seam, so both representations stay aligned by
/// construction. Package-bound; hosts may read the `NSFont` side
/// directly for their own AppKit text surfaces.
public enum EditorFont {
    case systemSubheadline
    case monoSubheadline
    case monoBody
    case monoURLBar
    case monoCaption

    public var swiftUIFont: Font {
        switch self {
        case .systemSubheadline: EditorTheme.fontSmall
        case .monoSubheadline: EditorTheme.fontMonoSubheadline
        case .monoBody: EditorTheme.fontMonoBody
        case .monoURLBar: EditorTheme.fontMonoURLBar
        case .monoCaption: EditorTheme.fontMonoCaption
        }
    }

    public var nsFont: NSFont {
        switch self {
        case .systemSubheadline: NSFont.systemFont(ofSize: size)
        default: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private var size: CGFloat {
        switch self {
        case .systemSubheadline, .monoSubheadline, .monoURLBar, .monoCaption: 12
        case .monoBody: 13
        }
    }
}
