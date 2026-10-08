import Foundation

/// One serial disk writer per course. UI snapshots can be coalesced while each
/// accepted revision is journaled with its original identity before checkpoint.
actor SessionArchiveWriter {
    private let store: SessionStore
    private var committed: SessionSnapshot?
    private var checkpointRequiredAfterFailure = false

    init(directory: URL, restored: SessionSnapshot? = nil) {
        store = SessionStore(directory: directory, legacySessionID: restored?.sessionID ?? UUID())
        committed = restored
    }

    /// Injection keeps failure tests confined to their own temporary directory.
    init(store: SessionStore, restored: SessionSnapshot? = nil) {
        self.store = store
        committed = restored
    }

    @discardableResult
    func commit(_ value: SessionSnapshot, retiringCheckpoints: [SessionGenerationCheckpoint] = []) throws -> SessionSnapshot {
        var desired = try SessionArchiveCoding.decode(SessionSnapshot.self,
            from: SessionArchiveCoding.encode(value))
        let retainedByCaller = Set(desired.generationCheckpoints.map(\.id))
        try desired.validate()
        let forceCheckpoint = checkpointRequiredAfterFailure
        // A final sync can fail after rename. An explicit retry must repeat the
        // checkpoint's durability boundary, even if readback sees its content.
        checkpointRequiredAfterFailure = true
        let saved = try store.withWriteTransaction(requiringExistingDirectory: (committed?.storageRevision ?? 0) > 0) { transaction in
            // An append/rename can reach disk before its final sync reports an
            // error. Re-read on each explicit attempt so an acknowledged prefix is
            // neither duplicated nor retried forever with a stale revision token.
            let loaded = transaction.snapshot
            guard loaded != nil || (committed?.storageRevision ?? 0) == 0 else {
                // A migrated/removed course must be explicitly rebound. A late
                // callback from its old saver must not recreate the old directory.
                throw SessionStoreError.missingSnapshot
            }
            committed = loaded
            guard let previous = committed else {
                let saved = try transaction.save(desired)
                committed = saved
                return saved
            }
            guard previous.sessionID == desired.sessionID else {
                throw SessionStoreError.identityConflict("存档写入属于另一课程")
            }
            for checkpoint in previous.generationCheckpoints where !desired.generationCheckpoints.contains(where: { $0.id == checkpoint.id }) {
                var retained = retiringCheckpoints.first(where: { $0.id == checkpoint.id }) ?? checkpoint
                if !desired.canResume(retained) { retained.invalidated = true }
                desired.generationCheckpoints.append(retained)
            }
            try desired.validate()
            // Legacy imports do not have a journal until their first explicit save.
            if previous.storageRevision == 0 {
                let saved = try transaction.save(desired)
                committed = saved
                return saved
            }
            // Reject a stale UI state before appending any of its events. Fresh
            // tokens alone must never authorize dropping another writer's data.
            try SessionStore.validatePreservation(from: previous, to: desired)
            func append(_ event: SessionJournalEvent) throws {
                committed = try transaction.append(event, expectedRevision: committed?.storageRevision)
            }
            for revision in desired.revisionHistory.sorted(by: { $0.toRevision < $1.toRevision })
                where !previous.revisionHistory.contains(where: { $0.id == revision.id }) {
                // Coalescing may skip the first save of a segment, or a translation
                // between two confirmed corrections. Journal the exact predecessor
                // first; the store still enforces its ordinary body-change checks.
                if committed?.segments.first(where: { $0.id == revision.previousSegment.id })?.sameContent(as: revision.previousSegment) != true {
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
            for requested in retiringCheckpoints where !retainedByCaller.contains(requested.id) {
                guard let checkpoint = committed?.generationCheckpoints.first(where: { $0.id == requested.id }) else { continue }
                try append(.retireGenerationCheckpoint(checkpoint))
                desired.generationCheckpoints.removeAll { $0.id == requested.id }
            }
            if committed?.processing != desired.processing { try append(.processing(desired.processing)) }
            guard let current = committed else { throw SessionStoreError.missingSnapshot }
            var next = desired
            next.storageRevision = current.storageRevision
            next.lastJournalSequence = current.lastJournalSequence
            next.lastJournalDigest = current.lastJournalDigest
            // This also validates that a coalesced update cannot discard a batch,
            // usable translation, or an explicit correction's revision record.
            let saved = try transaction.save(next, skippingUnchanged: !forceCheckpoint)
            committed = saved
            return saved
        }
        checkpointRequiredAfterFailure = false
        return saved
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
    private var retirementRequests: [UUID: SessionGenerationCheckpoint] = [:]
    private var pump: Task<Void, Never>?
    private var urgent = false
    private(set) var lastError: Error?
    private(set) var lastSavedSnapshot: SessionSnapshot?
    var onFailure: ((Error) -> Void)?
    var onSaved: ((SessionSnapshot) -> Void)?

    init(directory: URL, sessionID: UUID, restored: SessionSnapshot? = nil,
         coalescingInterval: Duration = .milliseconds(500), writer: SessionArchiveWriter? = nil,
         storageProgress: ExitDeadline.StorageProgress? = nil) {
        self.directory = directory
        self.sessionID = sessionID
        self.interval = coalescingInterval
        self.writer = writer ?? SessionArchiveWriter(store: SessionStore(directory: directory,
            legacySessionID: restored?.sessionID ?? UUID(),
            atomicWrite: { data, url in
                try ExitDeadline.$storageProgress.withValue(storageProgress) { try SessionArchiveCoding.atomicWrite(data, url) }
            }, journalWrite: { data, url in
                try ExitDeadline.$storageProgress.withValue(storageProgress) { try SessionArchiveCoding.appendAndSync(data, url) }
            }), restored: restored)
    }

    func submit(_ snapshot: SessionSnapshot, retiringCheckpoints: [SessionGenerationCheckpoint] = []) {
        guard snapshot.sessionID == sessionID else {
            let error = SessionStoreError.identityConflict("过期任务尝试保存另一课程")
            lastError = error; onFailure?(error)
            return
        }
        for checkpoint in retiringCheckpoints { retirementRequests[checkpoint.id] = checkpoint }
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
                let retirements = retirementRequests.values.sorted { $0.id.uuidString < $1.id.uuidString }
                pending = nil
                do {
                    let saved = try await writer.commit(snapshot, retiringCheckpoints: retirements)
                    for value in retirements where retirementRequests[value.id] == value { retirementRequests[value.id] = nil }
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
