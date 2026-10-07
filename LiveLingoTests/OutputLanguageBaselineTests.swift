import Foundation
import XCTest
@testable import LiveLingo

/// Captured default-language presentation, using authored text and stopped
/// dependencies. No Apple translation session or background service starts.
@MainActor
final class OutputLanguageBaselineTests: XCTestCase {
    private final class ReadOnlyDefaults: UserDefaults, @unchecked Sendable {
        override func string(forKey defaultName: String) -> String? { nil }
        override func object(forKey defaultName: String) -> Any? { nil }
        override func bool(forKey defaultName: String) -> Bool { false }
        override func set(_ value: Any?, forKey defaultName: String) {
            preconditionFailure("Presentation baselines must not persist preferences")
        }
    }

    private func presentationModel() async throws -> AppModel {
        let directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("OutputLanguageBaseline-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("Presentation must not request a generation")
                throw CancellationError()
            }
        await queue.shutdownForTesting()
        let defaults = try XCTUnwrap(ReadOnlyDefaults(suiteName: "OutputLanguageBaseline-\(UUID())"))
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                        backgroundServices: false, scheduledNotes: false, defaults: defaults)
    }

    func testCaptionPrimaryLinesMatchBaseline() {
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
            let row = CaptionPresentation(segment)
            XCTAssertEqual(row.languageName, name)
            XCTAssertEqual(row.isSourceOnly, sourceOnly)
            XCTAssertEqual(row.primaryText, primary)
        }
        XCTAssertEqual(CaptionPresentation.translationStatus(isTranslating: true), "翻译中…")
        XCTAssertEqual(CaptionPresentation.translationStatus(isTranslating: false), "等待翻译…")
    }

    func testPreviewChineseStringsMatchAllBaselineStates() async throws {
        let model = try await presentationModel()
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        XCTAssertEqual(model.previewEnglishDisplay, "等待英文语音…")
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
            ? "等待语音…" : "当前系统不支持初译；正式译文随后显示")
        model.previewTranslationEnabled = false
        XCTAssertEqual(model.previewChineseDisplay, "初译已关闭")
        model.previewTranslationEnabled = true
        model.receiveLivePreviewForTesting("A bell rings.")
        XCTAssertEqual(model.previewEnglishDisplay, "A bell rings.")
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
            ? "等待初译…" : "当前系统不支持初译；正式译文随后显示")
        model.receiveLivePreviewForTesting("A bell rings.", chinese: "鈴響了。")
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
            ? "初译 · 鈴響了。" : "当前系统不支持初译；正式译文随后显示")
        model.previewTranslationEnabled = false
        XCTAssertEqual(model.previewChineseDisplay, "初译已关闭")
        model.previewTranslationEnabled = true
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
            ? "等待初译…" : "当前系统不支持初译；正式译文随后显示")

        for language in ["zh", "yue", "ja", "es"] {
            let source = language == "zh" ? "葉子長大了。" : "合成来源文本。"
            let pending = TranscriptSegment(startTime: 0, endTime: 1, english: source, sourceLanguage: language)
            var translating = pending
            translating.beginTranslation()
            var failed = pending
            failed.failTranslation("Synthetic diagnostic; not user-facing")
            let completed = TranscriptSegment(startTime: 0, endTime: 1, english: source,
                                              chinese: "已保存的中文。", sourceLanguage: language)
            for (segment, expected) in [(pending, "等待正式译文…"), (translating, "等待正式译文…"),
                                        (failed, "本段翻译未完成"), (completed, "已保存的中文。")] {
                model.loadPresentationForTesting(phase: .idle, evidence: [segment])
                for enabled in [false, true] {
                    model.previewTranslationEnabled = enabled
                    model.receiveLivePreviewForTesting("", chinese: "过时的初译。")
                    XCTAssertEqual(model.previewEnglishDisplay, source)
                    XCTAssertEqual(model.previewChineseDisplay, language == "zh" ? "叶子长大了。" : expected)
                }
                model.receiveLivePreviewForTesting("New English speech.", chinese: "新初译。")
                XCTAssertEqual(model.previewEnglishDisplay, "New English speech.")
                XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                    ? "初译 · 新初译。" : "当前系统不支持初译；正式译文随后显示")
            }
        }
        let english = TranscriptSegment(startTime: 0, endTime: 1, english: "A bell rings.", chinese: "铃响了。")
        model.loadPresentationForTesting(phase: .idle, evidence: [english])
        model.receiveLivePreviewForTesting("", chinese: "")
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
            ? "等待初译…" : "当前系统不支持初译；正式译文随后显示")
    }

    func testSummaryLineClassificationMatchesOriginalWhitespaceAndPairing() {
        let lines = [
            "## 合成主题", "  ## 缩进标题保持正文", "- 知识点", "      - 深层知识点", "",
            "   ", "合成正文", "  - 原文：A leaf grows.", "    - 先前原文：Ice is cold.",
            "- 原文：不缩进就不是折叠", "- **原笔记 · 要点 1**：原值**：后缀",
            "- **9B 建议（待核对）**：建议值", "  - **原笔记 · 要点 2**：缩进原值",
            "- **9B 建议（待核对）**：建议仍单独显示", "- **原笔记 · 要点 3**：原值",
            "  - **9B 建议（待核对）**：缩进建议被隐藏", "- **9B 建议（待核对）**：孤立建议",
            "- **原筆記 · 要點 4**：繁体保持普通列表", "- **9B 建議（待核對）**：繁体保持普通列表",
            "\t- 原文：制表符不算空格缩进", "          - 原文：空格缩进最多四层"
        ]
        let expected: [SummaryMarkdownLine] = [
            .heading("合成主题"), .paragraph("  ## 缩进标题保持正文"),
            .bullet(text: "知识点", indentation: 0), .bullet(text: "深层知识点", indentation: 3),
            .blank, .blank, .paragraph("合成正文"),
            .sourceEvidence(label: "后文原文依据", text: "原文：A leaf grows.", indentation: 1),
            .sourceEvidence(label: "先前原文依据", text: "先前原文：Ice is cold.", indentation: 2),
            .bullet(text: "原文：不缩进就不是折叠", indentation: 0),
            .reviewChange(original: "原值**：后缀", proposed: "建议值"), .hidden,
            .reviewChange(original: "缩进原值", proposed: "建议仍单独显示"),
            .bullet(text: "**9B 建议（待核对）**：建议仍单独显示", indentation: 0),
            .bullet(text: "**原笔记 · 要点 3**：原值", indentation: 0), .hidden,
            .bullet(text: "**9B 建议（待核对）**：孤立建议", indentation: 0),
            .bullet(text: "**原筆記 · 要點 4**：繁体保持普通列表", indentation: 0),
            .bullet(text: "**9B 建議（待核對）**：繁体保持普通列表", indentation: 0),
            .bullet(text: "原文：制表符不算空格缩进", indentation: 0),
            .sourceEvidence(label: "后文原文依据", text: "原文：空格缩进最多四层", indentation: 4)
        ]
        XCTAssertEqual(lines.indices.map { SummaryMarkdownLine.classify(lines, at: $0) }, expected)
    }
}

