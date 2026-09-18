// AppBundleLayoutTests.swift
// Checks the packaging contract that SMAppService and the XPC connection depend on: the helper is
// embedded where the shared constants say it is, and the LaunchAgent plist agrees with it.
// This can only be tested from the Xcode project — the SPM tests never build an app bundle.

import XCTest
import LeiosShared
@testable import Leios

final class AppBundleLayoutTests: XCTestCase {

    /// The app bundle under test (the test host).
    private var appBundleURL: URL { Bundle.main.bundleURL }

    private var launchAgentPlist: [String: Any] {
        get throws {
            let url = appBundleURL
                .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent(LeiosConstants.launchdPlistName)
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            return try XCTUnwrap(plist as? [String: Any])
        }
    }

    func testHelperIsEmbeddedWhereTheConstantsSay() throws {
        let helperURL = appBundleURL.appendingPathComponent(LeiosConstants.helperRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperURL.path),
                      "Helper missing at \(LeiosConstants.helperRelativePath) — check the Embed Helper build phase")

        let helper = try XCTUnwrap(Bundle(url: helperURL))
        XCTAssertEqual(helper.bundleIdentifier, LeiosConstants.helperBundleID)
        XCTAssertEqual(helper.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true,
                       "The helper must stay a background agent")
    }

    /// `SMAppService.agent(plistName:)` only finds the agent at this exact path.
    func testLaunchAgentPlistIsCopiedAndMatchesTheHelper() throws {
        let plist = try launchAgentPlist
        XCTAssertEqual(plist["Label"] as? String, LeiosConstants.launchdLabel)

        let machServices = try XCTUnwrap(plist["MachServices"] as? [String: Any])
        XCTAssertNotNil(machServices[LeiosConstants.machServiceName],
                        "The plist must vend the mach service HelperClient connects to")

        let program = try XCTUnwrap(plist["BundleProgram"] as? String)
        let executable = appBundleURL.appendingPathComponent(program)
        XCTAssertTrue(FileManager.default.fileExists(atPath: executable.path),
                      "BundleProgram (\(program)) does not point at the embedded helper executable")
    }

    /// The helper walks back up to the main app with this path when it needs to relaunch it.
    func testHelperCanWalkBackToTheMainApp() {
        let helperURL = appBundleURL.appendingPathComponent(LeiosConstants.helperRelativePath)
        let backUp = helperURL
            .appendingPathComponent(LeiosConstants.mainAppRelativePathFromHelper)
            .standardizedFileURL
        XCTAssertEqual(backUp.standardizedFileURL.path, appBundleURL.standardizedFileURL.path)
    }

    /// Sparkle is a binary SPM target, so Xcode embeds it without an explicit build phase — which
    /// also means nothing in the project fails visibly if that stops happening. The updater would
    /// simply not launch.
    func testSparkleIsEmbedded() {
        let framework = appBundleURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        XCTAssertTrue(FileManager.default.fileExists(atPath: framework.path),
                      "Sparkle.framework missing from Contents/Frameworks — the updater cannot start")
    }

    /// Sparkle reads both of these from the bundle. They come from SupportFiles/Leios-Info.plist,
    /// merged into the generated plist; `INFOPLIST_KEY_` is silently ignored for non-Apple keys,
    /// so this is the assertion that catches a regression back to that.
    func testSparkleKeysReachTheBundle() throws {
        let feed = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        XCTAssertTrue(feed.hasPrefix("https://"), "the appcast must be fetched over HTTPS")

        let key = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        XCTAssertFalse(key.isEmpty, "Sparkle refuses to start without a public key")
    }

    func testAppAndHelperShareABundleIDPrefix() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, LeiosConstants.appBundleID)
        XCTAssertTrue(LeiosConstants.helperBundleID.hasPrefix(LeiosConstants.appBundleID + "."),
                      "The XPC code-signing check assumes app and helper ship under one identity")
    }
}
