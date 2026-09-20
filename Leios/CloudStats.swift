// CloudStats.swift
// Leios — carries each Mac's usage statistics through the user's iCloud account.

import Foundation
import CloudKit
import Compression
import os
import LeiosShared

/// Transport for the statistics, alongside `CloudSync`'s transport for the settings. Separate
/// because the two synchronise nothing like each other.
///
/// Settings are one document several Macs fight over, so they need last-writer-wins. Counts are
/// additive and each Mac only ever writes its own record, so there is no conflict to resolve —
/// merging is addition, and this class never has to decide anything.
///
/// Peers are found through a **roster** record at a known name rather than a `CKQuery`. A query
/// over a record type needs a queryable index deployed from the CloudKit dashboard, which record
/// fields do not: it would be a manual release step with no build-time signal. A roster is one
/// extra record and an ordinary fetch by identifier.
@MainActor
final class CloudStats {

    private let database: CKDatabase
    private let log = Logger(subsystem: "com.tmillot.Leios", category: "sync")

    /// The server's copy of each record we have written, for `.ifServerRecordUnchanged`.
    private var baseRecords: [CKRecord.ID: CKRecord] = [:]
    /// What we last put in our own record. Statistics change with every click, so uploading on
    /// every pass would be a write a minute for numbers nobody is looking at.
    private var lastUploaded: Data?
    private var lastUploadAt = Date.distantPast

    private static let recordType = "LeiosStats"
    private static let rosterType = "LeiosStatsRoster"
    private static let rosterID = CKRecord.ID(recordName: "stats-roster")
    /// A Mac's own record is refreshed at most this often. The figures are a history, not a live
    /// readout, and another Mac showing this one an hour behind costs nobody anything.
    private static let uploadInterval: TimeInterval = 15 * 60
    /// More than anyone has, and a bound on what one pass will fetch.
    private static let maxPeers = 24

    private enum Field {
        static let payload = "payload"
        static let modifiedAt = "modifiedAt"
        static let deviceName = "deviceName"
        static let schemaVersion = "schemaVersion"
        static let devices = "devices"
    }

    init?(containerID: String = LeiosConstants.iCloudContainerID) {
        // Same trap as `CloudSync`: `CKContainer(identifier:)` takes the process down rather than
        // throwing when the entitlement is missing, so it is checked before it is called.
        guard CloudSync.isEntitled(for: containerID) else { return nil }
        database = CKContainer(identifier: containerID).privateCloudDatabase
    }

