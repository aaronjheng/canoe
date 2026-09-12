import SwiftUI

// MARK: - HTTPMethod Presentation

/// View-layer mapping for `HTTPMethod`.
///
/// Lives here (not in `Request/Models/`) so the model stays free of SwiftUI:
/// models must never import the view framework, per the dependency rule.
extension HTTPMethod {
    var color: Color {
        switch self {
        case .get: AppColor.success
        case .post: AppColor.accent
        case .put: AppColor.accentDark
        case .patch: AppColor.done
        case .delete: AppColor.error
        case .head: AppColor.done
        case .options: AppColor.neutral
        }
    }
}
