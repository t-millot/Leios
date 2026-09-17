// HelperClient.swift
// MousePilot — XPC client for the helper.

import Foundation
import MousePilotShared

struct HelperXPCStatus: Equatable {
    var bundleVersion: String
    var accessibilityTrusted: Bool
    var engineRunning: Bool
}

/// Result of asking the helper to swallow and report the next mouse-button press.
enum ButtonCaptureOutcome: Equatable {
    case captured(Int)
    /// Nobody pressed a button in time; arming again is worthwhile.
    case timedOut
    /// The helper can't capture (not running, disabled, or no Accessibility permission).
    case unavailable
}

@MainActor
final class HelperClient {

    private var connection: NSXPCConnection?

    private func makeConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: MPConstants.machServiceName, options: [])
        c.remoteObjectInterface = XPC.interface()
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    /// Resolves with nil when the helper cannot be reached within `timeout` seconds.
    private func call<T: Sendable>(timeout: TimeInterval = 2.0,
                                   _ body: @escaping (MousePilotHelperXPC, @escaping @Sendable (T?) -> Void) -> Void) async -> T? {
        let conn = makeConnection()
        return await withCheckedContinuation { continuation in
            let once = OneShot<T?>(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
                once.resume(nil)
            } as? MousePilotHelperXPC
            guard let proxy else { once.resume(nil); return }
            body(proxy) { value in once.resume(value) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
            }
        }
    }

    func getStatus() async -> HelperXPCStatus? {
        await call { proxy, done in
            proxy.getStatus { version, trusted, running in
                done(HelperXPCStatus(bundleVersion: version, accessibilityTrusted: trusted, engineRunning: running))
            }
        }
    }

    @discardableResult
    func reloadConfig() async -> Bool {
        let ok: Bool? = await call { proxy, done in
            proxy.reloadConfig { done($0) }
        }
        return ok ?? false
    }

    func requestAccessibility() {
        let proxy = makeConnection().remoteObjectProxyWithErrorHandler { _ in } as? MousePilotHelperXPC
        proxy?.requestAccessibility()
    }

    /// Arms the helper to swallow the next mouse-button press and report which button it was.
    /// Suspends until a button is pressed or `timeout` elapses.
    func captureNextButton(timeout: TimeInterval) async -> ButtonCaptureOutcome {
        // Outlive the helper's own timeout, so the helper — not the client — decides when to give up.
        let raw: Int? = await call(timeout: timeout + 5) { proxy, done in
            proxy.captureNextButton(timeout: timeout) { done($0) }
        }
        guard let raw else { return .unavailable }
        // Anything above the lowest remappable button is a real press; the caller judges the range.
        if raw >= MPConstants.minButton { return .captured(raw) }
        return raw == ButtonCapture.timedOut ? .timedOut : .unavailable
    }

    func cancelButtonCapture() {
        let proxy = makeConnection().remoteObjectProxyWithErrorHandler { _ in } as? MousePilotHelperXPC
        proxy?.cancelButtonCapture()
    }
}

/// Resumes a continuation at most once, from any thread.
private final nonisolated class OneShot<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
