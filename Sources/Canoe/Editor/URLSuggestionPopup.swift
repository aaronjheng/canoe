import AppKit
import SwiftUI

/// One URL-history suggestion row: the request's method (display only) and
/// the URL exactly as entered. Built from the machine-local history.
struct URLSuggestion: Identifiable {
    let id = UUID()
    let method: HTTPMethod
    let urlString: String
}

/// The panel content: recent URLs, the highlighted one mirroring the
/// keyboard selection; hover and click share one selection state. No
/// footer - the affordance is the URL bar's own focus, not a popup.
struct URLSuggestionList: View {
    let suggestions: [URLSuggestion]
    let selectedIndex: Int
    let onHover: (Bool, Int) -> Void
    let onPick: (Int) -> Void

    static let rowHeight: CGFloat = 26
    static let maxVisibleRows = 8

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        row(index, suggestion)
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                guard suggestions.indices.contains(newIndex) else { return }
                proxy.scrollTo(suggestions[newIndex].id)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(AppColor.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(AppColor.border, lineWidth: AppLine.field)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    private func row(_ index: Int, _ suggestion: URLSuggestion) -> some View {
        HStack(spacing: AppSpacing.small) {
            MethodTag(method: suggestion.method)
            Text(suggestion.urlString)
                .font(AppFont.monoSubheadline)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.small)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        .background(index == selectedIndex ? AppColor.selectionBackground : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in onHover(hovering, index) }
        .onTapGesture { onPick(index) }
        .clickCursor()
        .id(suggestion.id)
    }
}

/// Drives the URL bar's history suggestions: a non-activating panel under
/// the URL bar listing recent URLs (filtered by the current text), with
/// arrow keys to navigate, Return to fill, Escape/click-away to dismiss.
/// Sibling of `VariableCompletionController` - same panel pattern, but the
/// session opens on focus (not on a `{{` fragment) and accepting replaces
/// the whole field text, which re-runs the URL bar's query parsing.
@MainActor
final class URLSuggestionController: NSObject {
    private var candidates: [URLSuggestion] = []
    private var matches: [URLSuggestion] = []
    private var selectedIndex = 0
    private weak var textView: NSTextView?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<URLSuggestionList>?
    private var isWatchingDismissal = false
    private var mouseDownMonitor: Any?

    /// True while a session with matches is on screen.
    var isVisible: Bool { panel?.isVisible == true && !matches.isEmpty }

    /// The open panel, if any. The URL bar's click-away watcher exempts it
    /// (a non-activating panel never moves keyboard focus, so picking must
    /// not blur the field).
    var popupWindow: NSWindow? { panel }

    // MARK: - Input from the editor

    /// Replaces the candidate universe (recent history, newest first) and
    /// re-filters an open panel against it.
    func setCandidates(_ candidates: [URLSuggestion]) {
        self.candidates = candidates
        if isVisible, let textView {
            refilter(for: textView)
        }
    }

    /// The URL bar gained keyboard focus: open with the current text's
    /// matches (all recents when the bar is empty). No matches, no panel.
    func open(for textView: NSTextView) {
        self.textView = textView
        refilter(for: textView)
    }

    /// The URL text changed while focused: re-filter; no matches closes.
    func textChanged(_ textView: NSTextView) {
        self.textView = textView
        guard isVisible else { return }
        refilter(for: textView)
    }

    private func refilter(for textView: NSTextView) {
        let query = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [URLSuggestion]
        if query.isEmpty {
            filtered = candidates
        } else {
            filtered = candidates.filter { $0.urlString.localizedCaseInsensitiveContains(query) }
        }
        guard !filtered.isEmpty else {
            hide()
            return
        }
        let sameMatches = matches.map(\.urlString) == filtered.map(\.urlString)
        selectedIndex = sameMatches ? min(selectedIndex, filtered.count - 1) : 0
        let wasHidden = !isVisible
        matches = filtered
        if wasHidden || !sameMatches {
            refreshContent()
        } else {
            positionPanel()
        }
    }

    // MARK: - Keyboard (from the editor's doCommandBy)

