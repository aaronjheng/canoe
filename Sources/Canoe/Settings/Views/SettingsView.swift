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
    /// Staged turn-on of iCloud sync: enabling it merges the whole vault
    /// into the cloud container and repoints every read and write, so it
    /// asks first. Turning it off only moves the files back, and stays a
    /// single click.
    @State private var isConfirmingSyncOn = false

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
        .scrollContentBackground(.hidden)
        .background(AppColor.controlBackground)
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
            // All of them, not just the first: a stale location warning would
            // otherwise hide `saveError`, which is the one this window most
            // needs to show - the iCloud toggle is the likeliest thing to fail
            // a write, and this window does not host the main window's banner.
            let failures = [
                locationError,
                appStore.vault.locationWarning,
                appStore.vault.loadError,
                appStore.vault.saveError,
            ]
            .compactMap { $0 }
            if !failures.isEmpty {
                Section {
                    ForEach(failures, id: \.self) { message in
                        Text(message)
                            .foregroundStyle(AppColor.error)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.controlBackground)
        .confirmationDialog(
            "Sync your vault with iCloud Drive?",
            isPresented: $isConfirmingSyncOn,
            titleVisibility: .visible
        ) {
            Button("Sync with iCloud Drive") { enableSync() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(syncOnConfirmationMessage)
        }
    }

    /// What turning the toggle on actually does, stated before it does it.
    /// The merge is two-way and newest-file-wins (`VaultStore.mergeFile`),
    /// so it must NOT read as a one-way copy out: a file in iCloud Drive
    /// that is newer than its local twin replaces the local one. Stating
    /// that is the whole point of asking - the user is about to hand this
    /// decision a real conflict-resolution rule.
    private var syncOnConfirmationMessage: String {
        [
            "Canoe merges your saved requests, collections and environments "
                + "into your iCloud Drive, then reads and writes there from now on.",
            "Both copies are combined by taking the newer version of each file, "
                + "so a file in iCloud Drive that is newer than the one on this Mac replaces it here.",
            "Nothing is deleted, and turning the toggle off later brings the files back.",
        ].joined(separator: " ")
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
    /// Turning sync on is confirmed first (`isConfirmingSyncOn`) - the merge
    /// rewrites every vault file, so it must not ride a single stray click
    /// on a checkbox, the way every other irreversible action in the app
    /// (deleting a request, clearing history, closing with unsaved edits)
    /// asks first.
    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { store.settings.iCloudSyncEnabled },
            set: { enabled in
                guard !isSwitchingLocation else { return }
                if enabled {
                    isConfirmingSyncOn = true
                } else {
                    applySync(false)
                }
            }
        )
    }

    /// Confirmed turn-on (see `syncEnabled`).
    private func enableSync() {
        applySync(true)
    }

    private func applySync(_ enabled: Bool) {
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
}
