// ScrollConfig.swift
// Leios Engine — resolved scroll parameters, animation-curve tables and acceleration-curve factory.
// Ports Helper/Core/Config/ScrollConfig.swift (tables copied verbatim; see ScrollConfigTesting.md in Mac Mouse Fix for the rationale).
// Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics
import LeiosShared

enum ScrollAnimationCurveName: Hashable {
    /// User selectable
    case none
    case lowInertia
    case highInertia
    case highInertiaPlusTrackpadSim
    /// Modifier overrides
    case touchDriver
    case touchDriverLinear
    case quickScroll
    case preciseScroll
}

/// Storage for animation-curve parameters (`MFScrollAnimationCurveParameters`).
struct AnimationCurveParameters {
    let baseCurve: Bezier
    /// How much of the base duration a tick that arrives while the content is still moving spends
    /// easing from that speed into its own, instead of jumping to it; 0 for none. See
    /// `ScrollController.speedMatchingCurve`. Leios's own: Mac Mouse Fix's field of this name
    /// synthesized a different curve, and every shipped entry set it to zero.
    let speedSmoothing: Double
    /// Duration of the base curve in ms, or -1 to use `baseMsPerStepCurve`.
    let baseMsPerStep: Int
    let baseMsPerStepCurve: Curve?
    let useDragCurve: Bool
    let dragExponent: Double
    let dragCoefficient: Double
    let stopSpeed: Double
    /// If false, send MMF-2-style continuous scroll events instead of gesture events.
    let sendGestureScrolls: Bool
    /// Send momentum-scroll events while the drag curve drives the animation (trackpad simulation).
    let sendMomentumScrolls: Bool

    /// Hybrid (base + drag) curve.
    init(baseCurve: Bezier, speedSmoothing: Double = 0, baseMsPerStep: Int, baseMsPerStepCurve: Curve?, dragExponent: Double, dragCoefficient: Double, stopSpeed: Double, sendGestureScrolls: Bool, sendMomentumScrolls: Bool) {
        if sendMomentumScrolls { assert(sendGestureScrolls) }
        // The speed-matching curve's control points sit at the ramp and twice it.
        assert(0 <= speedSmoothing && speedSmoothing <= 0.5)
        assert((baseMsPerStep == -1) != (baseMsPerStepCurve == nil))
        self.baseCurve = baseCurve
        self.speedSmoothing = speedSmoothing
        self.baseMsPerStep = baseMsPerStep
        self.baseMsPerStepCurve = baseMsPerStepCurve
        self.useDragCurve = true
        self.dragExponent = dragExponent
        self.dragCoefficient = dragCoefficient
        self.stopSpeed = stopSpeed
        self.sendGestureScrolls = sendGestureScrolls
        self.sendMomentumScrolls = sendMomentumScrolls
    }

    /// Base curve only.
    init(justBaseCurve baseCurve: Bezier, baseMsPerStep: Int, baseMsPerStepCurve: Curve?, sendGestureScrolls: Bool) {
        assert((baseMsPerStep == -1) != (baseMsPerStepCurve == nil))
        self.baseCurve = baseCurve
        self.speedSmoothing = 0
        self.baseMsPerStep = baseMsPerStep
        self.baseMsPerStepCurve = baseMsPerStepCurve
        self.useDragCurve = false
        self.dragExponent = -1
        self.dragCoefficient = -1
        self.stopSpeed = -1
        self.sendGestureScrolls = sendGestureScrolls
        self.sendMomentumScrolls = false
    }
}

/// A fully resolved scroll configuration for one (modifiers, axis, display) combination.
final class ScrollConfig {

    static let linearCurve = Bezier(points: [(0, 0), (0, 0), (1, 1), (1, 1)], defaultEpsilon: 0.001)

    // User settings
    let smoothness: ScrollSettings.Smoothness
    let speed: ScrollSettings.Speed
    /// Where between Low (0) and High (1) the acceleration curve sits. Unused at `.system` unless
    /// a modifier brings in a curve of its own.
    let speedLevel: Double
    let precise: Bool
    /// +1 or -1; multiply the input delta sign by this.
    let invertDirection: Int
    let invertedFromDevice = true
    let modifierFlags: ScrollModifierFlags

