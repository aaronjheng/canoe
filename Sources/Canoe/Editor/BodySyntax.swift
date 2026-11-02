import AppKit
import Plume
import SwiftUI

/// Request-body language selected in the raw editor. Canoe-side domain type
/// (glue over Plume, NOT package-bound): models and viewers speak
/// `BodySyntax`, the generic editor speaks `SyntaxProfile` - this enum maps
/// between them. `{{variable}}` background tints compose on top of the
/// foreground colors independently. The Scripts tab's editors reuse the
/// `.javascript` case.
enum BodySyntax {
    case plain
    case json
    case xml
    case javascript

    /// The package profile this syntax maps to.
    var profile: SyntaxProfile {
        switch self {
        case .plain: .plain
        case .json: .json
        case .xml: .xml
        case .javascript: .javascript
        }
    }
}

// Canoe-facing shims over the package's profile-based API, keeping the
// historical call surface (`syntax:`) alive for the response viewer and the
// WebSocket log views.
extension SyntaxHighlight {
    static func attributedText(_ source: String, syntax: BodySyntax) -> AttributedString {
        attributedText(source, profile: syntax.profile)
    }

    static func highlightedText(_ source: String, syntax: BodySyntax) -> Text {
        Text(attributedText(source, syntax: syntax))
    }
}
