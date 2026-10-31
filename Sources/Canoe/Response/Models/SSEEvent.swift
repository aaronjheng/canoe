import Foundation

/// One parsed server-sent event, shown by the Body pane of a
/// `text/event-stream` response. SSE is plain HTTP framing (WhatWG
/// "server-sent events"): the body is UTF-8 text where `data:` / `event:` /
/// `id:` / `retry:` lines build a block that a blank line dispatches.
struct SSEEvent: Sendable, Equatable, Identifiable {
    /// Arrival order, 0-based and chronological: the stream delivers events
    /// in order, so this doubles as the SwiftUI identity and the key the
    /// viewer's expand state hangs on.
    let index: Int
    /// The `event` field's value, or the spec's "message" default when the
    /// block carried none.
    let name: String
    /// The `data` field's content: the block's per-line values joined with
    /// "\n" (one `data:` line per line of payload).
    let data: String
    /// The block exactly as it arrived (every field line, "\n"-joined) -
    /// what the row's expanded view shows.
    let raw: String
    /// When the event's closing blank line left the socket: the arrival
    /// sample at-or-past the event's byte end offset
    /// (`ResponseModel.sseTimeline`). nil when the response carries no
    /// timeline - a history entry recorded before the feature, for example.
    let time: Date?

    var id: Int { index }

    /// First data line for the collapsed row's one-line preview.
    var preview: String {
        String(
            data.split(separator: "\n", omittingEmptySubsequences: false)
                .first ?? "")
    }
}

extension SSEEvent {
    /// Parses an event-stream body into its chronological events. `timeline`
    /// is the send's arrival samples (byte offset → wall-clock time) and
    /// `closedAt` the connection-close time as a safety net for offsets past
    /// the last sample. Pure over its inputs, so the viewer can run it off
    /// the main thread for large bodies.
    ///
    /// The scan stays in byte space - lines are located on the wire bytes,
    /// never on a decoded string - so an event's end offset always lines up
    /// with the timeline's byte counts, whatever the payload's encoding.
    static func parse(
        body: Data,
        timeline: [SSEStreamSample] = [],
        closedAt: Date? = nil
    ) -> [SSEEvent] {
        var events: [SSEEvent] = []
        // Current block's state: the lines between two blank lines.
        var dataLines: [String] = []
        var name: String?
        var blockLines: [String] = []
        // Events append in arrival order with a strictly growing end offset,
        // so mapping each end onto the first sample at-or-past it is one
        // continuing sweep over the samples, not a search per event.
        var sampleCursor = 0

        // A blank line ends the block. With data built up it dispatches the
        // event (covering the blank line's own bytes, since that line is
        // what carries the event over the wire); without, it only resets -
        // per the framing, an event needs a `data` field to dispatch.
        func dispatch(end: Int) {
            defer {
                dataLines.removeAll()
                name = nil
                blockLines.removeAll()
            }
            guard !dataLines.isEmpty else { return }
            while sampleCursor < timeline.count, timeline[sampleCursor].bytes < end {
                sampleCursor += 1
            }
            let time: Date?
            if sampleCursor < timeline.count {
                time = timeline[sampleCursor].date
            } else {
                time = closedAt
            }
            events.append(
                SSEEvent(
                    index: events.count,
                    name: name ?? "message",
                    data: dataLines.joined(separator: "\n"),
                    raw: blockLines.joined(separator: "\n"),
                    time: time
                ))
        }

        let bytes = [UInt8](body)
        let count = bytes.count
        let lineFeed = UInt8(ascii: "\n")
        var offset = 0
        while offset < count {
            // One line = the bytes up to the next LF (or EOF). Array slices
            // keep the base array's indices, so `firstIndex(of:)` on the
            // tail slice is already an absolute byte offset.
            let lineEnd = bytes[offset...].firstIndex(of: lineFeed) ?? count
            // The line's own interpretation tolerates CRLF (and bare CR):
            // a trailing \r is trimmed for the field's value only - the
            // byte accounting above consumed exactly what the wire carried.
            var text =
                String(
                    bytes: bytes[offset..<lineEnd], encoding: .utf8
                ) ?? "\u{FFFD}"
            if lineEnd < count, text.hasSuffix("\r") { text.removeLast() }
            let next = lineEnd < count ? lineEnd + 1 : count
            if text.isEmpty {
                dispatch(end: next)
            } else {
                // Framing: everything before the first colon is the field,
                // one leading space of the value is stripped, and a line
                // without a colon carries its whole text as the field.
                // Unknown fields and comment lines (`:…`, field "") do
                // nothing yet stay in the block's raw view.
                var field = text
                var value = ""
                if let colon = text.firstIndex(of: ":") {
                    field = String(text[..<colon])
                    value = String(text[text.index(after: colon)...])
                    if value.hasPrefix(" ") { value.removeFirst() }
                }
                switch field {
                case "data": dataLines.append(value)
                case "event": name = value.isEmpty ? nil : value
                default: break
                }
                blockLines.append(text)
            }
            offset = next
        }
        // EOF dispatches a pending block (the framing dispatches buffered
        // data without a closing blank line) - a truncated body's cut-off
        // final event included.
        dispatch(end: count)
        return events
    }
}
