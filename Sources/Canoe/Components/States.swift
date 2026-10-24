import AppKit
import SwiftUI

// Full-area states: error banners, loading views, and the app mark.
// MARK: - Error banner

struct ErrorBanner: View {
    let message: String
    var dismissAction: (() -> Void)?

    @State private var copyAck = CopyAcknowledgement()

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.error)
            Text(message)
                .font(AppFont.emptyStateBody)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(3)
                // The message is the payload users forward with bug reports:
                // selectable in place, plus a one-click copy of the full
                // text (visible or line-limited away).
                .textSelection(.enabled)
            Spacer()
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(message, forType: .string)
                copyAck.acknowledge()
            } label: {
                Image(systemName: copyAck.didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
            .foregroundStyle(copyAck.didCopy ? AppColor.success : AppColor.textSecondary)
            .help("Copy Error Message")
            if let dismissAction {
                Button("Dismiss", systemImage: "xmark") {
                    dismissAction()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                .help("Dismiss")
            }
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.compact)
        .background(AppColor.error.opacity(AppOpacity.errorBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        // The checkmark certifies the message that was on the pasteboard:
        // a banner whose error changes (next send, next failure) drops it
        // rather than tick over a message nobody copied.
        .onChange(of: message) { _, _ in
            copyAck.clear()
        }
    }
}

// MARK: - Loading

struct LoadingState: View {
    let message: String

    var body: some View {
        VStack(spacing: AppSpacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(AppFont.emptyStateBody)
                .foregroundStyle(AppColor.textSecondary)
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App icon

/// Shared Canoe mark with proportional continuous corners. The welcome
/// screen opts into the soft accent shadow; inline states stay flat.
/// Reads the running app's icon at runtime (like Runlet's welcome screen),
/// so no separate imageset asset is needed.
struct CanoeMarkView: View {
    let size: CGFloat
    var showsShadow = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .shadow(
                color: showsShadow ? AppColor.accent.opacity(AppOpacity.markShadow) : .clear,
                radius: showsShadow ? 20 : 0, y: showsShadow ? 8 : 0
            )
    }
}
