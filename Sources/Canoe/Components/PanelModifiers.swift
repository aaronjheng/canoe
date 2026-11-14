import AppKit
import ObjectiveC
import SwiftUI

// Panel chrome: save chip, toolbar/popup/focus modifiers, hover tracking.
// MARK: - Panel toolbar

// The system focus ring draws one frame at the shared field editor's
// pre-layout geometry the first time a text control takes focus. The
// field editor is a private NSTextView subclass: set focusRingType =
// .none on the instance when NSWindow hands it back, and force that
// private class's getter. Do not swizzle NSTextView / NSTextField /
// NSView broadly - replacing their drawing methods broke the URL bar's
// text layout. SwiftUI's own focus chrome is disabled at each window
// root (see ContentView / AppDelegate).
enum AppKitFocusRing {
    // AppKit swizzles are installed once on the main thread at launch;
    // the state is intentionally process-wide.
    nonisolated(unsafe) private static var swizzled = Set<ObjectIdentifier>()
    nonisolated(unsafe) private static var fieldEditorOriginal: IMP?
    /// Lock protecting swizzled state (install/disable) across concurrent
    /// window creation (the hook itself is nonisolated by design).
    private static let stateLock = NSLock()
    // ObjC selector is fieldEditor:forObject: (Swift renames the label to for:).
    private static let fieldEditorSelector = NSSelectorFromString("fieldEditor:forObject:")
    nonisolated(unsafe) private static let typeGetter: @convention(block) (AnyObject) -> UInt = { _ in
        NSFocusRingType.none.rawValue
    }
    nonisolated(unsafe) private static let typeSetter: @convention(block) (AnyObject, UInt) -> Void = { _, _ in }
    nonisolated(unsafe) private static let emptyMask: @convention(block) (AnyObject) -> Void = { _ in }
    // NSText in the signature only (ObjC object pointer); never touch its
    // MainActor-isolated members from this nonisolated block - replace the
    // private class's drawing methods instead.
    private typealias FieldEditorHook = @convention(block) (AnyObject, Bool, Any?) -> NSText?
    nonisolated(unsafe) private static let fieldEditorHook: FieldEditorHook = { window, createFlag, object in
        guard let original = fieldEditorOriginal else { return nil }
        typealias Original = @convention(c) (AnyObject, Selector, Bool, Any?) -> NSText?
        let call = unsafeBitCast(original, to: Original.self)
        let editor = call(window, fieldEditorSelector, createFlag, object)
        if let editor {
            MainActor.assumeIsolated {
                editor.focusRingType = .none
                editor.drawsBackground = false
                editor.backgroundColor = .clear
            }
            disable(on: type(of: editor))
        }
        return editor
    }

    static func install() {
        installFieldEditorHook()
    }

    @MainActor
    static func prepare(in window: NSWindow) {
        let probe = NSTextField(frame: NSRect(x: -100, y: -100, width: 1, height: 1))
        probe.isEditable = true
        probe.isBordered = false
        probe.isBezeled = false
        probe.drawsBackground = false
        probe.focusRingType = .none
        probe.cell?.focusRingType = .none
        probe.stringValue = "x"
        window.contentView?.addSubview(probe)
        defer { probe.removeFromSuperview() }
        window.contentView?.layoutSubtreeIfNeeded()
        if window.makeFirstResponder(probe), let editor = probe.currentEditor() as? NSTextView {
            editor.focusRingType = .none
            editor.drawsBackground = false
            editor.backgroundColor = .clear
        }
        window.makeFirstResponder(nil)
    }

