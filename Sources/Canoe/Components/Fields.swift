import AppKit
import SwiftUI

// Shared filter fields and underline tabs.
// MARK: - Filter field

/// Shared magnifier + plain field + clear button used by the sidebar,
/// variables inspector, and response headers search. Same spacing and help
/// everywhere; only the placeholder differs.
struct FilterField: View {
    @Binding var text: String
    var placeholder: String
    var verticalPadding: CGFloat = AppSpacing.xSmall
    /// Boxed presentation: a four-sided hairline border and a raised fill,
    /// floating inside the parent's padding (the workspace sidebar's
    /// filter). The default stays borderless for the other call sites.
    var isBoxed = false
    var minHeight: CGFloat?

    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    /// The box's screen frame - the blur monitor spares clicks inside it.
    @State private var fieldFrame: CGRect = .zero
    @State private var blurMonitor: Any?

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.subheadline)
                .focused($isFocused)
            if !text.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: minHeight)
        .background {
            // Boxed always paints; unboxed only on hover/focus (rest is clear).
            if isBoxed || isFocused || isHovered {
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(boxBackground)
            }
        }
        .overlay {
            if let borderColor = borderColor {
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    // Standard field width for rest and hover/focus alike.
                    .strokeBorder(borderColor, lineWidth: isFocused ? AppLine.focusedField : AppLine.field)
                    .animation(.easeOut(duration: 0.12), value: borderColor)
            }
        }
        .padding(.horizontal, isBoxed ? AppSpacing.small : 0)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            fieldFrame = frame
        }
        .onAppear { installBlurMonitor() }
        .onDisappear { removeBlurMonitor() }
    }

    /// Fill tiers: boxed idle field wash; hover/focus lift one
    /// luminance step (`fieldHoverBackground` / `fieldFocusBackground`).
    /// Unboxed rest is clear - only hover/focus paint (see body).
    private var boxBackground: Color {
        if isFocused { return AppColor.fieldFocusBackground }
        if isHovered { return AppColor.fieldHoverBackground }
        return isBoxed ? AppColor.fieldBackground : AppColor.controlBackground
    }

    /// Border tiers: idle `borderStrong`, brighter hover, focused accent.
    /// All at `AppLine.field` width;
    /// unboxed only draws on hover/focus (clear at rest).
    private var borderColor: Color? {
        if isFocused { return AppColor.accent }
        if isHovered { return AppColor.fieldHoverBorder }
        return isBoxed ? AppColor.borderStrong : nil
    }

    /// Observes without consuming: a leftMouseDown outside the box drops
    /// focus (macOS SwiftUI text fields don't blur on background clicks on
    /// their own - the same disease the sidebar's inline rename field and
    /// the request name field each hand-roll monitors for). The click point
    /// is converted from window-base into the screen-top-left space SwiftUI
    /// .global frames use (primary screen top edge, same as the tab strip's
    /// double-click monitor and the variables inspector's value blur - not
    /// `window.screen`, which can disagree on multi-display setups and make
    /// double-clicks on a focused field read as outside).
    private func installBlurMonitor() {
        guard blurMonitor == nil else { return }
        blurMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if isFocused, let window = event.window {
                    let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                    let point = CGPoint(
                        x: window.frame.origin.x + event.locationInWindow.x,
                        y: screenTop - window.frame.origin.y - event.locationInWindow.y)
                    if !fieldFrame.contains(point) {
                        isFocused = false
                    }
                }
            }
            return event
        }
    }

    private func removeBlurMonitor() {
        if let monitor = blurMonitor {
            NSEvent.removeMonitor(monitor)
            blurMonitor = nil
        }
    }
}

// MARK: - Underline tab

