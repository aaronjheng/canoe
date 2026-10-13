import SwiftUI

/// Sheet for naming a new workspace. Shown when the user creates a workspace
/// from the welcome screen, sidebar, or menu bar.
struct NewWorkspaceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Text("New Workspace")
                .font(AppFont.panelTitle)

            Text("Give your workspace a name to organize related collections and requests.")
                .font(AppFont.emptyStateBody)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Workspace Name", text: $name)
                .font(AppFont.small)
                .variableFieldBordered(
                    isFocused: isFocused,
                    isHovered: isHovered,
                    verticalPadding: AppSpacing.compact
                )
                .focused($isFocused)
                .onHover { isHovered = $0 }
                .onSubmit(create)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    // Standard sheet confirm, matching the folder editor's
                    // Save (hero buttons stay on the welcome/empty states).
                    .buttonStyle(PrimaryButtonStyle())
                    // Nothing to create yet: `createWorkspace` would silently
                    // fall back to a placeholder name, dismissing the sheet
                    // on an outcome the user never chose. Dimmed instead,
                    // like the Send button on an empty URL.
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.vertical, AppSpacing.large)
        .frame(width: 380)
        .sheetSurface()
        // Sheet is its own root: suppress SwiftUI focus chrome here too so
        // first focus in the name field never paints the white-box flash.
        .focusEffectDisabled()
        .onAppear {
            name = ""
            isFocused = true
        }
    }

    private func create() {
        // The gate lives here, not only on the button: Return submits the
        // auto-focused field straight into this action, and a disabled
        // button would not stop it. Without the guard an empty (or
        // whitespace-only) name silently created the "New Workspace"
        // placeholder and dismissed the sheet.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.createWorkspace(name: trimmed)
        dismiss()
    }
}
