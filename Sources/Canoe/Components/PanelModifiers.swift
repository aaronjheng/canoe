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

/// Hover for rows and pills, *derived* from live geometry instead of
/// accumulated from events.
///
/// The per-row `NSTrackingArea` approach this replaces was measured, not
/// guessed: the diagnostic run showed every row sensor's `.inVisibleRect`
/// spanning the whole list viewport (360×702 with per-row origins) instead of
/// the row's own 344×24 frame - SwiftUI-hosted background views inside a
/// `LazyVStack` do not track row geometry, so every area covered everything,
/// enters fired for many rows at once, and exits never came. That one fact
/// explains every symptom this file used to chase.
///
/// The design now:
///
/// - ONE tracking area per hover space, on the space's own background sensor -
///   a stable, never-re-rendered view that only feeds the pointer position
///   (AppKit-computed window rect + one deterministic y flip).
/// - Tracked views report their SwiftUI frames through `onGeometryChange`, in
///   the space's coordinates - frames always match what is rendered.
/// - Hover is re-derived on every frame or pointer change: a view is hovered
///   exactly while its frame contains the pointer. Frames are disjoint, so
///   several rows can never be lit at once; re-renders touch nothing; and
///   scrolling, reflowing, and inserting all re-derive cleanly because
///   nothing is accumulated. Nested controls (the "…" pill inside a row's
///   trailing actions) simply register their own frame and light up together
///   with their row.
@MainActor
final class HoverSpace {
    /// The coordinate space this instance owns; unique per instance.
    let name = "hover.\(UUID().uuidString)"

    private var pointer: CGPoint?
    private var entries: [UUID: Entry] = [:]

    private struct Entry {
        var cursor: NSCursor?
        var onHover: (Bool) -> Void
        var frame: CGRect = .null
        var isHovered = false
    }

    func register(_ id: UUID, cursor: NSCursor?, onHover: @escaping (Bool) -> Void) {
        var entry = entries[id] ?? Entry(cursor: cursor, onHover: onHover)
        entry.cursor = cursor
        entry.onHover = onHover
        entries[id] = entry
        recompute()
    }

    func unregister(_ id: UUID) {
        // A hovered entry torn down while the pointer still rests over it
        // (scroll-off, filter collapse) must still deliver its exit - the
        // state write to the detaching view is harmless in SwiftUI, and the
        // pop undoes its cursor push so the hand cannot strand.
        guard let entry = entries[id] else { return }
        entries[id] = nil
        if entry.isHovered {
            Task { @MainActor in
                if entry.cursor != nil { NSCursor.pop() }
                entry.onHover(false)
            }
        }
    }

    /// The frame action fires on every layout and carries the live closure,
    /// so an entry's callback can never go stale across view recycling.
    func setFrame(
        _ id: UUID,
        _ frame: CGRect,
        cursor: NSCursor?,
        onHover: @escaping (Bool) -> Void
    ) {
        var entry = entries[id] ?? Entry(cursor: cursor, onHover: onHover)
        entry.cursor = cursor
        entry.onHover = onHover
        entry.frame = frame
        entries[id] = entry
        recompute()
    }

    func setPointer(_ point: CGPoint?) {
        guard point != pointer else { return }
        pointer = point
        recompute()
    }

    private func recompute() {
        // Hover transitions hand state writes back to SwiftUI, and those
        // re-renders re-run the geometry callbacks that drive this method.
        // Delivering synchronously would close a layout loop (hover lights,
        // transient frames report, hover clears, repeat). Hand the
        // transitions to the next runloop tick instead; the frames reported
        // then are settled, so the derivation converges.
        //
        // Cursor push/pop rides the same transitions: the entries' geometry
        // is the rendered truth, so the hand appears exactly while the
        // pointer is inside a click target and pops when it leaves - unlike
        // cursorUpdate-driven styles, which strand an arrow whenever an exit
        // is dropped.
        var transitions: [() -> Void] = []
        // Snapshot the keys: flip() writes entries[id] while the loop walks
        // the dictionary - value replacement for existing keys is safe today,
        // but any future insert/remove inside the loop would be undefined.
        let ids = Array(entries.keys)
        func flip(_ id: UUID, _ value: Bool) {
            guard var entry = entries[id] else { return }
            entry.isHovered = value
            entries[id] = entry
            transitions.append({ [onHover = entry.onHover, cursor = entry.cursor, value] in
                if let cursor {
                    if value { cursor.push() } else { NSCursor.pop() }
                }
                onHover(value)
            })
        }
        guard let pointer else {
            for id in ids where entries[id]?.isHovered == true {
                flip(id, false)
            }
            deliver(transitions)
            return
        }
        for id in ids {
            guard let entry = entries[id] else { continue }
            let isHovered = entry.frame.contains(pointer)
            guard isHovered != entry.isHovered else { continue }
            flip(id, isHovered)
        }
        deliver(transitions)
    }

