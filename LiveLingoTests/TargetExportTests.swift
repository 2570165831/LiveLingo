import Foundation
import XCTest
@testable import LiveLingo

final class TargetExportTests: XCTestCase {
    func testNotesExportRejectsUnavailableRenderersInEveryFormat() throws {
        for target in [OutputLanguage.traditionalChineseTaiwan, .traditionalChineseHongKong] {
            let snapshot = NotesExportSnapshot(className: "Synthetic", sessionName: nil, scope: .wholeLesson,
                scopeDetail: "", coverageLine: "", notesMarkdown: "Synthetic notes.", reviewMarkdown: nil,
                transcript: [], generatedAt: Date(timeIntervalSince1970: 0), includesReviewAdvice: false,
                includesTranscript: false, target: target)
            for format in NotesExportFormat.allCases {
                XCTAssertThrowsError(try NotesExportDocument.data(snapshot, format: format,
                    converter: ChineseScriptConverter(resourceDirectory: nil))) { error in
                    guard case NotesExportError.rendererUnavailable = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
            }
        }
    }

    func testEnglishStoredOutputUsesDistinctFileAndSingleLineCue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TargetExport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Air is clear.", chinese: "Air is clear.")
        try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "Clear air.", createdAt: Date(timeIntervalSince1970: 0), target: .english)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript-target-en.txt"), encoding: .utf8), "Air is clear.\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript-en.txt"), encoding: .utf8), "Air is clear.\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("bilingual.srt"), encoding: .utf8),
            "1\n00:00:00,000 --> 00:00:01,000\nAir is clear.\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("summary-en.md"), encoding: .utf8), "Clear air.\n")
        let notes = NotesExportSnapshot(className: "Synthetic", sessionName: nil, scope: .wholeLesson,
            scopeDetail: "", coverageLine: "", notesMarkdown: "Clear air.", reviewMarkdown: nil,
            transcript: [segment], generatedAt: Date(timeIntervalSince1970: 0), includesReviewAdvice: false,
            includesTranscript: true, target: .english)
        XCTAssertEqual(notes.target, .english)
        XCTAssertTrue(NotesExportDocument.plainText(notes).contains("[00:00–00:01] Air is clear."))
        XCTAssertFalse(NotesExportDocument.plainText(notes).contains("Air is clear.\nAir is clear."))
    }

    func testSummaryLookupPrefersSnapshotThenManifestThenDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SummaryTarget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try SessionStore(directory: root).save(SessionSnapshot(targetLocale: "en"))
        for name in ["summary-zh-Hans.md", "summary-fr.md"] {
            try Data("Synthetic summary".utf8).write(to: root.appendingPathComponent(name))
        }
        try Data(#"{"targetLocale":"fr"}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertEqual(SessionExporter.savedSummaryURL(in: root).lastPathComponent, "summary-fr.md")
        try Data("Synthetic summary".utf8).write(to: root.appendingPathComponent("summary-en.md"))
        XCTAssertEqual(SessionExporter.savedSummaryURL(in: root).lastPathComponent, "summary-en.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("summary-en.md"))
        XCTAssertEqual(SessionExporter.savedSummaryURL(in: root).lastPathComponent, "summary-fr.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("summary-fr.md"))
        XCTAssertEqual(SessionExporter.savedSummaryURL(in: root).lastPathComponent, "summary-zh-Hans.md")
    }

    @MainActor
    func testPreferenceChangeDoesNotChangeSavedSummaryOrDirectoryIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TargetIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ClassroomPresentation-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try cleanup.remove(defaults)
            try FileManager.default.removeItem(at: root)
        }
        try Data(#"{"targetLocale":"en"}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        let caption = TranscriptSegment(startTime: 0, endTime: 1, english: "Original source.", chinese: "Target text.")
        var jsonl = try SessionArchiveCoding.encode(caption)
        jsonl.append(Data("\n".utf8))
        try jsonl.write(to: root.appendingPathComponent("bilingual.jsonl"))
        try Data("Summary\n".utf8).write(to: root.appendingPathComponent("summary-en.md"))
        defaults.set("zh-Hans", forKey: "LiveLingo.outputLanguage")
        let before = try SessionDirectoryIdentity.resolve(directory: root)
        let summary = SessionExporter.savedSummaryURL(in: root)
        defaults.set("fr", forKey: "LiveLingo.outputLanguage")
        XCTAssertEqual(try SessionDirectoryIdentity.resolve(directory: root), before)
        XCTAssertEqual(SessionExporter.savedSummaryURL(in: root), summary)
    }
}
