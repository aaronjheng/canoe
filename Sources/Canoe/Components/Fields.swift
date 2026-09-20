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

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !text.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, verticalPadding)
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
            // and stretches the whole tab across the row.
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? AppColor.accent : .clear)
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
    var font: Font = .subheadline.weight(.semibold)
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
            .focused($isFocused)
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
            .padding(.vertical, AppSpacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(
                        isFocused
                            ? AppColor.fieldBackground
                            : (isHovered ? AppColor.subtleBackground : .clear)
                    )
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(AppColor.accent, lineWidth: 2)
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
            if isFocused, !fieldFrame.contains(event.locationInWindow) {
                isFocused = false
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
