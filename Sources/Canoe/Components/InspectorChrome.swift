import SwiftUI

// Right-edge inspector chrome: panel switcher and shared header.
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
/// is visible. Hand-drawn (see `IconSwitcher`): the system segmented picker
/// gives no per-segment hover feedback on macOS.
struct InspectorSwitcher: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        IconSwitcher(
            selectedIndex: Binding(
                get: { store.showVariablesSidebar ? 0 : 1 },
                set: {
                    store.showVariablesSidebar = $0 == 0
                    store.showCodeSnippetSidebar = $0 == 1
                }
            ),
            items: [
                IconSwitcher.Item(
                    systemImage: InspectorTab.variables.systemImage,
                    help: InspectorTab.variables.rawValue
                ),
                IconSwitcher.Item(
                    systemImage: InspectorTab.code.systemImage,
                    help: InspectorTab.code.rawValue
                ),
            ]
        )
    }
}

/// Shared right-edge inspector header, Postman-style: the switcher stays
/// centered with the close button pinned trailing, and a bold title bar
/// below names the active panel ("Variables in Request", "Code Snippet"),
/// identical placement in both panels.
struct InspectorHeader: View {
    /// Title of the active panel, shown under the switcher row.
    let title: String
    let closeHelp: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                InspectorSwitcher()
                HStack {
                    Spacer(minLength: 0)
                    Button("Hide", systemImage: "xmark", action: onClose)
                        .labelStyle(.iconOnly)
                        // Toolbar-grade, not dense: this header is already
                        // `toolbarHeight` (32pt), so the standard 26pt pill
                        // fits without inflating the row - `inset: 0` would
                        // leave the hover target bare around the glyph.
                        .buttonStyle(IconButtonStyle(iconSquare: true))
                        .foregroundStyle(AppColor.textSecondary)
                        .help(closeHelp)
                }
            }
            .padding(.horizontal, AppSpacing.medium)
            .frame(minHeight: AppSize.toolbarHeight)
            Text(title)
                .font(AppFont.panelTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.top, AppSpacing.xSmall)
                .padding(.bottom, AppSpacing.small)
        }
    }
}
