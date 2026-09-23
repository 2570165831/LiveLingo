import Foundation
import Testing
@testable import LiveLingo

struct SessionStoreTests {
    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("LiveLingoStorageTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        var store: SessionStore { SessionStore(directory: root) }
        var snapshotURL: URL { root.appendingPathComponent(SessionStore.snapshotFileName) }
        var journalURL: URL { root.appendingPathComponent(SessionStore.journalFileName) }
        @discardableResult func initial(segments: [TranscriptSegment] = []) throws -> SessionSnapshot {
            try store.save(SessionSnapshot(segments: segments, createdAt: Date(timeIntervalSince1970: 1_000)))
        }
    }

    private enum Fault: Error { case injected }

    private func segment(id: UUID = UUID(), sessionID: UUID? = nil,
                         revision: Int = 0, english: String = "The speed is 30 m/s.", chinese: String = "") -> TranscriptSegment {
        TranscriptSegment(id: id, startTime: 1, endTime: 3, english: english, chinese: chinese,
                          sessionID: sessionID, inputRevision: revision)
    }

    private func batch(_ evidence: [TranscriptSegment]) -> LearningNoteBatch {
        LearningNoteBatch(id: UUID(), evidence: evidence,
                          note: LearningNote(topic: "速度", points: [LearningPoint(kind: "核心结论", text: "速度为 30 m/s。")]))
    }

    private func checkpoint(for snapshot: SessionSnapshot) -> SessionGenerationCheckpoint {
        let input = "Frozen input with its exact evidence."
        return SessionGenerationCheckpoint(sessionID: snapshot.sessionID, inputRevision: snapshot.inputRevision,
                                           modelName: "synthetic-model", protocolVersion: 2,
                                           inputDigest: SessionArchiveCoding.digest(Data(input.utf8)),
                                           promptDigest: SessionArchiveCoding.digest(Data("prompt-v2".utf8)),
                                           input: input, prefix: "{\"topic\":", evidenceIDs: snapshot.segments.map(\.id),
                                           attempts: 2)
    }

    private func rewriteEnvelope(_ data: Data, version: Int) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = version
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func rewritingRow(_ data: Data, sequence: Int? = nil, version: Int? = nil,
                             revision: Int? = nil) throws -> Data {
        var row = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let sequence { row["sequence"] = sequence }
        if let version { row["schemaVersion"] = version }
        if let revision { row["baseStorageRevision"] = revision }
        let schema = try #require(row["schemaVersion"] as? Int)
        let number = try #require(row["sequence"] as? Int)
        let session = try #require(row["sessionID"] as? String)
        let base = try #require(row["baseStorageRevision"] as? Int)
        let previous = try #require(row["previousDigest"] as? String)
        let encodedPayload = try #require(row["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encodedPayload))
        var bytes = Data("LiveLingo-journal-\(schema)\n\(number)\n\(session)\n\(base)\n\(previous)\n".utf8)
        bytes.append(payload)
        row["checksum"] = SessionArchiveCoding.digest(bytes)
        return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    }

