import Foundation

/// Simple atomic JSON file storage for the local vault. Writes are atomic so
/// a crash mid-save never leaves a half-written file behind.
enum FileStore {
    // MARK: - Read

    /// Reads and decodes a `Decodable` value from a JSON file.
    static func read<T: Decodable>(_ type: T.Type, at url: URL) async throws -> T {
        try JSONDecoder.iso.decode(T.self, from: try Data(contentsOf: url))
    }

    /// Reads raw file data if the file exists, otherwise returns nil.
    static func readDataIfExists(at url: URL) async throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    // MARK: - Write

    /// Encodes an `Encodable` value to pretty JSON and writes it atomically.
    static func write<T: Encodable>(_ value: T, to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await writeData(encoder.encode(value), to: url)
    }

    /// Writes raw data atomically, creating parent directories as needed.
    static func writeData(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Delete

    static func delete(at url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Directory listing

    /// Lists `*.json` files in a directory, sorted by name.
    static func jsonFiles(in directory: URL) async throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - Shared JSON coders

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
