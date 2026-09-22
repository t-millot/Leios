// CloudSync.swift
// Leios — carries the synced part of the configuration through the user's iCloud account.

import Foundation
import AppKit
import CloudKit
import Security
import os
import LeiosShared

/// What the user is told about sync. `AppModel` owns this; `CloudSync` is only the transport and
/// reports outcomes, so there is one place that decides what the state currently is.
enum SyncState: Equatable {
    case off
    /// The app is not signed for iCloud, so there is nothing to connect to.
    case unavailable
    case noAccount
    case syncing
    case synced(Date, device: String?)
    case incompatible(device: String?)
    case error(String)

    var description: String {
        switch self {
        case .off:
            return "Settings are stored on this Mac only."
        case .unavailable:
            return "This copy of Leios was not signed for iCloud, so sync is unavailable."
        case .noAccount:
            return "Sign in to iCloud in System Settings to sync."
        case .syncing:
            return "Syncing…"
        case .synced(let date, let device):
            // Clamped: our own stamp can sit a hair ahead of `now`, and the formatter would
            // render that as "in 0 seconds".
            let when = Self.formatter.localizedString(for: min(date, Date()), relativeTo: Date())
            guard let device else { return "Last synced \(when)." }
            return "Updated from \(device) \(when)."
        case .incompatible(let device):
            let who = device.map { "\($0) is" } ?? "Another Mac is"
            return "\(who) running a newer version of Leios. Update Leios to sync these settings."
        case .error(let message):
            return message
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // "now" rather than "0 seconds ago" for a sync that just finished.
        formatter.dateTimeStyle = .named
        return formatter
    }()
}

/// Who last wrote the record, and when. The date is ours rather than CloudKit's
/// `modificationDate`, which moves on every write including ones that change nothing.
struct SyncStamp: Equatable {
    var modifiedAt: Date
    var deviceName: String?
}

enum FetchOutcome {
    case record(SyncedConfig, SyncStamp)
    /// Nothing in the account yet — this Mac gets to seed it.
    case noRecord
    /// The payload did not decode. Almost always a peer running a newer Leios; either way we
    /// refuse to merge rather than guess, so neither Mac loses anything.
    case incompatible(device: String?)
    case noAccount
    case failed(String)
}

enum UploadOutcome {
    case uploaded(Date)
    /// Someone else wrote a newer record while we were composing ours. Their version wins.
    case superseded(SyncedConfig, SyncStamp)
    case incompatible(device: String?)
    case noAccount
    case failed(String)
}

@MainActor
final class CloudSync {

    /// Result of a debounced upload started by `scheduleUpload`.
    var onUploadResult: ((SyncedConfig, UploadOutcome) -> Void)?

    private let container: CKContainer
    private let database: CKDatabase
    private let log = Logger(subsystem: "com.tmillot.Leios", category: "sync")

    /// The last record the server gave us. Saving onto it carries its `recordChangeTag`, which is
    /// what lets `.ifServerRecordUnchanged` notice that someone else got there first.
    private var baseRecord: CKRecord?
    private var uploadTask: Task<Void, Never>?

    private static let recordType = "LeiosConfig"
    private static let recordID = CKRecord.ID(recordName: "config")
    /// Long enough that dragging a slider is one write rather than thirty. Separate from the
    /// app's 100 ms save debounce, which exists to keep the helper feeling responsive.
    private static let uploadDebounce = Duration.seconds(2)

    private enum Field {
        static let payload = "payload"
        static let modifiedAt = "modifiedAt"
        static let deviceName = "deviceName"
        static let schemaVersion = "schemaVersion"
    }

    /// Fails when this build carries no entitlement for the container. That has to be checked
    /// first: `CKContainer(identifier:)` traps rather than throwing when the entitlement is
    /// missing, so an unsigned or CI build would take the app down on the way in.
    init?(containerID: String = LeiosConstants.iCloudContainerID) {
        guard Self.isEntitled(for: containerID) else { return nil }
        // Explicit rather than `CKContainer.default()`, which derives from the bundle identifier.
        container = CKContainer(identifier: containerID)
        database = container.privateCloudDatabase
    }

    static func isEntitled(for containerID: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let identifiers = value as? [String]
        else { return false }
        return identifiers.contains(containerID)
    }

    static var deviceName: String { DeviceName.current }

    func cancelPendingUpload() {
        uploadTask?.cancel()
        uploadTask = nil
    }

    // MARK: Account

