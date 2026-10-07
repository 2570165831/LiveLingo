import AppKit
import Foundation
import PDFKit
import XCTest
@testable import LiveLingo

final class TraditionalSessionExporterTests: XCTestCase {
    private let source = "体温と気圧を記録する。"
    private let simplifiedNotes = """
    # 合成课堂
    ## 学习笔记
    - 头发在这里。
      - 原文：体温と気圧を記録する。
      - 先前原文：ここは台風の記録。
    ## 课程安排与待办
    - [00:00] 体温と気圧を記録する。 — 头发在这里。
    """

    // Handwritten expectations, independent of every production renderer.
    private var variants: [(language: OutputLanguage, target: String, passThrough: String, summary: String)] {
        [
            (.traditionalChineseTaiwan, "頭髮在這裡。", "這裡有頭髮。", """
            # 合成課堂
            ## 學習筆記
            - 頭髮在這裡。
              - 原文：体温と気圧を記録する。
              - 先前原文：ここは台風の記録。
            ## 課程安排與待辦
            - [00:00] 体温と気圧を記録する。 — 頭髮在這裡。
            """),
            (.traditionalChineseHongKong, "頭髮在這裏。", "這裏有頭髮。", """
            # 合成課堂
            ## 學習筆記
            - 頭髮在這裏。
              - 原文：体温と気圧を記録する。
              - 先前原文：ここは台風の記録。
            ## 課程安排與待辦
            - [00:00] 体温と気圧を記録する。 — 頭髮在這裏。
            """)
        ]
    }

