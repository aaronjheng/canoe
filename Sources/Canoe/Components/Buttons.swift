import AppKit
import SwiftUI

// Shared button styles and link buttons.
//
// Hover language (keep call sites on these two tokens):
// - Inline rows / text controls (tree rows, method picker, link labels,
//   panel rows): `AppColor.subtleBackground` (secondary 10%).
// - Icon chrome (toolbar glyphs, icon buttons, tab toggles):
//   `AppColor.tabHoverBackground` (primary 5%).
// Press deepens to `AppColor.border`; disabled controls get no hover fill and
// no pointing hand (`clickCursor`) either.
// Text fields use the standard field border on focus (accent) and lift to
// a brighter fill (`fieldHoverBackground` / `fieldFocusBackground`).
// MARK: - Click cursor

extension View {
    /// Pointing hand for the app's own click chrome (tree rows, tab pills,
    /// icon buttons, panel rows, the workspace pill). AppKit never put a hand
    /// on a button and SwiftUI follows it, but every one of those targets is
    /// drawn by hand rather than being a system control, so the affordance
    /// has to be asked for. `.link` is the system pointing-hand style, applied
    /// through the pointer-style machinery (a real tracking area) rather than
    /// `NSCursor.push`/`pop`, which strands a stuck hand cursor whenever a
    /// hovered view is removed before its exit event arrives.
    ///
    /// Disabled controls ask for `.default` back on purpose: they must not
    /// promise a click, the same rule their hover fill follows.
    func clickCursor(isEnabled: Bool = true) -> some View {
        pointerStyle(isEnabled ? .link : .default)
    }
}

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
            .clickCursor(isEnabled: isEnabled)
            .animation(AppMotion.quick, value: configuration.isPressed)
            .animation(AppMotion.quick, value: isHovering)
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
                        isDestructive ? AppColor.destructiveBorder : AppColor.borderStrong,
                        lineWidth: AppLine.field
                    )
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : AppOpacity.disabled)
            .onHover { isHovering = $0 }
            .clickCursor(isEnabled: isEnabled)
            .animation(AppMotion.quick, value: configuration.isPressed)
            .animation(AppMotion.quick, value: isHovering)
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
            .padding(AppSpacing.compact)
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
            .clickCursor(isEnabled: isEnabled)
            .animation(AppMotion.quick, value: isHovering)
            .animation(AppMotion.quick, value: configuration.isPressed)
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
///
/// The glyph size is the style's, not the call site's: one icon density for
/// every icon button, so a response toolbar, a panel close button, and a
/// tree row's action share it.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var iconSquare = true
    var inset: CGFloat = AppSpacing.xSmall
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.iconRow)
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
            .clickCursor(isEnabled: isEnabled)
            // Disabled reads as disabled: no hover fill and no hand (the rule
            // at the top of this file), but dimmed too - an icon button that
            // simply does nothing looks broken rather than unavailable.
            .opacity(isEnabled ? 1 : AppOpacity.disabled)
            .animation(AppMotion.quick, value: isHovering)
            .animation(AppMotion.quick, value: configuration.isPressed)
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
        .clickCursor(isEnabled: isEnabled)
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
            .clickCursor(isEnabled: isEnabled)
            .animation(AppMotion.quick, value: isHovering)
            .animation(AppMotion.quick, value: configuration.isPressed)
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

/// Hover-revealed overflow menu: one glyph wide, holding the actions that
/// outgrew a few inline icons - a sidebar row's right-click menu, the
/// console's display options. Shared so every overflow menu in the app is
/// the same pill, the same hover wash, and the same "More Actions" help.
///
/// The pill and its size are applied OUTSIDE the menu: a
/// `.menuStyle(.borderlessButton)` label lays itself out and drops the padding
/// and backgrounds declared inside it (the top bar's workspace pill learned
/// this the same way), so a fill drawn in the label never renders - and, for
/// the same reason, the SIZE must be imposed from outside too: a fixed frame
/// inside the label makes the AppKit button pad it further and hand the
/// inflated ideal size back to `fixedSize()`, which grows the host row.
///
/// Two geometries, because the menu has two homes. The default is a tree
/// row's: natural glyph size, tight padding, and the stronger wash (it sits
/// on the row's own hover tint, where the usual 5% disappears completely).
/// `matchesIconButtons` switches to exactly what `IconButtonStyle` draws -
/// the same pill side, the same icon-chrome wash - so an overflow menu in a
/// panel toolbar is the same size and shade as the icon buttons beside it.
struct RowActionsMenu<Content: View>: View {
    var matchesIconButtons = false
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis")
                .font(AppFont.iconRow)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(matchesIconButtons ? AppSize.compactControl : AppSpacing.xxSmall)
        .frame(width: pillSide, height: pillSide)
        .frame(minWidth: pillFloor, minHeight: pillFloor)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(
                    isHovering
                        ? (matchesIconButtons ? AppColor.tabHoverBackground : AppColor.border)
                        : .clear
                )
        )
        .clickCursor()
        .tracksHover { isHovering = $0 }
        .animation(AppMotion.quick, value: isHovering)
        .help("More Actions")
    }

    /// The icon-button pill's side when matching; nil keeps the menu's own
    /// natural width (the tree row's compact case).
    private var pillSide: CGFloat? {
        matchesIconButtons ? AppSize.iconButtonSide : nil
    }

    /// Floor for the compact case, where the menu is only as big as its glyph
    /// plus padding and must not pad itself out.
    private var pillFloor: CGFloat? {
        matchesIconButtons ? nil : AppSize.compactControl
    }
}
