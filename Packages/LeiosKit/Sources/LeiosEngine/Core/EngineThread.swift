// EngineThread.swift
// Leios Engine — the single dedicated input thread.
// Ports the idea of Mac Mouse Fix's Helper/Utility/GlobalEventTapThread.m, but every tap,
// timer and display-link callback of the engine lives on this one run loop.

import Foundation

final class EngineThread {

    private(set) var runLoop: CFRunLoop!
    /// Foundation wrapper of `runLoop` (needed by CADisplayLink).
    private(set) var foundationRunLoop: RunLoop!
    private var thread: Thread?
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let stopLock = NSLock()
    private var shouldStop = false
    private var keepAliveSource: CFRunLoopSource?

    var isCurrent: Bool { Thread.current === thread }

    func assertOnEngineThread(_ what: StaticString = #function) {
        assert(isCurrent, "\(what) must run on the engine thread")
    }

    /// Starts the thread and blocks until its run loop exists.
    func start() {
        guard thread == nil else { return }
        stopLock.lock(); shouldStop = false; stopLock.unlock()
        let t = Thread { [unowned self] in self.threadMain() }
        t.name = "com.tmillot.Leios.engine"
        t.qualityOfService = .userInteractive
        t.threadPriority = 1.0
        thread = t
        t.start()
        readySemaphore.wait()
    }

    private func threadMain() {
        let rl = CFRunLoopGetCurrent()!
        runLoop = rl
        foundationRunLoop = RunLoop.current
        // Keep the run loop alive even when no taps are installed.
        var ctx = CFRunLoopSourceContext()
        ctx.perform = { _ in }
        let src = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx)!
        CFRunLoopAddSource(rl, src, .commonModes)
        keepAliveSource = src
        readySemaphore.signal()
        while true {
            stopLock.lock(); let stop = shouldStop; stopLock.unlock()
            if stop { break }
            autoreleasepool {
                _ = CFRunLoopRunInMode(.defaultMode, 3600, false)
            }
        }
        if let src = keepAliveSource { CFRunLoopRemoveSource(rl, src, .commonModes) }
    }

    /// Asks the thread to exit after the current run-loop pass. Blocks up to `timeout` for it to finish.
    func stop(timeout: TimeInterval = 1.0) {
        guard let t = thread else { return }
        stopLock.lock(); shouldStop = true; stopLock.unlock()
        if let rl = runLoop { CFRunLoopStop(rl) }
        let deadline = Date().addingTimeInterval(timeout)
        while !t.isFinished && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        thread = nil
    }

    /// Enqueues `block` on the engine run loop (always asynchronous, preserves ordering).
    func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    /// Runs `block` immediately when already on the engine thread, otherwise enqueues it.
    func performInline(_ block: @escaping () -> Void) {
        if isCurrent { block() } else { perform(block) }
    }

    /// Runs `block` on the engine thread and waits for it. Must not be called from the engine thread.
    func performSync<T>(_ block: @escaping () -> T) -> T {
        if isCurrent { return block() }
        let sema = DispatchSemaphore(value: 0)
        var result: T?
        perform {
            result = block()
            sema.signal()
        }
        sema.wait()
        return result!
    }

    /// Creates a run-loop timer on the engine thread. Returns the timer so it can be invalidated.
    @discardableResult
    func scheduleTimer(after delay: TimeInterval, repeats: Bool = false, _ handler: @escaping () -> Void) -> CFRunLoopTimer {
        let interval = repeats ? delay : 0
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, interval, 0, 0) { _ in
            handler()
        }!
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
        return timer
    }
}
