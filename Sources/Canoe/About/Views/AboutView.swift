import SwiftUI

/// Contents of the About panel opened from `Canoe → About Canoe`.
///
/// The system panel (`orderFrontStandardAboutPanel`) has no room for a
/// License button, so the app shows its own window instead: app mark,
/// version, one-line description, the License button, and the copyright line
/// taken from the bundled `LICENSE`.
struct AboutView: View {
    let onShowLicense: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.medium) {
            CanoeMarkView(size: AppSize.aboutIconSide)

            VStack(spacing: AppSpacing.xSmall) {
                Text("Canoe")
                    .font(.title2)
                    .bold()

                Text(Self.versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Native macOS API client")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            Button("License", systemImage: "doc.text", action: onShowLicense)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("l", modifiers: .command)
                .help("Show the Canoe license text")

            if !AppLicense.copyrightLine.isEmpty {
                Text(AppLicense.copyrightLine)
                    .font(AppFont.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, AppSpacing.xLarge + AppSize.titlebarClearance)
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.bottom, AppSpacing.xLarge)
        .frame(width: AppSize.aboutPanelWidth, height: AppSize.aboutPanelHeight)
        .background(AppColor.controlBackground)
        // Window root: kill SwiftUI's focus chrome (the panel's only control
        // is the License button).
        .focusEffectDisabled()
    }

    /// `Version 1.0 (128)`, matching the system panel's wording, so a build
    /// number bump needs no code change.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }
}
