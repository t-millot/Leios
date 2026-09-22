// ScrollController.swift
// Leios Engine — scroll wheel interception, analysis, acceleration, animation and event output.
// Ports the live paths of Helper/Core/Scroll/Scroll.m and ScrollUtility.m. Derived from Mac Mouse Fix, MMF License.

import Foundation
import CoreGraphics
import QuartzCore
import LeiosShared

final class ScrollController {

    private enum OutputType {
        case gestureScroll, continuousScroll, lineScroll, zoom
    }

    private unowned let thread: EngineThread
    private let modifiers: Modifiers
    private let appUnderPointer: AppUnderPointerCache
    let baseResolver: ScrollConfigResolver
    /// One resolver per profiled app, so each keeps its own warm `resolve` cache.
    private var appResolvers: [String: ScrollConfigResolver] = [:]
    private var appSettings: [String: ScrollSettings] = [:]
    private let animator: TouchAnimator
    private let gestureSim: GestureScrollSimulator
    private let touchSim: TouchSimulator
    private let analyzer = ScrollAnalyzer()

    private var tap: EventTap?

    // Dynamic state
    private var currentModifications = ScrollModificationResult()
    private var scrollConfig: ScrollConfig
    /// Bundle ID of the profiled app the current scroll sequence belongs to, `nil` for the global
    /// settings. Keyed by name rather than by resolver identity so it survives a settings reload.
    private var activeProfile: String?
    private var lastTickTime: CFTimeInterval = -.infinity
    private var lastMomentumHint: MomentumHint = .none
    private let linePixelator = VectorSubPixelator.biased()
    /// Set once by `EngineSubsystems`. Optional so the controller can be built without it in tests.
    weak var stats: StatsRecorder?

    init(thread: EngineThread, modifiers: Modifiers, appUnderPointer: AppUnderPointerCache, settings: ScrollSettings, apps: [String: ScrollSettings], clockPool: FrameClockPool, gestureSim: GestureScrollSimulator, touchSim: TouchSimulator) {
        self.thread = thread
        self.modifiers = modifiers
        self.appUnderPointer = appUnderPointer
        self.baseResolver = ScrollConfigResolver(settings: settings)
        self.scrollConfig = baseResolver.base
        self.appSettings = apps
        self.appResolvers = apps.mapValues { ScrollConfigResolver(settings: $0) }
        self.animator = TouchAnimator(clockPool: clockPool)
        self.gestureSim = gestureSim
        self.touchSim = touchSim
    }

    // MARK: Lifecycle

    func createTap() {
        guard tap == nil else { return }
        tap = EventTap(name: "scroll", mask: CGEventMask(1 << CGEventType.scrollWheel.rawValue), runLoop: thread.runLoop) { [unowned self] _, _, event in
            self.handleEvent(event)
        }
    }

    func setReceiving(_ on: Bool) {
        tap?.enable(on)
    }

    func invalidate() {
        reset()
        tap?.invalidate()
        tap = nil
    }

    /// `apps` is already resolved against the global settings, and profiles that came out equal to
    /// them have been dropped, so an empty dictionary means "nothing app-specific to look up".
    func settingsChanged(_ settings: ScrollSettings, apps: [String: ScrollSettings]) {
        // Guard on both, or every unrelated Buttons/General edit would reset an in-flight animation.
        guard settings != baseResolver.settings || apps != appSettings else { return }
        reset()
        baseResolver.update(settings: settings)
        var next: [String: ScrollConfigResolver] = [:]
        for (bundleID, appScroll) in apps {
            if let existing = appResolvers[bundleID] {
                existing.update(settings: appScroll) // no-op when unchanged, so its cache survives
                next[bundleID] = existing
            } else {
                next[bundleID] = ScrollConfigResolver(settings: appScroll)
            }
        }
        appResolvers = next
        appSettings = apps
        activeProfile = nil
        scrollConfig = baseResolver.base
    }