    /// Replace `focusRingType` / `drawFocusRingMask` on `cls`. Only ever
    /// called on the private field-editor class (via the fieldEditor hook)
    /// - never on NSTextView / NSTextField, whose methods must stay intact
    /// for text layout.
    private static func disable(on cls: AnyClass) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard cls != NSView.self, cls != NSTextView.self, cls != NSTextField.self else { return }
        let key = ObjectIdentifier(cls)
        guard swizzled.insert(key).inserted else { return }
        class_replaceMethod(
            cls,
            #selector(getter: NSView.focusRingType),
            imp_implementationWithBlock(typeGetter),
            "Q@:"
        )
        class_replaceMethod(
            cls,
            #selector(setter: NSView.focusRingType),
            imp_implementationWithBlock(typeSetter),
            "v@:Q"
        )
        class_replaceMethod(
            cls,
            #selector(NSView.drawFocusRingMask),
            imp_implementationWithBlock(emptyMask),
            "v@:"
        )
    }

    /// Hook `NSWindow.fieldEditor:forObject:`. Whatever private class AppKit
    /// hands back is patched before it can paint the one-frame ring.
    private static func installFieldEditorHook() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard fieldEditorOriginal == nil else { return }
        guard let method = class_getInstanceMethod(NSWindow.self, fieldEditorSelector) else { return }
        guard let types = method_getTypeEncoding(method) else { return }
        fieldEditorOriginal = class_replaceMethod(
            NSWindow.self,
            fieldEditorSelector,
            imp_implementationWithBlock(fieldEditorHook),
            types
        )
    }
}

// MARK: - Hover tracking

/// Reports pointer enter/exit for a SwiftUI area through a real `NSTrackingArea`.
///
/// SwiftUI's own `.onHover` is hit-test based, so an AppKit view inside the
/// tracked area - the `NSMenuButton` behind every `Menu` that uses
/// `.menuStyle(.borderlessButton)`, an `NSTextField`, the field editor - takes
/// the hover away from the view that contains it. A row that reveals its
/// actions on hover then hides the very control the pointer is on, the control
/// vanishes from under the pointer, the row counts as hovered again, and the
/// two chase each other into a flicker. A tracking area is purely geometric,
/// so nothing inside can take the pointer away from it.
///
/// The sensor stays out of hit testing: it must never swallow a click meant for
/// whatever SwiftUI drew above it.
///
/// Enter/exit *delivery* itself is also unreliable here, and that is the bug
/// that stacks "several rows lit at once" in the sidebar: `mouseExited` is
/// dropped whenever a tracking area is replaced, moved, or torn down (and
/// rows shift under a stationary pointer every time the list scrolls, the
/// filter reflows, a group collapses, or a history entry is prepended - all
/// moments where the mouse never moves), while `mouseEntered` keeps firing.
/// So hover is never *accumulated* from events here - claims are *mutually
/// exclusive*: one pointer can only be over one row, so each sensor's enter
/// retires every other live sensor's claim (`HoverRegistry.entered`), no
/// matter which exits AppKit dropped along the way. Scroll/drag retires all
/// claims and reinstalls the areas, letting AppKit's synthetic enter re-mark
/// the one row that is actually under the stationary pointer. No code here
/// queries geometry - every attempt to re-derive hover from
/// `convert`/`visibleRect` against SwiftUI-hosted views has proven wrong
/// (it lit every row at once); only the enter/exit events themselves are
/// trusted, plus one invariant enforced by construction.
struct HoverTracker: NSViewRepresentable {
    let onHover: (Bool) -> Void
    /// Independent sensors (e.g. the overflow button nested inside a hovered
    /// row's own trailing actions) keep their state to themselves and never
    /// join the one-hovered-row group: retiring them from another row's enter
    /// would tear the row's actions down under the pointer and recreate the
    /// flicker loop this tracker exists to prevent.
    var joinsGroup = true

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.joinsGroup = joinsGroup
        view.onHover = onHover
        if joinsGroup { HoverRegistry.add(view) }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHover = onHover
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        var joinsGroup = true
        /// The last state handed to `onHover`, so the synthetic enters that
        /// every area re-add produces are deduped down to real transitions.
        private var isReportedHovered = false