    @Test func absentAndLegacyReadsCreateNoFiles() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let missing = fixture.root.appendingPathComponent("not-created", isDirectory: true)
        let absent = try SessionStore(directory: missing).loadDetailed()
        #expect(absent.snapshot == nil)
        #expect(absent.origin == .absent)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let store = fixture.store
        let original = segment(chinese: "[翻译失败：synthetic error]")
        let raw = try SessionArchiveCoding.encode(original)
        try raw.write(to: fixture.root.appendingPathComponent("bilingual.jsonl"))
        let markdown = "  ## 旧笔记\n无法还原其来源批次。\n\n"
        try Data(markdown.utf8).write(to: fixture.root.appendingPathComponent("summary-zh-Hans.md"))
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        let loaded = try store.loadDetailed()
        #expect(loaded.origin == .legacy)
        #expect(loaded.legacyProvenanceUnavailable)
        #expect(loaded.snapshot?.segments == [original])
        #expect(loaded.snapshot?.legacyMarkdown == markdown)
        #expect(loaded.snapshot?.batches.isEmpty == true)
        #expect(loaded.snapshot?.latestEvidenceIDs.isEmpty == true)
        #expect(try store.load()?.sessionID == loaded.snapshot?.sessionID)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("bilingual.jsonl")) == raw)
    }

    @Test func fullSnapshotRestoresIdentityNotesProgressAudioAndCheckpoints() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let id = UUID()
        var value = SessionSnapshot(sessionID: id, segments: [segment(sessionID: id, chinese: "速度为 30 m/s。")],
                                    notebookRevision: 5, notebookSelectionRound: 6,
                                    notebookLastOffered: ["question-1": 4], generation: 7,
                                    createdAt: Date(timeIntervalSince1970: 1_000))
        value.batches = [batch(value.segments)]
        value.latestEvidenceIDs = Set(value.segments.map(\.id))
        value.legacyMarkdown = "Old preserved Markdown."
        value.generationCheckpoints = [checkpoint(for: value)]
        value.processing = .init(phase: .paused, paused: true, pendingSegmentIDs: value.segments.map(\.id),
                                 pendingBatchIDs: value.batches.map(\.id), summaryPaused: true, reviewPaused: true,
                                 lastError: "synthetic interruption", lastCapturedTime: 3)
        value.audioFiles = [.init(relativePath: "recording.wav", sampleRate: 48_000, channelCount: 1,
                                  frameCount: 144_000, byteCount: 288_044, sha256: String(repeating: "a", count: 64),
                                  isFinalized: true)]
        value.audioRanges = [.init(segmentID: value.segments[0].id, filePath: "recording.wav", startFrame: 48_000,
                                   frameCount: 96_000, captureStart: 1, captureEnd: 3)]
        value.transcriptionJournalPath = "work/transcription-journal.jsonl"
        let saved = try fixture.store.save(value)
        let loaded = try #require(try fixture.store.load())
        #expect(loaded.sessionID == saved.sessionID)
        #expect(loaded.segments == value.segments)
        #expect(loaded.batches == value.batches)
        #expect(loaded.latestEvidenceIDs == value.latestEvidenceIDs)
        #expect(loaded.legacyMarkdown == value.legacyMarkdown)
        #expect(loaded.notebookRevision == 5)
        #expect(loaded.notebookSelectionRound == 6)
        #expect(loaded.notebookLastOffered == ["question-1": 4])
        #expect(loaded.generation == 7)
        #expect(loaded.generationCheckpoints == value.generationCheckpoints)
        #expect(loaded.processing == value.processing)
        #expect(loaded.audioFiles == value.audioFiles)
        #expect(loaded.audioRanges == value.audioRanges)
        #expect(loaded.transcriptionJournalPath == value.transcriptionJournalPath)
        #expect(loaded.storageRevision == 1)
        #expect(loaded.createdAt == value.createdAt)
        #expect(abs(loaded.updatedAt.timeIntervalSince(saved.updatedAt)) < 0.001)
        #expect(try loaded.inputFingerprint() == value.inputFingerprint())
    }

    @Test func activeCaptureIsInformationOnlyAndStoredPauseRemainsIntact() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var snapshot = SessionSnapshot()
        snapshot.processing = .init(phase: .capturing, paused: false, reviewPaused: true)
        try fixture.store.save(snapshot)
        let result = try fixture.store.loadDetailed()
        #expect(result.captureWasActive)
        #expect(result.snapshot?.processing.reviewPaused == true)
        // SessionStore links no capture, model runtime or application entrypoint.
    }

    @Test func appendsReplayInOrderAndRemainValidAcrossCheckpointSaves() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let first = segment()
        let initial = try fixture.initial()
        let one = try fixture.store.append(.upsertSegment(first), expectedRevision: initial.storageRevision)
        var translated = first
        translated.completeTranslation("速度为 30 m/s。")
        let two = try fixture.store.append(.upsertSegment(translated), expectedRevision: one.storageRevision)
        let notes = batch([translated])
        let three = try fixture.store.append(.appendBatch(notes), expectedRevision: two.storageRevision)
        let saved = try fixture.store.save(three)
        let paused = SessionProcessingState(phase: .paused, paused: true, reviewPaused: true)
        let four = try fixture.store.append(.processing(paused), expectedRevision: saved.storageRevision)
        let reloaded = try #require(try fixture.store.load())
        #expect(reloaded.segments == [translated])
        #expect(reloaded.batches == [notes])
        #expect(reloaded.latestEvidenceIDs == notes.ids)
        #expect(reloaded.processing == paused)
        #expect(reloaded.lastJournalSequence == 4)
        #expect(reloaded.storageRevision == four.storageRevision)
        #expect(reloaded.lastJournalDigest == four.lastJournalDigest)
        #expect(try Data(contentsOf: fixture.journalURL).split(separator: 10).count == 4)
    }

    @Test func staleWritersAndUnrecordedBodyChangesCannotOverwriteSavedData() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let old = segment(chinese: "速度为 30 m/s。")
        let initial = try fixture.initial(segments: [old])
        var newer = initial
        newer.processing.summaryPaused = true
        let saved = try fixture.store.save(newer)
        #expect(throws: SessionStoreError.staleSnapshot) { try fixture.store.save(initial) }
        #expect(throws: SessionStoreError.staleSnapshot) {
            try fixture.store.append(.processing(.init()), expectedRevision: initial.storageRevision)
        }
        let before = try Data(contentsOf: fixture.snapshotURL)
        var dropped = saved
        dropped.segments = []
        #expect(throws: SessionStoreError.self) { try fixture.store.save(dropped) }
        let rewritten = segment(id: old.id, english: "Invented replacement.", chinese: "改写")
        #expect(throws: SessionStoreError.self) { try fixture.store.append(.upsertSegment(rewritten)) }
        var failed = old
        failed.failTranslation("synthetic failure")
        #expect(throws: SessionStoreError.self) { try fixture.store.append(.upsertSegment(failed)) }
        #expect(try Data(contentsOf: fixture.snapshotURL) == before)
        #expect(try fixture.store.load()?.segments == [old])
    }

    @Test func existingTranslationCorrectionRequiresRevisionHistory() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let old = segment(chinese: "速度为 30 m/s。")
        let saved = try fixture.initial(segments: [old])
        var new = old
        new.completeTranslation("速度为 90 m/s。")
        #expect(throws: SessionStoreError.self) { try fixture.store.append(.upsertSegment(new)) }
        var direct = saved
        direct.segments = [new]
        #expect(throws: SessionStoreError.self) { try fixture.store.save(direct) }
        #expect(try fixture.store.load()?.segments == [old])
    }

    @Test func confirmedRevisionPreservesOldTextNotesAndInvalidatesDraft() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var snapshot = SessionSnapshot(segments: [segment(chinese: "速度为 30 m/s。")])
        snapshot.batches = [batch(snapshot.segments)]
        snapshot.generationCheckpoints = [checkpoint(for: snapshot)]
        let saved = try fixture.store.save(snapshot)
        let replacement = segment(id: saved.segments[0].id, revision: 1, english: "The speed is 40 m/s.")
        let change = SessionInputRevision(fromRevision: 0, toRevision: 1, previousSegment: saved.segments[0],
                                          replacementSegment: replacement, retainedBatches: saved.batches,
                                          reason: "Synthetic user-confirmed correction", confirmedAt: Date(timeIntervalSince1970: 2_000))
        let revised = try fixture.store.append(.inputRevision(change), expectedRevision: saved.storageRevision)
        let reopened = try #require(try fixture.store.load())
        #expect(reopened.inputRevision == 1)
        #expect(reopened.segments == [replacement])
        #expect(reopened.revisionHistory == [change])
        #expect(reopened.batches.isEmpty)
        #expect(reopened.revisionHistory.first?.retainedBatches == saved.batches)
        #expect(reopened.latestEvidenceIDs.isEmpty)
        #expect(reopened.generationCheckpoints.first?.invalidated == true)
        #expect(reopened.storageRevision == revised.storageRevision)
        #expect(throws: SessionStoreError.self) { try fixture.store.append(.inputRevision(change)) }
    }

    @Test func revisionsInvalidateOnlyDependentCheckpointsAndKeepUnrelatedProgress() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var value = SessionSnapshot(segments: [segment(), segment(english: "Independent lesson detail.")])
        let dependent = checkpoint(for: value)
        var unrelated = checkpoint(for: value)
        unrelated.evidenceIDs = [value.segments[1].id]
        value.generationCheckpoints = [dependent, unrelated]
        let saved = try fixture.store.save(value)
        let replacement = segment(id: value.segments[0].id, revision: 1, english: "A confirmed correction.")
        let change = SessionInputRevision(fromRevision: 0, toRevision: 1, previousSegment: value.segments[0],
                                          replacementSegment: replacement, reason: "Synthetic confirmation")
        try fixture.store.append(.inputRevision(change), expectedRevision: saved.storageRevision)
        let loaded = try #require(try fixture.store.load())
        #expect(loaded.generationCheckpoints[0].invalidated)
        #expect(loaded.generationCheckpoints[1] == unrelated)
        #expect(loaded.canResume(unrelated))
        #expect(unrelated.matches(snapshot: loaded, modelName: unrelated.modelName, protocolVersion: 2,
                                   input: unrelated.input, prompt: "prompt-v2"))
        #expect(!loaded.canResume(dependent))
        var continued = unrelated
        continued.prefix += "\"new content\""
        continued.attempts += 1
        try fixture.store.append(.generationCheckpoint(continued))
        #expect(try fixture.store.load()?.generationCheckpoints[1].prefix == continued.prefix)
        let second = segment(id: value.segments[1].id, revision: 2, english: "Now the other source is corrected.")
        try fixture.store.append(.inputRevision(.init(fromRevision: 1, toRevision: 2,
                                                      previousSegment: value.segments[1], replacementSegment: second,
                                                      reason: "Second synthetic confirmation")))
        #expect(try fixture.store.load()?.generationCheckpoints.allSatisfy(\.invalidated) == true)
    }

    @Test func prefixBindingRejectsChangedPromptAndRegressedPrefix() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let saved = try fixture.initial(segments: [segment()])
        let draft = checkpoint(for: saved)
        #expect(draft.matches(sessionID: saved.sessionID, inputRevision: 0, modelName: "synthetic-model",
                              protocolVersion: 2, input: draft.input, prompt: "prompt-v2"))
        #expect(!draft.matches(sessionID: saved.sessionID, inputRevision: 0, modelName: "synthetic-model",
                               protocolVersion: 2, input: draft.input, prompt: "changed prompt"))
        try fixture.store.append(.generationCheckpoint(draft))
        var changed = draft
        changed.promptDigest = SessionArchiveCoding.digest(Data("changed prompt".utf8))
        #expect(throws: SessionStoreError.self) { try fixture.store.append(.generationCheckpoint(changed)) }
        var regressed = draft
        regressed.prefix = ""
        #expect(throws: SessionStoreError.self) { try fixture.store.append(.generationCheckpoint(regressed)) }
        var extended = draft
        extended.prefix += "\"速度\""
        extended.attempts += 1
        try fixture.store.append(.generationCheckpoint(extended))
        #expect(try fixture.store.load()?.generationCheckpoints.first?.prefix == extended.prefix)
    }

    @Test func revisionWithoutAffectedOriginalBatchIsRejectedWithoutWriting() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var snapshot = SessionSnapshot(segments: [segment()])
        snapshot.batches = [batch(snapshot.segments)]
        let saved = try fixture.store.save(snapshot)
        let replacement = segment(id: saved.segments[0].id, revision: 1, english: "Confirmed new input.")
        let change = SessionInputRevision(fromRevision: 0, toRevision: 1,
            previousSegment: saved.segments[0], replacementSegment: replacement, reason: "Synthetic correction")
        #expect(throws: SessionStoreError.self) { try fixture.store.append(.inputRevision(change)) }
        #expect(try fixture.store.load() == saved)
        #expect(!FileManager.default.fileExists(atPath: fixture.journalURL.path))
    }

    @Test func retiredBatchCannotReturnToActiveNotebook() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var snapshot = SessionSnapshot(segments: [segment()])
        let oldBatch = batch(snapshot.segments)
        snapshot.batches = [oldBatch]
        let saved = try fixture.store.save(snapshot)
        let replacement = segment(id: saved.segments[0].id, revision: 1, english: "Confirmed new input.")
        let change = SessionInputRevision(fromRevision: 0, toRevision: 1,
            previousSegment: saved.segments[0], replacementSegment: replacement,
            retainedBatches: [oldBatch], reason: "Synthetic correction")
        var revised = try fixture.store.append(.inputRevision(change))
        let before = try Data(contentsOf: fixture.journalURL)
        #expect(throws: SessionStoreError.self) { try fixture.store.append(.appendBatch(oldBatch)) }
        revised.batches = [oldBatch]
        #expect(throws: SessionStoreError.self) { try fixture.store.save(revised) }
        #expect(try Data(contentsOf: fixture.journalURL) == before)
        #expect(try fixture.store.load()?.batches.isEmpty == true)
    }

    @Test func checkpointRetainsSeparateBatchEvidenceAndFullQuestionDependencies() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var snapshot = SessionSnapshot(segments: [segment(), segment(english: "Evidence for an earlier question.")])
        var draft = checkpoint(for: snapshot)
        draft.batchEvidenceIDs = [snapshot.segments[0].id]
        snapshot.generationCheckpoints = [draft]
        let saved = try fixture.store.save(snapshot)
        #expect(saved.generationCheckpoints[0].batchEvidenceIDs == draft.batchEvidenceIDs)
        let replacement = segment(id: snapshot.segments[1].id, revision: 1, english: "Corrected earlier question input.")
        let revised = try fixture.store.append(.inputRevision(.init(fromRevision: 0, toRevision: 1,
            previousSegment: snapshot.segments[1], replacementSegment: replacement, reason: "Confirmed question correction")))
        #expect(revised.generationCheckpoints[0].invalidated)
        #expect(!revised.canResume(draft))
        var invalid = saved
        invalid.generationCheckpoints[0].batchEvidenceIDs = [UUID()]
        #expect(throws: SessionStoreError.self) { try invalid.validate() }
    }

    @Test func oldCheckpointWithoutSeparateBatchEvidenceStillDecodes() throws {
        let snapshot = SessionSnapshot(segments: [segment()])
        let draft = checkpoint(for: snapshot)
        var object = try #require(try JSONSerialization.jsonObject(with: SessionArchiveCoding.encode(draft)) as? [String: Any])
        object.removeValue(forKey: "batchEvidenceIDs")
        let decoded = try SessionArchiveCoding.decode(SessionGenerationCheckpoint.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == draft)
        #expect(decoded.batchEvidenceIDs == nil)
    }

    @Test func journalReturnValueCanBeCheckpointedWithFractionalRevisionDates() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var current = try fixture.initial(segments: [segment()])
        for revision in 1...12 {
            let replacement = segment(id: current.segments[0].id, revision: revision,
                                      english: "Confirmed revision \(revision).")
            let change = SessionInputRevision(fromRevision: revision - 1, toRevision: revision,
                                              previousSegment: current.segments[0], replacementSegment: replacement,
                                              reason: "Synthetic confirmation",
                                              confirmedAt: Date(timeIntervalSinceReferenceDate: 811_572_342.1234567 + Double(revision) / 37))
            current = try fixture.store.append(.inputRevision(change), expectedRevision: current.storageRevision)
            let reloaded = try #require(try fixture.store.load())
            #expect(current.revisionHistory == reloaded.revisionHistory)
            current = try fixture.store.save(current)
        }
        #expect(try fixture.store.load()?.revisionHistory.count == 12)
    }

    @Test func originalFractionalRevisionCanBeSavedAfterItsJournalEvent() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        var desired = try fixture.initial(segments: [segment()])
        let replacement = segment(id: desired.segments[0].id, revision: 1, english: "Confirmed correction.")
        let change = SessionInputRevision(fromRevision: 0, toRevision: 1,
            previousSegment: desired.segments[0], replacementSegment: replacement,
            reason: "Synthetic confirmation",
            confirmedAt: Date(timeIntervalSinceReferenceDate: 811_572_342.1234567 + 1.0 / 37))
        let committed = try fixture.store.append(.inputRevision(change))
        desired.segments = [replacement]
        desired.inputRevision = 1
        desired.revisionHistory = [change]
        desired.storageRevision = committed.storageRevision
        desired.lastJournalSequence = committed.lastJournalSequence
        desired.lastJournalDigest = committed.lastJournalDigest
        let saved = try fixture.store.save(desired)
        #expect(saved.revisionHistory == committed.revisionHistory)
        #expect(saved.segments == [replacement])
        var changedHistory = saved
        changedHistory.revisionHistory[0].reason = "Unapproved history mutation"
        #expect(throws: SessionStoreError.self) { try fixture.store.save(changedHistory) }
    }

    @Test func completeUnterminatedRowWithWrongRevisionIsCorruption() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.initial()
        try fixture.store.append(.upsertSegment(segment()))
        let first = try Data(contentsOf: fixture.journalURL)
        try fixture.store.append(.processing(.init()))
        let all = try Data(contentsOf: fixture.journalURL)
        let row = Data(all.dropFirst(first.count).dropLast())
        var invalid = first
        invalid.append(try rewritingRow(row, revision: 999))
        try invalid.write(to: fixture.journalURL)
        #expect(throws: SessionStoreError.self) { try fixture.store.load() }
        #expect(throws: SessionStoreError.self) { try fixture.store.preserveIncompleteTailAndResume() }
        #expect(try Data(contentsOf: fixture.journalURL) == invalid)
    }

    @Test func snapshotWriteFailureLeavesLastSavedStateReadable() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let saved = try fixture.initial(segments: [segment()])
        let original = try Data(contentsOf: fixture.snapshotURL)
        let failing = SessionStore(directory: fixture.root, atomicWrite: { _, _ in throw Fault.injected })
        var pending = saved
        pending.processing.paused = true
        #expect(throws: Fault.self) { try failing.save(pending) }
        #expect(try Data(contentsOf: fixture.snapshotURL) == original)
        #expect(try fixture.store.load()?.processing == saved.processing)
    }

    @Test func corruptedSnapshotAndFutureSchemasBlockReadsAndWrites() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let saved = try fixture.initial()
        let original = try Data(contentsOf: fixture.snapshotURL)
        var object = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["checksum"] = String(repeating: "f", count: 64)
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        try corrupt.write(to: fixture.snapshotURL)
        #expect(throws: SessionStoreError.corruptSnapshot) { try fixture.store.load() }
        #expect(throws: SessionStoreError.corruptSnapshot) { try fixture.store.save(saved) }
        #expect(try Data(contentsOf: fixture.snapshotURL) == corrupt)
        let future = try rewriteEnvelope(original, version: 999)
        try future.write(to: fixture.snapshotURL)
        #expect(throws: SessionStoreError.unsupportedSchema(999)) { try fixture.store.load() }
        #expect(throws: SessionStoreError.unsupportedSchema(999)) { try fixture.store.save(saved) }
        #expect(throws: SessionStoreError.unsupportedSchema(999)) { try fixture.store.append(.processing(.init())) }
        #expect(try Data(contentsOf: fixture.snapshotURL) == future)
    }

    @Test func truncatedTailIsReadOnlyUntilExplicitPreservingRecovery() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let initial = try fixture.initial()
        let first = segment()
        try fixture.store.append(.upsertSegment(first))
        let prefix = try Data(contentsOf: fixture.journalURL)
        try fixture.store.append(.processing(.init(phase: .paused, paused: true)))
        let complete = try Data(contentsOf: fixture.journalURL)
        let row = Data(complete.dropFirst(prefix.count))
        let cuts = [1, 10, row.count / 2, row.count - 2, row.count - 1]
        for cut in cuts {
            var truncated = prefix
            truncated.append(row.prefix(cut))
            try truncated.write(to: fixture.journalURL)
            let loaded = try fixture.store.loadDetailed()
            #expect(loaded.incompleteTailBytes == cut)
            #expect(loaded.snapshot?.segments == [first])
            #expect(loaded.snapshot?.lastJournalSequence == 1)
            #expect(loaded.snapshot?.processing.phase == .idle)
            #expect(try Data(contentsOf: fixture.journalURL) == truncated)
            #expect(throws: SessionStoreError.incompleteJournalTail(bytes: cut)) {
                try fixture.store.save(try #require(loaded.snapshot))
            }
            #expect(throws: SessionStoreError.incompleteJournalTail(bytes: cut)) {
                try fixture.store.append(.processing(.init()))
            }
        }
        let originalTail = try Data(contentsOf: fixture.journalURL)
        let preserved = try #require(try fixture.store.preserveIncompleteTailAndResume())
        #expect(try Data(contentsOf: preserved) == originalTail)
        #expect(try Data(contentsOf: fixture.journalURL) == prefix)
        let resumed = try fixture.store.append(.processing(.init(phase: .paused, paused: true)))
        #expect(resumed.lastJournalSequence == 2)
        #expect(resumed.storageRevision == initial.storageRevision + 2)
        #expect(try fixture.store.loadDetailed().incompleteTailBytes == 0)
        #expect(try fixture.store.preserveIncompleteTailAndResume() == nil)
    }

    @Test func failedTailReplacementKeepsOriginalBytesAndTheVerifiedBackup() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.initial()
        try fixture.store.append(.upsertSegment(segment()))
        let prefix = try Data(contentsOf: fixture.journalURL)
        var original = prefix
        original.append(Data("{\"schemaVersion\":1,".utf8))
        try original.write(to: fixture.journalURL)
        let failing = SessionStore(directory: fixture.root, atomicWrite: { bytes, destination in
            if destination.lastPathComponent == SessionStore.journalFileName { throw Fault.injected }
            try SessionArchiveCoding.atomicWrite(bytes, destination)
        })
        #expect(throws: Fault.self) { try failing.preserveIncompleteTailAndResume() }
        #expect(try Data(contentsOf: fixture.journalURL) == original)
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("session-journal.incomplete-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == original)
        let preserved = try #require(try fixture.store.preserveIncompleteTailAndResume())
        #expect(try Data(contentsOf: preserved) == original)
        #expect(try Data(contentsOf: fixture.journalURL) == prefix)
    }

    @Test func garbageMiddleCorruptionSequenceGapsAndFutureRowsAreNeverDiscarded() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.initial()
        try fixture.store.append(.upsertSegment(segment()))
        let first = try Data(contentsOf: fixture.journalURL)
        try fixture.store.append(.processing(.init()))
        let valid = try Data(contentsOf: fixture.journalURL)
        let last = Data(valid.dropFirst(first.count).dropLast())
        for invalidTail in [Data("garbage".utf8), Data("{\"sequence\":oops".utf8), Data("{}".utf8), Data("\n".utf8)] {
            var invalid = first; invalid.append(invalidTail)
            try invalid.write(to: fixture.journalURL)
            #expect(throws: SessionStoreError.self) { try fixture.store.load() }
            #expect(throws: SessionStoreError.self) { try fixture.store.preserveIncompleteTailAndResume() }
            #expect(try Data(contentsOf: fixture.journalURL) == invalid)
        }
        var gap = first
        gap.append(try rewritingRow(last, sequence: 3)); gap.append(10)
        try gap.write(to: fixture.journalURL)
        #expect(throws: SessionStoreError.sequenceMismatch(expected: 2, found: 3)) { try fixture.store.load() }
        var future = first
        future.append(try rewritingRow(last, version: 999))
        try future.write(to: fixture.journalURL)
        #expect(throws: SessionStoreError.unsupportedSchema(999)) { try fixture.store.load() }
        var middle = Data("{}\n".utf8); middle.append(last); middle.append(10)
        try middle.write(to: fixture.journalURL)
        #expect(throws: SessionStoreError.corruptJournal(line: 1)) { try fixture.store.load() }
        #expect(try Data(contentsOf: fixture.journalURL) == middle)
    }

    @Test func checkpointDoesNotHideCorruptionInAlreadyAppliedRows() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.initial()
        let appended = try fixture.store.append(.upsertSegment(segment()))
        try fixture.store.save(appended)
        let good = try Data(contentsOf: fixture.journalURL)
        var row = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])
        row["checksum"] = String(repeating: "0", count: 64)
        var bad = try JSONSerialization.data(withJSONObject: row); bad.append(10)
        try bad.write(to: fixture.journalURL)
        #expect(throws: SessionStoreError.corruptJournal(line: 1)) { try fixture.store.load() }
        try good.write(to: fixture.journalURL)
        try FileManager.default.moveItem(at: fixture.journalURL, to: fixture.root.appendingPathComponent("retained-journal.jsonl"))
        #expect(throws: SessionStoreError.corruptSnapshot) { try fixture.store.load() }
    }

    @Test func legacyMigrationIsExplicitAndKeepsUnknownProvenance() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let old = segment(chinese: "速度为 30 m/s。")
        let jsonl = fixture.root.appendingPathComponent("bilingual.jsonl")
        let md = fixture.root.appendingPathComponent("summary-zh-Hans.md")
        let original = try SessionArchiveCoding.encode(old)
        try original.write(to: jsonl)
        try Data("## 原文\n保留所有旧内容。\n".utf8).write(to: md)
        let store = fixture.store
        let legacy = try #require(try store.loadDetailed().snapshot)
        try store.save(legacy)
        let reopened = try store.loadDetailed()
        #expect(reopened.origin == .snapshot)
        #expect(reopened.snapshot?.sessionID == legacy.sessionID)
        #expect(reopened.snapshot?.batches == [])
        #expect(reopened.snapshot?.legacyMarkdown == legacy.legacyMarkdown)
        #expect(try Data(contentsOf: jsonl) == original)
        #expect(try String(contentsOf: md, encoding: .utf8) == legacy.legacyMarkdown)
    }

    @Test func legacyTruncationAndDuplicateIDsProduceErrorsWithoutChanges() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let url = fixture.root.appendingPathComponent("bilingual.jsonl")
        let valid = try SessionArchiveCoding.encode(segment())
        var bad = valid; bad.append(10); bad.append(Data("{\"id\":".utf8))
        try bad.write(to: url)
        #expect(throws: SessionStoreError.corruptJournal(line: 2)) { try fixture.store.load() }
        #expect(try Data(contentsOf: url) == bad)
        var duplicate = valid; duplicate.append(10); duplicate.append(valid); duplicate.append(10)
        try duplicate.write(to: url)
        #expect(throws: SessionStoreError.self) { try fixture.store.load() }
        try Data("\n".utf8).write(to: url)
        #expect(try fixture.store.load()?.segments == [])
    }

    @Test func copiedIdentityAcceptsExactCopyAndRejectsDivergentContentOrBookmark() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let source = fixture.root.appendingPathComponent("original", isDirectory: true)
        let duplicate = fixture.root.appendingPathComponent("copy", isDirectory: true)
        try SessionStore(directory: source).save(SessionSnapshot(segments: [segment()]))
        try FileManager.default.copyItem(at: source, to: duplicate)
        let original = try SessionDirectoryIdentity.resolve(directory: source)
        let copied = try SessionDirectoryIdentity.resolve(directory: duplicate)
        try original.assertCompatible(with: copied)
        try SessionStore(directory: duplicate).append(.upsertSegment(segment(english: "Different new evidence.")))
        let divergent = try SessionDirectoryIdentity.resolve(directory: duplicate)
        #expect(throws: SessionStoreError.self) { try original.assertCompatible(with: divergent) }
        let bookmark = try source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #expect(throws: SessionStoreError.self) { try SessionDirectoryIdentity.resolve(directory: duplicate, bookmark: bookmark) }
        let resolved = try SessionDirectoryIdentity.resolve(directory: source, bookmark: bookmark)
        #expect(resolved.sessionID == original.sessionID)
    }

    @Test func unsafePathsAndFutureInputBindingsCannotBeSaved() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        for path in ["../other.wav", "/tmp/other.wav", "audio//recording.wav", "audio/./recording.wav"] {
            var value = SessionSnapshot()
            value.audioFiles = [.init(relativePath: path)]
            #expect(throws: SessionStoreError.self) { try fixture.store.save(value) }
        }
        var value = SessionSnapshot(segments: [segment()])
        var invalid = checkpoint(for: value)
        invalid.inputRevision = 1
        value.generationCheckpoints = [invalid]
        #expect(throws: SessionStoreError.self) { try fixture.store.save(value) }
    }

    @Test func concurrentInstancesSerializeJournalAppends() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.initial()
        let values = (0..<24).map { segment(english: "Synthetic item \($0).") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in values {
                let directory = fixture.root
                group.addTask { try SessionStore(directory: directory).append(.upsertSegment(value)) }
            }
            try await group.waitForAll()
        }
        let loaded = try #require(try fixture.store.load())
        #expect(Set(loaded.segments.map(\.id)) == Set(values.map(\.id)))
        #expect(loaded.lastJournalSequence == values.count)
        #expect(loaded.storageRevision == values.count + 1)
    }
}