/// A tab with an underline indicator and an optional count badge. Used for the
/// request/response section switchers.
struct UnderlineTab: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xSmall) {
                // Reserve the semibold variant's width with a hidden copy and
                // overlay the visible weight on top: bold text is wider than
                // regular, so switching selectedness would otherwise change
                // the tab's width and jitter the whole tab row.
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .hidden()
                    .overlay {
                        Text(title)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            // Hover lifts an unselected tab's label to primary
                            // so the row reads as interactive before the click.
                            .foregroundStyle(isSelected || isHovering ? .primary : .secondary)
                    }
                if let count, count > 0 {
                    Text("\(count)")
                        .font(AppFont.countBadge)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.top, AppSpacing.small)
            .padding(.bottom, AppSpacing.xSmall)
            // Underline as a bottom-aligned background: a bare `Rectangle()`
            // row below the label is width-unconstrained (shapes are greedy)
            // and stretches the whole tab across the row. Selected takes the
            // accent bar; hover on an idle tab draws a gray underline instead
            // of a fill wash, matching the section-switcher chrome.
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(
                        isSelected
                            ? AppColor.accent
                            : (isHovering ? AppColor.borderStrong : .clear)
                    )
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Inline name field

/// Postman-style inline name field (same language as the request name
/// field): quiet heading at rest, light pill on hover, accent-ring field on
/// focus. The field hugs its text (ViewThatFits) so the chrome never reads
/// as a wide empty input; a very long name falls back to the row remainder
/// and scrolls inside while focused. One persistent TextField - no view swap
/// on state change - so caret, undo, and the draft push behave like every
/// other field. Esc restores the focus-time baseline; Enter commits.
struct InlineNameField: View {
    @Binding var text: String
    var placeholder: String = "Name"
    var font: Font = AppFont.detailTitle
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    /// Text at focus time; Esc restores it (commit happens on blur/Enter).
    @State private var baseline = ""
    /// The field's frame in window coordinates - the click-away monitor
    /// needs it to spare clicks inside the field.
    @State private var fieldFrame: CGRect = .zero
    /// Local left-mouse-down monitor that ends editing when a click lands
    /// outside the field. Installed while on screen.
    @State private var dismissMonitor: Any?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fieldBody
                .fixedSize()
            fieldBody
        }
        .onHover { isHovered = $0 }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: {
            fieldFrame = $0
        }
        .onChange(of: isFocused) { _, focused in
            if focused { baseline = text }
        }
        .onAppear { installDismissMonitor() }
        .onDisappear { removeDismissMonitor() }
    }

    private var fieldBody: some View {
        TextField(placeholder, text: $text)
            .font(font)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .focused($isFocused)
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
            .padding(.vertical, AppSpacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    // Rest is clear: hover/focus lift to a brighter fill so
                    // the surface reads as raised, not tinted darker.
                    .fill(
                        isFocused
                            ? AppColor.fieldFocusBackground
                            : (isHovered ? AppColor.fieldHoverBackground : .clear)
                    )
            )
            .overlay {
                // Borderless at rest: field border on hover/focus.
                if isFocused || isHovered {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(
                            isFocused ? AppColor.accent : AppColor.borderStrong,
                            lineWidth: isFocused ? AppLine.focusedField : AppLine.field
                        )
                }
            }
            .onSubmit { isFocused = false }
            .onKeyPress(.escape) {
                text = baseline
                isFocused = false
                return .handled
            }
    }

    /// Ends editing when a click lands outside the field. A local NSEvent
    /// monitor observes without consuming, so TextField clicks are never
    /// delayed or stolen (a SwiftUI root gesture would race the field
    /// editor's mouseDown and break focus-by-click). Clicks anywhere else -
    /// chrome, other editors, buttons - read as blur and drop the ring.
    private func installDismissMonitor() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard isFocused, let window = event.window else { return }
                // Window-base -> screen-top-left conversion for SwiftUI .global
                // frames (primary screen top edge, same as TabBarView).
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                let point = CGPoint(
                    x: window.frame.origin.x + event.locationInWindow.x,
                    y: screenTop - window.frame.origin.y - event.locationInWindow.y)
                if !fieldFrame.contains(point) {
                    isFocused = false
                }
            }
            return event
        }
    }

    private func removeDismissMonitor() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
    }
}