        /// Hover only: clicks belong to the SwiftUI content this sits behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // A view leaving its window never gets mouseExited (rows torn down
            // mid-hover by lazy recycling, sidebar tab switches, filter
            // reflow) - clear now so a remounted row can't come back lit.
            if newWindow == nil { setHovered(false) }
            super.viewWillMove(toWindow: newWindow)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            reinstallTrackingArea()
        }

        /// Removes and re-adds the sensor's area: AppKit drops exits for
        /// removed areas, so this both refreshes the enter/exit bookkeeping
        /// after any geometry change and lets the window synthesize an enter
        /// for the sensor that ended up under a stationary pointer.
        func reinstallTrackingArea() {
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            if joinsGroup {
                HoverRegistry.entered(self)
            } else {
                setHovered(true)
            }
        }

        override func mouseExited(with event: NSEvent) {
            setHovered(false)
        }

        fileprivate func setHovered(_ value: Bool) {
            guard value != isReportedHovered else { return }
            isReportedHovered = value
            onHover?(value)
        }
    }
}

/// The live group-participating `HoverTracker` sensors. All call sites (the
/// sensors and the event monitor) run on the main thread, so the registry is
/// MainActor-confined.
@MainActor
private enum HoverRegistry {
    private final class WeakBox {
        weak var view: HoverTracker.TrackingView?
        init(_ view: HoverTracker.TrackingView) { self.view = view }
    }

    private static var boxes: [WeakBox] = []
    private static var monitor: Any?

    static func add(_ view: HoverTracker.TrackingView) {
        boxes.append(WeakBox(view))
        pruneAndInstallMonitor()
    }

    /// One pointer, one hovered row: a new enter retires every other live
    /// claim before taking effect. This is the backstop that makes dropped
    /// `mouseExited`s unobservable - however the list scrolled or reflowed,
    /// no earlier row can outlive the row the pointer has reached.
    static func entered(_ view: HoverTracker.TrackingView) {
        pruneAndInstallMonitor()
        view.setHovered(true)
        for box in boxes where box.view !== view {
            box.view?.setHovered(false)
        }
    }

    /// Scroll and drag move rows without any enter/exit when the pointer
    /// rests still. Retire every claim and reinstall the areas: whichever
    /// sensor ends up under the pointer gets AppKit's synthetic enter and
    /// lights up alone.
    static func geometryChanged() {
        pruneAndInstallMonitor()
        for box in boxes {
            box.view?.setHovered(false)
            box.view?.reinstallTrackingArea()
        }
    }

    /// Installs the shared event monitor once, with the first sensor; no
    /// sensors ever exist until a `tracksHover` view mounts.
    private static func pruneAndInstallMonitor() {
        boxes.removeAll { $0.view == nil }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { event in
            MainActor.assumeIsolated {
                geometryChanged()
            }
            return event
        }
    }
}

extension View {
    /// Hover enter/exit for a view that has to keep tracking while AppKit views
    /// (menus, text fields) sit inside it - the cases where `.onHover` hands the
    /// pointer to the nested view and reports an exit. See `HoverTracker`.
    ///
    /// Group participation is the default: one pointer, one hovered row, so a
    /// row's enter retires every other row's claim. Pass `independent: true`
    /// for a sensor nested inside another tracked view's bounds (the overflow
    /// button inside a hovered row's own trailing actions) - it must not
    /// retire its host, or the host's actions would tear down under the
    /// pointer and the two would chase each other in a flicker loop.
    func tracksHover(_ onHover: @escaping (Bool) -> Void, independent: Bool = false) -> some View {
        background { HoverTracker(onHover: onHover, joinsGroup: !independent) }
    }
}

/// Postman-style Save chip shared by the workspace/collection/environment
/// detail headers: icon + label, accent when dirty, plain otherwise.
struct SaveChipButton: View {
    let isDirty: Bool
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "square.and.arrow.down")
                Text("Save")
            }
            .font(AppFont.small.weight(.medium))
            .foregroundStyle(isDirty ? AppColor.accent : AppColor.textSecondary)
            .padding(.horizontal, AppSpacing.comfortable)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isDirty ? AppColor.subtleBackground : (isHovering ? AppColor.tabHoverBackground : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .clickCursor(isEnabled: isDirty)
        .disabled(!isDirty)
        .help(help)
    }
}

