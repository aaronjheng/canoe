import AppKit

/// Line-number gutter for `Editor`: a fixed strip left of the scroll
/// view, drawing one number per logical line aligned to the line's first
/// laid-out fragment. Wrapped continuations repeat nothing; the phantom
/// line after a trailing newline is numbered like every editor's last line.
///
/// The line ledger itself lives on the shared `SourceHighlighter` (the
/// editor already keeps it incrementally in sync), so the gutter only reads
/// counts and line numbers from it.
final class EditorGutterView: NSView, NSViewToolTipOwner {
    weak var textView: NSTextView?
    weak var highlighter: SourceHighlighter?
    /// The content range of the line where a gutter drag started (nil when
    /// not dragging).
    private var dragAnchorRange: NSRange?
    private var tooltipTag: NSView.ToolTipTag?
    private var tooltipBounds: NSRect = .zero
    /// Vertical hairline between the gutter and the text (off by default).
    var showsSeparator = false
    /// Lines (1-based) carrying a syntax error - drawn as red dots beside
    /// the numbers.
    var errorLines: Set<Int> = []
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var scrollObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // No wantsLayer here: a layer-backed subview inside SwiftUI's hosting
        // subtree reorders the pane's layers and composites the background
        // above the sibling content (rows vanish behind the pane fill).
        // Plain drawRect needs no layer.
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerTooltipRect()
    }

    override func layout() {
        super.layout()
        registerTooltipRect()
    }

    /// One tooltip rect covering the view; re-registered when the bounds
    /// change (the owner hit-tests by point).
    private func registerTooltipRect() {
        guard window != nil, bounds != tooltipBounds, bounds.height > 0 else { return }
        if let tooltipTag { removeToolTip(tooltipTag) }
        tooltipBounds = bounds
        tooltipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    /// Hover over an error dot: the diagnostic's line and message.
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let highlighter, !errorLines.isEmpty else { return "" }
        let line = highlighter.lineNumber(ofUTF16Offset: 0)
        _ = line
        let point = convert(point, from: nil)
        let textPoint = (textView?.convert(CGPoint(x: fragmentProbeX, y: point.y), from: self)) ?? .zero
        guard let textView, let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return "" }
        let glyph = layoutManager.glyphIndex(for: textPoint, in: container)
        var fragmentGlyphs = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
        let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
        guard charRange.length > 0 else { return "" }
        let location = min(charRange.location, (textView.string as NSString).length - 1)
        let lineNumber = highlighter.lineNumber(ofUTF16Offset: location)
        guard errorLines.contains(lineNumber) else { return "" }
        // Find the first diagnostic that matches this line for a detailed message.
        var message = "Syntax error"
        for (range, msg) in highlighter.diagnostics() {
            let lineNum = highlighter.lineNumber(ofUTF16Offset: range.location)
            if lineNum == lineNumber {
                message = msg
                break
            }
        }
        return "line \(lineNumber): \(message)"
    }

    /// Starts following the text view's clip view (scroll ticks redraw).
    func observeScroll(of scrollView: NSScrollView) {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
    }

    /// MainActor-isolated so the observer token can be touched here; the
    /// view lives on the main thread for its whole life.
    isolated deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    /// Width for the current line count: widest digit run + side padding.
    /// Read from the SwiftUI update pass, which applies it to the strip's
    /// width constraint - mutating the constraint during AppKit layout
    /// (this view's draw/layout callbacks) would reschedule layout from
    /// inside layout and starve the hosting view's layer commits, blanking
    /// the sibling SwiftUI rows around the editor.
    func requiredWidth() -> CGFloat {
        let digits = max(2, String(max(highlighter?.lineCount ?? 1, 1)).count)
        let charWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(digits) * charWidth) + 2 * Self.horizontalPadding
    }

    private static let horizontalPadding: CGFloat = 7
    /// The x the gutter probes the text layout with: just inside the text
    /// column (the gutter's right edge + 1), so any point in the column
    /// hits the correct line regardless of container origin or padding.
    private var fragmentProbeX: CGFloat { max(bounds.width, 1) + 1 }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let highlighter else { return }
        // Clamp painting to our own bounds: NSView drawing is not clipped
        // to bounds, and a dirty rect that strays outside (hosting-layout
        // timing) would fill white over the sibling SwiftUI rows around the
        // editor - the pane's rows vanished behind the gutter's fill.
        let safe = dirtyRect.intersection(bounds)
        guard !safe.isNull, safe.width > 0, safe.height > 0 else { return }
        EditorTheme.codeBackgroundNS.setFill()
        safe.fill()

        // Right hairline separating gutter from text. A solid dynamic token:
        // opacity-composited semantic colors are unreliable as NSView fills.
        if showsSeparator {
            NSColor(EditorTheme.border).setFill()
            NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        }

        let layoutManager = textView.layoutManager
        guard let container = textView.textContainer, let layoutManager else { return }
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let textLength = (textView.string as NSString).length

        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(EditorTheme.textSecondary),
        ]
        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        while index < end {
            var fragmentGlyphs = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentGlyphs)
            let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            // Only the fragment that opens a line carries the number.
            if highlighter.isLineStart(charRange.location) {
                let number = highlighter.lineNumber(ofUTF16Offset: charRange.location)
                drawNumber(number, forFragment: fragmentRect, in: textView, attributes: numberAttributes)
                if errorLines.contains(number) {
                    drawErrorDot(forFragment: fragmentRect, in: textView)
                }
            }
            index = NSMaxRange(fragmentGlyphs)
        }  // The phantom line after a trailing newline (or the empty
        // document) has no glyphs - number it so the caret line is labeled.
        // Without a trailing newline every real line already drew above.
        let endsWithNewline =
            textLength == 0
            || (textView.string as NSString).character(at: textLength - 1)
                == UInt16(UnicodeScalar("\n").value)
        if endsWithNewline {
            let line = highlighter.lineNumber(ofUTF16Offset: textLength)
            drawNumber(
                line,
                forFragment: layoutManager.extraLineFragmentRect,
                in: textView,
                attributes: numberAttributes)
        }
    }

    /// Click: select the clicked line in the text view; double-click:
    /// select and copy it. The gutter never takes focus (plain view, not
    /// first-responder capable), so the text view keeps its state.
    override func mouseDown(with event: NSEvent) {
        guard let textView, let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        let textPoint = textView.convert(CGPoint(x: fragmentProbeX, y: point.y), from: self)
        let glyph = layoutManager.glyphIndex(for: textPoint, in: container)
        var fragmentGlyphs = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
        let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
        let ns = textView.string as NSString
        guard ns.length > 0 else { return }
        var lineRange = ns.lineRange(for: NSRange(location: min(charRange.location, ns.length - 1), length: 0))
        // Content only: a trailing newline is not part of the selection.
        let endsWithNewline =
            lineRange.length > 0
            && ns.character(at: NSMaxRange(lineRange) - 1) == UInt16(UnicodeScalar("\n").value)
        if endsWithNewline {
            lineRange.length -= 1
        }
        textView.setSelectedRange(lineRange)
        textView.scrollRangeToVisible(lineRange)
        if event.clickCount >= 2 {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ns.substring(with: lineRange), forType: .string)
        }
    }

    /// A small red dot left of the number, marking a line with a syntax
    /// error (see `SourceHighlighter.diagnostics`).

    /// A small red dot left of the number, marking a line with a syntax
    /// error (see `SourceHighlighter.diagnostics`).
    private func drawErrorDot(forFragment fragmentRect: CGRect, in textView: NSTextView) {
        let originInTextView = CGPoint(
            x: fragmentRect.minX + textView.textContainerOrigin.x,
            y: fragmentRect.minY + textView.textContainerOrigin.y)
        let origin = convert(originInTextView, from: textView)
        let diameter: CGFloat = 7
        let dot = CGRect(
            x: Self.horizontalPadding - diameter - 1,
            y: origin.y + (fragmentRect.height - diameter) / 2,
            width: diameter,
            height: diameter)
        NSColor(EditorTheme.error).setFill()
        dot.fill()
    }

    private func drawNumber(
        _ number: Int,
        forFragment fragmentRect: CGRect,
        in textView: NSTextView,
        attributes: [NSAttributedString.Key: Any]
    ) {
        // Fragment rects live in the text CONTAINER's coordinate system;
        // the container sits at textContainerOrigin inside the text view,
        // so add that origin or every number rides high by exactly the
        // container inset.
        let containerOrigin = textView.textContainerOrigin
        let originInTextView = CGPoint(
            x: fragmentRect.minX + containerOrigin.x,
            y: fragmentRect.minY + containerOrigin.y)
        let origin = convert(originInTextView, from: textView)
        let text = String(number) as NSString
        let size = text.size(withAttributes: attributes)
        // Right-aligned with a fixed inner gap to the hairline.
        let numberX = bounds.maxX - Self.horizontalPadding - size.width
        let numberY = origin.y + (fragmentRect.height - size.height) / 2
        text.draw(at: CGPoint(x: numberX, y: numberY), withAttributes: attributes)
    }
}
