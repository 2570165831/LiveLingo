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
