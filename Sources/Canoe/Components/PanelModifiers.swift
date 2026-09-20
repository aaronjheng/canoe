import SwiftUI

// Panel chrome: save chip, toolbar/popup/focus modifiers.
// MARK: - Panel toolbar

/// Postman-style Save chip shared by the workspace/collection/environment
/// detail headers: icon + label, accent when dirty, plain otherwise.
struct SaveChipButton: View {
    let isDirty: Bool
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "square.and.arrow.down")
                Text("Save")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isDirty ? AppColor.accent : .secondary)
            .padding(.horizontal, AppSpacing.comfortable)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(
                        isDirty
                            ? (isHovering ? AppColor.tabHoverBackground : AppColor.subtleBackground)
                            : .clear
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(!isDirty)
        .help(help)
    }
}

struct PanelToolbarModifier: ViewModifier {
    var horizontalPadding: CGFloat = AppSpacing.large

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: AppSize.toolbarHeight)
    }
}

/// Floating card chrome for the popups anchored under the URL bar (the
/// method dropdown, the multi-line URL editor): solid fill, soft shadow,
/// and the standard border. One place so the floating surfaces always match.
struct PopupPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(.background)
                    .shadow(color: AppColor.popupShadow, radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(AppColor.border, lineWidth: 1)
            )
    }
}

/// Focus-border language for bordered fields (see `focusRingBorder`):
/// rest state is the strong border, focused state is the accent at 2pt.
/// The URL bar and method picker keep bespoke overlays only because their
/// spliced UnevenRoundedRectangle shape differs - same widths, same colors.
struct FocusRingBorderModifier: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(
                    isFocused ? AppColor.accent : AppColor.borderStrong,
                    lineWidth: isFocused ? 2 : 1)
        )
    }
}

extension View {
    func panelToolbar(horizontalPadding: CGFloat = AppSpacing.large) -> some View {
        modifier(PanelToolbarModifier(horizontalPadding: horizontalPadding))
    }

    func popupPanel() -> some View {
        modifier(PopupPanelModifier())
    }

    /// Single focus-border language for bordered fields: rest state is the
    /// strong border, focused state is the accent at 2pt.
    func focusRingBorder(isFocused: Bool) -> some View {
        modifier(FocusRingBorderModifier(isFocused: isFocused))
    }

    /// Applies `help` only when `condition` holds; otherwise leaves the view
    /// untouched (avoids empty tooltips from `help("")`).
    @ViewBuilder
    func helpIf(_ condition: Bool, _ text: String) -> some View {
        if condition {
            help(text)
        } else {
            self
        }
    }
}
