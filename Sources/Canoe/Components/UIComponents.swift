import SwiftUI

// MARK: - Badge

struct Badge: View {
    let text: String
    var systemImage: String?
    var foregroundColor: Color = .secondary
    var backgroundColor: Color = AppColor.subtleBackground

    var body: some View {
        HStack(spacing: AppSpacing.xxSmall) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(AppFont.countBadge)
        .lineLimit(1)
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A compact label showing an HTTP method in its signature color, used in the
/// sidebar and history list.
struct MethodTag: View {
    let method: HTTPMethod

    var body: some View {
        Text(method.rawValue)
            .font(AppFont.methodTag)
            .foregroundStyle(method.color)
    }
}

/// Postman-style protocol badge leading the breadcrumb row ("HTTP" today;
/// more protocol types may be added later). Distinct from `MethodTag`, which
/// shows the HTTP method.
struct RequestTypeBadge: View {
    let type: RequestType

    var body: some View {
        Text(type.label)
            .font(AppFont.requestTypeBadge)
            .monospaced()
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
            .frame(height: 16)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
    }
}

// MARK: - Inspector switcher

/// The right-edge inspector tabs. Icon-only (Postman-style): the segmented
/// highlight marks the active panel, so no text is needed.
enum InspectorTab: String, CaseIterable, Identifiable {
    case variables = "Variables"
    case code = "Code Snippet"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .variables: "curlybraces"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Icon-only switcher shared by both right-edge inspector headers. The two
/// panels are mutually exclusive, so the selection derives from which one
/// is visible.
struct InspectorSwitcher: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Picker(
            "Inspector",
            selection: Binding(
                get: { store.showVariablesSidebar ? InspectorTab.variables : .code },
                set: {
                    store.showVariablesSidebar = $0 == .variables
                    store.showCodeSnippetSidebar = $0 == .code
                }
            )
        ) {
            ForEach(InspectorTab.allCases) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .labelStyle(.iconOnly)
        .fixedSize()
        .help("Switch inspector panel")
    }
}

/// Shared right-edge inspector header: the switcher stays centered with
/// the close button pinned trailing, identical in both panels.
struct InspectorHeader: View {
    let closeHelp: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            InspectorSwitcher()
            HStack {
                Spacer(minLength: 0)
                Button("Hide", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(closeHelp)
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(minHeight: AppSize.toolbarHeight)
    }
}

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

// MARK: - Button styles

/// The primary call-to-action button (Primer `accent.fg` blue): Send, Create,
/// New Request. Disabled state dims so it never reads as tappable.
struct SendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(AppColor.onAccent)
            .padding(.horizontal, AppSpacing.large)
            .padding(.vertical, AppSpacing.xSmall)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
            .brightness(configuration.isPressed ? -0.10 : (isHovering ? 0.06 : 0))
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

struct ToolbarButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.body)
            .foregroundStyle(configuration.isPressed || isHovering ? .primary : .secondary)
            .padding(AppSpacing.small - AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? AppColor.border
                            : (isHovering ? AppColor.tabHoverBackground : .clear)
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
/// it is interactive.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(AppSpacing.compact - AppSpacing.xxSmall)
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
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(isOn ? AppColor.accent : .secondary)
                .frame(width: AppSize.topBarControlHeight, height: AppSize.topBarControlHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(
                            isOn
                                ? AppColor.tabActiveBackground
                                : (isHovering ? AppColor.tabHoverBackground : .clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Link button

/// The single text-link language (Postman-style inline actions): app accent,
/// underlined, plain chrome. Replaces scattered `.buttonStyle(.link)` uses,
/// which render the *system* accent and drift from `AppColor.accent` whenever
/// the user recolors their system accent.
struct LinkButton: View {
    let title: String
    var font: Font = .subheadline
    var isDestructive: Bool = false
    let action: () -> Void

    init(_ title: String, font: Font = .subheadline, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.font = font
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(font)
                .foregroundStyle(isDestructive ? AppColor.error : AppColor.accent)
                .underline()
        }
        .buttonStyle(.plain)
    }
}

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

// MARK: - Status capsule (response status bar)

/// A colored pill showing a response status code and its reason phrase.
struct StatusCapsule: View {
    let statusCode: Int
    let statusText: String

    private var color: Color { AppColor.statusColor(statusCode) }

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text("\(statusCode)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            Text(statusText)
                .font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(AppColor.badgeBackground(color))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .fixedSize()
    }
}

// MARK: - App icon

/// Shared Canoe mark with proportional continuous corners. The welcome
/// screen opts into the soft accent shadow; inline states stay flat.
struct CanoeMarkView: View {
    let size: CGFloat
    var showsShadow = false

    var body: some View {
        Image("CanoeMark")
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .shadow(
                color: showsShadow ? AppColor.accent.opacity(AppOpacity.markShadow) : .clear,
                radius: showsShadow ? 20 : 0, y: showsShadow ? 8 : 0
            )
    }
}

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
