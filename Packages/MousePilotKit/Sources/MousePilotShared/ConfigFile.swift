// ConfigFile.swift
// MousePilot — location and atomic read/write of config.json.

import Foundation

public enum ConfigFile {
    public static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MousePilot", isDirectory: true)
    }

    public static var url: URL { directoryURL.appendingPathComponent("config.json") }

    /// Loads the config; a missing file yields defaults. Corrupt files throw.
    public static func load() throws -> MousePilotConfig {
        let url = self.url
        guard FileManager.default.fileExists(atPath: url.path) else { return MousePilotConfig() }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> MousePilotConfig {
        try JSONDecoder().decode(MousePilotConfig.self, from: data)
    }

    public static func encode(_ config: MousePilotConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    /// Atomically writes the config, creating the directory if needed.
    public static func save(_ config: MousePilotConfig) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encode(config)
        try data.write(to: url, options: .atomic)
    }
}
