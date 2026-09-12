import SwiftUI

/// Settings window sidebar. Stock `.sidebar` styling throughout: headers and
/// selection are system-supplied.
struct SettingsSidebarView: View {
    @Environment(SettingsNavigationState.self) private var navigation

    var body: some View {
        List(selection: selection) {
            ForEach(SettingsPane.allCases, id: \.self) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(pane)
            }
        }
        .listStyle(.sidebar)
    }

    /// `List` hands back an optional selection; routing it through `select`
    /// records history.
    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { navigation.pane },
            set: { if let pane = $0 { navigation.select(pane) } }
        )
    }
}