    // Analysis
    let scrollSwipeThreshold_inTicks = 2
    var consecutiveScrollTickIntervalMax: TimeInterval = 160.0 / 1000
    let consecutiveScrollTickIntervalMin: TimeInterval = 1.0 / 1000
    var consecutiveScrollSwipeMaxInterval: TimeInterval
    var consecutiveScrollSwipeMinTickSpeed: Double
    let consecutiveScrollTickInterval_AccelerationEnd: TimeInterval = 15.0 / 1000

    // Fast scroll
    var fastScrollCurve: ScrollSpeedupCurve?

    // Animation
    private(set) var animationCurve: ScrollAnimationCurveName
    private(set) var animationCurveParams: AnimationCurveParameters?
    var smoothEnabled: Bool { animationCurve != .none }

    // Acceleration
    var accelerationCurve: Curve?
    var useAppleAcceleration: Bool { accelerationCurve == nil }

    /// True when this config would reproduce the incoming wheel event as it arrived, so the event
    /// can be passed through instead of being swallowed and re-synthesized from its components.
    var isNoOp: Bool { !smoothEnabled && useAppleAcceleration && invertDirection == 1 }

    init(settings: ScrollSettings) {
        smoothness = settings.smoothness
        speed = settings.speed
        speedLevel = settings.scrollSpeed.level
        precise = settings.precise
        invertDirection = settings.reverseDirection ? -1 : 1
        modifierFlags = settings.modifiers

        let curve: ScrollAnimationCurveName
        switch settings.smoothness {
        case .off: curve = .none
        case .regular: curve = .lowInertia
        case .high: curve = settings.trackpadSimulation ? .highInertiaPlusTrackpadSim : .highInertia
        }
        animationCurve = curve
        animationCurveParams = ScrollConfig.animationCurveParamsMap(curve)
        consecutiveScrollSwipeMaxInterval = ScrollConfig.swipeMaxInterval(for: curve)
        consecutiveScrollSwipeMinTickSpeed = ScrollConfig.swipeMinTickSpeed(for: curve)
        fastScrollCurve = ScrollConfig.fastScrollCurve(for: curve)
    }

    /// Shallow copy (the resolver mutates copies).
    init(copying other: ScrollConfig) {
        smoothness = other.smoothness
        speed = other.speed
        speedLevel = other.speedLevel
        precise = other.precise
        invertDirection = other.invertDirection
        modifierFlags = other.modifierFlags
        consecutiveScrollTickIntervalMax = other.consecutiveScrollTickIntervalMax
        consecutiveScrollSwipeMaxInterval = other.consecutiveScrollSwipeMaxInterval
        consecutiveScrollSwipeMinTickSpeed = other.consecutiveScrollSwipeMinTickSpeed
        fastScrollCurve = other.fastScrollCurve
        animationCurve = other.animationCurve
        animationCurveParams = other.animationCurveParams
        accelerationCurve = other.accelerationCurve
    }

    func setAnimationCurve(_ name: ScrollAnimationCurveName) {
        animationCurve = name
        animationCurveParams = ScrollConfig.animationCurveParamsMap(name)
    }

    // MARK: Tables

    private static func swipeMaxInterval(for curve: ScrollAnimationCurveName) -> TimeInterval {
        switch curve {
        case .none: return 325.0 / 1000
        case .lowInertia: return 375.0 / 1000
        case .highInertia, .highInertiaPlusTrackpadSim: return 600.0 / 1000
        case .touchDriver, .touchDriverLinear: return 375.0 / 1000
        case .preciseScroll, .quickScroll: return 0.1234 // overridden
        }
    }

    private static func swipeMinTickSpeed(for curve: ScrollAnimationCurveName) -> Double {
        switch curve {
        case .none: return 16
        case .lowInertia: return 16
        case .highInertia, .highInertiaPlusTrackpadSim: return 12
        case .touchDriver, .touchDriverLinear: return 16
        case .preciseScroll, .quickScroll: return 0.1234 // overridden
        }
    }

