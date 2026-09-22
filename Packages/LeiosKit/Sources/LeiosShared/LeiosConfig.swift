// LeiosConfig.swift
// Leios — the single configuration document shared by the app and the helper.
// Defaults mirror Mac Mouse Fix's default_config.plist.

import Foundation

public struct LeiosConfig: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var scroll = ScrollSettings()
    /// Keyed by mouse button number (3…32). Encoded with string keys in JSON.
    public var buttons: [Int: ButtonMapping] = LeiosConfig.defaultButtons
    public var general = GeneralSettings()
    /// Per-application scroll profiles, keyed by bundle identifier. Buttons and drags are global.
    public var apps: [String: AppProfile] = [:]

    public init() {}

    /// The scroll settings each profiled app should actually get. Profiles that resolve to the
    /// global settings are dropped, so the engine can skip the app lookup when nothing differs.
    public var effectiveAppScroll: [String: ScrollSettings] {
        var result: [String: ScrollSettings] = [:]
        for (bundleID, profile) in apps {
            let resolved = profile.scroll.resolved(against: scroll)
            if resolved != scroll { result[bundleID] = resolved }
        }
        return result
    }

    public static let defaultButtons: [Int: ButtonMapping] = [
        4: ButtonMapping(click: .navigateBack, drag: .threeFingerSwipe),
        5: ButtonMapping(click: .navigateForward, drag: .twoFingerSwipe),
    ]

    /// Preset for three-button mice (from Mac Mouse Fix `defaultRemaps.threeButtons`).
    public static let threeButtonPreset: [Int: ButtonMapping] = [
        3: ButtonMapping(click: .symbolicHotkey(.lookUp), doubleClick: .symbolicHotkey(.launchpad), hold: .symbolicHotkey(.showDesktop), drag: .threeFingerSwipe),
    ]

    /// Preset for five-button mice (from Mac Mouse Fix `defaultRemaps.fiveButtons`, but with the
    /// side buttons on Back/Forward, which is what the thumb buttons of a five-button mouse do elsewhere).
    public static let fiveButtonPreset: [Int: ButtonMapping] = defaultButtons

    /// What `SwitchMaster` needs to decide whether the scroll tap must run. The tap is armed before
    /// the app under the pointer is known, so it has to cover the global settings *and* every profile.
    public var scrollGating: ScrollGating {
        let perApp = effectiveAppScroll.values
        var maps = [scroll.modifiers]
        for settings in perApp where !maps.contains(settings.modifiers) {
            maps.append(settings.modifiers)
        }
        return ScrollGating(modifiesByDefault: scroll.modifiesScrollByDefault || perApp.contains { $0.modifiesScrollByDefault },
                            modifierMaps: maps)
    }

    enum CodingKeys: String, CodingKey { case version, scroll, buttons, general, apps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? ScrollSettings()
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
        if let raw = try c.decodeIfPresent([String: AppProfile].self, forKey: .apps) {
            apps = raw.filter { !$0.key.isEmpty }
        } else {
            apps = [:]
        }
        if let raw = try c.decodeIfPresent([String: ButtonMapping].self, forKey: .buttons) {
            var result: [Int: ButtonMapping] = [:]
            for (k, v) in raw {
                if let n = Int(k), n >= 1, n <= LeiosConstants.maxButton { result[n] = v }
            }
            buttons = result
        } else {
            buttons = LeiosConfig.defaultButtons
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(scroll, forKey: .scroll)
        try c.encode(general, forKey: .general)
        try c.encode(apps, forKey: .apps)
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
    /// What the config file stores for Speed, and all a Leios from before the Speed slider reads.
    /// The slider's exact position travels beside it; see `ScrollSpeed`.
    public enum Speed: String, Codable, CaseIterable, Sendable {
        case system, low, medium, high
    }

    public var smoothness: Smoothness = .high
    /// The preset nearest the Speed slider. Writing it drops any finer position, so the two can
    /// never disagree; the slider itself reads and writes `scrollSpeed`.
    public var speed: Speed = .medium {
        didSet { speedLevel = nil }
    }
    /// The slider's exact position when it is not on a preset; nil means exactly `speed`. See
    /// `ScrollSpeed.stored` for why the two are kept side by side.
    public private(set) var speedLevel: Double?
    public var precise: Bool = false
    public var reverseDirection: Bool = true
    public var trackpadSimulation: Bool = true
    public var modifiers = ScrollModifierFlags()

    public init() {}

    public var scrollSpeed: ScrollSpeed {
        get { ScrollSpeed(speed: speed, level: speedLevel) }
        set {
            let stored = newValue.stored
            speed = stored.speed
            speedLevel = stored.level
        }
    }

    /// True when these settings change scrolling with no modifier held, which is what decides
    /// whether the scroll tap has to run at all.
    ///
    /// `precise` and `trackpadSimulation` are deliberately absent: `precise` only feeds the
    /// acceleration curve, which is dropped entirely at `speed == .system`, and `trackpadSimulation`
    /// only picks between two curves once `smoothness == .high`. Neither can modify scrolling alone.
    public var modifiesScrollByDefault: Bool {
        smoothness != .off || speed != .system || reverseDirection
    }

    enum CodingKeys: String, CodingKey { case smoothness, speed, speedLevel, precise, reverseDirection, trackpadSimulation, modifiers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smoothness = try c.decodeIfPresent(Smoothness.self, forKey: .smoothness) ?? .high
        speed = try c.decodeIfPresent(Speed.self, forKey: .speed) ?? .medium
        // A hand-edited or foreign file is clamped rather than refused: this only moves a slider.
        speedLevel = try c.decodeIfPresent(Double.self, forKey: .speedLevel).flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        precise = try c.decodeIfPresent(Bool.self, forKey: .precise) ?? false
        reverseDirection = try c.decodeIfPresent(Bool.self, forKey: .reverseDirection) ?? true
        trackpadSimulation = try c.decodeIfPresent(Bool.self, forKey: .trackpadSimulation) ?? true
        modifiers = try c.decodeIfPresent(ScrollModifierFlags.self, forKey: .modifiers) ?? ScrollModifierFlags()
    }
}

/// The Speed setting as one value: macOS's own scroll speed, or a position on Leios's range from
/// Low to High. The settings form binds to this, and an app profile pins or reverts it whole.
public struct ScrollSpeed: Equatable, Sendable {
    public var usesSystem: Bool
    /// 0 is Low, 0.5 Medium and 1 High — the three tuned presets, which the engine interpolates
    /// between. Kept while `usesSystem` is on, so turning it off returns the slider where it was.
    public var level: Double {
        didSet { level = Self.normalized(level) }
    }

    public static let defaultLevel = 0.5

    public init(usesSystem: Bool = false, level: Double) {
        self.usesSystem = usesSystem
        self.level = Self.normalized(level)
    }

    /// Clamped to the range, and rounded to hundredths — finer than anyone can feel, and it keeps
    /// a slider's `0.30000000000000004` out of the config file.
    private static func normalized(_ level: Double) -> Double {
        level.isFinite ? (min(max(level, 0), 1) * 100).rounded() / 100 : defaultLevel
    }

    init(speed: ScrollSettings.Speed, level: Double?) {
        self.init(usesSystem: speed == .system, level: level ?? Self.level(of: speed) ?? Self.defaultLevel)
    }

    /// Where Low, Medium and High sit on the slider; nil for `.system`, which is not on it.
    public static func level(of preset: ScrollSettings.Speed) -> Double? {
        switch preset {
        case .low: return 0
        case .medium: return 0.5
        case .high: return 1
        case .system: return nil
        }
    }

    /// How this is written to disk: the nearest preset, plus the exact level whenever it is not
    /// already that preset. A Leios from before the slider reads `speed` alone, and rejects a whole
    /// config file over a value it does not recognise, so `speed` only ever holds one it knows.
    /// A slider left on a preset writes exactly what those builds wrote.
    var stored: (speed: ScrollSettings.Speed, level: Double?) {
        if usesSystem {
            return (.system, level == Self.defaultLevel ? nil : level)
        }
        let nearest: ScrollSettings.Speed = level < 0.25 ? .low : level < 0.75 ? .medium : .high
        return (nearest, level == Self.level(of: nearest) ? nil : level)
    }
}

/// Per-application scroll overrides. A `nil` field keeps following the global setting, so changing
/// a global value still moves every app that never pinned it.
///
/// Unlike its neighbours this relies on the synthesized `Codable`: every field is optional, so the
/// synthesized decoder already tolerates any missing key and the synthesized encoder omits unset
/// fields instead of writing nulls. Hand-writing it would only restate that.
public struct ScrollOverrides: Codable, Equatable, Sendable {
    public var smoothness: ScrollSettings.Smoothness?
    /// Pinned together with `speedLevel`, through `scrollSpeed`: a profile pinned to Low must not
    /// pick up the global slider's position.
    public var speed: ScrollSettings.Speed? {
        didSet { speedLevel = nil }
    }
    public private(set) var speedLevel: Double?
    public var precise: Bool?
    public var reverseDirection: Bool?
    public var trackpadSimulation: Bool?
    /// Overridden as a block, not per modifier: the four are mutually exclusive, so a half-inherited
    /// set could put two roles on the same key.
    public var modifiers: ScrollModifierFlags?

    public init() {}

    public var scrollSpeed: ScrollSpeed? {
        get { speed.map { ScrollSpeed(speed: $0, level: speedLevel) } }
        set {
            let stored = newValue?.stored
            speed = stored?.speed
            speedLevel = stored?.level
        }
    }

    public var isEmpty: Bool {
        smoothness == nil && speed == nil && precise == nil
            && reverseDirection == nil && trackpadSimulation == nil && modifiers == nil
    }

    public func resolved(against global: ScrollSettings) -> ScrollSettings {
        var result = global
        if let smoothness { result.smoothness = smoothness }
        if let scrollSpeed { result.scrollSpeed = scrollSpeed }
        if let precise { result.precise = precise }
        if let reverseDirection { result.reverseDirection = reverseDirection }
        if let trackpadSimulation { result.trackpadSimulation = trackpadSimulation }
        if let modifiers { result.modifiers = modifiers }
        return result
    }
}

/// One application's entry in the Apps tab. Scroll only — buttons and drag gestures stay global.
public struct AppProfile: Codable, Equatable, Sendable {
    /// Display name captured when the app was added, so an app that is no longer installed
    /// still shows a name rather than a bare bundle identifier.
    public var name: String?
    public var scroll = ScrollOverrides()

    public init(name: String? = nil, scroll: ScrollOverrides = ScrollOverrides()) {
        self.name = name
        self.scroll = scroll
    }

    enum CodingKeys: String, CodingKey { case name, scroll }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        scroll = try c.decodeIfPresent(ScrollOverrides.self, forKey: .scroll) ?? ScrollOverrides()
    }
}