/// Chrome for a detail pane's title row: the horizontal gutter plus the
/// shared toolbar height, so every editor header (request name bar,
/// collection/folder/environment/workspace pages) is one band. `pinned`
/// fixes the height instead of taking it as a floor - the request editor
/// needs that, since its VSplitView pane otherwise feeds the extra vertical
/// space into this row as blank bands.
struct PanelToolbarModifier: ViewModifier {
    var horizontalPadding: CGFloat = AppSpacing.large
    var pinned: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(
                minHeight: pinned ? nil : AppSize.toolbarHeight,
                maxHeight: pinned ? AppSize.toolbarHeight : nil
            )
    }
}

/// Floating card chrome for the popups anchored under the URL bar (the
/// method dropdown, the multi-line URL editor): solid fill, soft shadow,
/// and the standard border. One place so the floating surfaces always match.
struct PopupPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(AppColor.controlBackground)
                    .shadow(color: AppColor.popupShadow, radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(AppColor.border, lineWidth: AppLine.field)
            )
    }
}

/// Border language for fields (see `focusRingBorder`): rest is the strong
/// border at the standard field width, hover lifts the border to the shared
/// hover color, focus takes over with the accent at the wider focus width.
/// Fills are handled by the caller so they can pick the right idle
/// background. The URL bar's spliced rest outline is a bespoke
/// variant of the same language (`SplicedBarRestOutline`) because its two
/// halves draw their own accent rings.
struct FocusRingBorderModifier: ViewModifier {
    let isFocused: Bool
    var isHovered = false

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? AppLine.focusedField : AppLine.field)
        )
    }

    /// Border tiers: rest the standard field border, hover the shared hover
    /// border, focus the accent.
    private var borderColor: Color {
        if isFocused { return AppColor.accent }
        if isHovered { return AppColor.fieldHoverBorder }
        return AppColor.borderStrong
    }
}

/// Postman-style scrolled-under affordance for any toolbar/content seam: a
/// hairline at the content's top edge plus a short shadow fading downward,
/// so the content reads as sliding under the toolbar once it scrolls. Pure
/// overlay - no layout impact, no hit testing. Shared by the response body
/// and the docked console, so both seams read identically.
struct ScrolledUnderEdgeShadow: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            LinearGradient(
                stops: [
                    .init(color: AppColor.scrolledUnderShadow, location: 0),
                    .init(color: Color.primary.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 7)
        }
        .allowsHitTesting(false)
    }
}

/// Chrome for fields with no border at rest: hover/focus add a brighter
/// fill and the standard field border (`AppLine.field`) - accent when
/// focused, `fieldHoverBorder` on hover.
struct BorderlessFieldChromeModifier: ViewModifier {
    let isFocused: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, AppSpacing.compact)
            .padding(.vertical, AppSpacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(
                        isFocused
                            ? AppColor.fieldFocusBackground
                            : (isHovered ? AppColor.fieldHoverBackground : .clear)
                    )
            )
            .overlay {
                if isFocused || isHovered {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(
                            isFocused ? AppColor.accent : AppColor.fieldHoverBorder,
                            lineWidth: isFocused ? AppLine.focusedField : AppLine.field
                        )
                }
            }
            .onHover { isHovered = $0 }
            .animation(AppMotion.quick, value: isHovered)
            .animation(AppMotion.quick, value: isFocused)
    }
}

extension View {
    /// Detail-pane title row: the shared gutter plus the shared toolbar
    /// height, pinned so the VSplitView pane cannot inflate it into blank
    /// bands. `pinned: true` for the request name bar, whose row sits
    /// between the tab strip and the editor.
    func panelToolbar(horizontalPadding: CGFloat = AppSpacing.large, pinned: Bool = false) -> some View {
        modifier(PanelToolbarModifier(horizontalPadding: horizontalPadding, pinned: pinned))
    }

