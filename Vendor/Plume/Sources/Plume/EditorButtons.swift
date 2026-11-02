import AppKit
import SwiftUI

/// Editor-owned button chrome for the find/replace and go-to-line overlays.
/// Mirrors the host's button styles with the same hover language, but reads
/// only `EditorTheme` - the overlays must extract with the editor package
/// without dragging the host's whole button family along. Keep the two
/// families visually in step; divergence here reads as inconsistency
/// inside the editor overlays.
struct EditorSecondaryButtonStyle: ButtonStyle {
    var isDestructive = false
    var isAccented = false
    var minHeight: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(
                isEnabled
                    ? (isDestructive
                        ? EditorTheme.error
                        : (isAccented ? EditorTheme.accent : EditorTheme.textPrimary))
                    : EditorTheme.textSecondary
            )
            .padding(.horizontal, EditorTheme.spaceMedium)
            .padding(.vertical, EditorTheme.spaceXSmall)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? EditorTheme.border
                            : (isEnabled && isHovering ? EditorTheme.subtleBackground : EditorTheme.fieldBackground)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                    .strokeBorder(
                        isDestructive ? EditorTheme.destructiveBorder : EditorTheme.borderStrong,
                        lineWidth: EditorTheme.lineField
                    )
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : EditorTheme.opacityDisabled)
            .onHover { isHovering = $0 }
            .pointerStyle(isEnabled ? .link : .default)
            .animation(EditorTheme.motionQuick, value: configuration.isPressed)
            .animation(EditorTheme.motionQuick, value: isHovering)
    }
}

/// Compact icon toggle for the find bar's replace-row switch: on = accent
/// tint + active fill, hover = light gray. Editor-owned twin of
/// `ToolbarToggleButton` (see the file header).
struct EditorToolbarToggleButton: View {
    let systemImage: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(EditorTheme.fontIconCompact)
                .foregroundStyle(isOn ? EditorTheme.accent : EditorTheme.textSecondary)
                .frame(width: EditorTheme.toggleControlSize, height: EditorTheme.toggleControlSize)
                .background(
                    RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                        .fill(
                            isOn
                                ? EditorTheme.tabActiveBackground
                                : (isEnabled && isHovering ? EditorTheme.tabHoverBackground : .clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerStyle(isEnabled ? .link : .default)
        .help(help)
    }
}
