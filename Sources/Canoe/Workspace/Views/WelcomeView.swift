import SwiftUI

/// Full-screen onboarding shown when no workspace exists yet. Mirrors the
/// Postman "create your first workspace" prompt - the app stays in this state
/// until the user creates a workspace.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: AppSpacing.xLarge) {
            icon

            VStack(spacing: AppSpacing.small) {
                Text("Welcome to Canoe")
                    .font(.largeTitle.weight(.semibold))
                Text("Create a workspace to start organizing your API requests.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
                store.addWorkspace()
            } label: {
                Label("Create Workspace", systemImage: "plus")
            }
            .buttonStyle(SendButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    /// The app icon rendered large, with a soft shadow like the Postman
    /// welcome screen.
    private var icon: some View {
        Image("CanoeMark")
            .resizable()
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            .shadow(color: AppColor.accent.opacity(0.3), radius: 20, y: 8)
    }
}
