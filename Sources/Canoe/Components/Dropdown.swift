// Custom dropdown menus: the data model, the floating panel, and the
// window-level hosting that presents it. Every dropdown in the app (selection
// pickers and overflow action menus alike) renders through this one panel, so
// they all share the same card chrome, row pitch, checkmark language, hover
// wash and keyboard behavior - the same rules the method / environment / tab
// panels already follow (see MethodMenuPanel / EnvironmentPickerPanel).

import SwiftUI

// MARK: - Row model

/// One row of a dropdown panel. Data-driven (not arbitrary view content) so a
/// panel is a plain value the trigger hands over on click - the host can then
/// render it at window level with uniform hover/keyboard state.
struct DropdownRow: Identifiable {
    enum Kind {
        case action
        case divider
    }

    let id: UUID
    var kind: Kind = .action
    var label = ""
    var systemImage: String?
    /// Shows the checkmark (selection menus only).
    var isSelected = false
    var isDisabled = false
    var isDestructive = false
    var help: String?
    var action: () -> Void

    /// A tappable row. `isSelected` only matters when the panel shows the
    /// checkmark gutter (see `DropdownMenuPanel.showsSelection`).
    static func action(
        _ label: String,
        systemImage: String? = nil,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        isDestructive: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void = {}
    ) -> DropdownRow {
        DropdownRow(
            id: UUID(),
            label: label,
            systemImage: systemImage,
            isSelected: isSelected,
            isDisabled: isDisabled,
            isDestructive: isDestructive,
            help: help,
            action: action
        )
    }

    static func divider() -> DropdownRow {
        DropdownRow(id: UUID(), kind: .divider, action: {})
    }
}

// MARK: - Presentation coordinator

/// Owns the one open dropdown at a time. Triggers build their rows on click
/// (closures capture the current store state), the host overlay renders the
/// panel at the trigger's anchor - window-level, so scroll views and pane
/// boundaries never clip it.
@MainActor
@Observable
final class DropdownCoordinator {
    struct Presentation: Identifiable {
        /// Matches the trigger's `dropdownAnchor(id:)` key.
        let id: String
        var rows: [DropdownRow]
        var showsSelection: Bool
        var width: CGFloat
        /// Which edge of the trigger the panel aligns to.
        var alignment: DropdownAlignment
    }

    var active: Presentation?

    /// Opens the panel for `id`, or closes it when that panel is already the
    /// open one. (In practice the second click lands on the overlay's
    /// backdrop first - the trigger is under it - so this toggle is the
    /// programmatic path.)
    func toggle(
        id: String,
        showsSelection: Bool = true,
        width: CGFloat = AppSize.dropdownDefaultWidth,
        alignment: DropdownAlignment = .leading,
        rows: () -> [DropdownRow]
    ) {
        if active?.id == id {
            active = nil
        } else {
            active = Presentation(
                id: id,
                rows: rows(),
                showsSelection: showsSelection,
                width: width,
                alignment: alignment
            )
        }
    }

    func dismiss() {
        active = nil
    }
}

/// Where a panel sits relative to its trigger.
enum DropdownAlignment {
    /// Panel's leading edge meets the trigger's leading edge.
    case leading
    /// Panel hangs left off the trigger's trailing edge (top-bar pills,
    /// sidebar ellipsis buttons).
    case trailing
}

// MARK: - Anchor plumbing

/// Trigger frames keyed by presentation id. Each trigger publishes its own
/// entry only while its panel is open (see `dropdownAnchor`), so the
/// dictionary stays empty — and silent — the rest of the time.
struct DropdownAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [String: Anchor<CGRect>],
        nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publishes this view's frame as the anchor for the dropdown with `id`,
    /// but only while that dropdown is open: preferences flow on every
    /// layout pass, and a sidebar's worth of always-published anchors would
    /// re-render the host on every scroll frame. Opening the panel flips
    /// the coordinator, which re-evaluates the trigger and starts the
    /// publication in the same update cycle.
    func dropdownAnchor(id: String) -> some View {
        modifier(DropdownAnchorModifier(id: id))
    }
}

private struct DropdownAnchorModifier: ViewModifier {
    @Environment(DropdownCoordinator.self) private var dropdown
    let id: String

    func body(content: Content) -> some View {
        content.anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { anchor in
            dropdown.active?.id == id ? [id: anchor] : [:]
        }
    }
}

// MARK: - Panel

/// The floating dropdown card: fixed row pitch, hover pill, keyboard
/// navigation (arrows move, Return picks, Escape closes), checkmark gutter
/// for selection menus. Sizing/positioning happens at the host overlay
/// (ContentView), exactly like the method / environment / tab panels.
struct DropdownMenuPanel: View {
    var rows: [DropdownRow]
    /// Selection menus reserve a checkmark column on every row so the
    /// labels align; action menus drop the gutter and start at the label.
    var showsSelection = true
    var onDismiss: () -> Void

