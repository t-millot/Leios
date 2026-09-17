// MousePilotConfig.swift
// MousePilot — the single configuration document shared by the app and the helper.
// Defaults mirror Mac Mouse Fix's default_config.plist.

import Foundation

public struct MousePilotConfig: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var scroll = ScrollSettings()
    /// Keyed by mouse button number (3…32). Encoded with string keys in JSON.
    public var buttons: [Int: ButtonMapping] = MousePilotConfig.defaultButtons
    public var general = GeneralSettings()

    public init() {}

    public static let defaultButtons: [Int: ButtonMapping] = [
        4: ButtonMapping(click: .symbolicHotkey(.lookUp), drag: .threeFingerSwipe),
        5: ButtonMapping(click: .smartZoom, drag: .twoFingerSwipe),
    ]

    /// Preset for three-button mice (from Mac Mouse Fix `defaultRemaps.threeButtons`).
    public static let threeButtonPreset: [Int: ButtonMapping] = [
        3: ButtonMapping(click: .symbolicHotkey(.lookUp), doubleClick: .symbolicHotkey(.launchpad), hold: .symbolicHotkey(.showDesktop), drag: .threeFingerSwipe),
    ]

    /// Preset for five-button mice (from Mac Mouse Fix `defaultRemaps.fiveButtons`).
    public static let fiveButtonPreset: [Int: ButtonMapping] = defaultButtons

    enum CodingKeys: String, CodingKey { case version, scroll, buttons, general }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? ScrollSettings()
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
        if let raw = try c.decodeIfPresent([String: ButtonMapping].self, forKey: .buttons) {
            var result: [Int: ButtonMapping] = [:]
            for (k, v) in raw {
                if let n = Int(k), n >= 1, n <= MPConstants.maxButton { result[n] = v }
            }
            buttons = result
        } else {
            buttons = MousePilotConfig.defaultButtons
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(scroll, forKey: .scroll)
        try c.encode(general, forKey: .general)
        var raw: [String: ButtonMapping] = [:]
        for (k, v) in buttons { raw[String(k)] = v }
        try c.encode(raw, forKey: .buttons)
    }
}

public struct ScrollSettings: Codable, Equatable, Sendable {
    public enum Smoothness: String, Codable, CaseIterable, Sendable {
        case off, regular, high
        public var displayName: String {
            switch self { case .off: return "Off"; case .regular: return "Regular"; case .high: return "High" }
        }
    }
    public enum Speed: String, Codable, CaseIterable, Sendable {
        case system, low, medium, high
        public var displayName: String {
            switch self { case .system: return "macOS"; case .low: return "Low"; case .medium: return "Medium"; case .high: return "High" }
        }
    }

    public var smoothness: Smoothness = .high
    public var speed: Speed = .medium
    public var precise: Bool = false
    public var reverseDirection: Bool = true
    public var trackpadSimulation: Bool = true
    public var modifiers = ScrollModifierFlags()

    public init() {}

    enum CodingKeys: String, CodingKey { case smoothness, speed, precise, reverseDirection, trackpadSimulation, modifiers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smoothness = try c.decodeIfPresent(Smoothness.self, forKey: .smoothness) ?? .high
        speed = try c.decodeIfPresent(Speed.self, forKey: .speed) ?? .medium
        precise = try c.decodeIfPresent(Bool.self, forKey: .precise) ?? false
        reverseDirection = try c.decodeIfPresent(Bool.self, forKey: .reverseDirection) ?? true
        trackpadSimulation = try c.decodeIfPresent(Bool.self, forKey: .trackpadSimulation) ?? true
        modifiers = try c.decodeIfPresent(ScrollModifierFlags.self, forKey: .modifiers) ?? ScrollModifierFlags()
    }
}

/// Keyboard modifier flags (CGEventFlags raw values) that change scrolling behavior. 0 disables the modifier.
public struct ScrollModifierFlags: Codable, Equatable, Sendable {
    public var horizontal: UInt64 = MPConstants.ModifierFlag.shift
    public var quick: UInt64 = MPConstants.ModifierFlag.control
    public var precise: UInt64 = MPConstants.ModifierFlag.option
    public var zoom: UInt64 = MPConstants.ModifierFlag.command

    public init() {}

    enum CodingKeys: String, CodingKey { case horizontal, quick, precise, zoom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        horizontal = try c.decodeIfPresent(UInt64.self, forKey: .horizontal) ?? MPConstants.ModifierFlag.shift
        quick = try c.decodeIfPresent(UInt64.self, forKey: .quick) ?? MPConstants.ModifierFlag.control
        precise = try c.decodeIfPresent(UInt64.self, forKey: .precise) ?? MPConstants.ModifierFlag.option
        zoom = try c.decodeIfPresent(UInt64.self, forKey: .zoom) ?? MPConstants.ModifierFlag.command
    }

    public var anyConfigured: Bool { horizontal != 0 || quick != 0 || precise != 0 || zoom != 0 }
}

public struct ButtonMapping: Codable, Equatable, Sendable {
    public var click: Action?
    public var doubleClick: Action?
    public var hold: Action?
    public var drag: MouseDragGesture?

    public init(click: Action? = nil, doubleClick: Action? = nil, hold: Action? = nil, drag: MouseDragGesture? = nil) {
        self.click = click
        self.doubleClick = doubleClick
        self.hold = hold
        self.drag = drag
    }

    public var isEmpty: Bool { click == nil && doubleClick == nil && hold == nil && drag == nil }

    enum CodingKeys: String, CodingKey { case click, doubleClick, hold, drag }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        click = try c.decodeIfPresent(Action.self, forKey: .click)
        doubleClick = try c.decodeIfPresent(Action.self, forKey: .doubleClick)
        hold = try c.decodeIfPresent(Action.self, forKey: .hold)
        drag = try c.decodeIfPresent(MouseDragGesture.self, forKey: .drag)
    }
}

public struct GeneralSettings: Codable, Equatable, Sendable {
    public var showMenuBarItem: Bool = false
    public var lockPointerDuringDrag: Bool = false
    public var scrollingEnabled: Bool = true
    public var buttonsEnabled: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey { case showMenuBarItem, lockPointerDuringDrag, scrollingEnabled, buttonsEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showMenuBarItem = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem) ?? false
        lockPointerDuringDrag = try c.decodeIfPresent(Bool.self, forKey: .lockPointerDuringDrag) ?? false
        scrollingEnabled = try c.decodeIfPresent(Bool.self, forKey: .scrollingEnabled) ?? true
        buttonsEnabled = try c.decodeIfPresent(Bool.self, forKey: .buttonsEnabled) ?? true
    }
}
