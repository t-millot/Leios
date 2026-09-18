// HIDDescriptors.swift
// MousePilot — the HID vocabulary the Info tab reads devices with: usages, elements, device kinds.

import Foundation
import MousePilotShared

/// A HID usage page / usage pair, as it appears in `DeviceUsagePairs` and on every element.
struct HIDUsagePair: Equatable, Hashable {
    let page: Int
    let usage: Int
}

/// The usage numbers this app reasons about. HID assigns thousands; these are the ones that say
/// something about a pointing device.
enum HIDUsage {
    static let genericDesktopPage = 0x01
    static let simulationPage = 0x02
    static let keyboardPage = 0x07
    static let buttonPage = 0x09
    static let consumerPage = 0x0C
    static let digitizerPage = 0x0D
    /// Everything at or above this page is vendor-defined and has no published meaning.
    static let vendorDefinedPageStart = 0xFF00

    static let pointer = 0x01
    static let mouse = 0x02
    static let joystick = 0x04
    static let gamePad = 0x05
    static let keyboard = 0x06
    static let keypad = 0x07
    static let wheel = 0x38
    /// Set when the wheel can report finer steps than one detent — high-resolution scrolling.
    static let resolutionMultiplier = 0x48

    /// Consumer "AC Pan": what a tilting wheel or a thumb wheel reports for horizontal scrolling.
    static let acPan = 0x0238

    static let digitizer = 0x01
    static let pen = 0x02
    static let touchScreen = 0x04
    static let touchPad = 0x05

    /// The pairs the Info tab matches on. A device matches if any of its usage pairs is one of these.
    static let pointingDevicePairs = [HIDUsagePair(page: genericDesktopPage, usage: mouse),
                                      HIDUsagePair(page: genericDesktopPage, usage: pointer)]
}

// nonisolated: the Info tab builds its rows off the main actor's isolation, and this is pure.
nonisolated enum HIDUsageNaming {

    /// A readable name for a usage pair, written as "Mouse (1:2)" so the name never hides the
    /// numbers it was derived from — those are what shows up in `ioreg` and in bug reports.
    static func name(_ pair: HIDUsagePair) -> String {
        "\(usageName(pair)) (\(pair.page):\(pair.usage))"
    }

    static func pageName(_ page: Int) -> String {
        switch page {
        case HIDUsage.genericDesktopPage: return "Generic Desktop"
        case HIDUsage.simulationPage: return "Simulation"
        case HIDUsage.keyboardPage: return "Keyboard"
        case HIDUsage.buttonPage: return "Button"
        case HIDUsage.consumerPage: return "Consumer"
        case HIDUsage.digitizerPage: return "Digitizer"
        case HIDUsage.vendorDefinedPageStart...: return "Vendor-defined"
        default: return "Page \(page)"
        }
    }

    private static func usageName(_ pair: HIDUsagePair) -> String {
        switch pair.page {
        case HIDUsage.genericDesktopPage: return genericDesktopUsageName(pair.usage)
        case HIDUsage.digitizerPage: return digitizerUsageName(pair.usage)
        case HIDUsage.buttonPage: return MouseButtonNaming.name(pair.usage)
        default: return "\(pageName(pair.page)) usage \(pair.usage)"
        }
    }

    private static func genericDesktopUsageName(_ usage: Int) -> String {
        switch usage {
        case HIDUsage.pointer: return "Pointer"
        case HIDUsage.mouse: return "Mouse"
        case HIDUsage.joystick: return "Joystick"
        case HIDUsage.gamePad: return "Game Pad"
        case HIDUsage.keyboard: return "Keyboard"
        case HIDUsage.keypad: return "Keypad"
        case HIDUsage.wheel: return "Wheel"
        case HIDUsage.resolutionMultiplier: return "Resolution Multiplier"
        default: return "Generic Desktop usage \(usage)"
        }
    }

    private static func digitizerUsageName(_ usage: Int) -> String {
        switch usage {
        case HIDUsage.digitizer: return "Digitizer"
        case HIDUsage.pen: return "Pen"
        case HIDUsage.touchScreen: return "Touch Screen"
        case HIDUsage.touchPad: return "Touch Pad"
        default: return "Digitizer usage \(usage)"
        }
    }
}

/// What one pass over a device's HID elements says about its physical controls. Derived rather
/// than stored so a test can build it from a literal array of usage pairs.
struct HIDElementSummary: Equatable {
    let buttonUsages: Set<Int>
    let hasWheel: Bool
    let hasHorizontalScroll: Bool
    let hasResolutionMultiplier: Bool

    var buttonCount: Int { buttonUsages.count }
    var highestButton: Int { buttonUsages.max() ?? 0 }

    init(elements: [HIDUsagePair]) {
        // A descriptor can repeat a usage across collections, so count distinct usages, not elements.
        buttonUsages = Set(elements.filter { $0.page == HIDUsage.buttonPage }.map(\.usage))
        hasWheel = elements.contains(HIDUsagePair(page: HIDUsage.genericDesktopPage, usage: HIDUsage.wheel))
        hasHorizontalScroll = elements.contains(HIDUsagePair(page: HIDUsage.consumerPage, usage: HIDUsage.acPan))
        hasResolutionMultiplier = elements.contains(HIDUsagePair(page: HIDUsage.genericDesktopPage,
                                                                 usage: HIDUsage.resolutionMultiplier))
    }
}

