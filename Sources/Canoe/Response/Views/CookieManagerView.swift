import SwiftUI

/// Global manager for the persisted cookie jar (View ▸ Cookie Jar…, the
/// request tab row, or the response Cookies pane). The jar otherwise works
/// silently in the HTTP layer, so this is the visible way to inspect, search,
/// delete, or clear stored cookies.
struct CookieManagerView: View {
    @State private var cookies: [StoredCookie] = []
    @State private var query = ""
    @State private var showValues = false
    @State private var isLoading = true
    @State private var isConfirmingClear = false

    private static let expiresFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "cookie")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
                Text("Cookie Jar")
                    .font(AppFont.panelTitle)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Toggle("Show values", isOn: $showValues)
                    .font(AppFont.small)
                    .help("Show stored cookie values")
                Button("Refresh") {
                    Task { await refreshCookies() }
                }
                .buttonStyle(SecondaryButtonStyle(minHeight: AppSize.controlHeight))
                .help("Reload cookies from disk")
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            FilterField(text: $query, placeholder: "Search domain, name, value, or path")
                .padding(.horizontal, AppSpacing.medium)
                .padding(.bottom, AppSpacing.small)

            if isLoading {
                loadingState
            } else if cookies.isEmpty {
                emptyState
            } else if visibleCookies.isEmpty {
                noResultsState
            } else {
                cookieTable
            }

            footer
        }
        .background(AppColor.controlBackground)
        .task { await refreshCookies() }
        .confirmationDialog(
            "Clear all stored cookies",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear All Cookies", role: .destructive) { clearCookies() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Stored cookies are removed from this Mac and will no longer be sent with matching requests."
            )
        }
    }

    private var visibleCookies: [StoredCookie] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered =
            trimmed.isEmpty
            ? cookies
            : cookies.filter {
                $0.domain.localizedCaseInsensitiveContains(trimmed)
                    || $0.name.localizedCaseInsensitiveContains(trimmed)
                    || $0.value.localizedCaseInsensitiveContains(trimmed)
                    || $0.path.localizedCaseInsensitiveContains(trimmed)
            }
        return filtered.sorted {
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.path < $1.path
        }
    }

    private var loadingState: some View {
        HStack(spacing: AppSpacing.small) {
            ProgressView().controlSize(.small)
            Text("Loading cookies…")
                .font(AppFont.small)
                .foregroundStyle(AppColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Stored Cookies",
            systemImage: "cookie",
            description: Text("Cookies set by responses will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        ContentUnavailableView(
            "No Matching Cookies",
            systemImage: "magnifyingglass",
            description: Text("No stored cookies match the current search.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cookieTable: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 0) {
                headerRow
                Rectangle()
                    .fill(AppColor.tableBorder)
                    .frame(height: AppLine.hairline)
                ForEach(visibleCookies, id: \.self) { cookie in
                    cookieRow(cookie)
                    Rectangle()
                        .fill(AppColor.tableBorder)
                        .frame(height: AppLine.hairline)
                }
            }
            .frame(minWidth: 760, alignment: .leading)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            cookieHeaderCell("Name", width: 160)
            cookieHeaderCell("Value", width: nil)
            cookieHeaderCell("Domain", width: 180)
            cookieHeaderCell("Path", width: 110)
            cookieHeaderCell("Expires", width: 170)
            cookieHeaderCell("Flags", width: 130)
            Color.clear.frame(width: AppSize.controlHeight)
        }
        .frame(height: AppSize.tableRowHeight)
        .background(AppColor.tableHeaderBackground)
    }

    private func cookieHeaderCell(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(AppFont.columnHeader)
            .foregroundStyle(AppColor.textSecondary)
            .padding(.horizontal, AppSpacing.small)
            .applyCookieColumnWidth(width)
    }

    private func cookieRow(_ cookie: StoredCookie) -> some View {
        HStack(spacing: 0) {
            cookieTextCell(cookie.name, mono: true, width: 160)
            cookieTextCell(
                showValues ? cookie.value : String(repeating: "•", count: 8),
                mono: true,
                width: nil
            )
            cookieTextCell(cookie.domain, mono: false, width: 180)
            cookieTextCell(cookie.path, mono: false, width: 110)
            cookieTextCell(expiresText(for: cookie), mono: false, width: 170)
            cookieFlagsCell(cookie, width: 130)
            Button {
                deleteCookie(cookie)
            } label: {
                Image(systemName: "trash")
                    .contentShape(Rectangle())
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle(inset: 0))
            .foregroundStyle(AppColor.textSecondary)
            .frame(width: AppSize.controlHeight)
            .help("Delete \(cookie.name) for \(cookie.domain)")
        }
        .frame(minHeight: AppSize.tableRowHeight)
        .help("\(cookie.name)=\(showValues ? cookie.value : "••••••••")")
    }

    private func cookieTextCell(_ text: String, mono: Bool, width: CGFloat?) -> some View {
        Text(text)
            .font(mono ? AppFont.monoSubheadline : AppFont.small)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .padding(.horizontal, AppSpacing.small)
            .applyCookieColumnWidth(width)
    }

    private func cookieFlagsCell(_ cookie: StoredCookie, width: CGFloat) -> some View {
        HStack(spacing: AppSpacing.xxSmall) {
            FlagLabel(label: "Secure", isOn: cookie.secure)
            FlagLabel(label: "HttpOnly", isOn: cookie.httpOnly)
            if Self.isExpired(cookie) {
                FlagLabel(label: "Expired", isOn: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.small)
        .frame(width: width, alignment: .leading)
    }

    private static func isExpired(_ cookie: StoredCookie) -> Bool {
        cookie.expires.map { $0 <= Date() } ?? false
    }

    private func expiresText(for cookie: StoredCookie) -> String {
        guard let expires = cookie.expires else { return "Session" }
        return Self.expiresFormatter.string(from: expires)
    }

    private var footer: some View {
        HStack(spacing: AppSpacing.small) {
            Text(cookieSummary)
                .font(AppFont.small)
                .foregroundStyle(AppColor.textSecondary)
            Spacer(minLength: 0)
            Button("Clear All Cookies", role: .destructive) {
                isConfirmingClear = true
            }
            .buttonStyle(SecondaryButtonStyle(isDestructive: true, minHeight: AppSize.controlHeight))
            .disabled(cookies.isEmpty)
            .help("Clear all stored cookies")
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    private var cookieSummary: String {
        if cookies.isEmpty { return "Stored cookies are kept on this Mac." }
        return "\(visibleCookies.count) of \(cookies.count) stored cookies"
    }

    private func refreshCookies() async {
        isLoading = true
        cookies = await CookieStore.shared.allCookies()
        isLoading = false
    }

    private func deleteCookie(_ cookie: StoredCookie) {
        Task {
            await CookieStore.shared.deleteCookie(
                named: cookie.name,
                domain: cookie.domain,
                path: cookie.path
            )
            await refreshCookies()
        }
    }

    private func clearCookies() {
        Task {
            await CookieStore.shared.clearAll()
            await refreshCookies()
        }
    }
}

extension View {
    /// Fixed-width (or flexible) column reservation for the cookie table.
    @ViewBuilder
    fileprivate func applyCookieColumnWidth(_ width: CGFloat?) -> some View {
        if let width {
            self.frame(width: width, alignment: .leading)
        } else {
            self.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
