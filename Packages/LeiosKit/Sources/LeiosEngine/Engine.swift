// Engine.swift
// Leios Engine — top-level façade. Owns the engine thread and every input subsystem.
// Ported from Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix), MMF License.

import Foundation
import CoreGraphics
import LeiosShared

public final class Engine {

    public struct Status: Sendable, Equatable {
        public var isRunning = false
        public var scrollTapEnabled = false
        public var buttonTapEnabled = false
        public var dragTapEnabled = false
        public var flagsTapEnabled = false
        public var statsTapEnabled = false
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
    private var _config: LeiosConfig
    var config: LeiosConfig {
        configLock.lock(); defer { configLock.unlock() }
        return _config
    }

    // MARK: Internals (engine-thread only unless noted)

    let thread = EngineThread()
    private var started = false
    var subsystems: EngineSubsystems?
    private var clockPool: FrameClockPool?

    public init(config: LeiosConfig) {
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
    public func apply(_ config: LeiosConfig) {
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

    // MARK: Usage statistics (for the settings app)

    /// Empties the engine's accumulator and writes `statistics.json` now, so the settings app can
    /// show figures that are current rather than up to a flush interval stale. `completion` runs
    /// once the file is on disk, on the statistics queue — or immediately when the engine is not
    /// running, in which case there is nothing in flight to write.
    public func flushStatistics(completion: @escaping @Sendable () -> Void) {
        guard started else { completion(); return }
        thread.perform { [self] in
            guard let subsystems else { completion(); return }
            subsystems.statsFlusher.flushNow(completion: completion)
        }
    }

    /// Throws the recorded history away, including anything counted but not yet written. Works
    /// whether or not the engine is running: the file outlives the process that wrote it.
    public func resetStatistics(completion: @escaping @Sendable () -> Void) {
        guard started else {
            DispatchQueue.global(qos: .utility).async {
                try? StatsFile.delete()
                completion()
            }
            return
        }
        thread.perform { [self] in
            guard let subsystems else { completion(); return }
            subsystems.statsFlusher.reset(completion: completion)
        }
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
