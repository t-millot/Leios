// HelperRestartDecisionTests.swift
// The rule that notices a helper left behind by a replaced app bundle.

import XCTest
@testable import Leios

final class HelperRestartDecisionTests: XCTestCase {

    /// What a Sparkle install looks like from the app's side: the new app is talking to the
    /// engine the old bundle left running. Nothing else reports this — the helper answers XPC
    /// perfectly well, it is just the wrong build.
    func testAMismatchedHelperIsRestarted() {
        XCTAssertTrue(HelperRestartDecision.needsRestart(appVersion: "6", helperVersion: "5", alreadyRestarted: false))
    }

    func testAMatchingHelperIsLeftAlone() {
        XCTAssertFalse(HelperRestartDecision.needsRestart(appVersion: "6", helperVersion: "6", alreadyRestarted: false))
    }

    /// `refresh()` polls every two seconds, so a registration that does not take would otherwise
    /// restart the engine under the user's hand twice a second for as long as the app is open.
    func testItOnlyTriesOncePerLaunch() {
        XCTAssertFalse(HelperRestartDecision.needsRestart(appVersion: "6", helperVersion: "5", alreadyRestarted: true))
    }

    /// An unreadable version on either side is not evidence of anything, and restarting the
    /// engine mid-gesture on a bad read is worse than leaving a stale one running.
    func testAnUnknownVersionIsNotTreatedAsStale() {
        XCTAssertFalse(HelperRestartDecision.needsRestart(appVersion: "", helperVersion: "5", alreadyRestarted: false))
        XCTAssertFalse(HelperRestartDecision.needsRestart(appVersion: "6", helperVersion: "", alreadyRestarted: false))
        XCTAssertFalse(HelperRestartDecision.needsRestart(appVersion: "", helperVersion: "", alreadyRestarted: false))
    }

    /// A downgrade is still a mismatch: the point is that the two halves disagree, not which is
    /// newer. Sparkle will not install one, but a user dragging an older copy over the top can.
    func testADowngradeAlsoCounts() {
        XCTAssertTrue(HelperRestartDecision.needsRestart(appVersion: "5", helperVersion: "6", alreadyRestarted: false))
    }
}
