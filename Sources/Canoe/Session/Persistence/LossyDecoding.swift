import Foundation
import Synchronization

/// A `Decodable` wrapper that contains element-level failures.
///
/// A vault file is a nested tree (collection -> folders -> requests -> query
/// params), and plain `decodeIfPresent([T].self, ...)` is all-or-nothing: one
/// hand-edited row, one field this build doesn't know, or one file a future
/// version wrote differently throws out of the parent's `init(from:)`, and
/// because `VaultStore` only isolates failures at *file* granularity, the
/// whole collection silently disappears from the app.
///
/// Decoding through `Lossy` gives every element its own decoder, so a bad
/// element is dropped and its siblings survive. The trade is deliberate: a
/// malformed row is skipped rather than repaired, so the next save rewrites
/// the file without it - which is why every drop is counted (see
/// `DroppedElementCounter`) and surfaced to the user instead of quietly
/// shrinking their vault.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        // `try?` inside `init(from:)` is the whole point: this element's
        // decoder is already positioned, and the failure stops here instead
        // of unwinding the parent.
        value = try? T(from: decoder)
        if value == nil { DroppedElementCounter.shared.record() }
    }
}

/// Counts rows skipped by `Lossy` across a load, so a vault that quietly lost
/// rows still says so.
///
/// Decoding runs concurrently (one task per file), so attribution per file
/// would be a lie; the honest unit is "rows dropped during this load", read
/// once by `VaultStore` after the batch finishes. The counter is mutex-guarded
/// because the load runs off the main actor.
final class DroppedElementCounter: @unchecked Sendable {
    static let shared = DroppedElementCounter()

    private let count = Mutex<Int>(0)

    func record() {
        count.withLock { $0 += 1 }
    }

    func reset() {
        count.withLock { $0 = 0 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array of `T`, dropping the elements that fail. An absent
    /// key decodes as an empty array, same as a plain `decodeIfPresent`.
    ///
    /// Only *element* failures are tolerated. A malformed container (the key
    /// holds an object or a string instead of an array) still throws: that is
    /// a whole-file problem, and swallowing it here would replace "file
    /// skipped, banner shown, bytes still on disk" with "array silently
    /// emptied, file rewritten without its contents".
    func decodeLossyArray<T: Decodable>(forKey key: Key) throws -> [T] {
        guard let elements = try decodeIfPresent([Lossy<T>].self, forKey: key) else { return [] }
        return elements.compactMap(\.value)
    }
}
