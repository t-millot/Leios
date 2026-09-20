// StatsFlusher.swift
// Leios Engine — moves counted batches off the engine thread and onto disk.

import Foundation
import LeiosShared

/// The other half of the statistics: everything the recorder deliberately refuses to do.
///
/// It owns a serial background queue, and that queue owns the archive. Reading the clock, deciding
/// which hour a batch belongs to, pruning old buckets, encoding JSON and writing the file all
/// happen there. The engine thread's whole involvement is handing over a value type once a minute.
///
/// Nothing here ever blocks the engine thread on the queue except the one deliberate case:
/// `stop()`, which must get the last batch to disk before the helper exits. The queue never blocks
/// on the engine thread at all, so the two cannot deadlock against each other.
final class StatsFlusher {

    /// How often the engine's accumulator is emptied. Also the worst-case attribution error at an
    /// hour boundary, and the worst case lost to a crash.
    static let drainInterval: TimeInterval = 60
    /// The timer is allowed to slip by this much, so an idle Mac is not woken on a precise
    /// schedule for a job with no deadline.
    static let drainLeeway: DispatchTimeInterval = .seconds(15)
    /// Folding a batch in is cheap; writing a year of history is not. Disk writes are rate-limited
    /// to this, with `flushNow(force:)` and `stop()` overriding it when the file is about to matter.
    private static let minimumWriteInterval: TimeInterval = 300

    private unowned let thread: EngineThread
    /// Where the archive lives. Overridden only by the tests, which point it at a temporary
    /// directory so they can watch the whole drain-fold-write path run for real.
    private let fileURL: URL?
    /// Empties the engine-side accumulator. Called on the engine thread, only by this class.
    /// Set by `EngineSubsystems` once every subsystem exists.
    var drainBatch: (() -> StatsTotals)?
    /// Throws away the batch in flight *and* the recogniser state behind it. Only `reset` uses
    /// it: everywhere else an unflushed batch is counts the user asked for.
    var discardBatch: (() -> Void)?
    /// Run on the engine thread before each periodic drain, and not on a forced flush.
    /// `EngineSubsystems` uses it to re-evaluate the taps: macOS disables a tap outright on secure
    /// input and `EventTap` deliberately does not re-enable itself, so something has to ask.
    var onPeriodicTick: (() -> Void)?

    private let queue = DispatchQueue(label: "com.tmillot.Leios.stats", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Queue-confined state. Nothing below this line is touched off `queue`.
    private var archive: StatsArchive?
    private var unwritten = false
    private var lastWrite = Date.distantPast

    init(thread: EngineThread, fileURL: URL? = nil) {
        self.thread = thread
        self.fileURL = fileURL
    }

    /// Always called on the engine thread.
    private func drain() -> StatsTotals { drainBatch?() ?? StatsTotals() }

    // MARK: Lifecycle

    /// `interval` and `leeway` are only ever passed by the tests, which cannot wait a minute.
    func start(interval: TimeInterval = StatsFlusher.drainInterval,
               leeway: DispatchTimeInterval = StatsFlusher.drainLeeway) {
        thread.assertOnEngineThread()
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Final flush, synchronous, because the helper may exit as soon as this returns. The only
    /// place the engine thread waits on the statistics queue.
    func stop() {
        thread.assertOnEngineThread()
        timer?.cancel()
        timer = nil
        let batch = drain()
        let now = Date()
        queue.sync {
            self.fold(batch, at: now)
            self.write(force: true)
        }
    }

    /// Empties the accumulator now and writes the file. The settings app asks for this over XPC
    /// before it shows the Statistics pane, so the charts are not up to a minute stale.
    func flushNow(completion: (@Sendable () -> Void)? = nil) {
        thread.perform { [weak self] in
            guard let self else {
                completion?()
                return
            }
            let batch = self.drain()
            let now = Date()
            self.queue.async {
                self.fold(batch, at: now)
                self.write(force: true)
                completion?()
            }
        }
    }

    /// Throws the history away and starts counting again from now.
    func reset(completion: (@Sendable () -> Void)? = nil) {
        thread.perform { [weak self] in
            guard let self else {
                completion?()
                return
            }
            // Whatever is in flight belongs to the history being discarded, and so does the
            // half-finished scroll sequence and click level behind it.
            self.discardBatch?()
            self.queue.async {
                try? StatsFile.delete(at: self.fileURL)
                self.archive = nil
                self.unwritten = false
                self.lastWrite = .distantPast
                completion?()
            }
        }
    }

    // MARK: The tick

    /// Both halves run asynchronously: the engine thread is never made to wait on the queue here,
    /// and the queue is never made to wait on the engine thread at all.
    private func tick() {
        thread.perform { [weak self] in
            guard let self else { return }
            self.onPeriodicTick?()
            let batch = self.drain()
            let now = Date()
            self.queue.async {
                self.fold(batch, at: now)
                self.write(force: false)
            }
        }
    }

    // MARK: Queue-confined

    private func fold(_ batch: StatsTotals, at date: Date) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !batch.isEmpty else {
            // Still prune: a Mac left alone for a month should not come back to a stale month of
            // hourly buckets the first time it is used again.
            if archive != nil { pruneLoaded(now: date) }
            return
        }
        var loaded = load()
        loaded.apply(batch, at: date)
        loaded.prune(now: date)
        archive = loaded
        unwritten = true
    }

    private func pruneLoaded(now: Date) {
        guard var loaded = archive else { return }
        let before = loaded
        loaded.prune(now: now)
        guard loaded != before else { return }
        archive = loaded
        unwritten = true
    }

    private func write(force: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard unwritten, let archive else { return }
        guard force || Date().timeIntervalSince(lastWrite) >= Self.minimumWriteInterval else { return }
        do {
            try StatsFile.save(archive, to: fileURL)
            unwritten = false
            lastWrite = Date()
        } catch {
            Log.stats.error("could not write statistics: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the file once per process and keeps it in memory afterwards. A file we cannot parse
    /// is started over rather than kept: this is counts, and refusing to count is worse than
    /// losing them — unlike `config.json`, which is the user's own work and is never written over.
    private func load() -> StatsArchive {
        dispatchPrecondition(condition: .onQueue(queue))
        if let archive { return archive }
        var loaded: StatsArchive
        do {
            loaded = try StatsFile.load(from: fileURL) ?? StatsArchive(startedAt: Date())
        } catch {
            Log.stats.error("statistics file unreadable, starting over: \(error.localizedDescription, privacy: .public)")
            loaded = StatsArchive(startedAt: Date())
        }
        if loaded.deviceID.isEmpty { loaded.deviceID = UUID().uuidString }
        // Refreshed every launch: a Mac can be renamed, and the name is only ever a label.
        loaded.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        archive = loaded
        return loaded
    }
}
