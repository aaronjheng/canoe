import AppKit
import SwiftUI

// Shared filter fields and underline tabs.
// MARK: - Filter field

/// Shared magnifier + plain field + clear button used by the sidebar and
/// variables inspector. Same spacing and help everywhere; only the
/// placeholder differs.
struct FilterField: View {
    @Binding var text: String
    var placeholder: String
    var verticalPadding: CGFloat = AppSpacing.xSmall
    /// Boxed presentation: a four-sided hairline border and a raised fill,
    /// floating inside the parent's padding (the workspace sidebar's
    /// filter). The default stays borderless for the other call sites.
    var isBoxed = false
    /// Inner padding between the boxed border and the field's own bounds.
    /// The default keeps the box floating inside a padded container; a call
    /// site that wants the border flush on its page gutter passes 0.
    var boxedInset: CGFloat = AppSpacing.small
    var minHeight: CGFloat?

    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    /// The box's screen frame - the blur monitor spares clicks inside it.
    @State private var fieldFrame: CGRect = .zero
    @State private var blurMonitor: Any?

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(AppFont.small)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(AppFont.small)
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
                    .animation(AppMotion.quick, value: borderColor)
            }
        }
        .padding(.horizontal, isBoxed ? boxedInset : 0)
        .onHover { isHovered = $0 }
        .animation(AppMotion.quick, value: isHovered)
        .animation(AppMotion.quick, value: isFocused)
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

/// A tab with an underline indicator, an optional count badge, and an
/// optional green "has content" dot. Used for the request/response section
/// switchers.
struct UnderlineTab: View {
    let title: String
    let count: Int?
    /// Draws the success-green content dot (the request editor's signal that
    /// the section holds data even when it shows no count).
    var hasContent: Bool = false
    /// Horizontal inset between the label and the tab's underline/hit area.
    /// The request editor passes 0 and pads the whole row to its content
    /// gutter instead, so label, underline, and content share one edge.
    var labelInset: CGFloat = AppSpacing.small
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
                    .font(AppFont.small.weight(.semibold))
                    .hidden()
                    .overlay {
                        Text(title)
                            .font(AppFont.small.weight(isSelected ? .semibold : .regular))
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
                if hasContent {
                    Circle()
                        .fill(AppColor.success)
                        .frame(width: AppSize.contentDot, height: AppSize.contentDot)
                }
            }
            .padding(.horizontal, labelInset)
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
                    .frame(height: AppLine.focusedField)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .clickCursor()
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
    /// Fired when an editing session ends with a commit - Return, or a click
    /// away through the dismissal monitor. Callers whose value only lands on
    /// a commit (a structural rename, say) need this: macOS text fields do
    /// not blur on background clicks on their own, so without the hook such
    /// a value can sit uncommitted until some unrelated blur arrives - and a
    /// tab switch in between discards it.
    var onCommit: (() -> Void)?
    /// Lets a parent follow this field's focus for its own bookkeeping (the
    /// folder page must not adopt a vault-side rename while the user is
    /// typing into the title). Unset keeps the field's private focus state.
    var focus: FocusState<Bool>.Binding?
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    /// Set for the one update in which Esc ends the session, so the
    /// focus-loss commit below treats a cancel as a cancel.
    @State private var isCancelling = false
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
        .onChange(of: isFocusedNow) { _, focused in
            if focused {
                baseline = text
                isCancelling = false
            } else if !isCancelling {
                // Focus left by ANY route commits, not just by the monitor:
                // Tab, ⇧⌘], and clicking another control all end the session,
                // and a rename that only committed on Return or a
                // background click would be lost on the next tab switch.
                onCommit?()
            }
        }
        .onAppear { installDismissMonitor() }
        .onDisappear { removeDismissMonitor() }
    }

    /// The focus binding actually in force: the caller's when it supplied
    /// one, this field's own otherwise. One accessor so `focused(_:)`, the
    /// monitor, and the commit hook can never drift onto different state.
    private var focusBinding: FocusState<Bool>.Binding {
        focus ?? $isFocused
    }

    private var isFocusedNow: Bool { focusBinding.wrappedValue }

    private var fieldBody: some View {
        TextField(placeholder, text: $text)
            .font(font)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .focused(focusBinding)
            .padding(.horizontal, AppSpacing.compact)
            .padding(.vertical, AppSpacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    // Rest is clear: hover/focus lift to a brighter fill so
                    // the surface reads as raised, not tinted darker. Read
                    // through `isFocusedNow`, not the private state: a caller
                    // that supplies its own focus binding owns the focus, and
                    // the chrome has to follow that binding or the field
                    // loses its focus ring entirely.
                    .fill(
                        isFocusedNow
                            ? AppColor.fieldFocusBackground
                            : (isHovered ? AppColor.fieldHoverBackground : .clear)
                    )
            )
            .overlay {
                // Borderless at rest: field border on hover/focus.
                if isFocusedNow || isHovered {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(
                            isFocusedNow ? AppColor.accent : AppColor.borderStrong,
                            lineWidth: isFocusedNow ? AppLine.focusedField : AppLine.field
                        )
                }
            }
            .onSubmit { finishEditing() }
            .onKeyPress(.escape) {
                // Esc is a cancel, not a commit: restore the focus-time
                // baseline, then end the session with the commit suppressed.
                // The flag is cleared on the next focus gain, so it can only
                // ever cover this one focus loss.
                isCancelling = true
                text = baseline
                focusBinding.wrappedValue = false
                return .handled
            }
    }

    /// Ends an editing session (Return, or a click away). The commit itself
    /// is the focus-loss observer above, so there is exactly one commit per
    /// session no matter which gesture ended it.
    private func finishEditing() {
        focusBinding.wrappedValue = false
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
                guard isFocusedNow, let window = event.window else { return }
                // Window-base -> screen-top-left conversion for SwiftUI .global
                // frames (primary screen top edge, same as TabBarView).
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                let point = CGPoint(
                    x: window.frame.origin.x + event.locationInWindow.x,
                    y: screenTop - window.frame.origin.y - event.locationInWindow.y)
                if !fieldFrame.contains(point) {
                    finishEditing()
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
