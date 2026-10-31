import SwiftUI

/// The Body pane for a `text/event-stream` response (Postman's SSE view).
/// SSE is a plain HTTP request whose body streams events, so nothing in the
/// send pipeline changes - the pane renders what arrived: a newest-first
/// event log where each row shows the event type's badge, the first data
/// line, the arrival timestamp, and a chevron expanding the raw block, with
/// the connection-closed row above and a search filter on top.
struct EventStreamView: View {
    let response: ResponseModel

    /// The parsed events once the (deferred) parse has landed; nil while
    /// the pane still shows the synchronous parse or a loading state.
    @State private var events: [SSEEvent]?
    @State private var filter = ""
    @State private var expandedIndices: Set<Int> = []

    /// Bodies up to this parse in the same frame (matching the text modes'
    /// sync-render budget); above it the parse runs off the main thread
    /// behind a loading state.
    private static let syncParseBodyBytes = 262_144

    /// One event row's height, matching the dense-table rows' band.
    private static let rowHeight: CGFloat = AppSize.tableRowHeight + 4

    var body: some View {
        Group {
            if response.body.isEmpty {
                ContentUnavailableView(
                    "Empty Response Body",
                    systemImage: "doc.text",
                    description: Text("This response did not return any body content.")
                )
            } else if let events {
                streamPane(events)
            } else if response.body.count > Self.syncParseBodyBytes {
                // The off-main parse is running; the list lands when it
                // publishes (the task below).
                LoadingState(message: "Parsing events…")
            } else {
                streamPane(Self.parse(response))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.controlBackground)
        .task(id: response.id) {
            // Parse once per response. Small bodies already rendered the
            // synchronous result above - publish it to state, so no later
            // re-render pays the parse again; larger bodies parse off the
            // main thread and the cancelled check drops stale results.
            guard !Task.isCancelled else { return }
            if events == nil {
                let source = response
                if source.body.count > Self.syncParseBodyBytes {
                    let parsed = await Task.detached(priority: .userInitiated) {
                        Self.parse(source)
                    }.value
                    if !Task.isCancelled { events = parsed }
                } else {
                    events = Self.parse(source)
                }
            }
        }
    }

    /// The synchronous parse for small bodies (also what the deferred task
    /// runs off the main actor for large ones).
    private nonisolated static func parse(_ response: ResponseModel) -> [SSEEvent] {
        SSEEvent.parse(
            body: response.body,
            timeline: response.sseTimeline ?? [],
            closedAt: response.timestamp)
    }

    // MARK: - Pane

    private func streamPane(_ all: [SSEEvent]) -> some View {
        let filtered = filteredEvents(all)
        return VStack(spacing: 0) {
            filterRow
            Divider().padding(.horizontal, AppSpacing.medium)
            if response.bodyTruncated {
                truncationBanner
                Divider().padding(.horizontal, AppSpacing.medium)
            }
            if all.isEmpty {
                eventStreamEmptyState("The stream closed without sending any events.")
            } else if filtered.isEmpty {
                Text("No events match the search.")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(AppSpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                eventList(filtered)
            }
        }
    }

    /// Search filters the event rows (Postman's message search): the type
    /// name and the data content, case-insensitive.
    private func filteredEvents(_ events: [SSEEvent]) -> [SSEEvent] {
        guard !filter.isEmpty else { return events }
        let query = filter.lowercased()
        return events.filter {
            $0.name.lowercased().contains(query) || $0.data.lowercased().contains(query)
        }
    }

    private var filterRow: some View {
        HStack {
            FilterField(text: $filter, placeholder: "Search", isBoxed: true)
                .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
    }

    /// The transport-level body cap, the same notice the text modes show:
    /// events past the cap were never kept.
    private var truncationBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .font(AppFont.small)
            Text(
                "Response body exceeded \(Int64(HTTPClient.maxResponseBytes).formattedByteCount) and was truncated."
            )
            .font(AppFont.small)
        }
        .foregroundStyle(AppColor.textSecondary)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
    }

    /// The stream log: the connection-closed row on top (it happened last,
    /// Postman's ordering), then every event newest-first with hairline
    /// rules between rows.
    private func eventList(_ events: [SSEEvent]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                closedRow
                ForEach(Array(events.reversed().enumerated()), id: \.element.index) { index, event in
                    eventRow(event)
                    if index < events.count - 1 {
                        Divider().padding(.horizontal, AppSpacing.medium)
                    }
                }
            }
        }
        .background(AppColor.codeBackground)
    }

    private func eventStreamEmptyState(_ description: String) -> some View {
        ContentUnavailableView(
            "No Events",
            systemImage: "dot.radiowaves.left.and.right",
            description: Text(description)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rows

    /// The stream's lifecycle notice: the connection ended (a response only
    /// exists once the server closed the stream), with the close time.
    private var closedRow: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "info.circle")
                .font(AppFont.small)
                .foregroundStyle(AppColor.textSecondary)
            Text("Connection closed")
                .font(AppFont.small)
                .foregroundStyle(AppColor.textPrimary)
            Spacer(minLength: AppSpacing.medium)
            Text(Self.timeFormatter.string(from: response.timestamp))
                .font(AppFont.small)
                .monospacedDigit()
                .foregroundStyle(AppColor.textSecondary)
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(minHeight: Self.rowHeight)
    }

    private func eventRow(_ event: SSEEvent) -> some View {
        let color = Self.badgeColor(for: event.name)
        let isExpanded = expandedIndices.contains(event.index)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.accent)
                Text(event.name)
                    .font(AppFont.countBadge.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, AppSpacing.compact)
                    .padding(.vertical, AppSpacing.xxSmall)
                    .background(AppColor.badgeBackground(color))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                    .fixedSize(horizontal: true, vertical: false)
                Text(event.preview)
                    .font(AppFont.monoBody)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(AppColor.textPrimary)
                Spacer(minLength: AppSpacing.medium)
                if let time = event.time {
                    Text(Self.timeFormatter.string(from: time))
                        .font(AppFont.small)
                        .monospacedDigit()
                        .foregroundStyle(AppColor.textSecondary)
                }
                Button {
                    toggleExpanded(event.index)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(AppColor.textSecondary)
                .help(isExpanded ? "Collapse event" : "Expand event")
            }
            .frame(minHeight: Self.rowHeight)
            if isExpanded {
                // The block as it arrived, indented under the row content:
                // aligned with the badge column like the expanded log's own
                // fields.
                Text(event.raw)
                    .font(AppFont.monoCaption)
                    .foregroundStyle(AppColor.textPrimary)
                    .textSelection(.enabled)
                    .padding(.leading, AppSpacing.small + AppSize.iconButtonGlyphBox)
                    .padding(.vertical, AppSpacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, AppSpacing.medium)
    }

    private func toggleExpanded(_ index: Int) {
        if expandedIndices.contains(index) {
            expandedIndices.remove(index)
        } else {
            expandedIndices.insert(index)
        }
    }

    // MARK: - Presentation helpers

    /// Event name → badge color, stable across runs (FNV-1a over the name's
    /// UTF-8 bytes): one event type always reads as one color in a stream,
    /// different types differ, without a color per possible name.
    private static let badgePalette: [Color] = [
        AppColor.error, AppColor.accent, AppColor.success,
        AppColor.warning, AppColor.done, AppColor.methodWS,
    ]

    private static func badgeColor(for name: String) -> Color {
        var hash: UInt32 = 0x811C_9DC5
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        return badgePalette[Int(hash % UInt32(badgePalette.count))]
    }

    /// Sub-second wall-clock times ("11:26:52.371"), fixed locale like every
    /// other time label in the response pane.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