    func isSignedIn() async -> Bool {
        do {
            return try await container.accountStatus() == .available
        } catch {
            log.error("account status failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Fetch

    func fetch() async -> FetchOutcome {
        await fetch(allowRetry: true)
    }

    private func fetch(allowRetry: Bool) async -> FetchOutcome {
        do {
            let record = try await database.record(for: Self.recordID)
            baseRecord = record
            return Self.interpret(record)
        } catch let error as CKError where error.code == .unknownItem {
            return .noRecord
        } catch let error as CKError where error.code == .notAuthenticated {
            return .noAccount
        } catch {
            if allowRetry, let delay = Self.retryDelay(for: error) {
                try? await Task.sleep(for: .seconds(delay))
                return await fetch(allowRetry: false)
            }
            log.error("fetch failed: \(error.localizedDescription, privacy: .public)")
            return .failed(Self.message(for: error))
        }
    }

    private static func interpret(_ record: CKRecord) -> FetchOutcome {
        guard let data = record[Field.payload] as? Data else {
            return .incompatible(device: record[Field.deviceName] as? String)
        }
        // Strict on purpose: `Action` has no case for a value it does not know, so a config from a
        // newer Leios throws here. Refusing beats merging a payload we only partly understood.
        guard let payload = try? SyncedConfig.decode(data) else {
            return .incompatible(device: record[Field.deviceName] as? String)
        }
        let stamp = SyncStamp(modifiedAt: record[Field.modifiedAt] as? Date ?? Date.distantPast,
                              deviceName: record[Field.deviceName] as? String)
        return .record(payload, stamp)
    }

    // MARK: Upload

    func scheduleUpload(_ payload: SyncedConfig) {
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.uploadDebounce)
            guard !Task.isCancelled, let self else { return }
            let outcome = await self.upload(payload)
            guard !Task.isCancelled else { return }
            self.onUploadResult?(payload, outcome)
        }
    }

    func upload(_ payload: SyncedConfig) async -> UploadOutcome {
        let now = Date()
        do {
            let record = try compose(payload, at: now, onto: baseRecord)
            try await save(record)
            return .uploaded(now)
        } catch let error as CKError where error.code == .notAuthenticated {
            return .noAccount
        } catch {
            guard let conflict = Self.serverRecord(in: error) else {
                log.error("upload failed: \(error.localizedDescription, privacy: .public)")
                return .failed(Self.message(for: error))
            }
            return await resolve(conflict, ours: payload, stampedAt: now)
        }
    }

    /// Someone else wrote the record between our fetch and our save. Last writer wins, silently.
    private func resolve(_ serverRecord: CKRecord, ours: SyncedConfig, stampedAt: Date) async -> UploadOutcome {
        baseRecord = serverRecord
        let theirs = serverRecord[Field.modifiedAt] as? Date ?? Date.distantPast
        guard stampedAt > theirs else {
            log.info("upload superseded by \(serverRecord[Field.deviceName] as? String ?? "another Mac", privacy: .public)")
            switch Self.interpret(serverRecord) {
            case .record(let payload, let stamp): return .superseded(payload, stamp)
            case .incompatible(let device): return .incompatible(device: device)
            default: return .failed("Could not read the settings already in iCloud.")
            }
        }
        log.info("re-basing upload onto the server record and retrying")
        do {
            let rebased = try compose(ours, at: stampedAt, onto: serverRecord)
            try await save(rebased)
            return .uploaded(stampedAt)
        } catch {
            log.error("upload retry failed: \(error.localizedDescription, privacy: .public)")
            return .failed(Self.message(for: error))
        }
    }

    private func compose(_ payload: SyncedConfig, at date: Date, onto existing: CKRecord?) throws -> CKRecord {
        let record = existing ?? CKRecord(recordType: Self.recordType, recordID: Self.recordID)
        // A config with a hundred app profiles is a few KB against CloudKit's 1 MB per record.
        // If that ever stops being true this field becomes a CKAsset.
        record[Field.payload] = try SyncedConfig.encode(payload) as CKRecordValue
        record[Field.modifiedAt] = date as CKRecordValue
        record[Field.deviceName] = Self.deviceName as CKRecordValue
        record[Field.schemaVersion] = Int64(SyncedConfig.schemaVersion) as CKRecordValue
        return record
    }

    private func save(_ record: CKRecord) async throws {
        let (saved, _) = try await database.modifyRecords(saving: [record],
                                                          deleting: [],
                                                          savePolicy: .ifServerRecordUnchanged,
                                                          atomically: true)
        for result in saved.values {
            switch result {
            case .success(let stored): baseRecord = stored
            case .failure(let error): throw error
            }
        }
    }

    // MARK: Error shapes

    /// Digs the server's copy out of a `.serverRecordChanged`, whether it arrived on its own or
    /// wrapped in a partial failure.
    private static func serverRecord(in error: Error) -> CKRecord? {
        guard let ckError = error as? CKError else { return nil }
        if ckError.code == .serverRecordChanged,
           let record = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
            return record
        }
        for case let partial as CKError in (ckError.partialErrorsByItemID ?? [:]).values {
            if partial.code == .serverRecordChanged,
               let record = partial.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                return record
            }
        }
        return nil
    }

    private static func retryDelay(for error: Error) -> Double? {
        guard let ckError = error as? CKError else { return nil }
        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return ckError.retryAfterSeconds ?? 2
        default:
            return nil
        }
    }

    private static func message(for error: Error) -> String {
        guard let ckError = error as? CKError else { return error.localizedDescription }
        switch ckError.code {
        case .networkUnavailable, .networkFailure:
            return "Waiting for a network connection to sync."
        case .quotaExceeded:
            return "This iCloud account is out of space."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is busy. Leios will try again."
        default:
            return "iCloud sync failed: \(ckError.localizedDescription)"
        }
    }
}
