import SwiftUI

/// App-level configuration panel, hosted in a standalone window from the app
/// menu (`Canoe -> Settings…`, ⌘,). Every pane is a stock `Form`, so cards,
/// headers and hairlines are system-drawn. Every control applies instantly
/// through `SettingsStore`.
struct SettingsView: View {
    @Environment(SettingsNavigationState.self) private var navigation
    @Environment(AppStore.self) private var appStore
    @Bindable private var store = SettingsStore.shared
    @State private var isSwitchingLocation = false
    @State private var locationError: String?

    /// Live binding so a theme change from the menu is reflected while the
    /// panel is open (and vice versa through `validateMenuItem`).
    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: store.settings.appearance) ?? .system },
            set: { appearance in
                store.settings.appearance = appearance.rawValue
                store.save()
                appearance.apply()
                for window in NSApp.windows {
                    appearance.applyToWindow(window)
                }
            }
        )
    }

    var body: some View {
        switch navigation.pane {
        case .appearance: appearancePane
        case .sync: syncPane
        }
    }

    // MARK: - Appearance

    private var appearancePane: some View {
        Form {
            Section {
                HStack {
                    Text("Style")
                        .lineLimit(1)
                    Spacer(minLength: AppSpacing.small)
                    Picker("", selection: appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.name).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Theme")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sync

    private var syncPane: some View {
        Form {
            Section {
                Toggle("iCloud Drive Sync", isOn: syncEnabled)
                    .disabled(isSwitchingLocation)
            } header: {
                Text("Vault Location")
            } footer: {
                Text(
                    "Syncs saved requests, collections and environments through your iCloud Drive. Unsaved drafts always stay on this Mac."
                )
            }
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(syncStatus)
                        .foregroundStyle(.secondary)
                }
                if let vaultURL = appStore.vault.vaultURL {
                    HStack {
                        Text("Folder")
                        Spacer()
                        Text(vaultURL.path(percentEncoded: false))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if let message = locationError ?? appStore.vault.locationWarning ?? appStore.vault.loadError {
                Section {
                    Text(message)
                        .foregroundStyle(AppColor.error)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var syncStatus: String {
        if isSwitchingLocation { return "Switching…" }
        // The effective location, not the toggle: with iCloud Drive
        // unavailable the toggle stays on while the files stay local (with
        // a warning above explaining why).
        if appStore.vault.location == .iCloud { return "Syncing via iCloud Drive" }
        return appStore.vault.locationWarning == nil ? "Local only" : "Local only (iCloud unavailable)"
    }

    /// Flips the persisted setting first so a relaunch honors the choice,
    /// then migrates and reloads; a failed switch reverts the setting.
    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { store.settings.iCloudSyncEnabled },
            set: { enabled in
                guard !isSwitchingLocation else { return }
                store.settings.iCloudSyncEnabled = enabled
                store.save()
                locationError = nil
                isSwitchingLocation = true
                Task {
                    let message = await appStore.setVaultLocation(enabled ? .iCloud : .local)
                    locationError = message
                    if message != nil {
                        store.settings.iCloudSyncEnabled = !enabled
                        store.save()
                    }
                    isSwitchingLocation = false
                }
            }
        )
    }
}