    private static func fastScrollCurve(for curve: ScrollAnimationCurveName) -> ScrollSpeedupCurve? {
        switch curve {
        case .none: return ScrollSpeedupCurve(swipeThreshold: 6, initialSpeedup: 1.4, exponentialSpeedup: 3.0)
        case .lowInertia: return ScrollSpeedupCurve(swipeThreshold: 3, initialSpeedup: 1.33, exponentialSpeedup: 7.5)
        case .highInertia, .highInertiaPlusTrackpadSim: return ScrollSpeedupCurve(swipeThreshold: 2, initialSpeedup: 1.33, exponentialSpeedup: 7.5)
        case .touchDriver, .touchDriverLinear: return ScrollSpeedupCurve(swipeThreshold: 3, initialSpeedup: 1.33, exponentialSpeedup: 7.5)
        case .preciseScroll, .quickScroll: return nil
        }
    }

    static func animationCurveParamsMap(_ name: ScrollAnimationCurveName) -> AnimationCurveParameters? {
        switch name {
        case .none:
            return nil
        case .lowInertia:
            // "Smoothness: Regular". Shifted/scaled exponential for the base duration: https://www.desmos.com/calculator/l8plcdlpmn
            let curvature = 4.0
            let baseMsPerStepCurveMax = 180.0
            let baseMsPerStepCurveMin = 110.0
            let e1: RawCurve = { x in exp(x * curvature) - 1 }
            let e2: RawCurve = { x in e1(x) / e1(1) }
            let e3 = CurveTools.transformCurve(e2) { y in Math.scale(y, (0, 1), (baseMsPerStepCurveMax, baseMsPerStepCurveMin)) }
            return AnimationCurveParameters(baseCurve: linearCurve, baseMsPerStep: -1, baseMsPerStepCurve: Curve(rawCurve: e3), dragExponent: 1.0, dragCoefficient: 23, stopSpeed: 30, sendGestureScrolls: false, sendMomentumScrolls: false)
        case .highInertia:
            // The snappiest drag curve that can still be used to send momentum scrolls.
            //
            // Speed smoothing is Leios's, and part of what "High" means: a wheel turned at reading
            // pace otherwise surges to each tick's speed and coasts down until the next, 94 →
            // 429 pt/s in one frame at four ticks a second. 0.2 was picked by measuring the real
            // animator at 3–8 ticks a second: the largest frame-to-frame rise in speed falls to
            // about a quarter, a tick peaks ~80 ms later and ~15% faster, and the glide after the
            // last tick runs under 10 ms longer; by 0.4 the late peak starts to feel like lag.
            // Regular's glide has ended before the next slow tick arrives, so it would gain nothing.
            return AnimationCurveParameters(baseCurve: linearCurve, speedSmoothing: 0.2, baseMsPerStep: 220, baseMsPerStepCurve: nil, dragExponent: 0.7, dragCoefficient: 40, stopSpeed: 30, sendGestureScrolls: false, sendMomentumScrolls: false)
        case .highInertiaPlusTrackpadSim:
            return AnimationCurveParameters(baseCurve: linearCurve, speedSmoothing: 0.2, baseMsPerStep: 220, baseMsPerStepCurve: nil, dragExponent: 0.7, dragCoefficient: 40, stopSpeed: 30, sendGestureScrolls: true, sendMomentumScrolls: true)
        case .touchDriver:
            let baseCurve = Bezier(points: [(0, 0), (0, 0), (0.5, 1), (1, 1)], defaultEpsilon: 0.001)
            return AnimationCurveParameters(justBaseCurve: baseCurve, baseMsPerStep: 250, baseMsPerStepCurve: nil, sendGestureScrolls: false)
        case .touchDriverLinear:
            return AnimationCurveParameters(justBaseCurve: linearCurve, baseMsPerStep: 180, baseMsPerStepCurve: nil, sendGestureScrolls: false)
        case .quickScroll:
            return AnimationCurveParameters(baseCurve: linearCurve, baseMsPerStep: 300, baseMsPerStepCurve: nil, dragExponent: 0.7, dragCoefficient: 30, stopSpeed: 1, sendGestureScrolls: true, sendMomentumScrolls: true)
        case .preciseScroll:
            return AnimationCurveParameters(baseCurve: linearCurve, baseMsPerStep: 140, baseMsPerStepCurve: nil, dragExponent: 1.05, dragCoefficient: 15, stopSpeed: 50, sendGestureScrolls: false, sendMomentumScrolls: false)
        }
    }

    // MARK: Acceleration curve

    /// How far "Precise" pulls the top of the sensitivity range down, on top of dropping its floor
    /// to 10. Tuned by feel, like the tables above.
    static let preciseMaxSensitivityFactor = 0.5

