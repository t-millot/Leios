// Engine.swift
// MousePilot Engine — top-level façade. Owns the engine thread and every input subsystem.
// Ported from Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix), MMF License.

import Foundation
import CoreGraphics
import MousePilotShared

public final class Engine {

    public struct Status: Sendable, Equatable {
        public var isRunning = false
        public var scrollTapEnabled = false
        public var buttonTapEnabled = false
        public var dragTapEnabled = false
        public var flagsTapEnabled = false
        public var pointerFrozen = false
        public init() {}
    }

    // MARK: Public state

    private let statusLock = NSLock()
    private var _status = Status()
    public var status: Status {
        statusLock.lock(); defer { statusLock.unlock() }
        return _status
    }
    public var isRunning: Bool { status.isRunning }

    private let configLock = NSLock()
    private var _config: MousePilotConfig
    var config: MousePilotConfig {
        configLock.lock(); defer { configLock.unlock() }
        return _config
    }

    // MARK: Internals (engine-thread only unless noted)

    let thread = EngineThread()
    private var started = false
    var subsystems: EngineSubsystems?
    private var clockPool: FrameClockPool?

    public init(config: MousePilotConfig) {
        _config = config
    }

    // MARK: Lifecycle

    /// Spawns the engine thread and creates every tap (disabled). Requires Accessibility permission.
    public func start() {
        guard !started else { return }
        started = true
        thread.start()
        // Display links must be created on the main thread.
        let pool = FrameClockPool(engineRunLoop: thread.foundationRunLoop)
        onMain { pool.start() }
        clockPool = pool
        thread.perform { [self] in
            subsystems = EngineSubsystems(engine: self, clockPool: pool)
            subsystems?.start()
            updateStatus { $0.isRunning = true }
            Log.engine.info("Engine started")
        }
    }

    /// Cancels everything, restores the pointer, tears the taps down and stops the thread. Blocks briefly.
    public func stop() {
        guard started else { return }
        started = false
        thread.performSync { [self] in
            subsystems?.stop()
            subsystems = nil
            updateStatus { $0 = Status() }
        }
        thread.stop()
        if let pool = clockPool {
            onMain { pool.stop() }
            clockPool = nil
        }
        Log.engine.info("Engine stopped")
    }

    private func onMain(_ block: () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }

    /// Applies a new configuration (hops to the engine thread).
    public func apply(_ config: MousePilotConfig) {
        configLock.lock(); _config = config; configLock.unlock()
        guard started else { return }
        thread.perform { [self] in
            subsystems?.configChanged(config)
        }
    }

    // MARK: Button capture (for the settings app)

    /// Swallows the next mouse-button press and reports its number instead of acting on it, so the
    /// settings app can add a button the user presses — including one whose assignment would
    /// otherwise consume the press. `completion` runs exactly once, on the engine thread, with the
    /// button number or `ButtonCapture.timedOut` / `.unavailable`.
    public func captureNextButton(timeout: TimeInterval, completion: @escaping @Sendable (Int) -> Void) {
        guard started else { completion(ButtonCapture.unavailable); return }
        thread.perform { [self] in
            guard let subsystems else { completion(ButtonCapture.unavailable); return }
            subsystems.beginButtonCapture(timeout: timeout, completion: completion)
        }
    }

    /// Ends an armed capture; its completion runs with `ButtonCapture.timedOut`.
    public func cancelButtonCapture() {
        guard started else { return }
        thread.perform { [self] in subsystems?.cancelButtonCapture() }
    }

    /// Emergency cleanup usable from a signal handler path: restores the pointer even if `stop()` cannot run.
    public func emergencyCleanup() {
        subsystems?.emergencyCleanup()
    }

    // MARK: Status updates (engine thread)

    func updateStatus(_ mutate: (inout Status) -> Void) {
        statusLock.lock()
        mutate(&_status)
        statusLock.unlock()
    }
}
