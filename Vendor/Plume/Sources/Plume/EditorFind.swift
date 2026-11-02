import AppKit
import SwiftUI

/// The editor's find/replace state, owned by SwiftUI and mirrored into the
/// coordinator on every update. `Equatable` so updateNSView can diff.
struct EditorFindState: Equatable {
    var visible = false
    var replacing = false
    var query = ""
    var replacement = ""
    var caseSensitive = false
}

/// Buttons/fields dispatch through this: the SwiftUI side sets a pending
/// action, updateNSView performs it on the coordinator and clears it (the
/// same deferred-action pattern as the method dropdown's pending pick).
enum EditorFindAction {
    case next
    case previous
    case replaceCurrent
    case replaceAll
}

/// AppKit → SwiftUI callbacks: ⌘F opening the bar (with the selection as
/// the prefill and whether the replace row shows), match count/index
/// updates, Esc closing the bar.
struct EditorFindHooks {
    let requested: (String?, Bool) -> Void
    let countChanged: (Int, Int?) -> Void
    let closed: () -> Void
    /// ⌥⌘E: adopt the selection as the find query (bar stays closed).
    let useSelection: (String) -> Void
    /// ⌥⌘L: open the go-to-line panel.
    let linePanel: () -> Void
}

/// The find/replace bar overlaid across the editor's top-right corner
/// (Xcode-style): fields stacked left, controls right, with a replace row
/// behind the toggle. Pure presentation - actions are handed back out.
struct EditorFindBar: View {
    @Binding var query: String
    @Binding var replacement: String
    @Binding var caseSensitive: Bool
    @Binding var replacing: Bool
    let matchCount: Int
    let matchIndex: Int?
    let isEditable: Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    let onClose: () -> Void

    @FocusState private var findFocused: Bool
    @FocusState private var replaceFocused: Bool

    private let fieldWidth: CGFloat = 300
    private let controlZoneWidth: CGFloat = 160

    var body: some View {
        HStack(alignment: .top, spacing: EditorTheme.spaceCompact) {
            VStack(alignment: .leading, spacing: 6) {
                findField
                if replacing {
                    replaceField
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    countLabel
                        .frame(width: 56, alignment: .trailing)
                    hoverButton("Aa", isActive: caseSensitive, help: "Match case") {
                        caseSensitive.toggle()
                    }
                    hoverButton(
                        "chevron.up", isActive: false, help: "Previous (Shift-Return)",
                        disabled: matchCount == 0, action: onPrevious)
                    hoverButton(
                        "chevron.down", isActive: false, help: "Next (Return)",
                        disabled: matchCount == 0, action: onNext)
                }
                .frame(width: controlZoneWidth, alignment: .trailing)
                if replacing {
                    HStack(spacing: 4) {
                        Button("Replace", action: onReplace)
                            .buttonStyle(EditorSecondaryButtonStyle(minHeight: 24))
                            .disabled(!isEditable || matchCount == 0)
                            .help("Replace current match (⌘⌥F)")
                        Button("All", action: onReplaceAll)
                            .buttonStyle(EditorSecondaryButtonStyle(minHeight: 24))
                            .disabled(!isEditable || matchCount == 0)
                            .help("Replace all matches (⌘⌥⇧F)")
                    }
                    .frame(width: controlZoneWidth, alignment: .trailing)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 4) {
                    EditorToolbarToggleButton(
                        systemImage: "text.magnifyingglass",
                        isOn: replacing,
                        help: replacing ? "Hide Replace" : "Show Replace"
                    ) {
                        replacing.toggle()
                    }
                    Button("Done", action: onClose)
                        .buttonStyle(EditorSecondaryButtonStyle(minHeight: 24))
                        .help("Close find bar (Esc)")
                }
                if replacing {
                    Color.clear.frame(height: 24)
                }
            }
        }
        .padding(EditorTheme.spaceSmall)
        .background(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .fill(EditorTheme.controlBackground)
                .shadow(color: EditorTheme.popupShadow, radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .strokeBorder(EditorTheme.border, lineWidth: EditorTheme.lineField)
        )
        .onAppear {
            // Focus after the field is actually in a window - a same-tick
            // FocusState write races the overlay's first layout.
            DispatchQueue.main.async { findFocused = true }
        }
        .onChange(of: replacing) { _, on in
            DispatchQueue.main.async {
                if on {
                    replaceFocused = true
                } else {
                    findFocused = true
                }
            }
        }
    }

    private var findField: some View {
        field(text: $query, prompt: "Find", focused: findFocused)
            .focused($findFocused)
            .onSubmit(onNext)
            .onExitCommand { onClose() }
    }

    private var replaceField: some View {
        field(text: $replacement, prompt: "Replace with", focused: replaceFocused)
            .focused($replaceFocused)
            .onSubmit(onReplace)
            .onExitCommand { onClose() }
    }

    private func field(text: Binding<String>, prompt: String, focused: Bool) -> some View {
        TextField(prompt, text: text)
            .font(EditorTheme.fontMonoSubheadline)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, EditorTheme.spaceCompact)
            .frame(width: fieldWidth, height: 26)
            .background(
                RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                    .fill(EditorTheme.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                    .strokeBorder(
                        focused ? EditorTheme.accent : EditorTheme.border,
                        lineWidth: focused ? EditorTheme.lineFocusedField : EditorTheme.lineField
                    )
            )
    }

    @ViewBuilder
    private var countLabel: some View {
        if query.isEmpty {
            Text(" ")
                .font(EditorTheme.fontSmall.monospacedDigit())
        } else if matchCount == 0 {
            Text("No results")
                .font(EditorTheme.fontSmall)
                .foregroundStyle(EditorTheme.error)
        } else if let matchIndex {
            Text("\(matchIndex + 1)/\(matchCount)")
                .font(EditorTheme.fontSmall.monospacedDigit())
                .foregroundStyle(EditorTheme.textSecondary)
        } else {
            Text("\(matchCount) found")
                .font(EditorTheme.fontSmall)
                .foregroundStyle(EditorTheme.textSecondary)
        }
    }

    /// The bar's quiet square button (Aa, chevrons): hover fill, on-state
    /// accent tint, disabled dim - the shared icon-button language.
    private func hoverButton(
        _ label: String,
        isActive: Bool,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(EditorTheme.fontSmall.weight(isActive ? .semibold : .regular))
                .foregroundStyle(
                    isActive ? EditorTheme.accent : EditorTheme.textSecondary
                )
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: EditorTheme.radiusSmall)
                        .fill(isActive ? EditorTheme.subtleBackground : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? EditorTheme.opacityDisabled : 1)
        .help(help)
    }
}

