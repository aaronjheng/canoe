import AppKit
import ObjectiveC
import SwiftUI

// Panel chrome: save chip, toolbar/popup/focus modifiers.
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
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isDirty ? AppColor.accent : .secondary)
            .padding(.horizontal, AppSpacing.comfortable)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isDirty ? AppColor.subtleBackground : (isHovering ? AppColor.tabHoverBackground : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(!isDirty)
        .help(help)
    }
}

struct PanelToolbarModifier: ViewModifier {
    var horizontalPadding: CGFloat = AppSpacing.large

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: AppSize.toolbarHeight)
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
                    .fill(.background)
                    .shadow(color: AppColor.popupShadow, radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(AppColor.border, lineWidth: 1)
            )
    }
}

/// Border language for fields (see `focusRingBorder`): rest is the strong
/// border at the standard field width, focused is accent at the same width.
/// Hover/focus fills are handled by the caller so they can pick the right
/// idle background. The URL bar and method picker keep bespoke overlays
/// only because their spliced UnevenRoundedRectangle shape differs - same
/// widths, same colors.
struct FocusRingBorderModifier: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(
                    isFocused ? AppColor.accent : AppColor.borderStrong,
                    lineWidth: isFocused ? AppLine.focusedField : AppLine.field)
        )
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
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
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
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

extension View {
    func panelToolbar(horizontalPadding: CGFloat = AppSpacing.large) -> some View {
        modifier(PanelToolbarModifier(horizontalPadding: horizontalPadding))
    }

    func popupPanel() -> some View {
        modifier(PopupPanelModifier())
    }

    /// Border language for fields: rest is the strong border at the
    /// standard field width, focused is accent at the same width.
    func focusRingBorder(isFocused: Bool) -> some View {
        modifier(FocusRingBorderModifier(isFocused: isFocused))
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
