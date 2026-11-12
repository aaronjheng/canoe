import AppKit
import Plume
import SwiftUI

// NOTE: Canoe-side feature code, NOT part of Plume (the editor base library).
// When the editor extracts into a shared package, this file stays here.

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
    /// Plain-name mode for the dictionary-style completions (header keys):
    /// rows show the bare name instead of the `{{name}}` placeholder shape.
    var showsBraces: Bool = true

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
            Text(showsBraces ? "{{\(suggestion.name)}}" : suggestion.name)
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

/// Canoe's bridge over Plume's `SuggestController`: maps the
/// `{{variable}}` domain onto the generic engine. The trigger universe is
/// the scope-derived `VariableSuggestion` list; the word universe carries
/// the header-keys suggestions. NOT part of Plume.
@MainActor
final class VariableCompletionController: NSObject {
    private let engine = SuggestController(openToken: "{{", closeToken: "}}")

    var isVisible: Bool { engine.isVisible }

    /// The open suggestion panel, if any. Editors that watch for
    /// click-outside-to-blur exempt popup picks.
    var popupWindow: NSWindow? { engine.popupWindow }

    /// Replaces the candidate universe (parents re-render on every keystroke)
    /// and re-evaluates an open popup against the new candidates.
    func setCandidates(_ candidates: [VariableSuggestion]) {
        engine.setCandidates(candidates.map(\.completionCandidate))
    }

    /// Replaces the dictionary-style universe (nil disables the mode) and
    /// re-evaluates an open popup - the re-render call sites follow
    /// `setCandidates` for the same reasons.
    func setWordCandidates(_ candidates: [VariableSuggestion]?) {
        engine.setWordCandidates(candidates?.map(\.completionCandidate))
    }

    /// The editor text changed: (re)evaluate the popup from scratch.
    func textChanged(_ textView: NSTextView) {
        engine.textChanged(textView)
    }

    /// Only the caret moved: keep an open popup glued to it, but never open
    /// one from pure navigation (completion appears on typing, Postman-style).
    func selectionChanged(_ textView: NSTextView) {
        engine.selectionChanged(textView)
    }

    /// Handles the popup's key commands; returns true when the selector was
    /// consumed (the editor should not process it further).
    @discardableResult
    func handleCommand(_ selector: Selector) -> Bool {
        engine.handleCommand(selector)
    }

    /// Inserts the selected (or clicked) suggestion.
    @discardableResult
    func accept(at index: Int? = nil) -> Bool {
        engine.accept(at: index)
    }

    func hide() {
        engine.hide()
    }

    /// ⌥⎋ / F5 (Monaco `triggerSuggest`): explicitly opens the word-mode
    /// panel at the caret — the universe is already synced by the last
    /// textChanged, so this just presents it.
    func triggerSuggest(in textView: NSTextView) {
        engine.showSuggestions(at: textView)
    }
}

extension VariableSuggestion {
    /// Strips the Canoe metadata Plume's generic rows don't render (scope
    /// kind/name, secret flag); the summary rides along.
    fileprivate var completionCandidate: SuggestItem {
        SuggestItem(name: name, summary: summary)
    }
}