/// The go-to-line mini panel (⌥⌘L): a number field and a Go button,
/// matching the find bar's overlay language.
struct EditorGoToLineBar: View {
    @Binding var text: String
    let lineCount: Int
    let onClose: () -> Void
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: EditorTheme.spaceXSmall) {
            Text("Line")
                .font(EditorTheme.fontSmall)
                .foregroundStyle(EditorTheme.textSecondary)
            TextField("1–\(max(lineCount, 1))", text: $text)
                .font(EditorTheme.fontMonoSubheadline)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($focused)
                .onSubmit(onSubmit)
                .onExitCommand { onClose() }
                .onChange(of: text) { _, newValue in
                    let digitsOnly = newValue.filter { $0.isNumber }
                    text = digitsOnly
                }
                .padding(.horizontal, EditorTheme.spaceCompact)
                .frame(width: 110, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                        .fill(EditorTheme.fieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: EditorTheme.radiusSmall, style: .continuous)
                        .strokeBorder(
                            (text.isEmpty || Int(text) != nil)
                                ? EditorTheme.accent : EditorTheme.error,
                            lineWidth: EditorTheme.lineFocusedField
                        )
                )
            Button("Go", action: onSubmit)
                .buttonStyle(EditorSecondaryButtonStyle(minHeight: 24))
        }
        .padding(EditorTheme.spaceSmall)
        .background(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .fill(EditorTheme.controlBackground)
                .shadow(color: EditorTheme.popupShadow, radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: EditorTheme.radiusMedium, style: .continuous)
                .strokeBorder(EditorTheme.border, lineWidth: EditorTheme.lineField)
        )
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

// MARK: - Coordinator machinery

extension EditorCoordinator {
    /// Diffs the find state pushed from SwiftUI: recompute + highlight when
    /// the query/case/visibility changed, clear when closed.
    func syncFindState(_ state: EditorFindState, in textView: NSTextView) {
        guard state != lastFindState else { return }
        let wasVisible = lastFindState?.visible ?? false
        lastFindState = state
        guard state.visible else {
            if wasVisible || !findMatches.isEmpty { clearFind(in: textView) }
            return
        }
        refreshFindHighlights(in: textView, selectFirstAfterCaret: true)
    }

    func refreshFindHighlights(in textView: NSTextView) {
        refreshFindHighlights(in: textView, selectFirstAfterCaret: false)
    }

