// TerminationSignals.swift
// MousePilot Helper — SIGTERM/SIGINT/SIGHUP handling via dispatch sources (ports Helper/UNIXSignals.m).
// launchd never delivers applicationWillTerminate:, so this is where cleanup happens.

import Foundation

final class TerminationSignals {

    private let cleanup: () -> Void
    private var sources: [DispatchSourceSignal] = []
    private let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    init(cleanup: @escaping () -> Void) {
        self.cleanup = cleanup
    }

    func install() {
        for sig in signals {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [cleanup] in
                NSLog("MousePilot Helper: received signal \(sig), cleaning up")
                cleanup()
                signal(sig, SIG_DFL)
                raise(sig)
            }
            src.resume()
            sources.append(src)
        }
    }
}