    private static func recordID(for deviceID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "stats-\(deviceID)")
    }

    // MARK: Upload

    /// Writes this Mac's archive, and adds it to the roster if it is not there yet.
    func upload(_ archive: StatsArchive, force: Bool = false) async {
        guard !archive.deviceID.isEmpty else { return }
        guard let payload = Self.compress(archive) else { return }
        guard force || payload != lastUploaded,
              force || Date().timeIntervalSince(lastUploadAt) >= Self.uploadInterval
        else { return }

        let id = Self.recordID(for: archive.deviceID)
        let record = baseRecords[id] ?? CKRecord(recordType: Self.recordType, recordID: id)
        record[Field.payload] = payload as CKRecordValue
        record[Field.modifiedAt] = Date() as CKRecordValue
        record[Field.deviceName] = archive.deviceName as CKRecordValue
        record[Field.schemaVersion] = Int64(StatsArchive.schemaVersion) as CKRecordValue

        do {
            try await save(record)
            lastUploaded = payload
            lastUploadAt = Date()
            await register(archive.deviceID)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Only this Mac writes this record, so this means our base copy went stale — another
            // copy of Leios on the same Mac, or a record restored from elsewhere. Take theirs as
            // the base and let the next pass write on top of it.
            baseRecords[id] = Self.serverRecord(in: error)
        } catch {
            log.error("statistics upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds this Mac to the roster of devices peers should fetch. Union-only: a Mac is never
    /// removed by another Mac, so two of them racing can add but never lose an entry.
    private func register(_ deviceID: String) async {
        do {
            let roster = try await rosterRecord()
            var devices = roster[Field.devices] as? [String] ?? []
            guard !devices.contains(deviceID) else { return }
            devices.append(deviceID)
            roster[Field.devices] = devices as CKRecordValue
            try await save(roster)
        } catch let error as CKError where error.code == .serverRecordChanged {
            baseRecords[Self.rosterID] = Self.serverRecord(in: error)
        } catch {
            log.error("statistics roster update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Fetch

    /// Every other Mac's archive. Anything that will not decode is skipped rather than failing
    /// the pass — one Mac running a newer Leios must not blank the chart on this one.
    func fetchPeers(excluding deviceID: String) async -> [StatsArchive] {
        guard let roster = try? await rosterRecord() else { return [] }
        let devices = (roster[Field.devices] as? [String] ?? [])
            .filter { $0 != deviceID && !$0.isEmpty }
            .prefix(Self.maxPeers)
        guard !devices.isEmpty else { return [] }

        let ids = devices.map(Self.recordID(for:))
        do {
            let results = try await database.records(for: Array(ids))
            return results.values.compactMap { result in
                guard case .success(let record) = result else { return nil }
                baseRecords[record.recordID] = record
                guard let data = record[Field.payload] as? Data else { return nil }
                return Self.decompress(data)
            }
        } catch {
            log.error("statistics fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Removes this Mac's record and its roster entry — what "stop syncing statistics" means for
    /// the copies already in iCloud.
    func withdraw(_ deviceID: String) async {
        guard !deviceID.isEmpty else { return }
        do {
            _ = try? await database.deleteRecord(withID: Self.recordID(for: deviceID))
            baseRecords[Self.recordID(for: deviceID)] = nil
            lastUploaded = nil
            lastUploadAt = .distantPast
            let roster = try await rosterRecord()
            var devices = roster[Field.devices] as? [String] ?? []
            guard let index = devices.firstIndex(of: deviceID) else { return }
            devices.remove(at: index)
            roster[Field.devices] = devices as CKRecordValue
            try await save(roster)
        } catch {
            log.error("statistics withdrawal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Plumbing

    private func rosterRecord() async throws -> CKRecord {
        if let cached = baseRecords[Self.rosterID] { return cached }
        do {
            let record = try await database.record(for: Self.rosterID)
            baseRecords[Self.rosterID] = record
            return record
        } catch let error as CKError where error.code == .unknownItem {
            return CKRecord(recordType: Self.rosterType, recordID: Self.rosterID)
        }
    }

    private func save(_ record: CKRecord) async throws {
        let (saved, _) = try await database.modifyRecords(saving: [record],
                                                          deleting: [],
                                                          savePolicy: .ifServerRecordUnchanged,
                                                          atomically: true)
        for result in saved.values {
            switch result {
            case .success(let stored): baseRecords[stored.recordID] = stored
            case .failure(let error): throw error
            }
        }
    }

    private static func serverRecord(in error: CKError) -> CKRecord? {
        if let record = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord { return record }
        for case let partial as CKError in (error.partialErrorsByItemID ?? [:]).values {
            if let record = partial.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord { return record }
        }
        return nil
    }

    // MARK: Wire format

    /// Compressed, unlike `SyncedConfig`'s payload: a year of buckets is a few hundred kilobytes
    /// of very repetitive JSON, and zlib takes it to a few tens. That keeps it a `Data` field
    /// rather than a `CKAsset`, well inside CloudKit's 1 MB per record.
    private static func compress(_ archive: StatsArchive) -> Data? {
        guard let raw = try? StatsFile.encode(archive) else { return nil }
        return try? (raw as NSData).compressed(using: .zlib) as Data
    }

    private static func decompress(_ data: Data) -> StatsArchive? {
        guard let raw = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? StatsFile.decode(raw)
    }
}