/// Precomputed answer to "must the scroll tap run?", covering the global settings and every profile.
public struct ScrollGating: Equatable, Sendable {
    /// Some settings modify scrolling with no modifier held.
    public let modifiesByDefault: Bool
    /// Every distinct modifier map in play, so held flags can be tested against all of them.
    public let modifierMaps: [ScrollModifierFlags]

    public init(modifiesByDefault: Bool, modifierMaps: [ScrollModifierFlags]) {
        self.modifiesByDefault = modifiesByDefault
        self.modifierMaps = modifierMaps
    }

    public var anyModifierConfigured: Bool { modifierMaps.contains { $0.anyConfigured } }
}

/// Keyboard modifier flags (CGEventFlags raw values) that change scrolling behavior. 0 disables the modifier.
public struct ScrollModifierFlags: Codable, Equatable, Sendable {
    public var horizontal: UInt64 = LeiosConstants.ModifierFlag.shift
    public var quick: UInt64 = LeiosConstants.ModifierFlag.control
    public var precise: UInt64 = LeiosConstants.ModifierFlag.option
    public var zoom: UInt64 = LeiosConstants.ModifierFlag.command

    public init() {}

    enum CodingKeys: String, CodingKey { case horizontal, quick, precise, zoom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        horizontal = try c.decodeIfPresent(UInt64.self, forKey: .horizontal) ?? LeiosConstants.ModifierFlag.shift
        quick = try c.decodeIfPresent(UInt64.self, forKey: .quick) ?? LeiosConstants.ModifierFlag.control
        precise = try c.decodeIfPresent(UInt64.self, forKey: .precise) ?? LeiosConstants.ModifierFlag.option
        zoom = try c.decodeIfPresent(UInt64.self, forKey: .zoom) ?? LeiosConstants.ModifierFlag.command
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
    /// Whether the helper counts usage statistics. Lives here because the engine needs it, and
    /// stays out of `SyncedConfig` for the reason the kill switches do: "stop counting *here*"
    /// must not reach across and stop counting on the user's other Mac.
    public var collectStatistics: Bool = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case showMenuBarItem, lockPointerDuringDrag, scrollingEnabled, buttonsEnabled, collectStatistics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showMenuBarItem = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem) ?? false
        lockPointerDuringDrag = try c.decodeIfPresent(Bool.self, forKey: .lockPointerDuringDrag) ?? false
        scrollingEnabled = try c.decodeIfPresent(Bool.self, forKey: .scrollingEnabled) ?? true
        buttonsEnabled = try c.decodeIfPresent(Bool.self, forKey: .buttonsEnabled) ?? true
        collectStatistics = try c.decodeIfPresent(Bool.self, forKey: .collectStatistics) ?? true
    }
}
