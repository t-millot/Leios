import XCTest
@testable import Leios

final class SyncStateTests: XCTestCase {

    /// `CKContainer(identifier:)` traps rather than throwing when the app carries no entitlement
    /// for the container, so `CloudSync.init` has to refuse before constructing one. If this ever
    /// starts returning true for a container nobody is entitled to, toggling sync on crashes.
    func testEntitlementCheckRejectsAnUnentitledContainer() {
        XCTAssertFalse(CloudSync.isEntitled(for: "iCloud.com.example.NotOurs"))
    }

    func testEveryStateSaysSomething() {
        let states: [SyncState] = [.off, .unavailable, .noAccount, .syncing,
                                   .synced(Date(), device: nil), .incompatible(device: nil),
                                   .error("boom")]
        for state in states {
            XCTAssertFalse(state.description.isEmpty, "\(state) has no caption")
        }
        XCTAssertEqual(Set(states.map(\.description)).count, states.count, "captions should be distinguishable")
    }

    /// Naming the other Mac is the only transparency a silent last-writer-wins design offers.
    func testRemoteWriterIsNamedWhenKnown() {
        XCTAssertTrue(SyncState.synced(Date(), device: "Studio").description.contains("Studio"))
        XCTAssertFalse(SyncState.synced(Date(), device: nil).description.contains("Updated from"))
        XCTAssertTrue(SyncState.incompatible(device: "Studio").description.contains("Studio"))
        XCTAssertFalse(SyncState.incompatible(device: nil).description.isEmpty)
    }

    func testErrorStateShowsTheMessage() {
        XCTAssertEqual(SyncState.error("iCloud is busy.").description, "iCloud is busy.")
    }
}
