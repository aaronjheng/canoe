import SwiftUI

// MARK: - HTTPMethod Presentation

/// View-layer mapping for `HTTPMethod`.
///
/// Lives here (not in `Request/Models/`) so the model stays free of SwiftUI:
/// models must never import the view framework, per the dependency rule.
extension HTTPMethod {
    var color: Color {
        switch self {
        case .get: AppColor.methodGET
        case .post: AppColor.methodPOST
        case .put: AppColor.methodPUT
        case .patch: AppColor.methodPATCH
        case .delete: AppColor.methodDELETE
        case .head: AppColor.methodGET
        case .options: AppColor.methodOPTIONS
        case .query: AppColor.success
        }
    }
}
