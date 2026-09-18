// SyncedConfig.swift
// Leios — the part of the configuration that travels between a user's Macs.

import Foundation

/// The projection of `LeiosConfig` that iCloud carries.
///
/// Three settings are deliberately absent: the two kill switches and the menu bar item. A kill
/// switch means "stop doing this *here*, right now", so syncing one would reach across and turn
/// the engine off on the user's other Mac. Keeping them out of this type is what enforces that —
/// `apply(to:)` has no way to reach them, so they survive a remote apply by construction rather
/// than by remembering to put them back.
///
/// Every section is optional, and `nil` means "the payload said nothing about this, keep mine".
/// `init(_:)` always fills all four, so Leios never emits a partial payload; the optionality is a
/// defence against a truncated, hand-edited or unfamiliar payload arriving from somewhere else.
public struct SyncedConfig: Codable, Equatable, Sendable {

    /// The version of *this* projection, which the sync layer checks. Distinct from
    /// `LeiosConfig.version`, which is written to `config.json` and read by nothing.
    public static let schemaVersion = 1

    public var scroll: ScrollSettings?
    public var buttons: [Int: ButtonMapping]?
    public var general: SyncedGeneralSettings?
    public var apps: [String: AppProfile]?

    public init(scroll: ScrollSettings? = nil,
                buttons: [Int: ButtonMapping]? = nil,
                general: SyncedGeneralSettings? = nil,
                apps: [String: AppProfile]? = nil) {
        self.scroll = scroll
        self.buttons = buttons
        self.general = general
        self.apps = apps
    }

    /// Projects a configuration for upload. Every section is populated.
    public init(_ config: LeiosConfig) {
        scroll = config.scroll
        buttons = config.buttons
        general = SyncedGeneralSettings(config.general)
        apps = config.apps
    }

    /// Merges the payload into a configuration, touching only the synced fields.
    public func apply(to config: inout LeiosConfig) {
        if let scroll { config.scroll = scroll }
        if let buttons { config.buttons = buttons }
        if let general { general.apply(to: &config.general) }
        if let apps { config.apps = apps }
    }

    // MARK: Wire format

    /// Compact rather than pretty: this goes in a CloudKit record, not in front of a person.
    public static func encode(_ payload: SyncedConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    public static func decode(_ data: Data) throws -> SyncedConfig {
        try JSONDecoder().decode(SyncedConfig.self, from: data)
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey { case scroll, buttons, general, apps }

    /// Mirrors `LeiosConfig.init(from:)` — including its hostile-input handling, since a payload
    /// from another Mac deserves what `config.json` gets — with one deliberate difference: a
    /// missing key decodes to `nil` rather than to a default.
    ///
    /// That difference is the whole point for `buttons`. `LeiosConfig` reads a missing `buttons`
    /// key as `defaultButtons`, which is right for a fresh install reading a file and would be
    /// destructive here: a peer that omitted the key would reset every Mac's mappings. Absent
    /// leaves the local mappings alone; an empty object still means "the user cleared them all".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll)
        general = try c.decodeIfPresent(SyncedGeneralSettings.self, forKey: .general)
        if let raw = try c.decodeIfPresent([String: AppProfile].self, forKey: .apps) {
            apps = raw.filter { !$0.key.isEmpty }
        } else {
            apps = nil
        }
        if let raw = try c.decodeIfPresent([String: ButtonMapping].self, forKey: .buttons) {
            var result: [Int: ButtonMapping] = [:]
            for (k, v) in raw {
                if let n = Int(k), n >= 1, n <= LeiosConstants.maxButton { result[n] = v }
            }
            buttons = result
        } else {
            buttons = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(scroll, forKey: .scroll)
        try c.encodeIfPresent(general, forKey: .general)
        try c.encodeIfPresent(apps, forKey: .apps)
        if let buttons {
            var raw: [String: ButtonMapping] = [:]
            for (k, v) in buttons { raw[String(k)] = v }
            try c.encode(raw, forKey: .buttons)
        }
    }
}

/// The syncable part of `GeneralSettings`. One field today, and the type earns its place by what
/// it leaves out: `scrollingEnabled`, `buttonsEnabled` and `showMenuBarItem` are machine-local.
public struct SyncedGeneralSettings: Codable, Equatable, Sendable {
    public var lockPointerDuringDrag: Bool?

    public init(lockPointerDuringDrag: Bool? = nil) {
        self.lockPointerDuringDrag = lockPointerDuringDrag
    }

    public init(_ general: GeneralSettings) {
        lockPointerDuringDrag = general.lockPointerDuringDrag
    }

    public func apply(to general: inout GeneralSettings) {
        if let lockPointerDuringDrag { general.lockPointerDuringDrag = lockPointerDuringDrag }
    }
}