    private func deliver(_ transitions: [() -> Void]) {
        guard !transitions.isEmpty else { return }
        Task { @MainActor in
            for deliver in transitions {
                deliver()
            }
        }
    }
}

private struct HoverSpaceKey: EnvironmentKey {
    static let defaultValue: HoverSpace? = nil
}

extension EnvironmentValues {
    var hoverSpace: HoverSpace? {
        get { self[HoverSpaceKey.self] }
        set { self[HoverSpaceKey.self] = newValue }
    }
}

/// Declares a hover space: `tracksHover` descendants report their frames in
/// it, and the pointer position is fed from this view's bounds. Attach once
/// per list or container.
private struct HoverTrackingSpace: ViewModifier {
    @State private var space = HoverSpace()

    func body(content: Content) -> some View {
        content
            .environment(\.hoverSpace, space)
            // One sensor for the whole space, behind the content: it never
            // moves (no stale-area problem), and its flipped local pointer
            // coordinates align exactly with the frames the rows report.
            .background {
                HoverSensorRepresentable(space: space)
            }
            .coordinateSpace(name: space.name)
    }
}

/// Feeds the pointer position (in the sensor's own bounds, top-left origin)
/// into its hover space.
private struct HoverSensorRepresentable: NSViewRepresentable {
    let space: HoverSpace

    func makeNSView(context: Context) -> HoverSensorView {
        let view = HoverSensorView()
        view.space = space
        return view
    }

    func updateNSView(_ nsView: HoverSensorView, context: Context) {
        nsView.space = space
    }
}

/// One tracking area over the whole space's bounds. The view is a background:
/// it never participates in hit testing, never re-renders, and never moves
/// relative to the coordinate space, so its area can neither strand nor churn.
final class HoverSensorView: NSView {
    weak var space: HoverSpace?

    /// Hover only: clicks belong to the SwiftUI content this sits behind.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        feed(event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        feed(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        space?.setPointer(nil)
    }

    private func feed(_ windowLocation: NSPoint) {
        guard let space else { return }
        // The sensor's window rect is AppKit's own truth about where the
        // space's bounds sit; SwiftUI spaces are top-left origin, AppKit
        // bottom-left, hence the flip.
        let boundsInWindow = convert(bounds, to: nil)
        let point = CGPoint(
            x: windowLocation.x - boundsInWindow.minX,
            y: boundsInWindow.maxY - windowLocation.y
        )
        space.setPointer(point)
    }
}

/// Registers one view's frame in the enclosing hover space. Requires a
/// `hoverTracking()` ancestor - every call site has one; without one the
/// content passes through unchanged (hover cannot be derived there).
private struct TrackHover: ViewModifier {
    let onHover: (Bool) -> Void
    let cursor: NSCursor?
    @Environment(\.hoverSpace) private var environmentSpace: HoverSpace?
    @State private var sensorID = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if let space = environmentSpace {
            content
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(space.name))
                } action: { frame in
                    space.setFrame(sensorID, frame, cursor: cursor, onHover: onHover)
                }
                .onAppear { space.register(sensorID, cursor: cursor, onHover: onHover) }
                .onDisappear { space.unregister(sensorID) }
        } else {
            content
        }
    }
}

extension View {
    /// Declares a hover space: `tracksHover` descendants report their frames
    /// in it and the pointer position is fed from this view's bounds. Attach
    /// once per list or container.
    func hoverTracking() -> some View {
        modifier(HoverTrackingSpace())
    }

    /// Hover for a view whose pointer tracking must not depend on AppKit
    /// enter/exit delivery - the cases where `.onHover` strands the highlight
    /// and the cursor. Pushes/pops `cursor` (the pointing hand by default) on
    /// the same verified transitions; see `HoverSpace`. Must have a
    /// `hoverTracking()` ancestor; remove any `.clickCursor()` from the
    /// tracked view, or the two cursor mechanisms will fight.
    func tracksHover(
        _ onHover: @escaping (Bool) -> Void,
        cursor: NSCursor? = NSCursor.pointingHand
    ) -> some View {
        modifier(TrackHover(onHover: onHover, cursor: cursor))
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
