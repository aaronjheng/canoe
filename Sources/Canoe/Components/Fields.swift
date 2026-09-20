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