    /// Cancels the animation, stops momentum and resets analysis (called on modifier changes and by drags).
    func reset() {
        animator.cancel()
        gestureSim.stopMomentumScroll()
        analyzer.reset()
        lastMomentumHint = .none
        lastTickTime = -.infinity // the next tick starts a new sequence, so the app is looked up again
    }

    // MARK: Tap callback

    private func handleEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let deltaAxis1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let deltaAxis2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let tabletID = event.getIntegerValueField(.tabletEventDeviceID)
        let isDiagonal = deltaAxis1 != 0 && deltaAxis2 != 0

        // Every cheap rejection first, so the Wacom check below — the only one that can reach a
        // syscall — is asked about as few events as possible.
        if isContinuous != 0 || scrollPhase != 0 || tabletID != 0 || isDiagonal {
            return Unmanaged.passUnretained(event)
        }
        if deltaAxis1 == 0 && deltaAxis2 == 0 {
            return Unmanaged.passUnretained(event)
        }
        if appUnderPointer.isWacomEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        let tickTime = event.timestampSeconds
        guard process(event: event, deltaAxis1: deltaAxis1, deltaAxis2: deltaAxis2, tickTime: tickTime) else {
            return Unmanaged.passUnretained(event)
        }
        return nil // swallow the wheel event
    }

    // MARK: Processing

    /// Returns false when the event should be passed through untouched instead of swallowed.
    @discardableResult
    private func process(event: CGEvent, deltaAxis1: Int64, deltaAxis2: Int64, tickTime: CFTimeInterval) -> Bool {
        let inputAxis: MFAxis = deltaAxis2 != 0 ? .horizontal : .vertical
        var scrollDelta = inputAxis == .vertical ? deltaAxis1 : deltaAxis2

        // Preliminary analysis with the current config to detect the first consecutive tick. The
        // direction is recomputed below because the config may change in between — not redundant.
        var scrollDirection = ScrollController.direction(axis: inputAxis, delta: scrollDelta, invert: scrollConfig.invertDirection, horizontalModifier: currentModifications.effectMod == .horizontalScroll)
        let firstConsecutive = analyzer.peekIsFirstConsecutiveTick(at: tickTime, direction: scrollDirection, config: scrollConfig)

        if firstConsecutive {
            let resolver = resolveProfile(event: event, tickTime: tickTime)
            let flags = modifiers.current(event: event).keyboardFlags
            // The modifier map comes from the chosen profile, not from the outgoing `scrollConfig`:
            // an app with its own modifiers must apply them from its very first tick.
            let newMods = ScrollModifiers.modifications(forFlags: flags, settings: resolver.base.modifierFlags)
            if newMods != currentModifications {
                reset()
                currentModifications = newMods
            }
            if !newMods.isEmpty {
                modifiers.handleModificationHasBeenUsed()
            }
            let display = EventUtility.displayUnderPointer(event: event)
            scrollConfig = resolver.resolve(modifiers: newMods, inputAxis: inputAxis, display: display)
            // Every sequence, and whether or not a glide is still running. Mac Mouse Fix relinks
            // only when the pointer moved more than 10 pt since the last sequence *and* nothing is
            // animating, so scrolling onto a 120 Hz display while a 60 Hz glide was still running
            // stayed at 60 fps until the pointer happened to move and the wheel came to rest.
            animator.link(to: display)
        }
        lastTickTime = tickTime

        // Nothing here would change the event. Hand the original through rather than swallowing it
        // and re-synthesizing a lossy copy — the tap may be running only for some *other* app's
        // profile, and apps that are not profiled must behave exactly as they did before.
        if scrollConfig.isNoOp && currentModifications.isEmpty { return false }

        scrollDirection = ScrollController.direction(axis: inputAxis, delta: scrollDelta, invert: scrollConfig.invertDirection, horizontalModifier: currentModifications.effectMod == .horizontalScroll)
        let result = analyzer.update(tickAt: tickTime, direction: scrollDirection, config: scrollConfig)
        scrollDelta = abs(scrollDelta)

        // Acceleration
        var pxToScrollForThisTick: Int64
        if scrollConfig.useAppleAcceleration {
            pxToScrollForThisTick = scrollDelta
        } else {
            var timeBetweenTicks = result.timeBetweenTicks
            if timeBetweenTicks == .greatestFiniteMagnitude {
                timeBetweenTicks = scrollConfig.consecutiveScrollTickIntervalMax
            }
            timeBetweenTicks = max(timeBetweenTicks, scrollConfig.consecutiveScrollTickInterval_AccelerationEnd)
            let scrollSpeed = 1 / timeBetweenTicks
            guard let accelerationCurve = scrollConfig.accelerationCurve else { return true }
            pxToScrollForThisTick = Int64(accelerationCurve.evaluate(at: scrollSpeed))
            if pxToScrollForThisTick <= 0 {
                Log.scroll.error("Acceleration curve produced \(pxToScrollForThisTick) px for speed \(scrollSpeed)")
                return true
            }

            if let fastScrollCurve = scrollConfig.fastScrollCurve {
                var factor = fastScrollCurve.evaluate(at: result.consecutiveScrollSwipeCounter + 1)
                if factor > 100_000 { factor = 100_000 }
                pxToScrollForThisTick = Int64(Double(pxToScrollForThisTick) * factor)
            }

            // Direction change stops the running animation (the user gets control over stopping).
            //
            // This tick's analysis, not the previous one's. Mac Mouse Fix reads
            // `_lastScrollAnalysisResult` here, but assigns this tick's result to it a few lines
            // earlier, so the name means "latest". The flag is only ever set on the reversing tick
            // itself, so reading the previous tick's copy let the first reversed tick start a
            // reverse animation and the *second* one cancel it — a flick back stuttered, moved and
            // then stopped dead, instead of stopping first and then following the wheel.
            let currentAnimationSpeed = magnitude(animator.lastAnimationSpeed)
            if result.scrollDirectionDidChange, currentAnimationSpeed > 0 {
                animator.cancel()
                return true
            }
        }

        // Send
        if pxToScrollForThisTick == 0 {
            Log.scroll.warning("pxToScrollForThisTick is 0")
        } else if !scrollConfig.smoothEnabled {
            sendScroll(px: pxToScrollForThisTick, direction: scrollDirection, animated: false, phase: .none, momentumHint: .none, config: scrollConfig)
        } else {
            let config = scrollConfig
            let px = pxToScrollForThisTick
            let direction = scrollDirection
            animator.start(params: { [self] valueLeftVec, isRunning, _, currentSpeed in
                assert(valueLeftVec.x == 0 || valueLeftVec.y == 0)

                var pxLeftToScroll = 0.0
                if isRunning {
                    let isSwipeSequenceStart = result.consecutiveScrollTickCounter == 0 && result.consecutiveScrollSwipeCounter == 0
                    if isSwipeSequenceStart {
                        pxLeftToScroll = 0
                        animator.resetSubPixelator()
                    } else {
                        pxLeftToScroll = magnitude(valueLeftVec)
                    }
                } else {
                    pxLeftToScroll = 0
                    animator.resetSubPixelator()
                }

                let delta = Double(px) + pxLeftToScroll
                guard let animation = ScrollController.tickAnimation(distance: delta, currentSpeed: magnitude(currentSpeed), timeBetweenTicks: result.timeBetweenTicks, config: config) else { return .skip }
                return AnimatorStartParams(doStart: true, duration: animation.duration, vector: vectorFromDeltaAndDirection(delta, direction), curve: animation.curve)
            }, callback: { [self] deltaVec, animationPhase, momentumHint in
                assert(deltaVec.x == 0 || deltaVec.y == 0)
                let distanceDelta = magnitude(deltaVec)
                sendScroll(px: Int64(distanceDelta), direction: direction, animated: true, phase: animationPhase, momentumHint: momentumHint, config: config)
            })
        }
        return true
    }

    // MARK: Tick animation

    /// The curve one tick animates along, and for how long. `distance` already includes what the
    /// animation it replaces still had to go, and `currentSpeed` is how fast that one was moving,
    /// in points per second — zero from a standstill.
    static func tickAnimation(distance delta: Double, currentSpeed: Double, timeBetweenTicks: CFTimeInterval, config: ScrollConfig) -> (curve: Curve, duration: Double)? {
        guard let pCurve = config.animationCurveParams else { return nil }

        // Base duration
        var baseDuration: Double
        if pCurve.baseMsPerStep != -1 {
            baseDuration = Double(pCurve.baseMsPerStep) / 1000.0
        } else if let baseTimeCurve = pCurve.baseMsPerStepCurve {
            let baseTimeStart = baseTimeCurve.evaluate(at: 0.0)
            var tickStart = config.consecutiveScrollTickIntervalMax
            let tickEnd = config.consecutiveScrollTickIntervalMin
            var tick = timeBetweenTicks
            if tickStart > baseTimeStart { tickStart = baseTimeStart }
            if tick == .greatestFiniteMagnitude { tick = config.consecutiveScrollTickIntervalMax }
            if tick > config.consecutiveScrollTickIntervalMax { tick = config.consecutiveScrollTickIntervalMax }
            var unitTick = Math.scale(value: tick, from: Interval(start: tickStart, end: tickEnd), to: .unitInterval, allowOutOfBounds: true)
            unitTick = clip(unitTick, 0, 1)
            baseDuration = baseTimeCurve.evaluate(at: unitTick) / 1000.0
        } else {
            return nil
        }

        if !pCurve.useDragCurve {
            return (pCurve.baseCurve, baseDuration)
        }

        var baseCurve = pCurve.baseCurve
        if pCurve.speedSmoothing > 0, currentSpeed > 0 {
            // The curve's unit square spans the base duration and the distance, so this slope
            // starts it at `currentSpeed` points per second.
            baseCurve = speedMatchingCurve(startSlope: currentSpeed * baseDuration / delta, ramp: pCurve.speedSmoothing)
        }
        let hc = BezierHybridCurve(baseCurve: baseCurve, minDuration: baseDuration, distance: delta, dragCoefficient: pCurve.dragCoefficient, dragExponent: pCurve.dragExponent, stopSpeed: pCurve.stopSpeed, distanceEpsilon: 0.2)
        return (hc, hc.duration)
    }

    /// A base curve that sets off at `startSlope` and eases into the straight line every tick
    /// follows without smoothing, so a tick starts at the speed the content is already moving
    /// rather than jumping to its own. Running slower at first, it runs a little faster than the
    /// line afterwards to cover the same distance in the same time.
    ///
    /// The solver runs to 1e-4 rather than the 0.01 Mac Mouse Fix used for its version of this
    /// curve. That tolerance is on *time*, so at 0.01 a 100 pt tick can land up to a point off on
    /// any frame — the very unevenness this curve exists to remove.
    static func speedMatchingCurve(startSlope: Double, ramp: Double) -> Bezier {
        let p1x = ramp
        let p2 = 2 * ramp
        // Capped where the curve would stop rising monotonically. Content moving more than twice
        // as fast as the new tick drops to twice its speed at once, then eases the rest of the way.
        let slope = min(max(startSlope, 0), p2 / p1x)
        return Bezier(points: [(0, 0), (p1x, p1x * slope), (p2, p2), (1, 1)], defaultEpsilon: 1e-4)
    }

    /// Picks the resolver for the app under the pointer, once per scroll sequence.
    ///
    /// The lookup walks the whole on-screen window list, which is far too slow to run on every
    /// tick — slow scrolling makes every tick a "first consecutive" one. Holding the choice for the
    /// whole gesture is also the behaviour we want: the feel must not change mid-flick because the
    /// pointer grazed a window edge.
    private func resolveProfile(event: CGEvent, tickTime: CFTimeInterval) -> ScrollConfigResolver {
        let previous = activeProfile
        if appResolvers.isEmpty {
            activeProfile = nil
        } else if tickTime - lastTickTime > ScrollController.sequenceGap {
            let bundleID = appUnderPointer.bundleID(event: event)
            activeProfile = bundleID.flatMap { appResolvers[$0] != nil ? $0 : nil }
            Log.scroll.debug("Scroll sequence: app \(bundleID ?? "nil", privacy: .public), profile \(self.activeProfile ?? "global", privacy: .public)")
        }
        // Switching apps cancels momentum started under the other app's curve. This has to happen
        // before `currentModifications` is updated: `reset()` calls the animation callback
        // synchronously, and that callback reads the modifications the animation began with.
        if activeProfile != previous { reset() }
        return activeProfile.flatMap { appResolvers[$0] } ?? baseResolver
    }

    /// A scroll sequence ends after this long without a tick; the next one re-reads the app.
    private static let sequenceGap: CFTimeInterval = 0.5

    static func direction(axis: MFAxis, delta: Int64, invert: Int, horizontalModifier: Bool) -> MFDirection {
        let effective = mfsign(Double(delta)) * invert
        if axis == .horizontal || horizontalModifier {
            return effective == -1 ? .left : .right
        } else {
            return effective == -1 ? .down : .up
        }
    }

    // MARK: Output

    private func sendScroll(px: Int64, direction: MFDirection, animated: Bool, phase: AnimationCallbackPhase, momentumHint: MomentumHint, config: ScrollConfig) {
        // Counted here rather than at the tick: this is the single funnel every output type goes
        // through, so it is the distance actually delivered — once per tick unsmoothed, once per
        // animation frame smoothed, momentum included.
        stats?.recordScrollOutput(points: px, direction: direction)

        var dx: Int64 = 0
        var dy: Int64 = 0
        switch direction {
        case .up: dy = px
        case .down: dy = -px
        case .left: dx = -px
        case .right: dx = px
        case .none: break
        }

        var outputType: OutputType
        if !animated {
            outputType = .lineScroll
        } else if config.animationCurveParams?.sendGestureScrolls == true {
            outputType = .gestureScroll
        } else {
            outputType = .continuousScroll
        }
        if currentModifications.effectMod == .zoom {
            outputType = .zoom
        }
        sendOutputEvents(dx: dx, dy: dy, outputType: outputType, animatorPhase: phase, momentumHint: momentumHint, config: config)
    }

    private func sendOutputEvents(dx: Int64, dy: Int64, outputType: OutputType, animatorPhase: AnimationCallbackPhase, momentumHint: MomentumHint, config: ScrollConfig) {
        var eventPhase: IOHIDPhase = animatorPhase == .none ? .undefined : animatorPhase.iohidPhase
        let inverted = config.invertedFromDevice

        switch outputType {
        case .gestureScroll:
            if config.animationCurveParams?.sendMomentumScrolls != true {
                if eventPhase != .ended {
                    gestureSim.postGestureScroll(dx: dx, dy: dy, phase: eventPhase, autoMomentumScroll: true, invertedFromDevice: inverted)
                } else {
                    gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .ended, autoMomentumScroll: true, invertedFromDevice: inverted)
                    gestureSim.stopMomentumScroll()
                }
            } else {
                // Trackpad simulation: switch between gesture and momentum events following the momentum hint.
                assert(momentumHint != .none)
                if momentumHint == .gesture {
                    if lastMomentumHint == .momentum {
                        gestureSim.postMomentumScrollDirectly(dx: 0, dy: 0, momentumPhase: .end, invertedFromDevice: inverted)
                        eventPhase = .began
                    }
                    gestureSim.postGestureScroll(dx: dx, dy: dy, phase: eventPhase, autoMomentumScroll: false, invertedFromDevice: inverted)
                    if animatorPhase == .canceled {
                        // Simulate a two-finger tap to prevent apps from starting their own momentum scroll.
                        gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .mayBegin, autoMomentumScroll: false, invertedFromDevice: inverted)
                        gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .cancelled, autoMomentumScroll: false, invertedFromDevice: inverted)
                    }
                } else {
                    var momentumPhase: CGMomentumScrollPhase = .none
                    if lastMomentumHint == .gesture {
                        gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .ended, autoMomentumScroll: false, invertedFromDevice: inverted)
                        momentumPhase = .begin
                    } else if lastMomentumHint == .momentum {
                        if animatorPhase == .continue {
                            momentumPhase = .continuous
                        } else if animatorPhase == .end || animatorPhase == .canceled {
                            momentumPhase = .end
                        } else {
                            assertionFailure()
                        }
                    } else {
                        // First event already in momentum: treat as begin.
                        momentumPhase = .begin
                    }
                    gestureSim.postMomentumScrollDirectly(dx: Double(dx), dy: Double(dy), momentumPhase: momentumPhase, invertedFromDevice: inverted)
                    if animatorPhase == .end || animatorPhase == .canceled {
                        gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .mayBegin, autoMomentumScroll: false, invertedFromDevice: inverted)
                        gestureSim.postGestureScroll(dx: 0, dy: 0, phase: .cancelled, autoMomentumScroll: false, invertedFromDevice: inverted)
                    }
                }
                lastMomentumHint = momentumHint
                if animatorPhase == .end || animatorPhase == .canceled {
                    lastMomentumHint = .none
                }
            }

        case .continuousScroll:
            if dx + dy == 0 { return }
            guard let event = CGEvent(source: nil) else { return }
            event.setInt(55, 22)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if animatorPhase == .start { linePixelator.reset() }
            let lines = linePixelator.intVector(Vector(x: Double(dx) / 10.0, y: Double(dy) / 10.0))
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(lines.y))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: EventUtility.fixedScrollDelta(lines.y))
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(lines.x))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: EventUtility.fixedScrollDelta(lines.x))
            event.post(tap: .cgSessionEventTap)

        case .lineScroll:
            if dx + dy == 0 { return }
            guard let event = CGEvent(source: nil) else { return }
            event.setInt(55, 22)
            let dyLine = Double(dy) / 10
            let dxLine = Double(dx) / 10
            var dyLineInt = Int64(dyLine)
            var dxLineInt = Int64(dxLine)
            if dyLine != 0 && dyLineInt == 0 { dyLineInt = Int64(mfsign(dyLine)) }
            if dxLine != 0 && dxLineInt == 0 { dxLineInt = Int64(mfsign(dxLine)) }
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: dyLineInt)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: EventUtility.fixedScrollDelta(dyLine))
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: dxLineInt)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: EventUtility.fixedScrollDelta(dxLine))
            event.post(tap: .cgSessionEventTap)

        case .zoom:
            var eventDelta = Double(dx + dy) / 800.0
            if eventPhase == .began {
                // Chromium browsers need a lot of zoom delta before they react: pad the first event.
                if let bundleID = appUnderPointer.bundleID(), ScrollController.chromiumBundleIDs.contains(where: { bundleID.contains($0) }) {
                    touchSim.postMagnification(eventDelta, phase: .began)
                    eventPhase = .changed
                    if mfsign(eventDelta) > 0 {
                        eventDelta += 380 / 800.0
                    } else {
                        eventDelta -= 250 / 800.0
                    }
                }
            }
            touchSim.postMagnification(eventDelta, phase: eventPhase)
        }
    }

    private static let chromiumBundleIDs = [
        "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.brave.Browser",
    ]
}