    /// Handles the panel's key commands; returns true when consumed.
    func handleCommand(_ selector: Selector) -> Bool {
        guard isVisible else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            accept()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + matches.count) % matches.count
        refreshContent()
    }

    /// Replaces the field's whole text with the picked URL through the
    /// standard editing path (undo-able; fires the text-change callbacks
    /// so the binding and the params table follow), then hides.
    func accept(at index: Int? = nil) {
        guard let textView, matches.indices.contains(index ?? selectedIndex) else {
            hide()
            return
        }
        let urlString = matches[index ?? selectedIndex].urlString
        hide()
        textView.insertText(
            urlString,
            replacementRange: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        // Park the caret at the end, like a browser autocomplete fill.
        textView.setSelectedRange(NSRange(location: (urlString as NSString).length, length: 0))
    }

    // MARK: - Panel

    private func refreshContent() {
        guard !matches.isEmpty else { return }
        _ = ensurePanel()
        hostingView?.rootView = URLSuggestionList(
            suggestions: matches,
            selectedIndex: selectedIndex,
            onHover: { [weak self] hovering, index in
                // Only hover-enter moves the selection (re-renders emit
                // spurious exits, same rule as the variable popup).
                guard hovering, let self, selectedIndex != index else { return }
                selectedIndex = index
                refreshContent()
            },
            onPick: { [weak self] index in
                self?.accept(at: index)
            }
        )
        positionPanel()
    }

    private func positionPanel() {
        guard let textView, let window = textView.window else { return }
        let panel = ensurePanel()
        guard let frame = anchoredFrame(for: textView) else {
            hide()
            return
        }
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        registerDismissWatchers()
    }

    /// Screen-space frame: the full row of URLs hangs below the (possibly
    /// expanded) URL bar, leading-aligned with it and at least as wide,
    /// flipped above when the bottom would overflow the visible screen.
    private func anchoredFrame(for textView: NSTextView) -> NSRect? {
        guard let window = textView.window else { return nil }
        let viewRect = textView.convert(textView.bounds, to: nil)
        let fieldRect = window.convertToScreen(viewRect)
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(fieldRect) }) ?? window.screen
        else { return nil }
        let visible = screen.visibleFrame
        let height = listHeight(for: matches.count)
        let width = max(400, min(560, fieldRect.width))
        let gap: CGFloat = 2
        var origin = NSPoint(x: fieldRect.minX, y: fieldRect.minY - gap - height)
        if origin.y < visible.minY {
            let aboveY = fieldRect.maxY + gap
            if aboveY + height <= visible.maxY {
                origin.y = aboveY
            } else {
                origin.y = max(visible.minY, min(origin.y, visible.maxY - height))
            }
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    private func listHeight(for matchCount: Int) -> CGFloat {
        CGFloat(min(matchCount, URLSuggestionList.maxVisibleRows)) * URLSuggestionList.rowHeight + 4
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.worksWhenModal = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        let hosting = NSHostingView(
            rootView: URLSuggestionList(suggestions: [], selectedIndex: 0, onHover: { _, _ in }, onPick: { _ in })
        )
        panel.contentView = hosting
        hostingView = hosting
        self.panel = panel
        return panel
    }

    // MARK: - Dismissal watchers

    private func registerDismissWatchers() {
        guard !isWatchingDismissal else { return }
        isWatchingDismissal = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleClickOutside(event)
            }
            return event
        }
    }

    @objc private func appDidResignActive() {
        hide()
    }

    private func handleClickOutside(_ event: NSEvent) {
        guard let textView, isVisible else { return }
        // Picks inside the panel are not dismissals.
        if let panel, event.window === panel { return }
        // A click inside the URL bar itself just moves the caret - keep
        // the panel up, like a browser's autocomplete dropdown.
        if event.window === textView.window, textView.bounds.contains(textView.convert(event.locationInWindow, from: nil)) {
            return
        }
        hide()
    }

    func hide() {
        guard panel?.isVisible == true || !matches.isEmpty else { return }
        matches = []
        if let panel {
            panel.orderOut(nil)
            panel.parent?.removeChildWindow(panel)
        }
        if isWatchingDismissal {
            isWatchingDismissal = false
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
        }
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
    }
}
