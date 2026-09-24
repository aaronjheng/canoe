import AppKit
import SwiftUI

// Shared button styles and link buttons.
//
// Hover language (keep call sites on these two tokens):
// - Inline rows / text controls (tree rows, method picker, link labels,
//   panel rows): `AppColor.subtleBackground` (secondary 10%).
// - Icon chrome (toolbar glyphs, icon buttons, tab toggles):
//   `AppColor.tabHoverBackground` (primary 5%).
// Press deepens to `AppColor.border`; disabled controls get no hover fill.
// Text fields use the standard field border on focus (accent) and lift to
// a brighter fill (`fieldHoverBackground` / `fieldFocusBackground`).
// MARK: - Button styles

/// The primary call-to-action button (Primer `accent.fg` blue): Send, Create,
/// New Request. Disabled state dims so it never reads as tappable.
struct SendButtonStyle: ButtonStyle {
    var minHeight: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.large)
            .padding(.vertical, AppSpacing.xSmall)
            .frame(minHeight: minHeight)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .brightness(configuration.isPressed ? -0.10 : (isEnabled && isHovering ? 0.06 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : AppOpacity.disabled)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Alias kept for the one call site outside the request editor: every
/// primary action uses the same style.
typealias PrimaryButtonStyle = SendButtonStyle

/// Standard secondary button (Cancel, Select File): bordered neutral fill so
/// it never drifts from the app accent via the system `.bordered` style.
struct SecondaryButtonStyle: ButtonStyle {
    var isDestructive = false
    var minHeight: CGFloat?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(isEnabled ? (isDestructive ? AppColor.error : .primary) : .secondary)
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.xSmall)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? AppColor.border
                            : (isEnabled && isHovering ? AppColor.subtleBackground : AppColor.fieldBackground)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(
                        isDestructive ? AppColor.error.opacity(0.55) : AppColor.borderStrong,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : AppOpacity.disabled)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

struct ToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(AppFont.iconChrome)
            .foregroundStyle(configuration.isPressed || (isEnabled && isHovering) ? .primary : .secondary)
            .padding(AppSpacing.small - AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? AppColor.border
                            : (isEnabled && isHovering ? AppColor.tabHoverBackground : .clear)
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Inline icon-button feedback (response body tools, console actions,
/// snippet copy, row trash): hover paints the shared light fill, press
/// deepens it. Deliberately does not touch the label's own foreground so
/// callers keep custom tints (accent toggles, success checkmarks). Same
/// hover family as `ToolbarToggleButton` and the tree rows. Disabled
/// buttons get no hover fill - a control that cannot act must not pretend
/// it is interactive. Icon-only labels square into a fixed glyph box, so
/// every hover pill is the same size (SF Symbols have varying widths);
/// labels that carry text opt out via `iconSquare: false`. Dense call
/// sites (tree rows, table cells, filter fields) pass `inset: 0` so the
/// pill never inflates the host row's height.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var iconSquare = true
    var inset: CGFloat = AppSpacing.compact - AppSpacing.xxSmall
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .iconGlyphBox(active: iconSquare)
            .padding(inset)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? AppColor.border
                            : (isEnabled && isHovering ? AppColor.tabHoverBackground : .clear)
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Compact icon toggle for panel chrome (the tab-row inspector toggles, the
/// status-bar panel toggles): on = accent tint + selection fill, hover =
/// light gray. One component so both bars stay identical.
struct ToolbarToggleButton: View {
    let systemImage: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(AppFont.iconCompact)
                .foregroundStyle(isOn ? AppColor.accent : .secondary)
                .frame(width: AppSize.topBarControlHeight, height: AppSize.topBarControlHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(
                            isOn
                                ? AppColor.tabActiveBackground
                                : (isEnabled && isHovering ? AppColor.tabHoverBackground : .clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Icon glyph box

/// Squares an icon-only label so every `IconButtonStyle` hover pill shares
/// one size regardless of each SF Symbol's intrinsic width.
private struct IconGlyphBoxModifier: ViewModifier {
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.frame(
                width: AppSize.iconButtonGlyphBox,
                height: AppSize.iconButtonGlyphBox,
                alignment: .center
            )
        } else {
            content
        }
    }
}

extension View {
    fileprivate func iconGlyphBox(active: Bool) -> some View {
        modifier(IconGlyphBoxModifier(isActive: active))
    }
}

// MARK: - Link button

/// The single text-link language (Postman-style inline actions): app accent,
/// underlined, light pill on hover. Replaces scattered `.buttonStyle(.link)`
/// uses, which render the *system* accent and drift from `AppColor.accent`
/// whenever the user recolors their system accent.
struct LinkButton: View {
    let title: String
    var font: Font = AppFont.small
    var isDestructive: Bool = false
    let action: () -> Void

    init(_ title: String, font: Font = AppFont.small, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.font = font
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(isDestructive ? AppColor.error : AppColor.accent)
                .underline()
        }
        .buttonStyle(LinkButtonStyle())
    }
}

/// Hover/press feedback for `LinkButton` and inline text actions: row-token
/// wash under the label so they read as tappable next to icon-button
/// neighbors. Shared by ConsoleView's Show Raw / Copy actions.
struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, AppSpacing.xxSmall)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? AppColor.border
                            : (isEnabled && isHovering ? AppColor.subtleBackground : .clear)
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - File panel

/// Single-file open panel shared by the binary body editor and form-data
/// file rows (the sandbox is disabled, so the path is read directly).
@MainActor
func openFilePanel() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}
