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
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
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

    // SRT ends a cue at a blank line, so text with internal blank lines must not
    // split one caption into a numbered cue plus an orphan block.
    func testSRTCueTextKeepsEveryCaptionInsideItsNumberedCue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SRTBlankLines-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, english: "Heat moves.", chinese: "第一句解释热传递。\n\n第二句讨论温度。"),
            TranscriptSegment(startTime: 1, endTime: 2, english: "\nLine A.\r\n \r\nLine B.\n",
                chinese: "\n甲。\u{2028}\u{2028}乙。\r\n\t\r丙。\r\n"),
            TranscriptSegment(startTime: 2, endTime: 3, english: "Cold air.", chinese: "冷空气。")
        ]
        try SessionExporter.export(segments: segments, sessionDirectory: root, createdAt: Date(timeIntervalSince1970: 0))
        let srt = try String(contentsOf: root.appendingPathComponent("bilingual.srt"), encoding: .utf8)
        XCTAssertEqual(srt, "1\n00:00:00,000 --> 00:00:01,000\nHeat moves.\n第一句解释热传递。\n第二句讨论温度。\n\n"
            + "2\n00:00:01,000 --> 00:00:02,000\nLine A.\nLine B.\n甲。\n乙。\n丙。\n\n"
            + "3\n00:00:02,000 --> 00:00:03,000\nCold air.\n冷空气。\n")
        let blocks = srt.dropLast().components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count, segments.count)
        for (offset, block) in blocks.enumerated() {
            let lines = block.components(separatedBy: "\n")
            XCTAssertEqual(lines.first, String(offset + 1))
            XCTAssertTrue(lines.count > 2 && lines[1].contains(" --> "))
        }
        for (index, segment) in segments.enumerated() {
            XCTAssertEqual(SessionExporter.srtCue(segment, index: index), blocks[index])
            XCTAssertEqual(SessionExporter.srtCue(segment, index: index, outputLanguage: .simplifiedChinese), blocks[index])
        }
        // Only the SRT exit changes; saved text and the other formats keep raw text.
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript-en.txt"), encoding: .utf8),
            segments.map(\.english).joined(separator: "\n") + "\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript-zh-Hans.txt"), encoding: .utf8),
            segments.map(\.chinese).joined(separator: "\n") + "\n")
        let rows = try String(contentsOf: root.appendingPathComponent("bilingual.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(TranscriptSegment.self, from: Data($0.utf8)) }
        XCTAssertEqual(rows.map(\.english), segments.map(\.english))
        XCTAssertEqual(rows.map(\.chinese), segments.map(\.chinese))
    }

    func testSourceOnlySRTCueDropsBlankLinesAndKeepsSingleBreaks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SRTSourceOnly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Air is\n\n  \nclear.\nWater is wet.")
        try SessionExporter.export(segments: [segment], sessionDirectory: root,
            createdAt: Date(timeIntervalSince1970: 0), target: .english)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("bilingual.srt"), encoding: .utf8),
            "1\n00:00:00,000 --> 00:00:01,000\nAir is\nclear.\nWater is wet.\n")
        XCTAssertEqual(SessionExporter.srtCue(segment, index: 0, outputLanguage: .english),
            "1\n00:00:00,000 --> 00:00:01,000\nAir is\nclear.\nWater is wet.")
    }
}