    @State private var hovered: UUID?
    @State private var keyboard: UUID?
    @FocusState private var panelFocused: Bool

    private var selectableRows: [DropdownRow] {
        rows.filter { $0.kind == .action && !$0.isDisabled }
    }

    private func moveKeyboard(by delta: Int) {
        let rows = selectableRows
        guard !rows.isEmpty else { return }
        let idx =
            keyboard.flatMap { id in rows.firstIndex { $0.id == id } }
            ?? (delta > 0 ? -1 : rows.count)
        keyboard = rows[min(max(idx + delta, 0), rows.count - 1)].id
        hovered = nil
    }

    private func pick(_ row: DropdownRow) {
        guard row.kind == .action, !row.isDisabled else { return }
        row.action()
        onDismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                switch row.kind {
                case .divider:
                    Divider()
                case .action:
                    DropdownMenuRow(
                        row: row,
                        showsSelection: showsSelection,
                        isHighlighted: row.id == hovered || row.id == keyboard,
                        onHover: { hovering in
                            hovered = hovering ? row.id : nil
                            if hovering { keyboard = nil }
                        },
                        onPick: { pick(row) }
                    )
                }
            }
        }
        .padding(.horizontal, AppSpacing.xSmall)
        .padding(.vertical, AppSpacing.xSmall)
        .popupPanel()
        // The panel takes keyboard focus so arrows/Return work without the
        // pointer (the chrome is disabled - this is a menu, not a field).
        .focusable()
        .focused($panelFocused)
        .focusEffectDisabled()
        .onAppear {
            panelFocused = true
            keyboard = nil
            hovered = nil
        }
        .onExitCommand(perform: onDismiss)
        .onKeyPress(.upArrow) {
            moveKeyboard(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveKeyboard(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            if let id = keyboard, let row = rows.first(where: { $0.id == id }) {
                pick(row)
            } else if let first = selectableRows.first {
                pick(first)
            }
            return .handled
        }
    }
}

