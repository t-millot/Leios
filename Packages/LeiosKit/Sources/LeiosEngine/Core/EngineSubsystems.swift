// EngineSubsystems.swift
// Leios Engine — construction and wiring of every subsystem. Lives entirely on the engine thread.
// Ports the startup ordering of Mac Mouse Fix's Helper/AccessibilityCheck.m.

import Foundation
import LeiosShared

final class EngineSubsystems {

    unowned let engine: Engine
    let thread: EngineThread
    let clockPool: FrameClockPool
    private(set) var config: LeiosConfig
    /// Derived from `config` and cached, because `SwitchMaster.reevaluate()` runs on every
    /// modifier change and must not walk the profile list each time.
    private(set) var appScroll: [String: ScrollSettings]
    private(set) var scrollGating: ScrollGating

    let modifiers: Modifiers
    let appUnderPointer: AppUnderPointerCache
    let touchSim: TouchSimulator
    let gestureSim: GestureScrollSimulator
    let scroll: ScrollController
    let remapTable: RemapTable
    let executor: ActionExecutor
    let buttonsLogic: Buttons
    let buttons: ButtonInputReceiver
    let pointerFreeze: PointerFreeze
    let modifiedDrag: ModifiedDrag
    let statsRecorder: StatsRecorder
    let statsTap: StatsTap
    let statsFlusher: StatsFlusher
    private(set) var switchMaster: SwitchMaster!

    init(engine: Engine, clockPool: FrameClockPool) {
        self.engine = engine
        self.thread = engine.thread
        self.clockPool = clockPool
        self.config = engine.config
        appScroll = config.effectiveAppScroll
        scrollGating = config.scrollGating

        modifiers = Modifiers(runLoop: thread.runLoop)
        appUnderPointer = AppUnderPointerCache(thread: thread)
        touchSim = TouchSimulator(thread: thread)
        gestureSim = GestureScrollSimulator(clockPool: clockPool)
        scroll = ScrollController(thread: thread, modifiers: modifiers, appUnderPointer: appUnderPointer, settings: config.scroll, apps: appScroll, clockPool: clockPool, gestureSim: gestureSim, touchSim: touchSim)
        remapTable = RemapTable(buttons: config.buttons)
        executor = ActionExecutor(touchSim: touchSim, appUnderPointer: appUnderPointer)
        buttonsLogic = Buttons(thread: thread, modifiers: modifiers, remapTable: remapTable, executor: executor)
        buttons = ButtonInputReceiver(thread: thread)
        buttons.buttons = buttonsLogic
        pointerFreeze = PointerFreeze(thread: thread)
        modifiedDrag = ModifiedDrag(thread: thread, modifiers: modifiers)
        statsRecorder = StatsRecorder(thread: thread)
        statsTap = StatsTap(thread: thread, recorder: statsRecorder)
        statsFlusher = StatsFlusher(thread: thread)

        let lockPointer: () -> Bool = { [unowned self] in self.config.general.lockPointerDuringDrag }
        modifiedDrag.setOutput(TwoFingerSwipeOutput(thread: thread, clockPool: clockPool, gestureSim: gestureSim, pointerFreeze: pointerFreeze, scroll: scroll, lockPointer: lockPointer), for: .twoFingerSwipe)
        modifiedDrag.setOutput(ThreeFingerSwipeOutput(touchSim: touchSim, pointerFreeze: pointerFreeze, lockPointer: lockPointer), for: .threeFingerSwipe)

        switchMaster = SwitchMaster(subsystems: self)

        scroll.stats = statsRecorder
        buttonsLogic.stats = statsRecorder
        modifiedDrag.stats = statsRecorder

        statsFlusher.drainBatch = { [unowned self] in self.statsRecorder.drain() }
        statsFlusher.discardBatch = { [unowned self] in self.statsRecorder.discard() }
        statsFlusher.onPeriodicTick = { [unowned self] in self.switchMaster.reevaluate() }
    }

    func start() {
        thread.assertOnEngineThread()
        appUnderPointer.startObserving()
        scroll.createTap()
        buttons.createTap()
        modifiedDrag.createTap()
        pointerFreeze.createTap()
        // Last on purpose, and it has to stay last. `.headInsertEventTap` puts the newest tap at
        // the head of the chain, and only from there does the stats tap see a scroll event before
        // the scroll tap — a `.defaultTap` that can swallow it — has had its turn.
        statsTap.createTap()
        modifiers.onChange = { [weak self] _ in
            self?.switchMaster.reevaluate()
        }
        modifiers.onButtonModifierUsed = { [weak self] m in
            self?.buttonsLogic.handleButtonHasHadEffectAsModifier(button: m.button)
        }
        buttons.onCaptureStateChanged = { [weak self] in
            self?.switchMaster.reevaluate()
        }
        buttonsLogic.useButtonModifiers = remapTable.anyDragMapped
        statsRecorder.refreshSystemSettings()
        statsFlusher.start()
        switchMaster.reevaluate()
    }

    /// Arms button capture for the settings app and turns the button tap on for its duration.
    func beginButtonCapture(timeout: TimeInterval, completion: @escaping (Int) -> Void) {
        thread.assertOnEngineThread()
        buttons.beginCapture(timeout: timeout, completion: completion)
        switchMaster.reevaluate()
    }

    func cancelButtonCapture() {
        thread.assertOnEngineThread()
        buttons.cancelCapture()
        switchMaster.reevaluate()
    }

    func stop() {
        thread.assertOnEngineThread()
        buttons.cancelCapture()
        switchMaster.disableAll()
        buttonsLogic.killClickCycle()
        // Before the taps go away, and synchronously: the helper may exit as soon as this returns.
        statsFlusher.stop()
        statsTap.invalidate()
        scroll.invalidate()
        buttons.invalidate()
        modifiedDrag.invalidate()
        pointerFreeze.invalidate()
        modifiers.invalidate()
        appUnderPointer.stopObserving()
        touchSim.invalidate()
    }

    func configChanged(_ config: LeiosConfig) {
        thread.assertOnEngineThread()
        self.config = config
        appScroll = config.effectiveAppScroll
        scrollGating = config.scrollGating
        scroll.settingsChanged(config.scroll, apps: appScroll)
        remapTable.update(buttons: config.buttons)
        buttonsLogic.useButtonModifiers = remapTable.anyDragMapped
        statsRecorder.refreshSystemSettings()
        switchMaster.reevaluate()
    }

    func emergencyCleanup() {
        modifiedDrag.emergencyCleanup()
        pointerFreeze.emergencyUnfreeze()
    }
}
