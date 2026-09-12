import SwiftUI

/// Sheet for naming a new workspace. Shown when the user creates a workspace
/// from the welcome screen, sidebar, or menu bar.
struct NewWorkspaceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title)
                    .foregroundStyle(AppColor.accent)
                Text("New Workspace")
                    .font(.title2.weight(.semibold))
            }

            Text("Give your workspace a name to organize related collections and requests.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            TextField("Workspace Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(create)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: create)
                    .buttonStyle(SendButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppSpacing.xLarge)
        .frame(width: 380)
        .onAppear {
            name = ""
            isFocused = true
        }
    }

    private func create() {
        store.createWorkspace(name: name)
        dismiss()
    }
}