/// One row of the dropdown card. Disabled rows dim and drop the hover wash
/// and the pointing hand (the app's disabled-control language, see
/// Buttons.swift); destructive rows take the error hue.
private struct DropdownMenuRow: View {
    let row: DropdownRow
    let showsSelection: Bool
    let isHighlighted: Bool
    let onHover: (Bool) -> Void
    let onPick: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            if showsSelection {
                // A real hidden checkmark, not Color.clear: a sizeless view
                // absorbs whatever height it is offered (see
                // EnvironmentPickerPanel's rows for the same gotcha).
                Image(systemName: "checkmark")
                    .font(AppFont.small.weight(.medium))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: AppSize.compactControl)
                    .opacity(row.isSelected ? 1 : 0)
            } else if row.isSelected {
                // Toggle-style row in an action menu: no reserved gutter,
                // but the on-state still shows (like a native menu's
                // checkmarked item).
                Image(systemName: "checkmark")
                    .font(AppFont.small.weight(.medium))
                    .foregroundStyle(AppColor.textPrimary)
            }
            if let image = row.systemImage {
                Image(systemName: image)
                    .font(AppFont.small)
                    .foregroundStyle(row.isDestructive ? AppColor.error : AppColor.textSecondary)
            }
            Text(row.label)
                .font(AppFont.small)
                .foregroundStyle(row.isDestructive ? AppColor.error : AppColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, AppSpacing.small)
        .frame(maxWidth: .infinity, minHeight: AppSize.controlHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(isHighlighted && !row.isDisabled ? AppColor.subtleBackground : .clear)
        )
        .contentShape(Rectangle())
        .disabled(row.isDisabled)
        .onHover(perform: onHover)
        .onTapGesture(perform: onPick)
        .clickCursor(isEnabled: !row.isDisabled)
        .opacity(row.isDisabled ? AppOpacity.disabled : 1)
        .helpIf(row.help != nil, row.help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Context menu bridge

/// Renders dropdown row data inside a `.contextMenu`, so a sidebar row's
/// right-click menu and its hover overflow dropdown draw from the same row
/// list and can never drift apart.
struct DropdownMenuContent: View {
    let rows: [DropdownRow]

    var body: some View {
        ForEach(rows) { row in
            switch row.kind {
            case .divider:
                Divider()
            case .action:
                Button(role: row.isDestructive ? .destructive : nil) {
                    row.action()
                } label: {
                    if let image = row.systemImage {
                        Label(row.label, systemImage: image)
                    } else {
                        Text(row.label)
                    }
                }
                .disabled(row.isDisabled)
            }
        }
    }
}

// MARK: - Field trigger

/// The standard picker-style trigger: the current value with a trailing
/// chevron, opening a dropdown panel. Replaces the form menu pickers
/// (auth type, raw body format, snippet language, console filter...); the
/// panel itself is the shared one (see DropdownMenuPanel).
struct DropdownFieldButton: View {
    @Environment(DropdownCoordinator.self) private var dropdown
    /// Stable, site-unique presentation id.
    let id: String
    let label: String
    var showsSelection = true
    var width: CGFloat = AppSize.dropdownDefaultWidth
    var isDisabled = false
    let rows: () -> [DropdownRow]

    @State private var isHovering = false

    private var isExpanded: Bool { dropdown.active?.id == id }

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text(label)
                .font(AppFont.small)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(AppFont.small.weight(.medium))
                .foregroundStyle(AppColor.textSecondary)
        }
        .padding(.leading, AppSpacing.compact)
        .padding(.trailing, AppSpacing.compact)
        .frame(minHeight: AppSize.controlHeight)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(
                    isExpanded
                        ? AppColor.fieldFocusBackground
                        : (isHovering ? AppColor.fieldHoverBackground : AppColor.controlBackground)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(
                    isExpanded ? AppColor.accent : (isHovering ? AppColor.fieldHoverBorder : AppColor.borderStrong),
                    lineWidth: isExpanded ? AppLine.focusedField : AppLine.field
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDisabled else { return }
            dropdown.toggle(
                id: id,
                showsSelection: showsSelection,
                width: width,
                rows: rows
            )
        }
        .dropdownAnchor(id: id)
        .onHover { isHovering = $0 }
        .clickCursor(isEnabled: !isDisabled)
        .opacity(isDisabled ? AppOpacity.disabled : 1)
        .animation(AppMotion.quick, value: isHovering)
        .animation(AppMotion.quick, value: isExpanded)
        .disabled(isDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }
}

// MARK: - Link trigger

/// Text-link trigger (the "Select Environment" hint link): opens the shared
/// dropdown panel but keeps the quiet link look instead of a field box.
struct DropdownLinkButton: View {
    @Environment(DropdownCoordinator.self) private var dropdown
    /// Stable, site-unique presentation id.
    let id: String
    let label: String
    var showsSelection = true
    var width: CGFloat = AppSize.dropdownDefaultWidth
    var help: String?
    let rows: () -> [DropdownRow]

    var body: some View {
        Text(label)
            .font(AppFont.small.weight(.medium))
            .foregroundStyle(AppColor.accent)
            .underline()
            .padding(AppSpacing.xxSmall)
            .contentShape(Rectangle())
            .onTapGesture {
                dropdown.toggle(id: id, showsSelection: showsSelection, width: width, rows: rows)
            }
            .dropdownAnchor(id: id)
            .clickCursor()
            .helpIf(help != nil, help ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Overflow trigger

/// Hover-revealed ellipsis that opens a custom dropdown: a sidebar row's
/// right-click-menu twin, the console's display options. Shared so every
/// overflow menu in the app is the same pill, the same hover wash, and the
/// same "More Actions" help. Replaces the former `RowActionsMenu` Menu.
///
/// Two geometries, like the old menu: the default is a tree row's - natural
/// glyph size, tight padding, stronger wash (it sits on the row's own hover
/// tint, where the usual 5% disappears). `matchesIconButtons` switches to
/// exactly what IconButtonStyle draws, so an overflow trigger in a panel
/// toolbar is the same size and shade as the icon buttons beside it.
struct DropdownOverflowButton: View {
    @Environment(DropdownCoordinator.self) private var dropdown
    /// Stable, site-unique presentation id.
    let id: String
    var matchesIconButtons = false
    /// Row width for the panel (action menus are narrow).
    var width: CGFloat = AppSize.dropdownDefaultWidth
    let rows: () -> [DropdownRow]

    @State private var isHovering = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(AppFont.iconRow)
            .foregroundStyle(AppColor.textSecondary)
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
            .contentShape(Rectangle())
            .onTapGesture {
                dropdown.toggle(id: id, showsSelection: false, width: width, rows: rows)
            }
            .dropdownAnchor(id: id)
            .clickCursor()
            .tracksHover { isHovering = $0 }
            .animation(AppMotion.quick, value: isHovering)
            .help("More Actions")
            .accessibilityLabel("More Actions")
            .accessibilityAddTraits(.isButton)
    }

    /// The icon-button pill's side when matching; nil keeps the natural
    /// width (the tree row's compact case).
    private var pillSide: CGFloat? {
        matchesIconButtons ? AppSize.iconButtonSide : nil
    }

    /// Floor for the compact case, where the glyph plus padding must not pad
    /// itself out.
    private var pillFloor: CGFloat? {
        matchesIconButtons ? nil : AppSize.compactControl
    }
}