    /// Sensitivity (px per tick) as a function of tick speed (ticks per second).
    static func accelerationCurve(speedLevel speed_n: Double, precise: Bool, smoothness: ScrollSettings.Smoothness, animationCurve: ScrollAnimationCurveName, inputAxis: MFAxis, display: CGDirectDisplayID, scaleToDisplay: Bool, modifiers: ScrollModificationResult, useQuickModSpeed: Bool, usePreciseModSpeed: Bool, consecutiveScrollTickIntervalMax: Double, consecutiveScrollTickInterval_AccelerationEnd: Double) -> Curve {

        var screenSize = -1
        if useQuickModSpeed || scaleToDisplay {
            if inputAxis == .horizontal || modifiers.effectMod == .horizontalScroll {
                screenSize = CGDisplayPixelsWide(display)
            } else {
                screenSize = CGDisplayPixelsHigh(display)
            }
            if screenSize <= 0 { screenSize = inputAxis == .horizontal ? 1920 : 1080 }
        }

        // Mac Mouse Fix maps its three presets to 0, 0.5 and 1 here and interpolates the tuned
        // values below between them. Leios's Speed slider hands over any point on that range, so
        // Low, Medium and High land exactly where they always did and everything between them is
        // an interpolation of the same tuning. Clamped because the curves below only span 0…1.
        let speed_n = min(max(speed_n, 0), 1)

        var minSens: Double
        var maxSens: Double
        var curvature: Double

        if useQuickModSpeed {
            let windowSize = Double(screenSize) * 0.85
            minSens = windowSize * 0.5
            maxSens = windowSize * 1.5
            curvature = 0.0
        } else if usePreciseModSpeed {
            minSens = 1
            maxSens = 20
            curvature = 2.0
        } else if animationCurve == .touchDriver || animationCurve == .touchDriverLinear {
            minSens = CombinedLinearCurve(yValues: [45.0, 60.0, 90.0]).evaluate(atX: speed_n)
            maxSens = CombinedLinearCurve(yValues: [90.0, 120.0, 180.0]).evaluate(atX: speed_n)
            curvature = !precise
                ? CombinedLinearCurve(yValues: [0.25, 0.0, 0.0]).evaluate(atX: speed_n)
                : CombinedLinearCurve(yValues: [0.75, 0.75, 0.25]).evaluate(atX: speed_n)
        } else if smoothness == .off {
            minSens = CombinedLinearCurve(yValues: [20.0, 30.0, 40.0]).evaluate(atX: speed_n)
            maxSens = CombinedLinearCurve(yValues: [40.0, 60.0, 80.0]).evaluate(atX: speed_n)
            curvature = CombinedLinearCurve(yValues: [4.25, 3.0, 2.25]).evaluate(atX: speed_n)
        } else if smoothness == .regular {
            minSens = CombinedLinearCurve(yValues: [30.0, 60.0, 120.0]).evaluate(atX: speed_n)
            maxSens = CombinedLinearCurve(yValues: [90.0, 120.0, 180.0]).evaluate(atX: speed_n)
            curvature = !precise
                ? CombinedLinearCurve(yValues: [0.25, 0.0, 0.0]).evaluate(atX: speed_n)
                : CombinedLinearCurve(yValues: [0.75, 0.75, 0.25]).evaluate(atX: speed_n)
        } else { // .high
            minSens = CombinedLinearCurve(yValues: [60.0, 90.0, 150.0]).evaluate(atX: speed_n)
            maxSens = CombinedLinearCurve(yValues: [120.0, 180.0, 240.0]).evaluate(atX: speed_n)
            curvature = !precise
                ? 0.0
                : CombinedLinearCurve(yValues: [1.5, 1.25, 0.75]).evaluate(atX: speed_n)
        }

        // Deviation from MMF, which only drops the floor here. The acceleration curve leaves that
        // floor behind within a tick or two, and a real wheel ticks fast enough to sit at `maxSens`
        // for the rest of the scroll — so every tick but the very first came out identical whether
        // the setting was on or off, which reads as the toggle doing nothing. Pull the ceiling down
        // with the floor so it stays in effect for the whole scroll. Half keeps it clearly milder
        // than the precise *modifier*, which caps at 20 and stays the fine-grained option.
        if precise {
            minSens = 10
            maxSens *= preciseMaxSensitivityFactor
        }

        if scaleToDisplay {
            let baseScreenSize = inputAxis == .horizontal ? 1920.0 : 1080.0
            let screenSizeFactor = Double(screenSize) / baseScreenSize
            let screenSizeWeight = 0.1
            maxSens = (maxSens * (1 - screenSizeWeight)) + ((maxSens * screenSizeWeight) * screenSizeFactor)
        }

        let xMin = 1 / consecutiveScrollTickIntervalMax
        let xMax = 1 / consecutiveScrollTickInterval_AccelerationEnd
        return BezierCappedAccelerationCurve(xMin: xMin, xMax: xMax, yMin: minSens, yMax: maxSens, curvature: curvature, reduceToCubic: false, defaultEpsilon: 0.05)
    }
}

