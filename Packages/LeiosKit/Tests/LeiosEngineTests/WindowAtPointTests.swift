import XCTest
import AppKit
import CoreGraphics
import CPrivateShim
@testable import LeiosEngine

/// The SkyLight hit test replaces a window-list walk that is still present as the fallback, so the
/// walk doubles as an oracle: the two must answer the same thing everywhere.
final class WindowAtPointTests: XCTestCase {

    /// A grid over the desktop and past its edges, with deliberately odd strides so points do not
    /// all land on the same window geometry.
    private var sweep: [CGPoint] {
        var points: [CGPoint] = []
        for x in stride(from: -100.0, through: 2600.0, by: 57.0) {
            for y in stride(from: -100.0, through: 1500.0, by: 53.0) {
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }

    /// A machine with no GUI session has no window server to ask, so the symbols resolving is not
    /// meaningful there — skip rather than fail, but still fail on a real desktop, because that is a
    /// genuine regression (the app keeps working on the fallback, 8x slower, and nothing else says so).
    func testSkyLightSymbolsResolve() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "no GUI session, so SkyLight has nothing to resolve against")
        XCTAssertTrue(LeiosWindowAtPointIsAvailable(), "SkyLight window hit test unavailable — the fallback still works, but the fast path is gone")
    }

    /// Windows have rounded corners, and the two answers legitimately differ inside them: SkyLight
    /// hit-tests the window's real shape and sees through a transparent corner to whatever is
    /// behind, while the window list only knows the bounding rectangle. Generous, because the
    /// radius has grown with every recent macOS.
    private static let cornerAllowance = 32.0

    /// Bounds of the window the list walk picks at `point`, by the same rule it picks it.
    private func windowListBounds(at point: CGPoint) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if bounds.contains(point) { return bounds }
        }
        return nil
    }

    private func isInRoundedCorner(_ point: CGPoint, of bounds: CGRect) -> Bool {
        let a = Self.cornerAllowance
        let nearVerticalEdge = point.x - bounds.minX < a || bounds.maxX - point.x < a
        let nearHorizontalEdge = point.y - bounds.minY < a || bounds.maxY - point.y < a
        return nearVerticalEdge && nearHorizontalEdge
    }

    /// The point that matters: SkyLight and the window list use the same coordinate space, so no
    /// flip is needed. A flipped y would show up here as mass disagreement.
    func testAgreesWithWindowListEverywhere() throws {
        var disagreements: [String] = []
        var answered = 0
        for point in sweep {
            var pid: pid_t = 0
            guard LeiosPidOfWindowAtPoint(point, &pid) else { continue }
            answered += 1
            let viaSkyLight = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            let viaList = EventUtility.bundleIDOfAppViaWindowList(at: point)
            if viaSkyLight != viaList {
                if let bounds = windowListBounds(at: point), isInRoundedCorner(point, of: bounds) { continue }
                disagreements.append("(\(Int(point.x)),\(Int(point.y))) skylight=\(viaSkyLight ?? "nil") list=\(viaList ?? "nil")")
            }
        }
        XCTAssertTrue(disagreements.isEmpty, "\(disagreements.count) disagreements, first few: \(disagreements.prefix(5))")
        // With no windows on screen there is nothing to compare and the test would pass vacuously.
        // Report that as skipped rather than as green, so a CI run cannot look like coverage it isn't.
        try XCTSkipIf(answered == 0, "no window anywhere on screen — nothing to compare")
    }

    /// When SkyLight declines, `pidOfApp` must fall back rather than report "no app".
    func testDeclineFallsBackToWindowList() {
        for point in sweep {
            var pid: pid_t = 0
            guard !LeiosPidOfWindowAtPoint(point, &pid) else { continue }
            XCTAssertEqual(EventUtility.pidOfApp(at: point), EventUtility.pidOfAppViaWindowList(at: point),
                           "fallback disagreed with the window list at (\(point.x),\(point.y))")
        }
    }

    func testPidAndBundleIDPathsAgree() {
        for point in sweep {
            let viaPid = EventUtility.pidOfApp(at: point).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            XCTAssertEqual(EventUtility.bundleIDOfApp(at: point), viaPid)
        }
    }
}
