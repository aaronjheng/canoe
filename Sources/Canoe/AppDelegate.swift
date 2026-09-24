import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appStore = AppStore()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsToolbarController: SettingsToolbarController?
    private var variablesMenuItem: NSMenuItem?
    private var fullScreenMenuItem: NSMenuItem?
    private var appearanceMenuItems: [NSMenuItem] = []
    // File-menu items that only make sense with an active workspace; their
    // enabled state tracks the store (see refreshWorkspaceMenuItems).
    private var newRequestMenuItem: NSMenuItem?
    private var newCollectionMenuItem: NSMenuItem?
    private var newEnvironmentMenuItem: NSMenuItem?
    private var saveMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppKitFocusRing.install()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        (AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system).apply()
        buildMenuBar()

        let contentView = ContentView()
            .environment(appStore)
            .frame(minWidth: 980, minHeight: 620)
            .focusEffectDisabled()

        let mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.center()
        mainWindow.title = "Canoe"
        // Postman-style top bar: the SwiftUI content supplies the window
        // chrome (a solid top bar hosting the traffic lights), so the system
        // title bar is hidden - and its liquid-glass material with it.
        mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.styleMask.insert(.fullSizeContentView)
        mainWindow.contentView = NSHostingView(rootView: contentView)
        mainWindow.tabbingMode = .disallowed
        mainWindow.tabbingIdentifier = "Canoe"
        mainWindow.collectionBehavior.insert(.fullScreenPrimary)
        // Enforce the minimum interactively: the SwiftUI frame(minWidth:)
        // modifier does not propagate to the NSWindow, and a restored frame
        // must be clamped too (see the autosave name below).
        mainWindow.minSize = NSSize(width: 980, height: 620)
        // Remember the window frame across launches (AppKit-managed UI state
        // in UserDefaults, like the window toggles): reopening opens at the
        // size and position the user left. No saved frame yet - first run -
        // keeps the contentRect above.
        mainWindow.setFrameAutosaveName("Canoe Main Window")
        AppKitFocusRing.prepare(in: mainWindow)
        mainWindow.makeKeyAndOrderFront(nil)
        (AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system)
            .applyToWindow(mainWindow)
        window = mainWindow
        refreshWorkspaceMenuItems()
        observeEnvironmentChanges()
        observeSettingsChanges()
        observeWorkspaceChanges()
        observeFullScreenChanges()

        Task {
            await appStore.prepare(
                iCloudSyncEnabled: SettingsStore.shared.settings.iCloudSyncEnabled)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved edits live in memory and are mirrored to drafts.json
        // (debounced) - wait for an in-flight Save-all to land, then flush
        // the mirror, before quitting so the next launch restores the
        // edited state. Nothing is prompted and nothing is persisted as
        // saved content beyond what ⌘S already requested.
        appStore.flushAllWritesForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func newRequest() {
        guard !isSettingsWindowKey else { return }
        appStore.addRequest()
    }

    @objc func selectNextTab() {
        guard !isSettingsWindowKey else { return }
        appStore.selectNextTab()
    }

    @objc func selectPreviousTab() {
        guard !isSettingsWindowKey else { return }
        appStore.selectPreviousTab()
    }

    @objc func newCollection() {
        guard !isSettingsWindowKey else { return }
        appStore.addCollection()
    }

    @objc func newWorkspace() {
        guard !isSettingsWindowKey else { return }
        appStore.addWorkspace()
    }

    @objc func newEnvironment() {
        guard !isSettingsWindowKey else { return }
        appStore.addEnvironment()
    }

    @objc func clearHistory() {
        guard !isSettingsWindowKey else { return }
        appStore.clearHistory()
    }

    @objc func saveRequest() {
        guard !isSettingsWindowKey else { return }
        appStore.savePendingChanges()
    }

    @objc func closeTab() {
        // ⌘W in Settings must close Settings (macOS standard), not the
        // workspace tab behind it - both windows share one mainMenu.
        if isSettingsWindowKey {
            settingsWindow?.performClose(nil)
            return
        }
        appStore.closeSelectedTab()
    }

    @objc func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    @objc func revealVault() {
        appStore.vault.revealInFinder()
    }

    /// Shows/hides the console panel docked below the Response pane.
    @objc func toggleConsole() {
        guard !isSettingsWindowKey else { return }
        appStore.toggleConsole()
    }

    /// Opens the top-level workspaces management screen.
    @objc func openWorkspaces() {
        guard !isSettingsWindowKey else { return }
        appStore.enterWorkspacesManager()
    }

    @objc func openSettings() {
        if let settingsWindow {
            // Re-apply the current appearance: the window may have been
            // created before a menu-driven theme change while it was closed.
            (AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system)
                .applyToWindow(settingsWindow)
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let navigation = SettingsNavigationState()
        let split = SettingsSplitViewController(
            sidebar: SettingsSidebarView().environment(navigation).focusEffectDisabled(),
            detail: SettingsView().environment(navigation).environment(appStore).focusEffectDisabled()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 780, height: 520)
        window.setContentSize(NSSize(width: 780, height: 520))
        let toolbarController = SettingsToolbarController(navigation: navigation)
        toolbarController.install(in: window)
        settingsToolbarController = toolbarController
        window.center()
        (AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system)
            .applyToWindow(window)
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    /// Releases the Settings window (and its split/toolbar controllers) on
    /// close instead of holding a hidden zombie: reopening builds a fresh
    /// window instead of reusing stale navigation state.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == settingsWindow else { return }
        settingsWindow = nil
        settingsToolbarController = nil
    }

    // MARK: - Inspectors

    /// Whether the Settings window currently has keyboard focus. Workspace
    /// actions share one mainMenu across both windows, so they must no-op
    /// here instead of mutating the workspace behind Settings.
    private var isSettingsWindowKey: Bool {
        guard let settingsWindow else { return false }
        return NSApp.keyWindow == settingsWindow
    }

    @objc func toggleVariablesSidebar() {
        guard !isSettingsWindowKey else { return }
        appStore.toggleVariablesSidebar()
    }

    /// Keeps the View-menu checkmark for the variables inspector in step with
    /// the store, however the panel was shown or hidden (the tab-row buttons
    /// are SwiftUI now and sync themselves).
    private func observeEnvironmentChanges() {
        withObservationTracking {
            _ = appStore.showVariablesSidebar
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.variablesMenuItem?.state =
                    self?.appStore.showVariablesSidebar == true ? .on : .off
                self?.observeEnvironmentChanges()
            }
        }
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        guard let appearance = AppAppearance(rawValue: sender.tag) else { return }
        SettingsStore.shared.settings.appearance = appearance.rawValue
        SettingsStore.shared.save()
        appearance.apply()
        for window in NSApp.windows {
            appearance.applyToWindow(window)
        }
        refreshAppearanceMenu()
    }

    /// Syncs the View-menu checkmarks with the store, however the appearance
    /// was changed (menu or Settings panel).
    private func refreshAppearanceMenu() {
        let current = AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system
        for item in appearanceMenuItems {
            item.state = item.tag == current.rawValue ? .on : .off
        }
    }

    /// Keeps the View-menu checkmarks in step when the appearance changes
    /// from the Settings panel.
    private func observeSettingsChanges() {
        withObservationTracking {
            _ = SettingsStore.shared.settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshAppearanceMenu()
                self?.observeSettingsChanges()
            }
        }
    }

    /// File-menu items that create or persist workspace content are only
    /// enabled with an active workspace: firing them in the workspaces
    /// manager would land data where nobody can see it (the tab strip is
    /// not rendered there), and on the welcome screen it would create
    /// workspaceless data no workspace can ever display.
    private func refreshWorkspaceMenuItems() {
        let enabled = appStore.activeWorkspace != nil
        newRequestMenuItem?.isEnabled = enabled
        newCollectionMenuItem?.isEnabled = enabled
        newEnvironmentMenuItem?.isEnabled = enabled
        saveMenuItem?.isEnabled = enabled
    }

    private func observeWorkspaceChanges() {
        withObservationTracking {
            _ = appStore.activeWorkspace
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshWorkspaceMenuItems()
                self?.observeWorkspaceChanges()
            }
        }
    }

    /// Swaps the Full Screen menu title with the window state (macOS
    /// standard behavior lost by using a custom menu item).
    private func observeFullScreenChanges() {
        for name in [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(refreshFullScreenMenu),
                name: name,
                object: nil
            )
        }
    }

    @objc private func refreshFullScreenMenu() {
        let isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
        fullScreenMenuItem?.title = isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
    }

    private func buildMenuBar() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Canoe",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Canoe",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        // Manual enable/disable for the workspace-bound items below; with
        // auto-validation the menu would leave them enabled in the
        // workspaces manager and on the welcome screen.
        fileMenu.autoenablesItems = false
        let newRequestItem = NSMenuItem(
            title: "New Request",
            action: #selector(newRequest),
            keyEquivalent: "n")
        newRequestMenuItem = newRequestItem
        fileMenu.addItem(newRequestItem)
        let newCollectionItem = NSMenuItem(
            title: "New Collection",
            action: #selector(newCollection),
            keyEquivalent: "N")
        newCollectionMenuItem = newCollectionItem
        fileMenu.addItem(newCollectionItem)
        fileMenu.addItem(
            withTitle: "New Workspace",
            action: #selector(newWorkspace),
            keyEquivalent: "")
        let newEnvironmentItem = NSMenuItem(
            title: "New Environment",
            action: #selector(newEnvironment),
            keyEquivalent: "e")
        newEnvironmentMenuItem = newEnvironmentItem
        fileMenu.addItem(newEnvironmentItem)
        let saveItem = NSMenuItem(
            title: "Save",
            action: #selector(saveRequest),
            keyEquivalent: "s")
        saveMenuItem = saveItem
        fileMenu.addItem(saveItem)
        fileMenu.addItem(.separator())
        // Tab cycling lives with the tab lifecycle commands; the actions
        // no-op gracefully when the strip is empty.
        let selectPreviousTabItem = NSMenuItem(
            title: "Select Previous Tab",
            action: #selector(selectPreviousTab),
            keyEquivalent: "[")
        selectPreviousTabItem.keyEquivalentModifierMask = [.command, .shift]
        selectPreviousTabItem.target = self
        fileMenu.addItem(selectPreviousTabItem)
        let selectNextTabItem = NSMenuItem(
            title: "Select Next Tab",
            action: #selector(selectNextTab),
            keyEquivalent: "]")
        selectNextTabItem.keyEquivalentModifierMask = [.command, .shift]
        selectNextTabItem.target = self
        fileMenu.addItem(selectNextTabItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close Tab",
            action: #selector(closeTab),
            keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Reveal Vault in Finder",
            action: #selector(revealVault),
            keyEquivalent: "R")
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Clear History",
            action: #selector(clearHistory),
            keyEquivalent: "")
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let fullScreenItem = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(toggleFullScreen),
            keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        fullScreenItem.target = self
        fullScreenMenuItem = fullScreenItem
        viewMenu.addItem(fullScreenItem)
        viewMenu.addItem(.separator())
        let variablesItem = NSMenuItem(
            title: "Variables in Request",
            action: #selector(toggleVariablesSidebar),
            keyEquivalent: "v")
        variablesItem.keyEquivalentModifierMask = [.command, .shift]
        variablesItem.target = self
        variablesItem.state = appStore.showVariablesSidebar ? .on : .off
        variablesMenuItem = variablesItem
        viewMenu.addItem(variablesItem)
        viewMenu.addItem(.separator())
        let consoleItem = NSMenuItem(
            title: "Console",
            action: #selector(toggleConsole),
            keyEquivalent: "c")
        consoleItem.keyEquivalentModifierMask = [.command, .option]
        consoleItem.target = self
        viewMenu.addItem(consoleItem)
        let workspacesItem = NSMenuItem(
            title: "Workspaces",
            action: #selector(openWorkspaces),
            keyEquivalent: "")
        workspacesItem.target = self
        viewMenu.addItem(workspacesItem)
        viewMenu.addItem(.separator())
        let appearanceHeader = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceHeader.isEnabled = false
        viewMenu.addItem(appearanceHeader)
        let currentAppearance = AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system
        for appearance in AppAppearance.allCases {
            let item = NSMenuItem(
                title: appearance.name,
                action: #selector(setAppearance(_:)),
                keyEquivalent: "")
            item.tag = appearance.rawValue
            item.target = self
            item.state = currentAppearance == appearance ? .on : .off
            appearanceMenuItems.append(item)
            viewMenu.addItem(item)
        }
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }
}
