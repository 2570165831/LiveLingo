import Foundation

/// One serial disk writer per course. UI snapshots can be coalesced while each
/// accepted revision is journaled with its original identity before checkpoint.
actor SessionArchiveWriter {
    private let store: SessionStore
    private var committed: SessionSnapshot?

    init(directory: URL, restored: SessionSnapshot? = nil) {
        store = SessionStore(directory: directory, legacySessionID: restored?.sessionID ?? UUID())
        committed = restored
    }

    /// Injection keeps failure tests confined to their own temporary directory.
    init(store: SessionStore) { self.store = store }

    @discardableResult
    func commit(_ value: SessionSnapshot) throws -> SessionSnapshot {
        let desired = try SessionArchiveCoding.decode(SessionSnapshot.self,
            from: SessionArchiveCoding.encode(value))
        try desired.validate()
        // An append/rename can reach disk before its final sync reports an
        // error. Re-read on each explicit attempt so an acknowledged prefix is
        // neither duplicated nor retried forever with a stale revision token.
        let loaded = try store.load()
        guard loaded != nil || (committed?.storageRevision ?? 0) == 0 else {
            // A migrated/removed course must be explicitly rebound. A late
            // callback from its old saver must not recreate the old directory.
            throw SessionStoreError.missingSnapshot
        }
        committed = loaded
        guard let previous = committed else {
            let saved = try store.save(desired)
            committed = saved
            return saved
        }
        guard previous.sessionID == desired.sessionID else {
            throw SessionStoreError.identityConflict("存档写入属于另一课程")
        }
        // Legacy imports do not have a journal until their first explicit save.
        if previous.storageRevision == 0 {
            let saved = try store.save(desired)
            committed = saved
            return saved
        }
        // Reject a stale UI state before appending any of its events. Fresh
        // tokens alone must never authorize dropping another writer's data.
        try SessionStore.validatePreservation(from: previous, to: desired)
        for revision in desired.revisionHistory.sorted(by: { $0.toRevision < $1.toRevision })
            where !previous.revisionHistory.contains(where: { $0.id == revision.id }) {
            // Coalescing may skip the first save of a segment, or a translation
            // between two confirmed corrections. Journal the exact predecessor
            // first; the store still enforces its ordinary body-change checks.
            if committed?.segments.first(where: { $0.id == revision.previousSegment.id }) != revision.previousSegment {
                try append(.upsertSegment(revision.previousSegment))
            }
            for batch in revision.retainedBatches
                where committed?.batches.contains(where: { $0.id == batch.id }) != true
                    && committed?.revisionHistory.contains(where: { $0.retainedBatches.contains(where: { $0.id == batch.id }) }) != true {
                try append(.appendBatch(batch))
            }
            try append(.inputRevision(revision))
        }
        for segment in desired.segments {
            if committed?.segments.first(where: { $0.id == segment.id }) != segment {
                try append(.upsertSegment(segment))
            }
        }
        for batch in desired.batches {
            if committed?.batches.first(where: { $0.id == batch.id }) == nil {
                try append(.appendBatch(batch))
            }
        }
        for checkpoint in desired.generationCheckpoints {
            if committed?.generationCheckpoints.first(where: { $0.id == checkpoint.id }) != checkpoint {
                try append(.generationCheckpoint(checkpoint))
            }
        }
        if committed?.processing != desired.processing { try append(.processing(desired.processing)) }
        guard let current = committed else { throw SessionStoreError.missingSnapshot }
        var next = desired
        next.storageRevision = current.storageRevision
        next.lastJournalSequence = current.lastJournalSequence
        next.lastJournalDigest = current.lastJournalDigest
        // This also validates that a coalesced update cannot discard a batch,
        // usable translation, or an explicit correction's revision record.
        let saved = try store.save(next)
        committed = saved
        return saved
    }

    private func append(_ event: SessionJournalEvent) throws {
        committed = try store.append(event, expectedRevision: committed?.storageRevision)
    }

    func readback() throws -> SessionSnapshot? { try store.load() }
}

/// At most one saving Task plus one replacement snapshot. Token updates never
/// create a waiting Task chain or synchronously write on the classroom thread.
@MainActor
final class SessionSaveCoordinator {
    let sessionID: UUID
    let directory: URL
    private let writer: SessionArchiveWriter
    private let interval: Duration
    private var pending: SessionSnapshot?
    private var pump: Task<Void, Never>?
    private var urgent = false
    private(set) var lastError: Error?
    private(set) var lastSavedSnapshot: SessionSnapshot?
    var onFailure: ((Error) -> Void)?
    var onSaved: ((SessionSnapshot) -> Void)?

    init(directory: URL, sessionID: UUID, restored: SessionSnapshot? = nil,
         coalescingInterval: Duration = .milliseconds(500), writer: SessionArchiveWriter? = nil) {
        self.directory = directory
        self.sessionID = sessionID
        self.interval = coalescingInterval
        self.writer = writer ?? SessionArchiveWriter(directory: directory, restored: restored)
    }

    func submit(_ snapshot: SessionSnapshot) {
        guard snapshot.sessionID == sessionID else {
            let error = SessionStoreError.identityConflict("过期任务尝试保存另一课程")
            lastError = error; onFailure?(error)
            return
        }
        pending = snapshot
        // A failed writer retains the latest pending state. Subsequent state
        // changes or explicit flush may retry; an unchanged error never spins.
        if pump == nil { startPump() }
    }

    private func startPump() {
        lastError = nil
        pump = Task { [self] in
            defer { pump = nil; urgent = false }
            while pending != nil {
                if !urgent { try? await Task.sleep(for: interval) }
                guard let snapshot = pending else { return }
                pending = nil
                do {
                    let saved = try await writer.commit(snapshot)
                    lastSavedSnapshot = saved
                    onSaved?(saved)
                }
                catch {
                    if pending == nil { pending = snapshot }
                    lastError = error
                    onFailure?(error)
                    return
                }
            }
        }
    }

    @discardableResult
    func flush() async throws -> SessionSnapshot? {
        urgent = true
        if pump == nil, pending != nil { startPump() }
        while let task = pump { await task.value }
        if let lastError { throw lastError }
        return lastSavedSnapshot
    }

    func readback() async throws -> SessionSnapshot? {
        try await flush()
        return try await writer.readback()
    }

    var hasPendingWrite: Bool { pump != nil || pending != nil }
}
