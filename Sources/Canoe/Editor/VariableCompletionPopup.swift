import AppKit
import SwiftUI

/// The SwiftUI content hosted inside the completion panel: the filtered
/// `{{name}}` rows plus a keyboard-hint footer. Selection is owned by the
/// controller; hover mirrors it so mouse and keyboard share one state.
struct VariableSuggestionList: View {
    let suggestions: [VariableSuggestion]
    /// Binding, not a value: selection changes (arrows, hover) mutate it in
    /// place, so SwiftUI only re-renders the affected rows - rebuilding the
    /// whole list per selection reset the scroll offset and made the rows
    /// visibly jump once the list overflowed the panel (dynamic variables
    /// pushed it past the visible cap).
    @Binding var selectedIndex: Int
    let onHover: (Bool, Int) -> Void
    let onPick: (Int) -> Void

    static let rowHeight: CGFloat = 24
    static let footerHeight: CGFloat = 20
    /// The dynamic section's header strip (fixed, so the panel's height
    /// math can include it exactly).
    static let dynamicSectionHeaderHeight: CGFloat = 22
    /// Rows shown before the list scrolls internally.
    static let maxVisibleRows = 8

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            // Postman-style grouping: the dynamic generators
                            // get their own section header once the list
                            // reaches them (type `$` to filter down to them).
                            if startsDynamicSection(at: index) {
                                dynamicSectionHeader
                            }
                            row(index, suggestion)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    guard suggestions.indices.contains(newIndex) else { return }
                    proxy.scrollTo(suggestions[newIndex].id)
                }
            }
            footer
        }
        .frame(width: AppSize.inspectorWidth)
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

    /// Whether row `index` opens the dynamic section: it is a dynamic
    /// candidate and the previous row (if any) is not.
    private func startsDynamicSection(at index: Int) -> Bool {
        guard suggestions.indices.contains(index), suggestions[index].isDynamic else { return false }
        return index == 0 || !suggestions[index - 1].isDynamic
    }

    /// Non-interactive section header before the dynamic candidates. The
    /// rows keep their own selection indices - headers are decoration only.
    private var dynamicSectionHeader: some View {
        HStack(spacing: AppSpacing.xxSmall) {
            Image(systemName: "bolt.fill")
                .font(AppFont.completionMetaSmall)
            Text("Dynamic Variables")
                .font(AppFont.microHeader)
            Spacer(minLength: 0)
            Text("fresh value per send")
                .font(AppFont.small)
                .foregroundStyle(AppColor.tertiaryText)
        }
        .foregroundStyle(AppColor.textSecondary)
        .padding(.horizontal, AppSpacing.small)
        .frame(maxWidth: .infinity)
        .frame(height: Self.dynamicSectionHeaderHeight, alignment: .leading)
        .background(AppColor.subtleBackground)
        .help("Generates a fresh value every time it resolves; no definition needed")
    }

    private func row(_ index: Int, _ suggestion: VariableSuggestion) -> some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text("{{\(suggestion.name)}}")
                .font(AppFont.monoSubheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            if suggestion.isSecret {
                Image(systemName: "key.fill")
                    .font(AppFont.completionMeta)
                    .foregroundStyle(AppColor.warning)
                    .help("Secret variable")
            }
            Spacer(minLength: AppSpacing.small)
            if suggestion.isDynamic {
                HStack(spacing: AppSpacing.xxSmall) {
                    Image(systemName: "bolt.fill")
                        .font(AppFont.completionMetaSmall)
                    Text("Dynamic")
                        .font(AppFont.small)
                }
                .foregroundStyle(AppColor.textSecondary)
                .help("Dynamic variable: a fresh value every time the request is sent")
            } else if let kind = suggestion.scopeKind {
                HStack(spacing: AppSpacing.xxSmall) {
                    Image(systemName: kind.systemImage)
                        .font(AppFont.completionMetaSmall)
                    Text(kind.rawValue)
                        .font(AppFont.small)
                }
                .foregroundStyle(AppColor.textSecondary)
            }
        }
        .padding(.horizontal, AppSpacing.small)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        .background(index == selectedIndex ? AppColor.selectionBackground : Color.clear)
        .contentShape(Rectangle())
        .helpIf(suggestion.summary != nil, suggestion.summary ?? "")
        .onHover { hovering in onHover(hovering, index) }
        .onTapGesture { onPick(index) }
        .clickCursor()
        .id(suggestion.id)
    }

    private var footer: some View {
        Text("↑↓ Navigate   ↩ Insert   esc Dismiss")
            .font(AppFont.small)
            .foregroundStyle(AppColor.tertiaryText)
            .frame(maxWidth: .infinity, minHeight: Self.footerHeight, maxHeight: Self.footerHeight)
            .overlay(Divider(), alignment: .top)
    }
}