    private var segments: [TranscriptSegment] {
        [
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                startTime: 0, endTime: 1, english: "Hair is here.", chinese: "头发在这里。"),
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                startTime: 1, endTime: 2, english: source, chinese: "头发在这里。", sourceLanguage: "ja"),
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
                startTime: 2, endTime: 3, english: "这里有头发。", sourceLanguage: "zh")
        ]
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraditionalExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func notesSnapshot(target: OutputLanguage, notes: String? = nil,
                               legacy: Bool = false) -> NotesExportSnapshot {
        NotesExportSnapshot(className: "合成课堂", sessionName: "原文录音 2001-01-02 {1}", scope: .wholeLesson,
            scopeDetail: "全部片段", coverageLine: "已整理", notesMarkdown: notes ?? simplifiedNotes,
            reviewMarkdown: """
            # 复查进度
            ## 第 1 批
            - **原笔记 · 要点 1**：头发在这里。
            - **9B 建议（待核对）**：这里有头发。
              - 原文：体温と気圧を記録する。
            """, transcript: segments, generatedAt: Date(timeIntervalSince1970: 0),
            includesReviewAdvice: true, includesTranscript: true, target: target,
            notesAreLegacyRendered: legacy)
    }

    private func documentText(_ data: Data, format: NotesExportFormat) throws -> String {
        switch format {
        case .markdown, .plainText:
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        case .word:
            return try NSAttributedString(data: data,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil).string
        case .pdf:
            return try XCTUnwrap(try XCTUnwrap(PDFDocument(data: data)).string)
        }
    }

    private func assertMissingConverter<T>(_ operation: @autoclosure () throws -> T,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case ChineseScriptConverter.Failure.resourcesMissing = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    func testRenderedHelpersKeepGenerationAPIsAndOriginalLinesUnchanged() throws {
        for variant in variants {
            let english = segments[0], japanese = segments[1], chinese = segments[2]
            XCTAssertEqual(SessionExporter.targetLine(english, outputLanguage: variant.language), "头发在这里。")
            XCTAssertEqual(SessionExporter.captionLines(japanese, outputLanguage: variant.language), [source, "头发在这里。"])
            XCTAssertEqual(try SessionExporter.renderedTargetLine(english, outputLanguage: variant.language), variant.target)
            XCTAssertEqual(try SessionExporter.renderedCaptionLines(japanese, outputLanguage: variant.language), [source, variant.target])
            XCTAssertEqual(try SessionExporter.renderedCaptionLines(chinese, outputLanguage: variant.language), [variant.passThrough])
            XCTAssertEqual(try SessionExporter.renderedSRTCue(japanese, index: 1, outputLanguage: variant.language),
                "2\n00:00:01,000 --> 00:00:02,000\n体温と気圧を記録する。\n" + variant.target)
        }
    }

    func testRegionalSessionBytesKeepJSONLAndSourceIdenticalToSimplifiedExport() throws {
        let baseline = try directory()
        let input = segments
        try SessionExporter.export(segments: input, sessionDirectory: baseline, summary: simplifiedNotes,
            createdAt: Date(timeIntervalSince1970: 0))
        let expectedSource = Data("Hair is here.\n体温と気圧を記録する。\n这里有头发。\n".utf8)
        XCTAssertEqual(try Data(contentsOf: baseline.appendingPathComponent("transcript-en.txt")), expectedSource)
        for variant in variants {
            let root = try directory()
            try SessionExporter.export(segments: input, sessionDirectory: root, summary: simplifiedNotes,
                createdAt: Date(timeIntervalSince1970: 0), target: variant.language)
            let expectedTarget = variant.target + "\n" + variant.target + "\n" + variant.passThrough + "\n"
            let expectedSRT = "1\n00:00:00,000 --> 00:00:01,000\nHair is here.\n" + variant.target + "\n\n"
                + "2\n00:00:01,000 --> 00:00:02,000\n体温と気圧を記録する。\n" + variant.target + "\n\n"
                + "3\n00:00:02,000 --> 00:00:03,000\n" + variant.passThrough + "\n"
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("transcript-" + variant.language.rawValue + ".txt")),
                Data(expectedTarget.utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("bilingual.srt")), Data(expectedSRT.utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("summary-" + variant.language.rawValue + ".md")),
                Data((variant.summary + "\n").utf8))
            for name in ["bilingual.jsonl", "transcript-en.txt"] {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)),
                    try Data(contentsOf: baseline.appendingPathComponent(name)), name)
            }
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:
                Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
            XCTAssertEqual(manifest["targetLocale"] as? String, variant.language.rawValue)
            XCTAssertEqual(manifest["converterVersion"] as? String, "opencc-ver.1.1.9+livelingo-v1")
            XCTAssertEqual(manifest["sourceLanguages"] as? [String], ["ja", "zh"])
        }
        XCTAssertEqual(input, segments, "Rendering must not rewrite stored segment fields")
    }

    func testPendingAndFailureMarkersRenderAfterTheirSimplifiedClassification() throws {
        let pending = TranscriptSegment(startTime: 0, endTime: 1, english: "Next sentence.")
        let failed = TranscriptSegment(startTime: 1, endTime: 2, english: "Another sentence.",
            chinese: "[翻译失败：synthetic]")
        var stateOnly = TranscriptSegment(startTime: 2, endTime: 3, english: "One more sentence.")
        stateOnly.failTranslation("synthetic")
        for variant in variants {
            XCTAssertEqual(try SessionExporter.renderedTargetLine(pending, outputLanguage: variant.language), "（本段暫無譯文）")
            XCTAssertEqual(try SessionExporter.renderedTargetLine(failed, outputLanguage: variant.language), "（本段翻譯未完成，可對照英文）")
            XCTAssertEqual(try SessionExporter.renderedTargetLine(stateOnly, outputLanguage: variant.language), "（本段翻譯未完成，可對照英文）")
        }
        XCTAssertEqual(failed.chinese, "[翻译失败：synthetic]")
    }

    func testIdentityManifestsOmitConverterVersionAndOldManifestStillDecodes() throws {
        for language in [OutputLanguage.simplifiedChinese, .english, .spanish, .french] {
            let root = try directory()
            try SessionExporter.export(segments: [], sessionDirectory: root, createdAt: Date(timeIntervalSince1970: 0), target: language)
            let expected = "{\"createdAt\":\"1970-01-01T00:00:00Z\",\"recordingFile\":\"recording.wav\",\"segmentCount\":0,\"sourceLocale\":\"en-US\",\"targetLocale\":\""
                + language.rawValue + "\"}"
            let bytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
            XCTAssertEqual(bytes, Data(expected.utf8))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            XCTAssertNil(try decoder.decode(SessionExporter.Manifest.self, from: bytes).converterVersion)
            for name in ["transcript-en.txt", "bilingual.jsonl", "bilingual.srt"] {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data("\n".utf8))
            }
        }
    }

    func testEveryNotesFormatConvertsFieldsAndPreservesBothKindsOfSourceText() throws {
        for variant in variants {
            let snapshot = notesSnapshot(target: variant.language)
            for format in NotesExportFormat.allCases {
                let text = try documentText(NotesExportDocument.data(snapshot, format: format), format: format)
                XCTAssertTrue(text.contains("合成課堂"), format.rawValue)
                XCTAssertTrue(text.contains("整課筆記"), format.rawValue)
                XCTAssertTrue(text.contains("學習筆記"), format.rawValue)
                XCTAssertTrue(text.contains("課程安排與待辦"), format.rawValue)
                // OpenCC STPhrases contains 复查 -> 複查. This checks the pinned
                // dictionary spelling, not native approval of terminology.
                XCTAssertTrue(text.contains("複查進度"), format.rawValue)
                XCTAssertTrue(text.contains(variant.target), format.rawValue)
                XCTAssertTrue(text.contains(variant.passThrough), format.rawValue)
                XCTAssertTrue(text.contains("体温と気圧を記録する。"), format.rawValue)
                XCTAssertTrue(text.contains("ここは台風の記録。"), format.rawValue)
                XCTAssertTrue(text.contains("体温と気圧を記録する。 — " + variant.target), format.rawValue)
                XCTAssertTrue(text.contains("原文录音 2001-01-02 {1}"), "Recording names are inserted after template conversion")
                XCTAssertFalse(text.contains("头发在这里。"), format.rawValue)
                XCTAssertFalse(text.contains("这里有头发。"), format.rawValue)
            }
        }
    }

    func testLegacyNotesAndSummaryAreNotConvertedAgainWhileReviewStillRenders() throws {
        let legacy = "# 舊筆記\n頭髮在這裏。\n体温は低い。"
        let snapshot = notesSnapshot(target: .traditionalChineseTaiwan, notes: legacy, legacy: true)
        for format in NotesExportFormat.allCases {
            let text = try documentText(NotesExportDocument.data(snapshot, format: format), format: format)
            XCTAssertTrue(text.contains("頭髮在這裏。"), format.rawValue)
            XCTAssertTrue(text.contains("体温は低い。"), format.rawValue)
            XCTAssertTrue(text.contains("頭髮在這裡。"), "Review and caption text still need their own conversion")
            XCTAssertTrue(text.contains("整課筆記"), format.rawValue)
        }
        let root = try directory()
        try SessionExporter.export(segments: [], sessionDirectory: root, summary: legacy,
            target: .traditionalChineseTaiwan, summaryIsLegacyRendered: true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("summary-zh-Hant-TW.md")), Data((legacy + "\n").utf8))
    }

    func testMissingConverterFailsEveryNotesFormatIncludingEmptyLegacyNotes() throws {
        let missing = ChineseScriptConverter(resourceDirectory: nil)
        for variant in variants {
            for snapshot in [notesSnapshot(target: variant.language),
                NotesExportSnapshot(className: "Synthetic", sessionName: nil, scope: .wholeLesson,
                    scopeDetail: "", coverageLine: "", notesMarkdown: "", reviewMarkdown: nil, transcript: [],
                    generatedAt: Date(timeIntervalSince1970: 0), includesReviewAdvice: false,
                    includesTranscript: false, target: variant.language, notesAreLegacyRendered: true)] {
                for format in NotesExportFormat.allCases {
                    XCTAssertThrowsError(try NotesExportDocument.data(snapshot, format: format, converter: missing)) { error in
                        guard case NotesExportError.rendererUnavailable = error else {
                            return XCTFail("Unexpected error: \(error)")
                        }
                    }
                }
            }
        }
    }

    func testMissingConverterFailsAllRenderedCaptionHelpers() throws {
        let missing = ChineseScriptConverter(resourceDirectory: nil)
        for variant in variants {
            assertMissingConverter(try SessionExporter.renderedTargetLine(segments[0], outputLanguage: variant.language, converter: missing))
            assertMissingConverter(try SessionExporter.renderedCaptionLines(segments[1], outputLanguage: variant.language, converter: missing))
            assertMissingConverter(try SessionExporter.renderedSRTCue(segments[2], index: 2, outputLanguage: variant.language, converter: missing))
        }
    }

    func testMissingConverterFailsSessionExportBeforeWritingAnything() throws {
        let missing = ChineseScriptConverter(resourceDirectory: nil)
        for variant in variants {
            let root = try directory()
            assertMissingConverter(try SessionExporter.export(segments: segments, sessionDirectory: root,
                summary: "legacy", target: variant.language, summaryIsLegacyRendered: true, converter: missing))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    func testNotesWithoutTranscriptStillHaveEvidenceForAmbiguousScheduleFields() throws {
        let segment = TranscriptSegment(startTime: 1, endTime: 2, english: "図書館 — 这里で登记。",
            chinese: "这里登记 — 后天确认。", sourceLanguage: "ja")
        let snapshot = NotesExportSnapshot(className: "合成课堂", sessionName: nil, scope: .wholeLesson,
            scopeDetail: "全部", coverageLine: "已整理",
            notesMarkdown: "## 课程安排与待办\n- [00:01] 図書館 — 这里で登记。 — 这里登记 — 后天确认。",
            reviewMarkdown: nil, transcript: [], generatedAt: Date(timeIntervalSince1970: 0),
            includesReviewAdvice: false, includesTranscript: false, target: .traditionalChineseTaiwan,
            scheduleEvidence: [segment])
        for format in NotesExportFormat.allCases {
            let text = try documentText(NotesExportDocument.data(snapshot, format: format), format: format)
            XCTAssertTrue(text.contains("図書館 — 这里で登记。 — 這裡登記 — 後天確認。"), format.rawValue)
            XCTAssertFalse(text.contains("逐段字幕"), format.rawValue)
        }
    }

    func testIdentityTargetsIgnoreTheMissingConverterAndKeepTheirRawDocumentText() throws {
        let missing = ChineseScriptConverter(resourceDirectory: nil)
        let raw = "**Raw**：头发在这里。"
        for language in [OutputLanguage.simplifiedChinese, .english, .spanish, .french] {
            let snapshot = NotesExportSnapshot(className: "Synthetic", sessionName: nil, scope: .wholeLesson,
                scopeDetail: "", coverageLine: "", notesMarkdown: raw, reviewMarkdown: nil, transcript: [],
                generatedAt: Date(timeIntervalSince1970: 0), includesReviewAdvice: false, includesTranscript: false, target: language)
            for format in NotesExportFormat.allCases {
                let text = try documentText(NotesExportDocument.data(snapshot, format: format, converter: missing), format: format)
                XCTAssertTrue(text.contains("头发在这里。"), format.rawValue)
                XCTAssertFalse(text.contains("頭髮在這"), format.rawValue)
            }
            XCTAssertEqual(try SessionExporter.renderedTargetLine(segments[1], outputLanguage: language, converter: missing), "头发在这里。")
        }
        #if DEBUG
        XCTAssertEqual(missing.debugLoadCount, 0)
        #endif
    }

    func testLegacyReviewBindingUsesManifestLanguageAndKeepsIdenticalRenderedBytes() throws {
        for variant in variants {
            let root = try directory()
            try Data(("{\"targetLocale\":\"" + variant.language.rawValue + "\"}").utf8)
                .write(to: root.appendingPathComponent("manifest.json"))
            try Data((variant.summary + "\n").utf8)
                .write(to: root.appendingPathComponent("summary-" + variant.language.rawValue + ".md"))
            XCTAssertNoThrow(try ReviewInputBinding.validate(identity: nil, scope: .wholeLesson, batches: [],
                digest: nil, original: simplifiedNotes, in: root, allowHistorical: false))
            XCTAssertNoThrow(try ReviewInputBinding.validate(identity: nil, scope: .wholeLesson, batches: [],
                digest: nil, original: variant.summary, in: root, allowHistorical: false))
            XCTAssertThrowsError(try ReviewInputBinding.validate(identity: nil, scope: .wholeLesson, batches: [],
                digest: nil, original: "# 无关笔记", in: root, allowHistorical: true))
        }
        let identityRoot = try directory()
        try Data(#"{"targetLocale":"en"}"#.utf8).write(to: identityRoot.appendingPathComponent("manifest.json"))
        try Data("頭髮在這裡。\n".utf8).write(to: identityRoot.appendingPathComponent("summary-en.md"))
        XCTAssertThrowsError(try ReviewInputBinding.validate(identity: nil, scope: .wholeLesson, batches: [],
            digest: nil, original: "头发在这里。", in: identityRoot, allowHistorical: false))
    }

    func testLegacyByteEqualityPrecedesConversionAndBoundJobsStillNeedTheirSnapshot() throws {
        let root = try directory()
        let legacy = "頭髮在這裏。"
        try Data(#"{"targetLocale":"zh-Hant-TW"}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data((legacy + "\n").utf8).write(to: root.appendingPathComponent("summary-zh-Hant-TW.md"))
        // Converting this older regional text to Taiwan would change 裏 to 裡.
        XCTAssertNoThrow(try ReviewInputBinding.validate(identity: nil, scope: .wholeLesson, batches: [],
            digest: nil, original: legacy, in: root, allowHistorical: false))
        let batch = LearningNoteBatch(id: UUID(), evidence: [segments[0]],
            note: .init(topic: "合成笔记", points: [.init(kind: "核心结论", text: "头发在这里。")]))
        let identity = try ReviewIdentity(sessionID: UUID(), scope: .wholeLesson, inputRevision: 0)
        XCTAssertThrowsError(try ReviewInputBinding.validate(identity: identity, scope: .wholeLesson, batches: [batch],
            digest: nil, original: legacy, in: root, allowHistorical: true)) { error in
            guard case ReviewIdentityError.conflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSnapshotBindingCannotBeDowngradedToRenderedSummaryEquality() throws {
        let root = try directory()
        let batch = LearningNoteBatch(id: UUID(), evidence: [segments[0]],
            note: .init(topic: "合成笔记", points: [.init(kind: "核心结论", text: "头发在这里。")]))
        let sessionID = UUID()
        _ = try SessionStore(directory: root).save(SessionSnapshot(sessionID: sessionID,
            segments: batch.evidence, batches: [batch], notebookRevision: 1, targetLocale: "zh-Hant-TW"))
        try Data("頭髮在這裡。\n".utf8).write(to: root.appendingPathComponent("summary-zh-Hant-TW.md"))
        let identity = try ReviewIdentity(sessionID: sessionID, scope: .wholeLesson, inputRevision: 0, notebookRevision: 1)
        let changed = LearningNoteBatch(id: batch.id, evidence: batch.evidence,
            note: .init(topic: "合成笔记", points: [.init(kind: "核心结论", text: "这是不同的冻结内容。")]))
        XCTAssertThrowsError(try ReviewInputBinding.validate(identity: identity, scope: .wholeLesson, batches: [changed],
            digest: nil, original: "头发在这里。", in: root, allowHistorical: true)) { error in
            guard case ReviewIdentityError.conflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
