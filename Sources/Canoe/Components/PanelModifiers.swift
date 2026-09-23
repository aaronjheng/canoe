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
            // Private field-editor class only - patch before AppKit's first paint.
            disable(on: type(of: editor))
        }
        return editor
    }

    static func install() {
        installFieldEditorHook()
    }

    /// Replace `focusRingType` / `drawFocusRingMask` on `cls`. Only ever
    /// called on the private field-editor class (via the fieldEditor hook)
    /// - never on NSTextView / NSTextField, whose methods must stay intact
    /// for text layout.
    private static func disable(on cls: AnyClass) {
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

/// Focus-border language for bordered fields (see `focusRingBorder`):
/// rest state is the strong border, focused state is the accent at 2pt.
/// The URL bar and method picker keep bespoke overlays only because their
/// spliced UnevenRoundedRectangle shape differs - same widths, same colors.
struct FocusRingBorderModifier: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(
                    isFocused ? AppColor.accent : AppColor.borderStrong,
                    lineWidth: isFocused ? 2 : 1)
        )
    }
}

extension View {
    func panelToolbar(horizontalPadding: CGFloat = AppSpacing.large) -> some View {
        modifier(PanelToolbarModifier(horizontalPadding: horizontalPadding))
    }

    func popupPanel() -> some View {
        modifier(PopupPanelModifier())
    }

    /// Single focus-border language for bordered fields: rest state is the
    /// strong border, focused state is the accent at 2pt.
    func focusRingBorder(isFocused: Bool) -> some View {
        modifier(FocusRingBorderModifier(isFocused: isFocused))
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
