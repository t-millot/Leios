// SyncReconciler.swift
// Leios — decides what a sync pass should do, given local and remote state.

import Foundation

/// What a sync pass concluded. Kept separate from the code that acts on it so the rule can be
/// tested exhaustively without a network, an account or a CloudKit container.
public enum SyncDecision: Equatable {
    /// Nothing to do; local and remote already agree.
    case upToDate
    /// The remote payload wins. Merge it into the local configuration.
    case applyRemote
    /// The local configuration wins. Push it.
    case upload
    /// There is no remote record yet. Push the local configuration as the origin.
    case seed
}

public enum SyncReconciler {

    /// - Parameters:
    ///   - local: the local configuration, projected.
    ///   - remote: what the server holds, or `nil` when no record exists yet.
    ///   - lastAgreed: the payload this Mac last agreed with the server, so a server that has not
    ///     moved can be told apart from one that has.
    ///   - localDirtySince: when this Mac first diverged from `lastAgreed`, or `nil` if it has not.
    ///     Persisted across launches: a Mac edited offline and then quit must still know it has
    ///     unsent work, or it would adopt a stale remote over the user's changes.
    ///   - remoteModifiedAt: the stamp the remote writer put on the record.
    public static func decide(local: SyncedConfig,
                              remote: SyncedConfig?,
                              lastAgreed: SyncedConfig?,
                              localDirtySince: Date?,
                              remoteModifiedAt: Date?) -> SyncDecision {
        guard let remote else { return .seed }
        if local == remote { return .upToDate }

        let serverMoved = remote != lastAgreed
        if !serverMoved { return .upload }

        guard let localDirtySince else { return .applyRemote }
        guard let remoteModifiedAt else { return .upload }

        // Last writer wins. A tie resolves to the remote, so two Macs stamped in the same instant
        // converge on one answer instead of overwriting each other turn by turn.
        return remoteModifiedAt >= localDirtySince ? .applyRemote : .upload
    }
}
