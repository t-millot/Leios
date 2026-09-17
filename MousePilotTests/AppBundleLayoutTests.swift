// AppBundleLayoutTests.swift
// Checks the packaging contract that SMAppService and the XPC connection depend on: the helper is
// embedded where the shared constants say it is, and the LaunchAgent plist agrees with it.
// This can only be tested from the Xcode project — the SPM tests never build an app bundle.

import XCTest
import MousePilotShared
@testable import MousePilot

final class AppBundleLayoutTests: XCTestCase {

    /// The app bundle under test (the test host).
    private var appBundleURL: URL { Bundle.main.bundleURL }

    private var launchAgentPlist: [String: Any] {
        get throws {
            let url = appBundleURL
                .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent(MPConstants.launchdPlistName)
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            return try XCTUnwrap(plist as? [String: Any])
        }
    }

    func testHelperIsEmbeddedWhereTheConstantsSay() throws {
        let helperURL = appBundleURL.appendingPathComponent(MPConstants.helperRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperURL.path),
                      "Helper missing at \(MPConstants.helperRelativePath) — check the Embed Helper build phase")

        let helper = try XCTUnwrap(Bundle(url: helperURL))
        XCTAssertEqual(helper.bundleIdentifier, MPConstants.helperBundleID)
        XCTAssertEqual(helper.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true,
                       "The helper must stay a background agent")
    }

    /// `SMAppService.agent(plistName:)` only finds the agent at this exact path.
    func testLaunchAgentPlistIsCopiedAndMatchesTheHelper() throws {
        let plist = try launchAgentPlist
        XCTAssertEqual(plist["Label"] as? String, MPConstants.launchdLabel)

        let machServices = try XCTUnwrap(plist["MachServices"] as? [String: Any])
        XCTAssertNotNil(machServices[MPConstants.machServiceName],
                        "The plist must vend the mach service HelperClient connects to")

        let program = try XCTUnwrap(plist["BundleProgram"] as? String)
        let executable = appBundleURL.appendingPathComponent(program)
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path),
                      "BundleProgram (\(program)) does not point at the embedded helper executable")
    }

    /// The helper walks back up to the main app with this path when it needs to relaunch it.
    func testHelperCanWalkBackToTheMainApp() throws {
        let helperURL = appBundleURL.appendingPathComponent(MPConstants.helperRelativePath)
        let backUp = helperURL
            .appendingPathComponent(MPConstants.mainAppRelativePathFromHelper)
            .standardizedFileURL
        XCTAssertEqual(backUp.standardizedFileURL.path, appBundleURL.standardizedFileURL.path)
    }

    func testAppAndHelperShareABundleIDPrefix() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, MPConstants.appBundleID)
        XCTAssertTrue(MPConstants.helperBundleID.hasPrefix(MPConstants.appBundleID + "."),
                      "The XPC code-signing check assumes app and helper ship under one identity")
    }
}