    func popupPanel() -> some View {
        modifier(PopupPanelModifier())
    }

    /// Sheet chrome: replaces the system presentation material (which picks up
    /// the desktop tint and reads warm in dark mode) with the theme's chrome
    /// color, so a sheet matches the window it drops from.
    func sheetSurface() -> some View {
        presentationBackground(AppColor.primaryBackground)
    }

    /// Border language for fields: rest is the strong border at the
    /// standard field width, hover lifts it to the shared hover border,
    /// focused is accent at the wider focus width.
    func focusRingBorder(isFocused: Bool, isHovered: Bool = false) -> some View {
        modifier(FocusRingBorderModifier(isFocused: isFocused, isHovered: isHovered))
    }

    /// Borderless-at-rest field chrome: brighter hover/focus fill + field border.
    func borderlessFieldChrome(isFocused: Bool) -> some View {
        modifier(BorderlessFieldChromeModifier(isFocused: isFocused))
    }

    /// Applies `help` only when `condition` holds; otherwise leaves the view
    /// untouched (avoids empty tooltips from `help("")`).
    @ViewBuilder
    func helpIf(_ condition: Bool, _ text: String) -> some View {
        if condition {
            help(text)
        } else {
            self
        }
    }
}

/// Drag handle on the leading edge of a manually-sized pane (VS Code-style
/// splitter): drag to resize between the min/max bounds, double-click to
/// reset to the default.
///
/// The pane must live OUTSIDE any split view - a conditionally-presented
/// split pane breaks the split view's sizing - so the splitter is manual.
///
/// `axis` picks the direction: the right-hand inspector resizes horizontally,
/// the bottom console panel vertically.
struct PaneResizeHandle: View {
    let axis: Axis
    let range: ClosedRange<CGFloat>
    let defaultLength: CGFloat
    /// The size at drag start; nil until the pointer actually moves, so an
    /// abandoned drag leaves the value untouched.
    @Binding var length: CGFloat
    /// Called once when the drag ends, to persist the new size.
    let onCommit: () -> Void
    @State private var dragStart: CGFloat?

    /// Thickness of the grab area. A touch wider than the hairline it
    /// straddles, so the pointer does not have to find a 1pt line.
    private static let thickness: CGFloat = 7

    var body: some View {
        Color.clear
            .frame(
                width: axis == .horizontal ? Self.thickness : nil,
                height: axis == .vertical ? Self.thickness : nil
            )
            .contentShape(Rectangle())
            // The axis decides the cursor: `axis` is the direction the pane
            // resizes IN, not the orientation of the edge it sits on - the
            // inspector's vertical leading edge uses `.horizontal` and
            // resizes left/right, the console's horizontal top edge uses
            // `.vertical` and resizes up/down. Declared through
            // `pointerStyle`, not `NSCursor.push()/pop()` - the handle is
            // torn down whenever its pane closes, and push/pop would leave
            // the resize cursor stranded over the rest of the UI.
            .pointerStyle(axis == .vertical ? PointerStyle.rowResize : PointerStyle.columnResize)
            .gesture(
                // Global coordinates on purpose: the handle itself moves
                // with the size it controls, so a local-space translation
                // feeds back into the layout and oscillates (the tab strip
                // and the trailing controls jitter). Global space keeps the
                // delta a pure function of the pointer.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = length }
                        let start = dragStart ?? length
                        // A pane on the leading edge (inspector) grows as
                        // the pointer moves left; a pane below (console)
                        // grows as it moves up. Both are therefore the
                        // negative of the translation - the console's top
                        // edge follows the pointer instead of running from
                        // it.
                        let delta =
                            axis == .horizontal
                            ? -value.translation.width : -value.translation.height
                        length = min(max(start + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onCommit()
                    }
            )
            .onTapGesture(count: 2) {
                length = defaultLength
                onCommit()
            }
            .help("Drag to resize the \(axis == .horizontal ? "inspector" : "console") (double-click to reset)")
    }
}
