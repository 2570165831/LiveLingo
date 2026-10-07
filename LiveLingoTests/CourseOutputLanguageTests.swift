import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class CourseOutputLanguageTests: XCTestCase {
    private final class ObservedDefaults: UserDefaults, @unchecked Sendable {
        var outputReads = 0
        override func string(forKey key: String) -> String? {
            if key == "LiveLingo.outputLanguage" {
                outputReads += 1
                return "en"
            }
            return super.string(forKey: key)
        }
    }

    func testOpeningOldAndStampedCoursesNeverReadsPreference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CourseOutputLanguage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ClassroomPresentation-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(ObservedDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("Opening a course must not call a model")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove(defaults)
            try FileManager.default.removeItem(at: root)
        }
        let old = root.appendingPathComponent("old")
        try SessionStore(directory: old).save(SessionSnapshot(createdAt: Date(timeIntervalSince1970: 1_000)))
        try await model.openSavedSession(old, allowAutomaticProcessing: false)
        XCTAssertEqual(model.outputLanguage, .simplifiedChinese)
        XCTAssertEqual(defaults.outputReads, 0)

        let stamped = root.appendingPathComponent("stamped")
        try SessionStore(directory: stamped).save(SessionSnapshot(createdAt: Date(timeIntervalSince1970: 1_000),
            targetLocale: "zh-Hant-TW"))
        try await model.openSavedSession(stamped, allowAutomaticProcessing: false)
        XCTAssertEqual(model.outputLanguage, .traditionalChineseTaiwan)
        XCTAssertEqual(defaults.outputReads, 0)
    }

    func testSavedTargetUsesSnapshotThenManifestThenDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SavedTarget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = SessionSnapshot()
        XCTAssertEqual(try OutputLanguage.savedLanguage(in: root, snapshot: snapshot), .simplifiedChinese)
        try Data(#"{"targetLocale":"fr"}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try OutputLanguage.savedLanguage(in: root, snapshot: snapshot), .french)
        XCTAssertEqual(try OutputLanguage.savedLanguage(in: root,
            snapshot: SessionSnapshot(targetLocale: "zh-Hant-HK")), .traditionalChineseHongKong)
        try Data(#"{"targetLocale":"unknown"}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try OutputLanguage.savedLanguage(in: root, snapshot: snapshot))
    }
}