    private func refreshFindHighlights(in textView: NSTextView, selectFirstAfterCaret: Bool) {
        let state = parent.find
        guard state.visible, !state.query.isEmpty else {
            clearFind(in: textView)
            return
        }
        findMatches = Self.findMatches(
            in: textView.string, query: state.query, caseSensitive: state.caseSensitive)
        let caret = textView.selectedRange().location
        if selectFirstAfterCaret {
            // Query changed: select the first match at/after the caret
            // (wrapping to the first match), like Xcode.
            findCurrentIndex =
                findMatches.firstIndex(where: { NSMaxRange($0) > caret })
                ?? (findMatches.isEmpty ? nil : 0)
            if let index = findCurrentIndex {
                textView.setSelectedRange(findMatches[index])
                textView.scrollRangeToVisible(findMatches[index])
            }
        } else {
            // An edit in the editor: keep the index on the first match
            // ending at/after the caret so the count stays meaningful.
            findCurrentIndex =
                findMatches.firstIndex(where: { NSMaxRange($0) > caret })
                ?? (findMatches.isEmpty ? nil : findMatches.count - 1)
        }
        applyFindHighlights(in: textView)
        parent.findHooks?.countChanged(findMatches.count, findCurrentIndex)
    }

    private func clearFind(in textView: NSTextView) {
        findMatches = []
        findCurrentIndex = nil
        let length = (textView.string as NSString).length
        textView.layoutManager?.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        parent.findHooks?.countChanged(0, nil)
    }

    private func applyFindHighlights(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        layoutManager.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        guard !findMatches.isEmpty else { return }
        // Temporary background attributes overlay the storage tints (and
        // drop automatically on edits - the pipeline re-runs this after).
        let wash = NSColor(EditorTheme.warning).withAlphaComponent(0.28)
        let currentWash = NSColor(EditorTheme.warning).withAlphaComponent(0.48)
        for (index, range) in findMatches.enumerated() {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: index == findCurrentIndex ? currentWash : wash,
                forCharacterRange: range)
        }
    }

    /// All occurrences of `query`, non-overlapping, in order.
    static func findMatches(in text: String, query: String, caseSensitive: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        while searchRange.length > 0 {
            let found = ns.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchRange.location = NSMaxRange(found)
            searchRange.length = ns.length - searchRange.location
        }
        return ranges
    }

    func performFindAction(_ action: EditorFindAction, in textView: NSTextView) {
        switch action {
        case .next: findNext(in: textView)
        case .previous: findPrevious(in: textView)
        case .replaceCurrent: replaceCurrent(in: textView)
        case .replaceAll: replaceAll(in: textView)
        }
    }

    func findNext(in textView: NSTextView) {
        guard !findMatches.isEmpty else { return }
        let next = ((findCurrentIndex ?? -1) + 1) % findMatches.count
        findCurrentIndex = next
        applyFindHighlights(in: textView)
        textView.setSelectedRange(findMatches[next])
        textView.scrollRangeToVisible(findMatches[next])
        parent.findHooks?.countChanged(findMatches.count, next)
    }

    func findPrevious(in textView: NSTextView) {
        guard !findMatches.isEmpty else { return }
        let previous = ((findCurrentIndex ?? findMatches.count) - 1 + findMatches.count) % findMatches.count
        findCurrentIndex = previous
        applyFindHighlights(in: textView)
        textView.setSelectedRange(findMatches[previous])
        textView.scrollRangeToVisible(findMatches[previous])
        parent.findHooks?.countChanged(findMatches.count, previous)
    }

    func replaceCurrent(in textView: NSTextView) {
        guard textView.isEditable, let index = findCurrentIndex, index < findMatches.count else { return }
        let range = findMatches[index]
        let replacement = parent.find.replacement
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        // processEditing refreshed the matches; the index now points at the
        // first match at/after the replacement, so Replace walks forward.
        if let index = findCurrentIndex, index < findMatches.count {
            textView.setSelectedRange(findMatches[index])
            textView.scrollRangeToVisible(findMatches[index])
            applyFindHighlights(in: textView)
        }
        parent.findHooks?.countChanged(findMatches.count, findCurrentIndex)
    }

    func replaceAll(in textView: NSTextView) {
        guard textView.isEditable, !findMatches.isEmpty else { return }
        let replacement = parent.find.replacement
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        for range in findMatches.reversed() {
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { continue }
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Replace All")
        textView.didChangeText()
        if let first = findMatches.first {
            textView.setSelectedRange(first)
            textView.scrollRangeToVisible(first)
        }
        parent.findHooks?.countChanged(findMatches.count, findCurrentIndex)
    }

    /// ⌘F: opens the bar, prefilling the query with the selection.
    func requestFind(replaceMode: Bool, in textView: NSTextView) {
        let selection = textView.selectedRange()
        var selectedText: String?
        if selection.length > 0, selection.length <= 200 {
            let substring = (textView.string as NSString).substring(with: selection)
            if !substring.contains("\n") { selectedText = substring }
        }
        parent.findHooks?.requested(selectedText, replaceMode)
    }

    func closeFind(in textView: NSTextView) {
        parent.findHooks?.closed()
        clearFind(in: textView)
    }
}