/// Drives the `{{variable}}` completion popup for one text view: parses the
/// fragment under the caret, filters candidates, shows/positions a
/// non-activating panel anchored to the caret, and owns the interaction -
/// arrow keys to navigate, Return/Tab to insert, Escape to dismiss, mouse to
/// hover/pick. Text editors (NSTextField field editors and the multi-line
/// NSTextView) call in from their delegate callbacks.
@MainActor
final class VariableCompletionController: NSObject {
    private struct Session: Equatable {
        let context: VariableCompletionEngine.Context
        let matches: [VariableSuggestion]
        var selectedIndex: Int
    }

    private var candidates: [VariableSuggestion] = []
    private var session: Session?
    private weak var textView: NSTextView?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<VariableSuggestionList>?
    private var isWatchingDismissal = false
    private var mouseDownMonitor: Any?

    var isVisible: Bool { session != nil }

    /// The open suggestion panel, if any. Editors that watch for
    /// click-outside-to-blur use it to exempt popup picks (a non-activating
    /// panel never moves keyboard focus, so picking must not blur the field).
    var popupWindow: NSWindow? { panel }

    // MARK: - Input from the editors

    /// Replaces the candidate universe (parents re-render on every keystroke)
    /// and re-evaluates an open popup against the new candidates.
    func setCandidates(_ candidates: [VariableSuggestion]) {
        self.candidates = candidates
        if session != nil, let textView {
            updateSession(for: textView, allowNewSession: false)
        }
    }

    /// The editor text changed: (re)evaluate the popup from scratch.
    func textChanged(_ textView: NSTextView) {
        updateSession(for: textView, allowNewSession: true)
    }

    /// Only the caret moved: keep an open popup glued to it, but never open
    /// one from pure navigation (completion appears on typing, Postman-style).
    func selectionChanged(_ textView: NSTextView) {
        guard session != nil else { return }
        updateSession(for: textView, allowNewSession: false)
    }

    // MARK: - Keyboard commands (from the editors' doCommandBy)

