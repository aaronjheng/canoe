import SwiftUI

// Sidebar/history badges, method tags, the response status pill, and the
// small on/off attribute flags of grid rows.
// MARK: - Badge

struct Badge: View {
    let text: String
    var systemImage: String?
    var foregroundColor: Color = AppColor.textSecondary
    var backgroundColor: Color = AppColor.subtleBackground
    /// Drops the vertical padding so the pill stays one text line tall:
    /// for badges inline with a text run, where the default pill would
    /// stretch the whole line (and, in a fixed-pitch list, the row).
    var isCompact = false

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
        .padding(.horizontal, AppSpacing.compact)
        .padding(.vertical, isCompact ? 0 : AppSpacing.xxSmall)
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

/// The protocol tag leading a request row: the HTTP method's colored tag,
/// or the WS chip for WebSocket requests (which have no method).
struct RequestTypeTag: View {
    let requestType: RequestType
    let method: HTTPMethod

    var body: some View {
        switch requestType {
        case .http: MethodTag(method: method)
        case .websocket: WebSocketTag()
        }
    }
}

/// The compact WS chip (sidebar rows, the request name bar): Postman marks
/// WebSocket requests with a WS tag instead of an HTTP method.
struct WebSocketTag: View {
    var body: some View {
        Text(RequestType.websocket.shortLabel)
            .font(AppFont.methodTag)
            .foregroundStyle(AppColor.methodWS)
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
            .padding(.horizontal, AppSpacing.compact)
            .frame(height: AppSize.compactControl)
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
                .font(AppFont.statusCode)
                .monospacedDigit()
            Text(statusText)
                .font(AppFont.small)
        }
        .foregroundStyle(color)
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(AppColor.badgeBackground(color))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .fixedSize()
    }
}

// MARK: - Flag label

/// A small on/off attribute flag for grid rows (the cookie tables' Secure /
/// HttpOnly / Expired): set flags read as quiet meta text, unset ones dim
/// to half presence - visible but receded, not gone - so an off flag never
/// vanishes from the row, and both cookie surfaces show the same shape.
struct FlagLabel: View {
    let label: String
    let isOn: Bool

    var body: some View {
        Text(label)
            .font(AppFont.small)
            .foregroundStyle(isOn ? AppColor.textSecondary : AppColor.tertiaryText)
            .opacity(isOn ? 1 : AppOpacity.unsetFlag)
    }
}
