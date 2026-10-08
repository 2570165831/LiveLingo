import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class OutputLanguageSelectionTests: XCTestCase {
    private func fixture() throws -> (AppModel, UserDefaults, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LanguageSelection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "LiveLingo-Test-" + UUID().uuidString
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Selecting a display language must never start a model")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await model.chineseDisplayPreparationForTesting?.value
            await queue.shutdownForTesting()
            try cleanup.remove()
            try FileManager.default.removeItem(at: root)
        }
        return (model, defaults, root)
    }

    func testSingleReleasedLanguageHidesSelectorAndAutonymsAreExact() throws {
        let (model, _, _) = try fixture()
        XCTAssertEqual(model.outputLanguageChoices, [.simplifiedChinese])
        XCTAssertFalse(model.showsOutputLanguageSelector)
        XCTAssertEqual(OutputLanguage.allCases.map { $0.profile.autonym },
            ["简体中文", "繁體中文（中國台灣）", "繁體中文（中國港澳）", "English", "Español", "Français"])
        XCTAssertFalse(OutputLanguage.traditionalChineseTaiwan.isReleased)
        XCTAssertFalse(OutputLanguage.traditionalChineseHongKong.isReleased)
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
        XCTAssertTrue(model.showsOutputLanguageSelector)
        XCTAssertEqual(model.outputLanguageChoices, [.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
    }

    func testAbsentOrUnreleasedPreferenceReturnsHansWithoutWriting() throws {
        let (model, defaults, _) = try fixture()
        XCTAssertNil(defaults.object(forKey: "LiveLingo.outputLanguage"))
        XCTAssertEqual(model.newCourseOutputLanguagePreference, .simplifiedChinese)
        XCTAssertNil(defaults.object(forKey: "LiveLingo.outputLanguage"))
        defaults.set("zh-Hant-TW", forKey: "LiveLingo.outputLanguage")
        XCTAssertEqual(model.newCourseOutputLanguagePreference, .simplifiedChinese)
        model.newCourseOutputLanguagePreference = .traditionalChineseHongKong
        XCTAssertEqual(defaults.string(forKey: "LiveLingo.outputLanguage"), "zh-Hant-TW",
                       "The GUI must not write an unreleased language")
    }

    func testPreferenceChangesOnlyTheNextCourseAndBusySelectionIsBlocked() async throws {
        let (model, defaults, root) = try fixture()
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
        let first = root.appendingPathComponent("first")
        try await model.beginSavedCourseForTesting(directory: first)
        let snapshotURL = first.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: snapshotURL)
        XCTAssertNil(try XCTUnwrap(SessionStore(directory: first).load()).targetLocale)
        XCTAssertTrue(model.outputLanguageSelectionDisabled)
        model.newCourseOutputLanguagePreference = .traditionalChineseTaiwan
        XCTAssertNil(defaults.object(forKey: "LiveLingo.outputLanguage"))
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        XCTAssertFalse(model.outputLanguageSelectionDisabled)
        model.newCourseOutputLanguagePreference = .traditionalChineseTaiwan
        XCTAssertEqual(defaults.string(forKey: "LiveLingo.outputLanguage"), "zh-Hant-TW")
        XCTAssertEqual(model.outputLanguage, .simplifiedChinese)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), bytes)
        let second = root.appendingPathComponent("second")
        try await model.beginSavedCourseForTesting(directory: second)
        XCTAssertEqual(try XCTUnwrap(SessionStore(directory: second).load()).targetLocale, "zh-Hant-TW")
        XCTAssertEqual(model.outputLanguage, .traditionalChineseTaiwan)
        XCTAssertEqual(model.captionTarget, .simplifiedChinese)
        // Starting another course normally finalizes the prior course's state.
        // Its stamped language still stays independent of the new preference;
        // the exact byte check above covers the preference change itself.
        XCTAssertNil(try XCTUnwrap(SessionStore(directory: first).load()).targetLocale)
    }

    func testSavedLanguageLabelUsesTheCourseAndNeverTheCreationPreference() async throws {
        let (model, defaults, root) = try fixture()
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
        defaults.set("zh-Hant-HK", forKey: "LiveLingo.outputLanguage")
        let stamped = root.appendingPathComponent("stamped")
        try SessionStore(directory: stamped).save(SessionSnapshot(createdAt: Date(timeIntervalSince1970: 1_000),
            targetLocale: "zh-Hant-TW"))
        try await model.openSavedSession(stamped, allowAutomaticProcessing: false)
        XCTAssertEqual(model.savedOutputLanguageLabel, "输出语言：繁體中文（中國台灣）")
        XCTAssertEqual(model.newCourseOutputLanguagePreference, .traditionalChineseHongKong)
        let old = root.appendingPathComponent("old")
        try SessionStore(directory: old).save(SessionSnapshot(createdAt: Date(timeIntervalSince1970: 1_000)))
        try await model.openSavedSession(old, allowAutomaticProcessing: false)
        XCTAssertEqual(model.outputLanguage, .simplifiedChinese)
        XCTAssertNil(model.savedOutputLanguageLabel)
        XCTAssertEqual(defaults.string(forKey: "LiveLingo.outputLanguage"), "zh-Hant-HK")
    }

    func testChineseDisplaySwitchPreservesSnapshotAndDoesNotChangeGeneration() async throws {
        let (model, defaults, root) = try fixture()
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
        defaults.set("zh-Hant-TW", forKey: "LiveLingo.outputLanguage")
        let directory = root.appendingPathComponent("course")
        try await model.beginSavedCourseForTesting(directory: directory)
        await model.chineseDisplayPreparationForTesting?.value
        let snapshotURL = directory.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: snapshotURL)
        XCTAssertTrue(model.setChineseDisplayLanguage(.traditionalChineseHongKong))
        await model.chineseDisplayPreparationForTesting?.value
        XCTAssertEqual(model.chineseReadingLanguage, .traditionalChineseHongKong)
        XCTAssertEqual(model.captionDisplayLanguage, .traditionalChineseHongKong)
        XCTAssertEqual(model.outputLanguage, .traditionalChineseTaiwan)
        XCTAssertEqual(model.captionTarget, .simplifiedChinese)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), bytes)
        XCTAssertEqual(try XCTUnwrap(SessionStore(directory: directory).load()).targetLocale, "zh-Hant-TW")
        XCTAssertFalse(model.setChineseDisplayLanguage(.english))
        XCTAssertEqual(model.chineseReadingLanguage, .traditionalChineseHongKong)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.beginSavedCourseForTesting(directory: root.appendingPathComponent("next"))
        XCTAssertEqual(model.chineseReadingLanguage, .traditionalChineseTaiwan,
                       "A view-only override must not carry into another course")
    }

    func testReadingHansKeepsEvidenceForTheStampedTraditionalExport() async throws {
        let (model, _, _) = try fixture()
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
        let segment = TranscriptSegment(startTime: 0, endTime: 1,
            english: "Synthetic original — source field", chinese: "头发 — 在这里。")
        var notebook = LearningNotebook()
        try notebook.append(evidence: [segment], note: .init(topic: "合成笔记", points: [
            .init(kind: "核心结论", text: "头发在这里。", sourceIDs: ["en0s0"])
        ], sourceVersion: 2))
        model.loadPresentationForTesting(phase: .idle, evidence: [segment], notebook: notebook,
            outputLanguage: .traditionalChineseTaiwan)
        await model.chineseDisplayPreparationForTesting?.value
        model.exportIncludesReviewAdvice = false
        model.exportIncludesTranscript = false
        XCTAssertTrue(model.setChineseDisplayLanguage(.simplifiedChinese))
        XCTAssertEqual(model.captionDisplayLanguage, .simplifiedChinese)
        let snapshot = try XCTUnwrap(model.notesExportSnapshot())
        XCTAssertEqual(snapshot.target, .traditionalChineseTaiwan)
        XCTAssertFalse(snapshot.includesTranscript)
        XCTAssertTrue(snapshot.scheduleEvidence.contains { $0.id == segment.id && $0.english == segment.english })
        XCTAssertEqual(model.notesScheduleEvidence.count, 2,
                       "Both frozen notebook evidence and current captions must survive a reading-only override")
    }

    func testProductionReleaseGateCannotEnableTraditionalDisplay() throws {
        let (model, _, _) = try fixture()
        XCTAssertFalse(model.setChineseDisplayLanguage(.traditionalChineseTaiwan))
        XCTAssertEqual(model.chineseReadingLanguage, .simplifiedChinese)
        XCTAssertFalse(model.showsChineseReadingSelector)
    }

    func testProductionReleaseGateRejectsTaiwanSnapshotWithoutReplacingCourse() async throws {
        try await assertUnreleasedCourseIsRejected(.traditionalChineseTaiwan, legacyManifest: false)
    }

    func testProductionReleaseGateRejectsHongKongSnapshotWithoutReplacingCourse() async throws {
        try await assertUnreleasedCourseIsRejected(.traditionalChineseHongKong, legacyManifest: false)
    }

    func testProductionReleaseGateRejectsTaiwanLegacyManifestWithoutReplacingCourse() async throws {
        try await assertUnreleasedCourseIsRejected(.traditionalChineseTaiwan, legacyManifest: true)
    }

    func testProductionReleaseGateRejectsHongKongLegacyManifestWithoutReplacingCourse() async throws {
        try await assertUnreleasedCourseIsRejected(.traditionalChineseHongKong, legacyManifest: true)
    }

    private func assertUnreleasedCourseIsRejected(_ language: OutputLanguage, legacyManifest: Bool,
                                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let (model, defaults, root) = try fixture()
        // Use the production release list, without the test-only language injection.
        XCTAssertEqual(model.outputLanguageChoices, [.simplifiedChinese], file: file, line: line)
        XCTAssertFalse(language.isReleased, file: file, line: line)

        let currentDirectory = root.appendingPathComponent("current")
        let currentID = UUID()
        let currentSegment = TranscriptSegment(startTime: 0, endTime: 1,
            english: "Synthetic current course must remain open.", chinese: "合成当前课程必须保留。",
            sessionID: currentID)
        var notebook = LearningNotebook()
        try notebook.append(evidence: [currentSegment], note: .init(topic: "合成当前课程", points: [
            .init(kind: "核心结论", text: "当前字幕与笔记必须保留。", sourceIDs: ["en0s0"])
        ], sourceVersion: 2))
        var currentSnapshot = SessionSnapshot(sessionID: currentID, segments: [currentSegment],
            processing: .init(phase: .completed), createdAt: Date(timeIntervalSince1970: 1_000))
        notebook.writeState(to: &currentSnapshot)
        try SessionStore(directory: currentDirectory).save(currentSnapshot)
        try await model.openSavedSession(currentDirectory, allowAutomaticProcessing: false)
        try await model.flushSavedCourseForTesting()
        let currentFiles = try savedCourseFileBytes(in: currentDirectory)
        let currentPhase = model.phase
        let currentSegments = model.segments
        let currentBatches = model.learningNotebookForTesting.batches
        let currentSummary = model.lectureSummary
        let currentLatestSummary = model.latestSummaryUpdate
        let currentNotice = model.archiveNotice
        let currentReview = model.reviewAdvice

        let unopenedDirectory = root.appendingPathComponent("unreleased")
        let unopenedSegment = TranscriptSegment(startTime: 2, endTime: 3,
            english: "Synthetic unreleased course must not replace the current course.", chinese: "合成未开放课程。",
            sessionID: UUID())
        let targetSummary = "## 合成未開放課程\n原檔必須保留。\n"
        if legacyManifest {
            try FileManager.default.createDirectory(at: unopenedDirectory, withIntermediateDirectories: true)
            try Data("{\"targetLocale\":\"\(language.rawValue)\"}\n".utf8)
                .write(to: unopenedDirectory.appendingPathComponent("manifest.json"))
            var jsonl = try SessionArchiveCoding.encode(unopenedSegment)
            jsonl.append(Data("\n".utf8))
            try jsonl.write(to: unopenedDirectory.appendingPathComponent("bilingual.jsonl"))
            try Data(targetSummary.utf8)
                .write(to: unopenedDirectory.appendingPathComponent("summary-\(language.rawValue).md"))
        } else {
            try SessionStore(directory: unopenedDirectory).save(SessionSnapshot(
                sessionID: try XCTUnwrap(unopenedSegment.sessionID), segments: [unopenedSegment],
                legacyMarkdown: targetSummary, processing: .init(phase: .completed),
                createdAt: Date(timeIntervalSince1970: 2_000), targetLocale: language.rawValue))
        }
        let unopenedStore = SessionStore(directory: unopenedDirectory)
        let loaded = try unopenedStore.loadDetailed()
        XCTAssertEqual(loaded.origin, legacyManifest ? .legacy : .snapshot, file: file, line: line)
        let unopenedSnapshot = try XCTUnwrap(loaded.snapshot, file: file, line: line)
        XCTAssertEqual(try OutputLanguage.savedLanguage(in: unopenedDirectory, snapshot: unopenedSnapshot,
            origin: loaded.origin), language, file: file, line: line)
        let unopenedFiles = try savedCourseFileBytes(in: unopenedDirectory)

        do {
            try await model.openSavedSession(unopenedDirectory, allowAutomaticProcessing: false)
            XCTFail("The ordinary GUI restore route accepted an unreleased language", file: file, line: line)
        } catch SessionStoreError.invalidState(let message) {
            XCTAssertTrue(message.contains("尚未开放"), file: file, line: line)
            XCTAssertTrue(message.contains(language.profile.autonym), file: file, line: line)
        } catch {
            XCTFail("Expected a clear unreleased-language error, got \(error)", file: file, line: line)
        }

        XCTAssertEqual(model.phase, currentPhase, file: file, line: line)
        XCTAssertEqual(model.captureHealthSessionIDForTesting, currentID, file: file, line: line)
        XCTAssertEqual(model.reviewDisplayDirectory, currentDirectory, file: file, line: line)
        XCTAssertEqual(model.segments, currentSegments, file: file, line: line)
        XCTAssertEqual(model.learningNotebookForTesting.batches, currentBatches, file: file, line: line)
        XCTAssertEqual(model.lectureSummary, currentSummary, file: file, line: line)
        XCTAssertEqual(model.latestSummaryUpdate, currentLatestSummary, file: file, line: line)
        XCTAssertEqual(model.archiveNotice, currentNotice, file: file, line: line)
        XCTAssertEqual(model.reviewAdvice, currentReview, file: file, line: line)
        XCTAssertEqual(model.outputLanguage, .simplifiedChinese, file: file, line: line)
        XCTAssertEqual(model.captionTarget, .simplifiedChinese, file: file, line: line)
        XCTAssertEqual(model.chineseReadingLanguage, .simplifiedChinese, file: file, line: line)
        XCTAssertEqual(model.captionDisplayLanguage, .simplifiedChinese, file: file, line: line)
        XCTAssertNil(model.chineseDisplayPreparationForTesting, file: file, line: line)
        XCTAssertFalse(model.archiveLoading, file: file, line: line)
        XCTAssertNil(defaults.object(forKey: "LiveLingo.outputLanguage"), file: file, line: line)
        XCTAssertEqual(try savedCourseFileBytes(in: currentDirectory), currentFiles, file: file, line: line)
        XCTAssertEqual(try savedCourseFileBytes(in: unopenedDirectory), unopenedFiles, file: file, line: line)
        XCTAssertEqual(try unopenedStore.loadDetailed().snapshot, unopenedSnapshot, file: file, line: line)
        XCTAssertEqual(FileManager.default.fileExists(atPath: unopenedDirectory
            .appendingPathComponent(SessionStore.snapshotFileName).path), !legacyManifest, file: file, line: line)
    }

    private func savedCourseFileBytes(in directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    func testLegacyRenderedNotesDoNotPermitASecondRegionalConversion() async throws {
        let (model, _, root) = try fixture()
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
        let directory = root.appendingPathComponent("legacy")
        var snapshot = SessionSnapshot(createdAt: Date(timeIntervalSince1970: 1_000), targetLocale: "zh-Hant-TW")
        snapshot.legacyMarkdown = "## 學習筆記\n頭髮在這裏。"
        try SessionStore(directory: directory).save(snapshot)
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertTrue(model.summaryIsLegacyRendered)
        XCTAssertFalse(model.showsChineseReadingSelector)
        XCTAssertFalse(model.setChineseDisplayLanguage(.traditionalChineseHongKong))
        XCTAssertEqual(model.lectureSummary, snapshot.legacyMarkdown)
    }
}