/// Builds and caches `ScrollConfig`s for (modifiers, axis, display) combinations from the user's settings.
final class ScrollConfigResolver {

    private struct Key: Hashable {
        let mods: ScrollModificationResult
        let axis: MFAxis
        let display: CGDirectDisplayID
    }

    private(set) var settings: ScrollSettings
    private(set) var base: ScrollConfig
    private var cache: [Key: ScrollConfig] = [:]

    init(settings: ScrollSettings) {
        self.settings = settings
        base = ScrollConfig(settings: settings)
    }

    func update(settings: ScrollSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        base = ScrollConfig(settings: settings)
        cache.removeAll()
    }

    /// Ports `ScrollConfig.scrollConfig(modifiers:inputAxis:display:)`.
    func resolve(modifiers: ScrollModificationResult, inputAxis: MFAxis, display: CGDirectDisplayID) -> ScrollConfig {
        let key = Key(mods: modifiers, axis: inputAxis, display: display)
        if let cached = cache[key] { return cached }

        let new = ScrollConfig(copying: base)
        let u_speed = new.speed
        let u_speedLevel = new.speedLevel
        var precise = new.precise
        let useQuickMod = modifiers.inputMod == .quick
        let usePreciseMod = modifiers.inputMod == .precise
        var scaleToDisplay = true
        var animationCurveOverride: ScrollAnimationCurveName?

        // 1. Effect modifications
        switch modifiers.effectMod {
        case .horizontalScroll, .none:
            break
        case .zoom:
            animationCurveOverride = .touchDriver
            scaleToDisplay = false
        }

        // 2. Input modifications
        if useQuickMod {
            if animationCurveOverride == nil {
                animationCurveOverride = .quickScroll
            }
            precise = false
            scaleToDisplay = false
            new.consecutiveScrollSwipeMaxInterval = 725.0 / 1000.0
            new.consecutiveScrollTickIntervalMax = 200.0 / 1000.0
            new.consecutiveScrollSwipeMinTickSpeed = 12.0
            new.fastScrollCurve = ScrollSpeedupCurve(swipeThreshold: 1, initialSpeedup: 2.0, exponentialSpeedup: 10)
        } else if usePreciseMod {
            // Only override if that does not turn smoothing on.
            if (animationCurveOverride == nil && new.animationCurve != .none)
                || (animationCurveOverride != nil && animationCurveOverride != ScrollAnimationCurveName.none) {
                animationCurveOverride = .preciseScroll
            }
            precise = false
            scaleToDisplay = false
            new.fastScrollCurve = nil
        }

        if let ovr = animationCurveOverride {
            new.setAnimationCurve(ovr)
        }

        if u_speed == .system && !usePreciseMod && !useQuickMod {
            new.accelerationCurve = nil
        } else {
            new.accelerationCurve = ScrollConfig.accelerationCurve(speedLevel: u_speedLevel, precise: precise, smoothness: new.smoothness, animationCurve: new.animationCurve, inputAxis: inputAxis, display: display, scaleToDisplay: scaleToDisplay, modifiers: modifiers, useQuickModSpeed: useQuickMod, usePreciseModSpeed: usePreciseMod, consecutiveScrollTickIntervalMax: new.consecutiveScrollTickIntervalMax, consecutiveScrollTickInterval_AccelerationEnd: new.consecutiveScrollTickInterval_AccelerationEnd)
        }

        cache[key] = new
        return new
    }
}
