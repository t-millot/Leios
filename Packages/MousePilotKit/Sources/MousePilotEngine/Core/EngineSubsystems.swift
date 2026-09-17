// EngineSubsystems.swift
// MousePilot Engine — construction and wiring of every subsystem. Lives entirely on the engine thread.
// Ports the startup ordering of Mac Mouse Fix's Helper/AccessibilityCheck.m.

import Foundation
import MousePilotShared

final class EngineSubsystems {

    unowned let engine: Engine
    let thread: EngineThread
    let clockPool: FrameClockPool
    private(set) var config: MousePilotConfig

    let modifiers: Modifiers
    let touchSim: TouchSimulator
    let gestureSim: GestureScrollSimulator
    let scroll: ScrollController
    let remapTable: RemapTable
    let executor: ActionExecutor
    let buttonsLogic: Buttons
    let buttons: ButtonInputReceiver
    let pointerFreeze: PointerFreeze
    let modifiedDrag: ModifiedDrag
    private(set) var switchMaster: SwitchMaster!

    init(engine: Engine, clockPool: FrameClockPool) {
        self.engine = engine
        self.thread = engine.thread
        self.clockPool = clockPool
        self.config = engine.config

        modifiers = Modifiers(runLoop: thread.runLoop)
        touchSim = TouchSimulator(thread: thread)
        gestureSim = GestureScrollSimulator(clockPool: clockPool)
        scroll = ScrollController(thread: thread, modifiers: modifiers, settings: config.scroll, clockPool: clockPool, gestureSim: gestureSim, touchSim: touchSim)
        remapTable = RemapTable(buttons: config.buttons)
        executor = ActionExecutor(touchSim: touchSim)
        buttonsLogic = Buttons(thread: thread, modifiers: modifiers, remapTable: remapTable, executor: executor)
        buttons = ButtonInputReceiver(thread: thread)
        buttons.buttons = buttonsLogic
        pointerFreeze = PointerFreeze(thread: thread)
        modifiedDrag = ModifiedDrag(thread: thread, modifiers: modifiers)

        let lockPointer: () -> Bool = { [unowned self] in self.config.general.lockPointerDuringDrag }
        modifiedDrag.setOutput(TwoFingerSwipeOutput(thread: thread, clockPool: clockPool, gestureSim: gestureSim, pointerFreeze: pointerFreeze, scroll: scroll, lockPointer: lockPointer), for: .twoFingerSwipe)
        modifiedDrag.setOutput(ThreeFingerSwipeOutput(touchSim: touchSim, pointerFreeze: pointerFreeze, lockPointer: lockPointer), for: .threeFingerSwipe)

        switchMaster = SwitchMaster(subsystems: self)
    }

    func start() {
        thread.assertOnEngineThread()
        scroll.createTap()
        buttons.createTap()
        modifiedDrag.createTap()
        pointerFreeze.createTap()
        modifiers.onChange = { [weak self] _ in
            self?.switchMaster.reevaluate()
        }
        modifiers.onButtonModifierUsed = { [weak self] m in
            self?.buttonsLogic.handleButtonHasHadEffectAsModifier(button: m.button)
        }
        buttonsLogic.useButtonModifiers = remapTable.anyDragMapped
        switchMaster.reevaluate()
    }

    func stop() {
        thread.assertOnEngineThread()
        switchMaster.disableAll()
        buttonsLogic.killClickCycle()
        scroll.invalidate()
        buttons.invalidate()
        modifiedDrag.invalidate()
        pointerFreeze.invalidate()
        modifiers.invalidate()
        touchSim.invalidate()
    }

    func configChanged(_ config: MousePilotConfig) {
        thread.assertOnEngineThread()
        self.config = config
        scroll.settingsChanged(config.scroll)
        remapTable.update(buttons: config.buttons)
        buttonsLogic.useButtonModifiers = remapTable.anyDragMapped
        switchMaster.reevaluate()
    }

    func emergencyCleanup() {
        modifiedDrag.emergencyCleanup()
        pointerFreeze.emergencyUnfreeze()
    }
}
