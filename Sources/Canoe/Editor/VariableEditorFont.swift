import AppKit
import SwiftUI

/// Font tokens for the AppKit-backed variable editors: `NSFont` for the text
/// views, SwiftUI `Font` for the placeholder overlay. Sizes mirror the
/// `AppFont` monospaced tokens (small 12, body 13, URL bar 12). Shared by
/// `VariableHighlightEditor` and `CodeEditor`.
enum VariableEditorFont {
    case systemSubheadline
    case monoSubheadline
    case monoBody
    case monoURLBar
    case monoCaption

    var swiftUIFont: Font {
        switch self {
        case .systemSubheadline: AppFont.small
        case .monoSubheadline: AppFont.monoSubheadline
        case .monoBody: AppFont.monoBody
        case .monoURLBar: AppFont.monoURLBar
        case .monoCaption: AppFont.monoCaption
        }
    }

    var nsFont: NSFont {
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