    /// Handles the popup's key commands; returns true when the selector was
    /// consumed (the editor should not process it further).
    func handleCommand(_ selector: Selector) -> Bool {
        guard session != nil else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            return accept()
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: - Session

    private func updateSession(for textView: NSTextView, allowNewSession: Bool) {
        self.textView = textView
        guard allowNewSession || session != nil else { return }
        guard
            textView.isEditable,
            textView.selectedRange().length == 0,
            !textView.hasMarkedText(),
            let context = VariableCompletionEngine.context(
                atCaret: textView.selectedRange().location,
                in: textView.string
            )
        else {
            hide()
            return
        }
        let matches = VariableCompletionEngine.suggestions(matching: context, from: candidates)
        guard !matches.isEmpty else {
            hide()
            return
        }
        let sameMatches = session?.matches == matches
        let selectedIndex = sameMatches ? min(session?.selectedIndex ?? 0, matches.count - 1) : 0
        let wasHidden = session == nil
        session = Session(context: context, matches: matches, selectedIndex: selectedIndex)
        if wasHidden || !sameMatches {
            refreshContent()
        } else {
            // Same matches, caret moved: reposition only.
            positionPanel()
        }
    }

    private func moveSelection(_ delta: Int) {
        guard var session, !session.matches.isEmpty else { return }
        session.selectedIndex = (session.selectedIndex + delta + session.matches.count) % session.matches.count
        // Selection only: the list observes the binding and updates its rows
        // (and scrolls to the new selection) in place - rebuilding the
        // rootView here would reset the scroll offset on every arrow press.
        self.session = session
    }

    /// Inserts the selected (or clicked) suggestion: `{{fragment` becomes
    /// `{{name}}`, swallowing a trailing `}}` when the caret sat inside a
    /// closed placeholder.
    @discardableResult
    func accept(at index: Int? = nil) -> Bool {
        guard let session, let textView, session.matches.indices.contains(index ?? session.selectedIndex) else {
            hide()
            return false
        }
        let suggestion = session.matches[index ?? session.selectedIndex]
        let replacementRange = session.context.replacementRange
        hide()
        // The standard editing path: registers undo, fires didChangeText,
        // and leaves the caret right after the inserted `}}`.
        textView.insertText("\(suggestion.name)}}", replacementRange: replacementRange)
        return true
    }

    // MARK: - Panel

    private func refreshContent() {
        guard let session else { return }
        _ = ensurePanel()
        hostingView?.rootView = VariableSuggestionList(
            suggestions: session.matches,
            selectedIndex: Binding(
                get: { [weak self] in self?.session?.selectedIndex ?? 0 },
                set: { [weak self] index in self?.session?.selectedIndex = index }
            ),
            onHover: { [weak self] hovering, index in
                self?.hoverRow(hovering, index: index)
            },
            onPick: { [weak self] index in
                self?.accept(at: index)
            }
        )
        positionPanel()
    }

    private func hoverRow(_ hovering: Bool, index: Int) {
        // Only hover-enter moves the selection; hover-exit events (which the
        // re-render itself produces) must not undo it. Binding-driven, like
        // the arrow keys - no rootView rebuild (see moveSelection).
        guard hovering, let session, session.selectedIndex != index else { return }
        self.session?.selectedIndex = index
    }

    private func positionPanel() {
        guard let session, let textView, let window = textView.window else { return }
        let panel = ensurePanel()
        let height = listHeight(for: session.matches)
        guard let frame = anchoredFrame(for: textView, height: height) else {
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

    /// Rows (capped at the visible count) plus the footer, and the dynamic
    /// section's header strip whenever dynamic candidates are in the list -
    /// the header lives inside the scrolling content, so the panel must be
    /// taller by exactly its height or the rows clip at the bottom.
    private func listHeight(for matches: [VariableSuggestion]) -> CGFloat {
        let rows =
            CGFloat(min(matches.count, VariableSuggestionList.maxVisibleRows))
            * VariableSuggestionList.rowHeight
        let header = matches.contains(where: \.isDynamic) ? VariableSuggestionList.dynamicSectionHeaderHeight : 0
        return rows + header + VariableSuggestionList.footerHeight
    }

    /// Screen-space frame for the panel: just below the caret when there is
    /// room, above it otherwise, clamped into the visible screen.
    private func anchoredFrame(for textView: NSTextView, height: CGFloat) -> NSRect? {
        guard let window = textView.window, var caretRect = caretScreenRect(for: textView) else { return nil }
        if caretRect.isEmpty {
            let viewRect = textView.convert(textView.bounds, to: nil)
            caretRect = window.convertToScreen(viewRect)
        }
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) }) ?? window.screen
        else { return nil }
        let visible = screen.visibleFrame
        let gap: CGFloat = 2
        let width = AppSize.inspectorWidth
        var origin = NSPoint(x: caretRect.minX - 2, y: caretRect.minY - gap - height)
        if origin.y < visible.minY {
            let aboveY = caretRect.maxY + gap
            if aboveY + height <= visible.maxY {
                origin.y = aboveY
            } else {
                origin.y = max(visible.minY, min(origin.y, visible.maxY - height))
            }
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    /// Screen-space rect of the caret's line, via the layout manager
    /// (`firstRect` is unavailable in Swift). Probing a real character keeps
    /// the glyph math valid; the caret sits at its leading edge (or the last
    /// character's trailing edge at the end of the text).
    private func caretScreenRect(for textView: NSTextView) -> NSRect? {
        guard
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer,
            let window = textView.window
        else { return nil }
        let ns = textView.string as NSString
        let caretLocation = textView.selectedRange().location
        let characterRange: NSRange
        if caretLocation < ns.length {
            characterRange = NSRange(location: caretLocation, length: 1)
        } else if ns.length > 0 {
            characterRange = NSRange(location: ns.length - 1, length: 1)
        } else {
            characterRange = NSRange(location: 0, length: 0)
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard lineRect.width > 0, lineRect.height > 0 else { return nil }
        let caretX: CGFloat
        if caretLocation < ns.length {
            caretX = lineRect.minX
        } else {
            caretX = lineRect.maxX
        }
        // Container coordinates → view coordinates → window → screen.
        let viewRect = NSRect(
            x: caretX + textView.textContainerOrigin.x,
            y: lineRect.minY + textView.textContainerOrigin.y,
            width: 1,
            height: lineRect.height
        )
        return window.convertToScreen(textView.convert(viewRect, to: nil))
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppSize.inspectorWidth, height: 100),
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
            rootView: VariableSuggestionList(suggestions: [], selectedIndex: .constant(0), onHover: { _, _ in }, onPick: { _ in })
        )
        panel.contentView = hosting
        hostingView = hosting
        self.panel = panel
        return panel
    }

    // MARK: - Dismissal watchers

    /// While the popup is open: hide it when the app resigns active, and when
    /// a click lands anywhere except the popup itself and the editing text
    /// view (clicking inside the text view just moves the caret, which
    /// re-evaluates the popup).
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
        guard let textView, session != nil else { return }
        if let panel, event.window === panel { return }
        let locationInEditor = textView.convert(event.locationInWindow, from: nil)
        if event.window === textView.window, textView.bounds.contains(locationInEditor) {
            return
        }
        hide()
    }

    func hide() {
        session = nil
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
