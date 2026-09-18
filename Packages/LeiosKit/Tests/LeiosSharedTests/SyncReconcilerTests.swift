import XCTest
@testable import LeiosShared

final class SyncReconcilerTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private var later: Date { epoch.addingTimeInterval(60) }

    private func config(speed: ScrollSettings.Speed) -> SyncedConfig {
        var config = LeiosConfig()
        config.scroll.speed = speed
        return SyncedConfig(config)
    }

    func testNoRemoteRecordSeeds() {
        let decision = SyncReconciler.decide(local: config(speed: .low),
                                             remote: nil,
                                             lastAgreed: nil,
                                             localDirtySince: nil,
                                             remoteModifiedAt: nil)
        XCTAssertEqual(decision, .seed)
    }

    func testIdenticalPayloadsAreUpToDate() {
        let both = config(speed: .low)
        let decision = SyncReconciler.decide(local: both,
                                             remote: both,
                                             lastAgreed: nil,
                                             localDirtySince: epoch,
                                             remoteModifiedAt: later)
        XCTAssertEqual(decision, .upToDate)
    }

    func testLocalEditWithUnmovedServerUploads() {
        let agreed = config(speed: .low)
        let decision = SyncReconciler.decide(local: config(speed: .high),
                                             remote: agreed,
                                             lastAgreed: agreed,
                                             localDirtySince: epoch,
                                             remoteModifiedAt: epoch)
        XCTAssertEqual(decision, .upload)
    }

    func testMovedServerWithCleanLocalApplies() {
        let decision = SyncReconciler.decide(local: config(speed: .low),
                                             remote: config(speed: .high),
                                             lastAgreed: config(speed: .low),
                                             localDirtySince: nil,
                                             remoteModifiedAt: later)
        XCTAssertEqual(decision, .applyRemote)
    }

    func testBothMovedRemoteNewerApplies() {
        let decision = SyncReconciler.decide(local: config(speed: .low),
                                             remote: config(speed: .high),
                                             lastAgreed: config(speed: .medium),
                                             localDirtySince: epoch,
                                             remoteModifiedAt: later)
        XCTAssertEqual(decision, .applyRemote)
    }

    func testBothMovedLocalNewerUploads() {
        let decision = SyncReconciler.decide(local: config(speed: .low),
                                             remote: config(speed: .high),
                                             lastAgreed: config(speed: .medium),
                                             localDirtySince: later,
                                             remoteModifiedAt: epoch)
        XCTAssertEqual(decision, .upload)
    }

    /// A tie must resolve the same way on both Macs, or they would overwrite each other in turn.
    func testSimultaneousStampsResolveToRemote() {
        let decision = SyncReconciler.decide(local: config(speed: .low),
                                             remote: config(speed: .high),
                                             lastAgreed: config(speed: .medium),
                                             localDirtySince: epoch,
                                             remoteModifiedAt: epoch)
        XCTAssertEqual(decision, .applyRemote)
    }

    /// Why `localDirtySince` is persisted rather than kept in memory: this Mac was edited offline
    /// and then quit, so it has no `lastAgreed` to compare against. Without the stored stamp it
    /// would read as clean and adopt the older remote over the user's unsent changes.
    func testOfflineEditSurvivingRelaunchUploads() {
        let decision = SyncReconciler.decide(local: config(speed: .low),
                                             remote: config(speed: .high),
                                             lastAgreed: nil,
                                             localDirtySince: later,
                                             remoteModifiedAt: epoch)
        XCTAssertEqual(decision, .upload)
    }

    func testDirtyLocalAgainstUnstampedRemoteUploads() {
        let decision = SyncReconciler.decide(local: config(speed: .low),
                                             remote: config(speed: .high),
                                             lastAgreed: nil,
                                             localDirtySince: epoch,
                                             remoteModifiedAt: nil)
        XCTAssertEqual(decision, .upload)
    }
}
