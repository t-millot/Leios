// HelperClient.swift
// MousePilot — XPC client for the helper.

import Foundation
import MousePilotShared

struct HelperXPCStatus: Equatable {
    var bundleVersion: String
    var accessibilityTrusted: Bool
    var engineRunning: Bool
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
}

/// Resumes a continuation at most once, from any thread.
nonisolated private final class OneShot<T>: @unchecked Sendable {
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
