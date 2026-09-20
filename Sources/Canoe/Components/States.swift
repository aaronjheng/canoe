import AppKit
import SwiftUI

// Full-area states: error banners, loading views, and the app mark.
// MARK: - Error banner

struct ErrorBanner: View {
    let message: String
    var dismissAction: (() -> Void)?

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.error)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer()
            if let dismissAction {
                Button("Dismiss", systemImage: "xmark") {
                    dismissAction()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.small - AppSpacing.xxSmall)
        .background(AppColor.error.opacity(AppOpacity.errorBackground))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
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
                .font(.caption)
                .foregroundStyle(.secondary)
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
