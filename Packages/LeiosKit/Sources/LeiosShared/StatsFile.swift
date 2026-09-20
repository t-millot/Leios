// StatsFile.swift
// Leios — location and atomic read/write of statistics.json.

import Foundation

public enum StatsFile {

    /// A subdirectory of the Application Support folder rather than a file beside `config.json`,
    /// and that matters: the helper's `ConfigStore` watches the config *directory* with a
    /// `DispatchSourceFileSystemObject` on the main queue, so an atomic write of a sibling file
    /// would make it re-read and re-decode the configuration every time statistics were flushed.
    /// Writes inside a child directory do not fire the parent's vnode source.
    public static var directoryURL: URL {
        ConfigFile.directoryURL.appendingPathComponent("Statistics", isDirectory: true)
    }

    public static var url: URL { directoryURL.appendingPathComponent("statistics.json") }

    /// Loads the archive. A missing file yields `nil` — a fresh install has no history, which is
    /// different from having one we could not read. Corrupt files throw.
    ///
    /// The `from:` and `to:` overloads exist so the engine's write path can be exercised against
    /// a temporary directory; nothing in the app or the helper passes one.
    public static func load(from url: URL? = nil) throws -> StatsArchive? {
        let url = url ?? self.url
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> StatsArchive {
        try decoder().decode(StatsArchive.self, from: data)
    }

    /// Compact, unlike `ConfigFile.encode`: nobody edits this file by hand, and pretty-printing a
    /// year of buckets is most of its size. Keys stay sorted so a diff of two snapshots is readable.
    public static func encode(_ archive: StatsArchive) throws -> Data {
        try encoder().encode(archive)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Atomically writes the archive, creating the directory if needed.
    public static func save(_ archive: StatsArchive, to url: URL? = nil) throws {
        let url = url ?? self.url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encode(archive).write(to: url, options: .atomic)
    }

    /// Removes the file. The next flush starts a fresh archive.
    public static func delete(at url: URL? = nil) throws {
        let url = url ?? self.url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
