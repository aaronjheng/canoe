import SwiftUI

// Sidebar/history badges, method tags, and the response status pill.
// MARK: - Badge

struct Badge: View {
    let text: String
    var systemImage: String?
    var foregroundColor: Color = .secondary
    var backgroundColor: Color = AppColor.subtleBackground

    var body: some View {
        HStack(spacing: AppSpacing.xxSmall) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(AppFont.countBadge)
        .lineLimit(1)
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A compact label showing an HTTP method in its signature color, used in the
/// sidebar and history list.
struct MethodTag: View {
    let method: HTTPMethod

    var body: some View {
        Text(method.rawValue)
            .font(AppFont.methodTag)
            .foregroundStyle(method.color)
    }
}

/// Postman-style protocol badge leading the breadcrumb row ("HTTP" today;
/// more protocol types may be added later). Distinct from `MethodTag`, which
/// shows the HTTP method.
struct RequestTypeBadge: View {
    let type: RequestType

    var body: some View {
        Text(type.label)
            .font(AppFont.requestTypeBadge)
            .monospaced()
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
            .frame(height: 16)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
    }
}

// MARK: - Status capsule (response status bar)

/// A colored pill showing a response status code and its reason phrase.
struct StatusCapsule: View {
    let statusCode: Int
    let statusText: String

    private var color: Color { AppColor.statusColor(statusCode) }

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text("\(statusCode)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            Text(statusText)
                .font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(AppColor.badgeBackground(color))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .fixedSize()
    }
}
