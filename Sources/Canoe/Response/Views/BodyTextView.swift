import AppKit
import SwiftUI

/// The response body's rendered text: a read-only AppKit `NSTextView`
/// inside an `NSScrollView`. A single SwiftUI `Text` lost large
/// pretty-printed bodies on this OS builds (blank or pushed-down layout),
/// while the text view keeps the selection, horizontal line widths, and
/// scroll behavior Postman's body pane has.
struct BodyTextView: NSViewRepresentable {
    /// The highlighted body, ready for the text view. SwiftUI-scope colors
    /// (.foregroundColor / .backgroundColor from the syntax highlighter and
    /// the find overlay) bridge per run below: the default
    /// `NSAttributedString(AttributedString)` conversion drops
    /// SwiftUI-scoped colors entirely, which once rendered the whole
    /// pretty view in one plain color.
    let attributed: AttributedString
    /// Body-toolbar word wrap: on, lines fill the pane width and the view
    /// scrolls vertically; off, lines keep their natural width and the view
    /// scrolls in both axes.
    let wordWrap: Bool
    /// The find match to bring into view; nil (or a repeat) is a no-op.
    let reveal: NSRange?
    /// Reports the scrolled-under state: true once the content moved away
    /// from the top, false when it is back - drives the hairline above.
    let onScrolledPastTop: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Sendable box for the bounds-observer token: `deinit` is nonisolated,
    /// so the backstop unregister there can only touch Sendable state
    /// (dismantleNSView covers the normal removal path).
    fileprivate final class ObserverBox: @unchecked Sendable {
        let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) {
            self.token = token
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onScrolledPastTop: ((Bool) -> Void)?
        var isPastTop = false
        var lastAttributed: AttributedString?
        var lastReveal: NSRange?
        fileprivate var observerBox: ObserverBox?
        var wordWrap: Bool?
        // Streaming state: the body lands in the text view in slices so a
        // large render never blocks one runloop pass. The first slice paints
        // synchronously with the view; the rest follow one per main-queue
        // tick until the body is complete.
        var streamBase: AttributedString?
        var streamRanges: [Range<AttributedString.Index>] = []
        var streamGeneration = 0
        /// A find reveal that arrived before its text was loaded; applied
        /// once the stream finishes.
        var pendingReveal: NSRange?

        deinit {
            if let box = observerBox {
                NotificationCenter.default.removeObserver(box.token)
            }
        }

        /// Starts (or restarts) the stream for `attributed`: drops any
        /// in-flight pump via the generation counter, installs the first
        /// chunk synchronously, and leaves the rest for `pump`.
        func beginStream(_ attributed: AttributedString, into textView: NSTextView) {
            streamGeneration += 1
            streamBase = attributed
            streamRanges = BodyTextView.chunkRanges(in: attributed)
            lastReveal = nil
            pendingReveal = nil
            if let first = streamRanges.first {
                streamRanges.removeFirst()
                textView.textStorage?.setAttributedString(
                    BodyTextView.nsAttributed(AttributedString(attributed[first])))
            } else {
                textView.textStorage?.setAttributedString(NSAttributedString())
            }
            // A body that fit in the single synchronous chunk is already
            // fully in storage: close the stream NOW, or `streamBase` would
            // stay set forever (pump's guard returns on empty ranges, so it
            // can never reach its own clearing branch) and every find reveal
            // would park in `pendingReveal` - the common small-body case
            // never scrolled to its first match.
            if streamRanges.isEmpty {
                streamBase = nil
            }
        }

        /// Appends the next stream chunk on a later main-actor tick, then
        /// reschedules until the body is complete. A body change bumps the
        /// generation, so stale scheduled chunks no-op instead of appending
        /// into the wrong text.
        func pump(_ scrollView: NSScrollView) {
            guard !streamRanges.isEmpty, let base = streamBase else { return }
            let generation = streamGeneration
            let range = streamRanges.removeFirst()
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, self.streamGeneration == generation, let scrollView,
                    let textView = scrollView.documentView as? NSTextView
                else { return }
                textView.textStorage?.beginEditing()
                textView.textStorage?.append(BodyTextView.nsAttributed(AttributedString(base[range])))
                textView.textStorage?.endEditing()
                if self.streamRanges.isEmpty {
                    self.streamBase = nil
                    // A find reveal that pointed into not-yet-loaded text
                    // lands now that the whole body is in storage.
                    if let pending = self.pendingReveal {
                        self.pendingReveal = nil
                        self.lastReveal = pending
                        textView.scrollRangeToVisible(pending)
                    }
                } else {
                    self.pump(scrollView)
                }
            }
        }

