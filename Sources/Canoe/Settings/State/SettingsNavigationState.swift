import Observation

/// One settings window's session. Browser semantics: choosing a pane truncates
/// what was ahead, and re-choosing it is not a move.
@MainActor
@Observable
final class SettingsNavigationState {
    private var history: [SettingsPane] = [.appearance]
    private var historyIndex = 0

    /// Refreshed by every navigation so the AppKit toolbar can sync its title
    /// and button states.
    var onChange: (() -> Void)?

    var pane: SettingsPane { history[historyIndex] }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func select(_ pane: SettingsPane) {
        guard pane != history[historyIndex] else { return }
        history.removeSubrange((historyIndex + 1)...)
        history.append(pane)
        historyIndex = history.count - 1
        onChange?()
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        onChange?()
    }

    func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        onChange?()
    }
}
