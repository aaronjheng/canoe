import Foundation
import os

/// One structured breadcrumb per out-of-bounds selection clamp: the live
/// length and the raw ranges AppKit (or the host) tried to install. Shows
/// up with `log show --predicate 'subsystem == "app.plume"'`, naming the
/// repeat offender when a selection source misbehaves.
enum EditorSelectionClampLog {
    private static let logger = Logger(subsystem: "app.plume", category: "editor-selection")

    static func log(length: Int, ranges: [NSValue]) {
        let described = ranges.map { value -> String in
            let range = value.rangeValue
            return "(\(range.location), \(range.length))"
        }
        .joined(separator: " ")
        logger.info("clamped OOB selection to length \(length, privacy: .public): [\(described, privacy: .public)]")
    }
}
