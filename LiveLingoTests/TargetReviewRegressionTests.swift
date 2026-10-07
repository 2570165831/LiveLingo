import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class TargetReviewRegressionTests: XCTestCase {
    private final class ObservedDefaults: UserDefaults, @unchecked Sendable {
        var outputReads = 0
        override func string(forKey key: String) -> String? {
            if key == "LiveLingo.outputLanguage" { outputReads += 1 }
            return super.string(forKey: key)
        }
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TargetReview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func files(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    private func queueFixture(_ root: URL, target: String? = nil) throws
        -> (URL, LearningReviewQueue.Journal) {
        let directory = root.appendingPathComponent("course")
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Heat increases.", chinese: "热量增加。")
        let batch = LearningNoteBatch(id: UUID(), evidence: [segment], note: LearningNote(topic: "Heat",
            points: [.init(kind: "核心结论", text: "热量增加。")]))
        let snapshot = try SessionStore(directory: directory).save(SessionSnapshot(segments: [segment],
            batches: [batch], createdAt: Date(timeIntervalSince1970: 1_000), targetLocale: target))
        var job = LearningReviewQueue.Job(directory: directory, batches: [batch], original: "Frozen notes.",
            prefix: "Frozen unfinished prefix.", prompt: "Frozen original prompt.",
            prefixInputDigest: "original-binding", retryPending: .init(attempts: 1,
                notBefore: Date().timeIntervalSince1970 + 3_600, code: "requestTimedOut"),
            awaitingManualStart: true,
            identity: try ReviewIdentity(sessionID: snapshot.sessionID, scope: .wholeLesson, inputRevision: 0),
            inputDigest: try ReviewInputBinding.digest([batch]))
        var retired = job
        retired.id = UUID()
        retired.supersededByRevision = 1
        // A nil target is exactly the old v3 job shape, including the retired
        // task that previously let a directory read abort the whole journal.
        job.targetLocale = target
        retired.targetLocale = target
        return (directory, .init(jobs: [job], userPaused: true, version: 3, retiredJobs: [retired]))
    }

    private func assertUnavailableCoursePreservesV3(_ kind: String) async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (directory, journal) = try queueFixture(root)
        switch kind {
        case "tail":
            try Data(#"{"unfinished":"#.utf8).write(to: directory.appendingPathComponent(SessionStore.journalFileName))
            XCTAssertThrowsError(try ReviewInputBinding.snapshot(in: directory)) { error in
                guard case SessionStoreError.incompleteJournalTail = error else {
                    return XCTFail("Expected an incomplete tail, got \(error)")
                }
            }
        case "snapshot":
            try Data("damaged snapshot".utf8).write(to: directory.appendingPathComponent(SessionStore.snapshotFileName))
            XCTAssertThrowsError(try ReviewInputBinding.snapshot(in: directory))
        default: break
        }
        let url = root.appendingPathComponent("queue.json")
        let bytes = try encode(journal)
        try bytes.write(to: url)
        let before = try files(directory)
        var reads = 0
        let queue = LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
            generate: { _, _, _, _, _ in XCTFail("Startup must not generate"); throw CancellationError() },
            startupSnapshotReader: { directory in
                reads += 1
                if kind == "permission" { throw POSIXError(.EPERM) }
                return try ReviewInputBinding.snapshot(in: directory)
            })
        await queue.shutdownForTesting()
        XCTAssertEqual(reads, 2, "Both current and retired nil-target jobs are best-effort reads")
        XCTAssertTrue(queue.userPaused)
        XCTAssertFalse(queue.running)
        XCTAssertEqual(try encode(queue.journalForTesting), bytes, "In-memory task state must also be unchanged")
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Do not rewrite a valid old v3 journal")
        XCTAssertEqual(try files(directory), before, "Do not repair course files during queue startup")
        XCTAssertFalse(queue.status.contains("读取失败"))
    }

    func testPermissionDeniedCoursePreservesCurrentAndRetiredV3Jobs() async throws {
        try await assertUnavailableCoursePreservesV3("permission")
    }
    func testIncompleteCourseJournalPreservesCurrentAndRetiredV3Jobs() async throws {
        try await assertUnavailableCoursePreservesV3("tail")
    }
    func testCorruptCourseSnapshotPreservesCurrentAndRetiredV3Jobs() async throws {
        try await assertUnavailableCoursePreservesV3("snapshot")
    }

    func testInvisibleBookmarkedCoursePreservesV3StateWithoutReading() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var (_, journal) = try queueFixture(root)
        let inaccessible = root.appendingPathComponent("not-accessible")
        journal.jobs[0].directory = inaccessible
        journal.jobs[0].directoryBookmark = Data("synthetic-bookmark-not-resolved-at-startup".utf8)
        journal.retiredJobs?[0].directory = inaccessible
        journal.retiredJobs?[0].directoryBookmark = journal.jobs[0].directoryBookmark
        let url = root.appendingPathComponent("queue.json")
        let bytes = try encode(journal); try bytes.write(to: url)
        let queue = LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
            startupSnapshotReader: { _ in XCTFail("An invisible course must not be opened"); throw POSIXError(.EPERM) })
        await queue.shutdownForTesting()
        XCTAssertEqual(try encode(queue.journalForTesting), bytes)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testStampedJobsDoNotReadCourseDuringTargetUpgrade() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var (_, journal) = try queueFixture(root, target: "en")
        journal.jobs[0].next = 1
        journal.jobs[0].reports = ["Frozen report."]
        journal.jobs[0].prefix = ""
        journal.jobs[0].prefixInputDigest = nil
        let url = root.appendingPathComponent("queue.json")
        let bytes = try encode(journal); try bytes.write(to: url)
        let queue = LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
            startupSnapshotReader: { _ in XCTFail("Stamped, bound jobs must not read a course"); throw POSIXError(.EPERM) })
        await queue.shutdownForTesting()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(queue.userPaused)
        XCTAssertFalse(queue.status.contains("读取失败"))
    }

    func testUnavailableTargetDoesNotSkipManualStartOrIdentityValidation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var (_, journal) = try queueFixture(root)
        journal.version = nil
        journal.jobs[0].identity = nil
        journal.jobs[0].awaitingManualStart = nil
        let url = root.appendingPathComponent("queue.json")
        try encode(journal).write(to: url)
        let queue = LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
            startupSnapshotReader: { _ in throw POSIXError(.EPERM) })
        await queue.shutdownForTesting()
        let restored = try XCTUnwrap(queue.journalForTesting.jobs.first)
        XCTAssertEqual(restored.awaitingManualStart, true)
        XCTAssertEqual(restored.prefix, journal.jobs[0].prefix)
        XCTAssertEqual(restored.prompt, journal.jobs[0].prompt)
        XCTAssertEqual(restored.retryPending, journal.jobs[0].retryPending)
        XCTAssertNil(restored.failure)
        XCTAssertNil(restored.identity)
        XCTAssertFalse(queue.status.contains("读取失败"))
    }

    func testDeferredTargetResolvesBeforeRuntimeValidationAndNeverUsesWrongPrompt() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var (_, journal) = try queueFixture(root, target: "en")
        journal.jobs[0].targetLocale = nil
        journal.retiredJobs = nil
        let url = root.appendingPathComponent("queue.json")
        try encode(journal).write(to: url)
        var calls = 0
        let queue = LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
            generate: { _, _, _, _, _ in calls += 1; throw CancellationError() },
            startupSnapshotReader: { _ in throw POSIXError(.EPERM) })
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        queue.performPrimaryAction()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while queue.journalForTesting.jobs.first?.failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await queue.shutdownForTesting()
        let restored = try XCTUnwrap(queue.journalForTesting.jobs.first)
        XCTAssertEqual(restored.targetLocale, "en")
        XCTAssertEqual(restored.prompt, journal.jobs[0].prompt)
        XCTAssertEqual(restored.prefix, journal.jobs[0].prefix)
        XCTAssertNotNil(restored.failure)
        XCTAssertEqual(calls, 0)
    }

    private func modelFixture() throws -> (AppModel, URL, ObservedDefaults) {
        let root = try root()
        let suite = "ClassroomPresentation-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(ObservedDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("These tests must not call a model"); throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            try await model.flushSavedCourseForTesting()
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove(defaults)
            try FileManager.default.removeItem(at: root)
        }
        return (model, root, defaults)
    }

    func testSnapshotNilTargetIgnoresDerivedManifestWhileOpening() async throws {
        let (model, root, defaults) = try modelFixture()
        for (index, metadata) in [#"{"targetLocale":"zh-Hant"}"#, #"{"targetLocale":"fr"}"#,
                                 #"{"targetLocale":"unknown"}"#, "damaged manifest"].enumerated() {
            let directory = root.appendingPathComponent("course-\(index)")
            try SessionStore(directory: directory).save(SessionSnapshot())
            try Data(metadata.utf8).write(to: directory.appendingPathComponent("manifest.json"))
            try await model.openSavedSession(directory, allowAutomaticProcessing: false)
            XCTAssertEqual(model.outputLanguage, .simplifiedChinese)
            XCTAssertEqual(try SessionStore(directory: directory).load()?.targetLocale, nil)
        }
        XCTAssertEqual(defaults.outputReads, 0)
    }

    func testLegacyTraditionalAndUndecodableManifestOpenWithSupportedTarget() async throws {
        let (model, root, defaults) = try modelFixture()
        for (index, metadata) in [#"{"targetLocale":"zh-Hant"}"#, "damaged manifest"].enumerated() {
            let directory = root.appendingPathComponent("legacy-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(metadata.utf8).write(to: directory.appendingPathComponent("manifest.json"))
            try Data("Frozen legacy notes.\n".utf8).write(to: directory.appendingPathComponent("summary-zh-Hans.md"))
            try await model.openSavedSession(directory, allowAutomaticProcessing: false)
            XCTAssertEqual(model.outputLanguage, .simplifiedChinese)
            XCTAssertTrue(model.lectureSummary.contains("Frozen legacy notes."))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(SessionStore.snapshotFileName).path))
        }
        XCTAssertEqual(defaults.outputReads, 0)
    }

    func testUnsupportedTargetIsRejectedBeforeParkingOrTailPreservation() async throws {
        let (model, root, _) = try modelFixture()
        let current = root.appendingPathComponent("current")
        try SessionStore(directory: current).save(SessionSnapshot())
        try await model.openSavedSession(current, allowAutomaticProcessing: false)
        try await model.flushSavedCourseForTesting()
        let incoming = root.appendingPathComponent("incoming")
        try SessionStore(directory: incoming).save(SessionSnapshot(targetLocale: "en"))
        try Data(#"{"unfinished":"#.utf8).write(to: incoming.appendingPathComponent(SessionStore.journalFileName))
        let currentBefore = try files(current), incomingBefore = try files(incoming)
        do {
            try await model.openSavedSession(incoming, allowAutomaticProcessing: false)
            XCTFail("An unavailable generation target must be rejected")
        } catch let error as SessionStoreError {
            guard case .invalidState = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try files(current), currentBefore)
        XCTAssertEqual(try files(incoming), incomingBefore)
        guard case .saved(let opened) = model.phase else { return XCTFail("The original course must remain displayed") }
        XCTAssertEqual(opened, current)
    }

    func testPreferenceChangeAfterCreationDoesNotChangeCourseOrExports() async throws {
        let (model, root, defaults) = try modelFixture()
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .english])
        for (index, target) in [OutputLanguage.simplifiedChinese, .english].enumerated() {
            defaults.set(target.rawValue, forKey: "LiveLingo.outputLanguage")
            let directory = root.appendingPathComponent("created-\(index)")
            let readsBefore = defaults.outputReads
            try await model.beginSavedCourseForTesting(directory: directory)
            XCTAssertEqual(defaults.outputReads, readsBefore + 1)
            XCTAssertEqual(model.outputLanguage, target, "The test release injection must select a non-default value")
            let initial = try XCTUnwrap(SessionStore(directory: directory).load())
            let identity = try SessionDirectoryIdentity.resolve(directory: directory)
            defaults.outputReads = 0
            defaults.set(target == .english ? "zh-Hans" : "en", forKey: "LiveLingo.outputLanguage")
            await model.stopSavedCourseForTesting()
            try await model.flushSavedCourseForTesting()
            XCTAssertNil(model.archiveError)
            let saved = try XCTUnwrap(SessionStore(directory: directory).load())
            XCTAssertEqual(saved.targetLocale, initial.targetLocale)
            XCTAssertEqual(saved.effectiveTargetLocale, target.rawValue)
            XCTAssertEqual(try SessionDirectoryIdentity.resolve(directory: directory), identity)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(SessionExporter.Manifest.self,
                from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            XCTAssertEqual(manifest.targetLocale, target.rawValue)
            XCTAssertEqual(SessionExporter.savedSummaryURL(in: directory, targetLocale: saved.targetLocale).lastPathComponent,
                SessionExporter.targetSummaryFileName(for: target.rawValue))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
                SessionExporter.targetTranscriptFileName(for: target.rawValue)).path))
            XCTAssertEqual(defaults.outputReads, 0, "Stopping and exporting an existing course must not reread preferences")
        }
    }

    func testEnglishPassThroughExportsOneLineEvenWhenBodiesDiffer() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Air  is clear.", chinese: "Air is clear.")
        try SessionExporter.export(segments: [segment], sessionDirectory: root, target: .english)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("bilingual.srt"), encoding: .utf8),
            "1\n00:00:00,000 --> 00:00:01,000\nAir is clear.\n")
        let notes = NotesExportSnapshot(className: "Synthetic", sessionName: nil, scope: .wholeLesson,
            scopeDetail: "", coverageLine: "", notesMarkdown: "", reviewMarkdown: nil,
            transcript: [segment], generatedAt: Date(timeIntervalSince1970: 0), includesReviewAdvice: false,
            includesTranscript: true, target: .english)
        for text in [NotesExportDocument.plainText(notes), NotesExportDocument.markdown(notes)] {
            XCTAssertFalse(text.contains(segment.english))
            XCTAssertTrue(text.contains("Air is clear."))
        }
    }

    func testOutputLanguageCaptionRowsMatchFrozenDefaultTable() {
        let cases: [(String?, String, String, String?, Bool, String)] = [
            (nil, "A bell rings.", "铃响了。", nil, false, "A bell rings."),
            ("en", "A bell rings.", "铃响了。", nil, false, "A bell rings."),
            ("zh", "葉子長大了。", "", "中文", true, "叶子长大了。"),
            ("zh", "葉子長大了。", "已保存的中文。", "中文", true, "已保存的中文。"),
            ("yue", "塊葉長大咗。", "叶子长大了。", "粤语", false, "塊葉長大咗。"),
            ("ja", "葉が大きくなります。", "叶子长大了。", "日语", false, "葉が大きくなります。"),
            ("es", "La hoja crece.", "", "西班牙语", false, "La hoja crece.")
        ]
        for (language, source, translated, name, sourceOnly, primary) in cases {
            let segment = TranscriptSegment(startTime: 0, endTime: 1, english: source,
                chinese: translated, sourceLanguage: language)
            let row = CaptionPresentation(segment, outputLanguage: .simplifiedChinese)
            XCTAssertEqual(row, CaptionPresentation(segment))
            XCTAssertEqual(row.languageName, name)
            XCTAssertEqual(row.isSourceOnly, sourceOnly)
            XCTAssertEqual(row.primaryText, primary)
        }
    }
}
