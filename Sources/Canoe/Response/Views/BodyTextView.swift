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

    final class Coordinator: NSObject {
        var onScrolledPastTop: ((Bool) -> Void)?
        var isPastTop = false
        var lastAttributed: AttributedString?
        var lastReveal: NSRange?
        var observesPastTop: NSObjectProtocol?
        var wordWrap: Bool?

        deinit {
            if let observer = observesPastTop {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observe(pastTopOf scrollView: NSScrollView) {
            observesPastTop = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                // Same 1pt threshold as the pre-replacement SwiftUI
                // geometry change, so the hairline timing stays put.
                let offset = scrollView.contentView.bounds.origin.y + scrollView.contentInsets.top
                let pastTop = offset > 1
                guard pastTop != isPastTop else { return }
                isPastTop = pastTop
                onScrolledPastTop?(pastTop)
            }
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

        applyMetrics(textView, wordWrap: wordWrap)
        context.coordinator.wordWrap = wordWrap
        textView.textStorage?.setAttributedString(Self.nsAttributed(attributed))
        context.coordinator.lastAttributed = attributed

        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(pastTopOf: scroll)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScrolledPastTop = onScrolledPastTop
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if coordinator.wordWrap != wordWrap {
            applyMetrics(textView, wordWrap: wordWrap)
            coordinator.wordWrap = wordWrap
        }
        if attributed != coordinator.lastAttributed {
            coordinator.lastAttributed = attributed
            // Fresh content starts at the top; a pending reveal (find's
            // cursor carried over between bodies) belongs to old text.
            coordinator.lastReveal = nil
            textView.textStorage?.setAttributedString(Self.nsAttributed(attributed))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if let reveal, reveal != coordinator.lastReveal {
            coordinator.lastReveal = reveal
            textView.scrollRangeToVisible(reveal)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observesPastTop {
            NotificationCenter.default.removeObserver(observer)
            coordinator.observesPastTop = nil
        }
    }

    /// Maps the word-wrap switch onto how the text container tracks the
    /// scroll width: on, the container follows the viewport width (lines
    /// refill, vertical-only scroll); off, the container is unbounded so
    /// every line keeps its own width and the view pans horizontally.
    private func applyMetrics(_ textView: NSTextView, wordWrap: Bool) {
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wordWrap
        textView.autoresizingMask = wordWrap ? [.width] : []
        let container = textView.textContainer ?? NSTextContainer()
        container.widthTracksTextView = wordWrap
        container.containerSize = NSSize(
            width: wordWrap ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: container)
    }

    /// Bridges the SwiftUI attribute pipeline onto AppKit run by run: the
    /// default `NSAttributedString(AttributedString)` conversion silently
    /// drops SwiftUI-scoped colors (the plain-colored pretty view), while
    /// `NSColor(Color)` handles every color used here - theme-dynamic
    /// palette entries, accent washes at find-highlight opacity included.
    /// Colors come from whichever scope the producer wrote; anything else
    /// (fonts, styles) is intentionally left to the view's own settings.
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
        return ns
    }
}
