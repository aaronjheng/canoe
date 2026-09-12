import AppKit
import SwiftUI

/// A real `NSSplitViewController` so the toolbar can use
/// `.sidebarTrackingSeparator`.
@MainActor
final class SettingsSplitViewController: NSSplitViewController {
    init(sidebar: some View, detail: some View) {
        super.init(nibName: nil, bundle: nil)

        // sizingOptions must stay empty so SwiftUI never drives the window
        // size (the window owns its frame and minimum size instead).
        let sidebarHost = NSHostingController(rootView: sidebar)
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        // Fixed: nothing here reflows with width.
        sidebarItem.minimumThickness = AppSize.settingsSidebarWidth
        sidebarItem.maximumThickness = AppSize.settingsSidebarWidth
        sidebarItem.canCollapse = false

        let detailHost = NSHostingController(rootView: detail)
        detailHost.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = AppSize.settingsDetailMinimumWidth

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
