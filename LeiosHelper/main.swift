// main.swift
// Leios Helper — background agent entry point.

import AppKit

/// NSApplication.delegate is a weak reference, so the delegate must be owned by something that outlives
/// `run()`. A local would be released by ARC right after the assignment in optimized builds.
private let helperDelegate = MainActor.assumeIsolated { HelperAppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = helperDelegate
    app.run()
}