        func observe(pastTopOf scrollView: NSScrollView) {
            observerBox = ObserverBox(
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self, weak scrollView] _ in
                    guard let self, let scrollView else { return }
                    // The block queue is the main queue, so the isolated
                    // state below is only ever touched from the main actor.
                    MainActor.assumeIsolated {
                        // Same 1pt threshold as the pre-replacement SwiftUI
                        // geometry change, so the hairline timing stays put.
                        let offset = scrollView.contentView.bounds.origin.y + scrollView.contentInsets.top
                        let pastTop = offset > 1
                        guard pastTop != self.isPastTop else { return }
                        self.isPastTop = pastTop
                        self.onScrolledPastTop?(pastTop)
                    }
                }
            )
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let textView = NSTextView()
        // Selection-only: the body is a readout, not an editor - no input,
        // no smart substitutions that would rewrite what the server sent,
        // and no focus ring (read-only views can still take focus).
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Postman renders the body pane at 13px; this is the AppKit NSFont
        // mirror of `AppFont.monoBody` (the old single-Text render used the
        // 12pt table tier, which read undersized beside Postman).
        textView.font = VariableEditorFont.monoBody.nsFont
        // Postman's body rides ~20px lines at that size (~1.5x); AppKit's
        // default ~16pt extent read cramped once the glyphs matched, so the
        // line box gets the +4. Runs keep their own colors only - paragraph
        // attrs come from here, filling every range the storage would
        // otherwise print with no paragraph style.
        let spacing = NSMutableParagraphStyle()
        spacing.lineSpacing = 4
        textView.defaultParagraphStyle = spacing
        textView.textColor = AppColor.textPrimaryNS
        textView.drawsBackground = false
        textView.focusRingType = .none
        // The single-Text render's padding: 12pt all around (medium).
        textView.textContainerInset = NSSize(width: 0, height: 12)
        textView.textContainer?.lineFragmentPadding = 12
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)

        applyMetrics(textView, scrollView: scroll, wordWrap: wordWrap)
        context.coordinator.wordWrap = wordWrap
        context.coordinator.lastAttributed = attributed
        context.coordinator.beginStream(attributed, into: textView)

        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(pastTopOf: scroll)
        context.coordinator.pump(scroll)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScrolledPastTop = onScrolledPastTop
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if coordinator.wordWrap != wordWrap {
            applyMetrics(textView, scrollView: scrollView, wordWrap: wordWrap)
            coordinator.wordWrap = wordWrap
        }
        if attributed != coordinator.lastAttributed {
            let previous = coordinator.lastAttributed
            coordinator.lastAttributed = attributed
            // Find's highlight toggle and match stepping swap attributes
            // but keep the same characters: swap the storage in place -
            // no re-stream, no scroll reset - and let the reveal branch
            // below place the match. Re-streaming here used to send every
            // ⌘G back to the top with the next match off-screen, and
            // re-rendered the whole body per keystroke on large responses.
            let charactersUnchanged =
                previous.map { attributed.characters.elementsEqual($0.characters) } ?? false
            if charactersUnchanged, coordinator.streamBase == nil {
                textView.textStorage?.setAttributedString(BodyTextView.nsAttributed(attributed))
            } else {
                // Fresh content starts at the top; a pending reveal (find's
                // cursor carried over between bodies) belongs to old text.
                coordinator.lastReveal = nil
                coordinator.beginStream(attributed, into: textView)
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                coordinator.pump(scrollView)
                // The scrolled-under shadow belongs to the body it was
                // scrolled in: a short body that never scrolls would
                // inherit the previous body's stuck-on shadow (no bounds
                // change ever arrives to correct it).
                if coordinator.isPastTop {
                    coordinator.isPastTop = false
                    onScrolledPastTop(false)
                }
            }
        } else if let reveal, reveal != coordinator.lastReveal {
            if coordinator.streamBase != nil {
                // Still streaming: land on the match once the body completes
                // - scrolling now would clamp to the loaded prefix.
                coordinator.pendingReveal = reveal
            } else {
                coordinator.lastReveal = reveal
                textView.scrollRangeToVisible(reveal)
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let box = coordinator.observerBox {
            NotificationCenter.default.removeObserver(box.token)
            coordinator.observerBox = nil
        }
    }

    /// Maps the word-wrap switch onto how the text container tracks the
    /// scroll width: on, the container follows the viewport width (lines
    /// refill, vertical-only scroll); off, the container is unbounded so
    /// every line keeps its own width and the view pans horizontally.
    private func applyMetrics(
        _ textView: NSTextView, scrollView: NSScrollView, wordWrap: Bool
    ) {
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wordWrap
        textView.autoresizingMask = wordWrap ? [.width] : []
        let container = textView.textContainer ?? NSTextContainer()
        container.widthTracksTextView = wordWrap
        container.containerSize = NSSize(
            width: wordWrap ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        if wordWrap {
            // The view still carries the unbounded width of the pan layout
            // here, and nothing shrinks it for us: `.width` sizing only
            // reacts to clip-view resizes, which do not occur at toggle
            // time. Turning tracking on without the snap relayouts into a
            // degenerate 10,000,000pt line-fragment width - the blank
            // Pretty view - so first pull the frame back to the live
            // content width (zero until the scroll view first tiles).
            let contentWidth = scrollView.contentSize.width
            if contentWidth > 0, abs(textView.frame.width - contentWidth) > 0.5 {
                textView.frame.size.width = contentWidth
            }
        }
        textView.layoutManager?.ensureLayout(for: container)
    }

    /// Characters per streamed chunk: the first chunk paints within one
    /// layout pass, and a 200K-character body (the display cap) completes in
    /// ~9 ticks instead of one long block.
    private static let streamChunkCharacters = 24_000

    /// Splits the body into per-tick character ranges for the stream pump.
    /// AttributedString slices keep the base's index space, so the stored
    /// ranges stay valid against `streamBase` for the whole stream.
    private static func chunkRanges(in attributed: AttributedString) -> [Range<AttributedString.Index>] {
        var starts: [AttributedString.Index] = [attributed.startIndex]
        var index = attributed.startIndex
        var count = 0
        while index < attributed.endIndex {
            count += 1
            index = attributed.index(afterCharacter: index)
            if count == streamChunkCharacters, index < attributed.endIndex {
                // Snap the cut back to the last newline so a chunk ends on
                // whole logical lines: the per-line paragraph styles are
                // attached chunk-wise, and a line split between chunks
                // would lose its head indent on the second half. Bodies
                // without any newline in the chunk (one giant line) cut
                // at the raw character position.
                let limit = starts.last ?? attributed.startIndex
                var probe = index
                var back = 0
                var snapped: AttributedString.Index?
                while probe > limit {
                    let before = attributed.index(beforeCharacter: probe)
                    if attributed.characters[before] == "\n" {
                        snapped = attributed.index(afterCharacter: before)
                        break
                    }
                    probe = before
                    back += 1
                }
                if let snapped {
                    starts.append(snapped)
                    count = back
                } else {
                    starts.append(index)
                    count = 0
                }
            }
        }
        var ranges: [Range<AttributedString.Index>] = []
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1] : attributed.endIndex
            ranges.append(start..<end)
        }
        return ranges
    }

    /// Bridges the SwiftUI attribute pipeline onto AppKit run by run: the
    /// default `NSAttributedString(AttributedString)` conversion silently
    /// drops SwiftUI-scoped colors (the plain-colored pretty view), while
    /// `NSColor(Color)` handles every color used here - theme-dynamic
    /// palette entries, accent washes at find-highlight opacity included.
    /// Colors come from whichever scope the producer wrote; anything else
    /// (fonts, styles) is intentionally left to the view's own settings.
    @MainActor
    private static func nsAttributed(_ attributed: AttributedString) -> NSAttributedString {
        let ns = NSMutableAttributedString(string: String(attributed.characters))
        for run in attributed.runs {
            let foreground: NSColor?
            if let color = run.swiftUI.foregroundColor {
                foreground = NSColor(color)
            } else if let color = run.appKit.foregroundColor {
                foreground = color
            } else {
                foreground = nil
            }
            let background: NSColor?
            if let color = run.swiftUI.backgroundColor {
                background = NSColor(color)
            } else if let color = run.appKit.backgroundColor {
                background = color
            } else {
                background = nil
            }
            guard foreground != nil || background != nil else { continue }
            let range = NSRange(run.range, in: attributed)
            if let foreground {
                ns.addAttribute(.foregroundColor, value: foreground, range: range)
            }
            if let background {
                ns.addAttribute(.backgroundColor, value: background, range: range)
            }
        }
        applyWrappingParagraphs(to: ns)
        return ns
    }

    /// Paragraph geometry for each logical line, keyed by the line's leading
    /// whitespace. Pretty-printed bodies repeat a handful of indent levels,
    /// so lines coming out of the same indent share one style instance.
    @MainActor
    private static var lineStyles: [String: NSParagraphStyle] = [:]

    /// VS Code-style wrapped-body geometry, attached as one paragraph style
    /// per logical line:
    /// - Head indent = the line's own leading whitespace width, so a line
    ///   that fills the pane wraps its tail aligned with the line's content
    ///   start (the `headIndent` continuation indent) instead of column
    ///   zero - `firstLineHeadIndent` stays 0 because the whitespace itself
    ///   is text and carries the first line's indent.
    /// - Character-granularity line breaking. This engine's word wrapping
    ///   breaks a wrapped paragraph's FIRST line at its first whitespace,
    ///   leaving the rest of the row empty (a long token never gets pulled
    ///   up), which read as ragged jumps on JSON bodies; breaking at glyphs
    ///   fills every row to the pane edge, matching how editors wrap a
    ///   long token.
    @MainActor
    private static func lineStyle(forIndent indent: String) -> NSParagraphStyle {
        if let cached = lineStyles[indent] { return cached }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineBreakStrategy = []
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent =
            indent.isEmpty
            ? 0
            : (indent as NSString).size(
                withAttributes: [.font: VariableEditorFont.monoBody.nsFont]
            ).width
        lineStyles[indent] = paragraph
        return paragraph
    }

    /// Walks `ns` one logical line at a time and attaches the line's paragraph
    /// style (see `lineStyle`) over its text range.
    @MainActor
    private static func applyWrappingParagraphs(to ns: NSMutableAttributedString) {
        let text = ns.string as NSString
        let length = text.length
        var lineStart = 0
        while lineStart < length {
            let newline = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: lineStart, length: length - lineStart)
            ).location
            let contentsEnd = newline == NSNotFound ? length : newline
            var indentEnd = lineStart
            while indentEnd < contentsEnd {
                let code = text.character(at: indentEnd)
                guard code == 0x20 || code == 0x09 else { break }
                indentEnd += 1
            }
            let indent = text.substring(
                with: NSRange(location: lineStart, length: indentEnd - lineStart))
            ns.addAttribute(
                .paragraphStyle,
                value: lineStyle(forIndent: indent),
                range: NSRange(location: lineStart, length: contentsEnd - lineStart)
            )
            if newline == NSNotFound {
                break
            }
            lineStart = newline + 1
        }
    }
}
