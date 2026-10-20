import SwiftUI

/// Contents of the Keyboard Shortcuts window (Help ▸ Keyboard Shortcuts,
/// ⌘/ - Postman opens the same cheat sheet with ⌘/): the app's shortcuts
/// grouped like Postman's Shortcuts tab, one action-per-row table with the
/// key glyphs right-aligned.
///
/// The list mirrors the menu bar (this is a reading aid, not a second
/// source of truth): when a shortcut changes, update the menu and the row
/// here together.
struct KeyboardShortcutsView: View {
    private struct Shortcut: Identifiable {
        let action: String
        let keys: String
        var id: String { action }
    }

    private struct Group: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    private static let groups: [Group] = [
        Group(
            title: "General",
            shortcuts: [
                Shortcut(action: "New Tab", keys: "⌘T"),
                Shortcut(action: "New Request", keys: "⌘N"),
                Shortcut(action: "New Collection", keys: "⇧⌘N"),
                Shortcut(action: "New Environment", keys: "⌘E"),
                Shortcut(action: "Duplicate Request", keys: "⌘D"),
                Shortcut(action: "Save", keys: "⌘S"),
                Shortcut(action: "Reveal Vault in Finder", keys: "⌘R"),
                Shortcut(action: "Settings", keys: "⌘,"),
                Shortcut(action: "Canoe Help", keys: "⌘?"),
            ]),
        Group(
            title: "Tabs",
            shortcuts: [
                Shortcut(action: "Next Tab", keys: "⌘⇧]"),
                Shortcut(action: "Previous Tab", keys: "⌘⇧["),
                Shortcut(action: "Switch to Tab", keys: "⌘1–9"),
                Shortcut(action: "Close Tab", keys: "⌘W"),
                Shortcut(action: "Close Other Tabs", keys: "⌘⌥W"),
            ]),
        Group(
            title: "Request",
            shortcuts: [
                Shortcut(action: "Send Request", keys: "⌘↩"),
                Shortcut(action: "Cancel Request", keys: "⎋"),
                Shortcut(action: "Jump to Request URL", keys: "⌘L"),
                Shortcut(action: "Search in Response", keys: "⌘F"),
            ]),
        Group(
            title: "Interface",
            shortcuts: [
                Shortcut(action: "Toggle Sidebar", keys: "⌘\\"),
                Shortcut(action: "Variables in Request", keys: "⇧⌘V"),
                Shortcut(action: "Right Sidebar", keys: "⌘⌥\\"),
                Shortcut(action: "Console", keys: "⌘⌥C"),
                Shortcut(action: "Enter Full Screen", keys: "⌃⌘F"),
            ]),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.large) {
                ForEach(Self.groups) { group in
                    VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                        Text(group.title)
                            .font(AppFont.small.weight(.semibold))
                            .foregroundStyle(AppColor.textSecondary)
                        ForEach(group.shortcuts) { shortcut in
                            row(shortcut)
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.vertical, AppSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColor.controlBackground)
        // The full-size-content window already reports the transparent
        // titlebar as a top safe-area inset, which pushes the first group
        // below the window title - no extra clearance margin needed (unlike
        // LicenseView, whose scrolling text would otherwise touch the title).
        // Window root: no control here takes focus, but the scroll view can
        // (see the focus-ring checklist in AGENTS.md).
        .focusEffectDisabled()
    }

    private func row(_ shortcut: Shortcut) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Text(shortcut.action)
                .font(AppFont.rowTitle.weight(.regular))
                .foregroundStyle(AppColor.textPrimary)
            Spacer(minLength: 0)
            Text(shortcut.keys)
                .font(AppFont.monoCaption)
                .foregroundStyle(AppColor.textSecondary)
                .padding(.horizontal, AppSpacing.compact)
                .padding(.vertical, AppSpacing.xxSmall)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(AppColor.subtleBackground)
                )
        }
        .padding(.vertical, AppSpacing.xxSmall)
    }
}
