// ButtonCaptureTests.swift
// Covers the settings app's side of button capture: how a captured press is classified.
// The engine's side lives in Packages/MousePilotKit/Tests.

import XCTest
import MousePilotShared
@testable import MousePilot

final class ButtonCaptureTests: XCTestCase {

    func testPrimaryButtonsAreNotCapturable() {
        // Left and right keep their system behavior, so pressing them is rejected rather than added.
        XCTAssertEqual(ButtonCaptureResult.classify(button: 1, isAlreadyMapped: false), .primaryButton)
        XCTAssertEqual(ButtonCaptureResult.classify(button: 2, isAlreadyMapped: false), .primaryButton)
    }

    func testMiddleButtonIsTheFirstCapturableNumber() {
        XCTAssertEqual(MPConstants.minButton, 3, "The capture zone assumes the middle button is number 3")
        XCTAssertEqual(ButtonCaptureResult.classify(button: 3, isAlreadyMapped: false), .added(3))
    }

    func testNumbersAboveTheSupportedRangeAreRejected() {
        let tooHigh = MPConstants.maxButton + 1
        XCTAssertEqual(ButtonCaptureResult.classify(button: MPConstants.maxButton, isAlreadyMapped: false),
                       .added(MPConstants.maxButton))
        XCTAssertEqual(ButtonCaptureResult.classify(button: tooHigh, isAlreadyMapped: false), .outOfRange(tooHigh))
    }

    func testAlreadyMappedButtonIsReportedInsteadOfAddedTwice() {
        XCTAssertEqual(ButtonCaptureResult.classify(button: 4, isAlreadyMapped: true), .alreadyMapped(4))
    }

    /// The default config ships buttons 4 and 5, so capturing them must report "already in the list".
    func testDefaultConfigButtonsAreSeenAsMapped() {
        let config = MousePilotConfig()
        for button in [4, 5] {
            XCTAssertEqual(ButtonCaptureResult.classify(button: button,
                                                        isAlreadyMapped: config.buttons[button] != nil),
                           .alreadyMapped(button))
        }
    }

    func testButtonNames() {
        XCTAssertEqual(MouseButtonNaming.name(1), "Left Button")
        XCTAssertEqual(MouseButtonNaming.name(2), "Right Button")
        XCTAssertEqual(MouseButtonNaming.name(3), "Middle Button (3)")
        XCTAssertEqual(MouseButtonNaming.name(4), "Button 4")
    }
}