/// What kind of pointing device this is. Usage alone can't tell them apart — a trackpad reports
/// Mouse (1:2) like any mouse does — so the digitizer pairs and the driver's own hints decide.
enum PointerDeviceKind: Equatable {
    case mouse
    case trackball
    case trackpad
    case tablet
    case pointer

    static func classify(usagePairs: [HIDUsagePair], product: String?, supportsGestureScrolling: Bool?) -> PointerDeviceKind {
        let name = (product ?? "").lowercased()
        if usagePairs.contains(where: { $0.page == HIDUsage.digitizerPage && $0.usage == HIDUsage.touchPad }) {
            return .trackpad
        }
        let tabletUsages = [HIDUsage.digitizer, HIDUsage.pen, HIDUsage.touchScreen]
        if usagePairs.contains(where: { $0.page == HIDUsage.digitizerPage && tabletUsages.contains($0.usage) }) {
            return .tablet
        }
        if supportsGestureScrolling == true || name.contains("trackpad") || name.contains("touchpad") {
            return .trackpad
        }
        if name.contains("trackball") { return .trackball }
        if usagePairs.contains(HIDUsagePair(page: HIDUsage.genericDesktopPage, usage: HIDUsage.mouse)) {
            return .mouse
        }
        return .pointer
    }

    var displayName: String {
        switch self {
        case .mouse: return "Mouse"
        case .trackball: return "Trackball"
        case .trackpad: return "Trackpad"
        case .tablet: return "Tablet"
        case .pointer: return "Pointing Device"
        }
    }

    var symbolName: String {
        switch self {
        case .mouse, .trackball: return "computermouse.fill"
        case .trackpad: return "rectangle.and.hand.point.up.left.fill"
        case .tablet: return "applepencil.and.scribble"
        case .pointer: return "cursorarrow"
        }
    }

    /// Mice first: they are the devices MousePilot exists for.
    var sortRank: Int {
        switch self {
        case .mouse: return 0
        case .trackball: return 1
        case .pointer: return 2
        case .trackpad: return 3
        case .tablet: return 4
        }
    }
}

/// How a device reaches the Mac.
enum DeviceTransport: Equatable {
    case usb
    case bluetooth
    case bluetoothLowEnergy
    /// A bus that only exists inside the Mac — SPI, SPU, I2C.
    case internalBus(String)
    case other(String)
    case unknown

    static func parse(_ raw: String?) -> DeviceTransport {
        guard let raw, !raw.isEmpty else { return .unknown }
        switch raw.uppercased() {
        case "USB": return .usb
        case "BLUETOOTH": return .bluetooth
        case "BTLE", "BLUETOOTH LOW ENERGY": return .bluetoothLowEnergy
        case "SPI", "SPU", "I2C": return .internalBus(raw)
        default: return .other(raw)
        }
    }

    var displayName: String {
        switch self {
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .bluetoothLowEnergy: return "Bluetooth Low Energy"
        case .internalBus(let raw): return "Internal (\(raw))"
        case .other(let raw): return raw
        case .unknown: return "Unknown"
        }
    }
}

/// Which of MousePilot's features can reach a device. Derived from the device's own controls, not
/// from any per-device setting: the engine's taps are system-wide and it has no device filter.
/// Scrolling is the subtle one — `ScrollController.handleEvent` passes continuous scrolls, tablet
/// events and diagonal scrolls straight through, so a trackpad's scrolling is never reshaped.
enum EngineHandling: Equatable {
    case buttonsAndScroll(highestButton: Int)
    case buttonsOnly(highestButton: Int)
    case scrollOnly
    case notAffected

    static func forDevice(kind: PointerDeviceKind, elements: HIDElementSummary) -> EngineHandling {
        let buttons = elements.highestButton >= MPConstants.minButton
        // Only a wheel produces the line scrolls the engine acts on.
        let scroll = elements.hasWheel && kind != .trackpad && kind != .tablet
        switch (buttons, scroll) {
        case (true, true): return .buttonsAndScroll(highestButton: elements.highestButton)
        case (true, false): return .buttonsOnly(highestButton: elements.highestButton)
        case (false, true): return .scrollOnly
        case (false, false): return .notAffected
        }
    }

    var summary: String {
        switch self {
        case .buttonsAndScroll(let highest):
            return "\(Self.buttonPhrase(upTo: highest)) and scrolling"
        case .buttonsOnly(let highest):
            return "\(Self.buttonPhrase(upTo: highest)) — no scroll wheel to change"
        case .scrollOnly:
            return "Scrolling only — no buttons past the right button"
        case .notAffected:
            return "Nothing — MousePilot leaves this device alone"
        }
    }

    /// A range once there is one to state, and the button's own name when there is only the one.
    private static func buttonPhrase(upTo highest: Int) -> String {
        highest <= MPConstants.minButton
            ? MouseButtonNaming.name(MPConstants.minButton)
            : "Buttons \(MPConstants.minButton)–\(highest)"
    }

    var isAffected: Bool { self != .notAffected }
}
