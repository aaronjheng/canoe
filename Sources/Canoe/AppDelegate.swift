import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appStore = AppStore()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsToolbarController: SettingsToolbarController?
    private var variablesMenuItem: NSMenuItem?
    private var fullScreenMenuItem: NSMenuItem?
    private var appearanceMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        (AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system).apply()
        buildMenuBar()

        let contentView = ContentView()
            .environment(appStore)
            .frame(minWidth: 980, minHeight: 620)

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
        mainWindow.makeKeyAndOrderFront(nil)
        (AppAppearance(rawValue: SettingsStore.shared.settings.appearance) ?? .system)
            .applyToWindow(mainWindow)
        window = mainWindow
        observeEnvironmentChanges()
        observeSettingsChanges()
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
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let navigation = SettingsNavigationState()
        let split = SettingsSplitViewController(
            sidebar: SettingsSidebarView().environment(navigation),
            detail: SettingsView().environment(navigation).environment(appStore)
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
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
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
        fileMenu.addItem(
            withTitle: "New Request",
            action: #selector(newRequest),
            keyEquivalent: "n")
        fileMenu.addItem(
            withTitle: "New Collection",
            action: #selector(newCollection),
            keyEquivalent: "N")
        fileMenu.addItem(
            withTitle: "New Workspace",
            action: #selector(newWorkspace),
            keyEquivalent: "")
        fileMenu.addItem(
            withTitle: "New Environment",
            action: #selector(newEnvironment),
            keyEquivalent: "e")
        fileMenu.addItem(
            withTitle: "Save",
            action: #selector(saveRequest),
            keyEquivalent: "s")
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
