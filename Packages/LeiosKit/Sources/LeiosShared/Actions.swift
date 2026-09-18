// Actions.swift
// Leios — the effects a mouse button can be mapped to. Schema derived from Mac Mouse Fix's Shared/Constants.h.

import Foundation

/// Drag gestures triggered by holding a mouse button and moving the mouse.
public enum MouseDragGesture: String, Codable, CaseIterable, Sendable, Hashable {
    /// Simulates a two-finger trackpad swipe (scroll anywhere, Safari page back/forward, Mail swipe actions).
    case twoFingerSwipe
    /// Simulates a three-finger trackpad swipe (Spaces horizontally, Mission Control / App Exposé vertically).
    case threeFingerSwipe

    public var displayName: String {
        switch self {
        case .twoFingerSwipe: return "Scroll & Navigate (two-finger swipe)"
        case .threeFingerSwipe: return "Spaces & Mission Control (three-finger swipe)"
        }
    }
}

/// macOS symbolic hotkeys (values from Mac Mouse Fix `MFSymbolicHotkey`, which match `com.apple.symbolichotkeys`).
public enum SymbolicHotkey: Int, Codable, CaseIterable, Sendable, Hashable {
    case missionControl = 32
    case appExpose = 33
    case showDesktop = 36
    case launchpad = 160
    case lookUp = 70
    case appSwitcher = 71
    case moveLeftASpace = 79
    case moveRightASpace = 81
    case cycleThroughWindows = 27
    case switchToDesktop1 = 118
    case switchToDesktop2 = 119
    case switchToDesktop3 = 120
    case switchToDesktop4 = 121
    case switchToDesktop5 = 122
    case switchToDesktop6 = 123
    case switchToDesktop7 = 124
    case switchToDesktop8 = 125
    case switchToDesktop9 = 126
    case switchToDesktop10 = 127
    case switchToDesktop11 = 128
    case switchToDesktop12 = 129
    case switchToDesktop13 = 130
    case switchToDesktop14 = 131
    case switchToDesktop15 = 132
    case switchToDesktop16 = 133
    case spotlight = 64
    case siri = 176
    case notificationCenter = 163
    case toggleDoNotDisturb = 175

    public var displayName: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .lookUp: return "Look Up"
        case .appSwitcher: return "App Switcher"
        case .moveLeftASpace: return "Move Left a Space"
        case .moveRightASpace: return "Move Right a Space"
        case .cycleThroughWindows: return "Cycle Through Windows"
        case .spotlight: return "Spotlight"
        case .siri: return "Siri"
        case .notificationCenter: return "Notification Center"
        case .toggleDoNotDisturb: return "Toggle Do Not Disturb"
        default:
            let n = rawValue - SymbolicHotkey.switchToDesktop1.rawValue + 1
            return "Switch to Desktop \(n)"
        }
    }
}

/// `NSEvent` system-defined event types (media keys). Values from Mac Mouse Fix `MFSystemDefinedEventType`.
public enum SystemDefinedEventType: Int, Codable, CaseIterable, Sendable, Hashable {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case volumeMute = 7
    case mediaPlayPause = 16
    case mediaForward = 19
    case mediaBack = 20
    case keyboardBacklightUp = 21
    case keyboardBacklightDown = 22

    public var displayName: String {
        switch self {
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        case .volumeMute: return "Mute"
        case .mediaPlayPause: return "Play / Pause"
        case .mediaForward: return "Next Track"
        case .mediaBack: return "Previous Track"
        case .keyboardBacklightUp: return "Keyboard Backlight Up"
        case .keyboardBacklightDown: return "Keyboard Backlight Down"
        }
    }
}

/// A one-shot effect executed when a button is clicked, double-clicked or held.
public enum Action: Codable, Equatable, Hashable, Sendable {
    case symbolicHotkey(SymbolicHotkey)
    /// "Universal Back" — navigation swipe, ⌘[ or mouse button 4 depending on the app under the pointer.
    case navigateBack
    /// "Universal Forward".
    case navigateForward
    case smartZoom
    case middleClick
    case mouseButtonClicks(button: Int, count: Int)
    case keyboardShortcut(keyCode: Int, modifierFlags: UInt64)
    case systemDefinedEvent(type: SystemDefinedEventType, modifierFlags: UInt64)

    public var displayName: String {
        switch self {
        case .symbolicHotkey(let s): return s.displayName
        case .navigateBack: return "Back"
        case .navigateForward: return "Forward"
        case .smartZoom: return "Smart Zoom"
        case .middleClick: return "Middle Click"
        case .mouseButtonClicks(let b, let n): return n == 1 ? "Mouse Button \(b)" : "Mouse Button \(b) ×\(n)"
        case .keyboardShortcut(let k, _): return "Keyboard Shortcut (\(k))"
        case .systemDefinedEvent(let t, _): return t.displayName
        }
    }

    /// The actions offered in the settings UI (in display order).
    public static let uiChoices: [Action] = [
        .symbolicHotkey(.missionControl),
        .symbolicHotkey(.appExpose),
        .symbolicHotkey(.showDesktop),
        .symbolicHotkey(.launchpad),
        .symbolicHotkey(.moveLeftASpace),
        .symbolicHotkey(.moveRightASpace),
        .navigateBack,
        .navigateForward,
        .smartZoom,
        .symbolicHotkey(.lookUp),
        .middleClick,
        .symbolicHotkey(.appSwitcher),
        .symbolicHotkey(.spotlight),
        .symbolicHotkey(.notificationCenter),
        .symbolicHotkey(.toggleDoNotDisturb),
        .symbolicHotkey(.siri),
        .systemDefinedEvent(type: .mediaPlayPause, modifierFlags: 0),
        .systemDefinedEvent(type: .mediaForward, modifierFlags: 0),
        .systemDefinedEvent(type: .mediaBack, modifierFlags: 0),
        .systemDefinedEvent(type: .volumeUp, modifierFlags: 0),
        .systemDefinedEvent(type: .volumeDown, modifierFlags: 0),
        .systemDefinedEvent(type: .volumeMute, modifierFlags: 0),
    ]
}
