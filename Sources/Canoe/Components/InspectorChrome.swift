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
                        .buttonStyle(IconButtonStyle(iconSquare: false, inset: 0))
                        .foregroundStyle(.secondary)
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
