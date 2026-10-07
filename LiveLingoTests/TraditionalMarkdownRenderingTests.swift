import Foundation
import XCTest
@testable import LiveLingo

final class TraditionalMarkdownRenderingTests: XCTestCase {
    func testClassificationPrecedesRenderingAndBothReviewSidesConvert() {
        let lines = ["## 学习笔记", "- **原笔记 · 要点 1**：头发在这里。",
                     "- **9B 建议（待核对）**：头发在后面。", "  - 原文：明日、図書館へ行く。", ""]
        for language in [OutputLanguage.traditionalChineseTaiwan, .traditionalChineseHongKong] {
            for index in lines.indices {
                XCTAssertEqual(SummaryMarkdownLine.classify(lines, at: index).role,
                               SummaryMarkdownLine.displayed(lines, at: index, language: language).role)
            }
        }
        XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: 1, language: .traditionalChineseTaiwan),
                       .reviewChange(original: "頭髮在這裡。", proposed: "頭髮在後面。"))
        XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: 2, language: .traditionalChineseTaiwan), .hidden)
        XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: 3, language: .traditionalChineseTaiwan),
                       .sourceEvidence(label: "后文原文依据", text: "原文：明日、図書館へ行く。", indentation: 1))
    }

    func testScheduleSourceIsPreservedByField() throws {
        let original = "## 课程安排与待办\n- [00:01] 明日、図書館の受付を確認します。 — 明天在这里确认登记。\n## 学习笔记\n这里有图书。\n"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(original, language: .traditionalChineseTaiwan),
                       "## 課程安排與待辦\n- [00:01] 明日、図書館の受付を確認します。 — 明天在這裡確認登記。\n## 學習筆記\n這裡有圖書。\n")
        XCTAssertEqual(try ClassroomMarkdownRendering.render(original, language: .simplifiedChinese), original)
    }

    func testAlreadyRenderedLegacyMarkdownIsNeverConvertedAgain() throws {
        // s2tw would otherwise change this HK variant to 裡.
        let original = "## 學習筆記\n頭髮在這裏。\n"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(original, language: .traditionalChineseTaiwan,
                                                             isLegacyRendered: true), original)
        let lines = original.components(separatedBy: "\n")
        XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: 1, language: .traditionalChineseTaiwan,
                                                    isLegacyRendered: true), .paragraph("頭髮在這裏。"))
    }

    func testLatinOutputsRemainByteIdentical() throws {
        let text = "Résumé: élan.\r\n数学函数 DNA pH 7.4\n"
        for language in [OutputLanguage.simplifiedChinese, .english, .spanish, .french] {
            XCTAssertEqual(Data(try ClassroomMarkdownRendering.render(text, language: language).utf8), Data(text.utf8))
        }
    }

    func testScheduleEvidenceDisambiguatesSeparatorsInsideBothFields() throws {
        let evidence = TranscriptSegment(startTime: 1, endTime: 2,
            english: "明日 — 図書館で登记します。", chinese: "明天在这里登记 — 后天确认。", sourceLanguage: "ja")
        let text = "## 课程安排与待办\r\n- [00:01] 明日 — 図書館で登记します。 — 明天在这里登记 — 后天确认。\r\n"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(text, language: .traditionalChineseTaiwan,
            scheduleEvidence: [evidence]),
            "## 課程安排與待辦\r\n- [00:01] 明日 — 図書館で登记します。 — 明天在這裡登記 — 後天確認。\r\n")
        XCTAssertEqual(evidence.english, "明日 — 図書館で登记します。")
        XCTAssertEqual(evidence.chinese, "明天在这里登记 — 后天确认。")
    }

    func testSourceEvidenceCRLFAndNonHanScalarsStayExact() throws {
        let text = "## 学习笔记\r\n  - 原文：ここで登记する。 e\u{0301} 😀\r\n  - 先前原文：図書館。\r\n"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(text, language: .traditionalChineseHongKong),
                       "## 學習筆記\r\n  - 原文：ここで登记する。 e\u{0301} 😀\r\n  - 先前原文：図書館。\r\n")
    }

    func testSourceEvidenceWhitespaceIsPreservedInRenderedMarkdown() throws {
        let text = "## 学习笔记\n  - 原文：ここで登记する。  \n\t- 先前原文：図書館。\t\n\u{00a0}- 原文：登记  \n"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(text, language: .traditionalChineseTaiwan),
                       "## 學習筆記\n  - 原文：ここで登记する。  \n\t- 先前原文：図書館。\t\n\u{00a0}- 原文：登记  \n")
    }

    func testMissingDictionaryPreservesDisplayStructureAndLegacyNeedsNoDictionary() throws {
        let missing = ChineseScriptConverter(resourceDirectory: nil)
        let lines = ["## 学习笔记", "- **原笔记 · 要点 1**：这里。", "- **9B 建议（待核对）**：后面。",
                     "  - 原文：図書館。", "- 后续", "尾段", ""]
        for index in lines.indices {
            XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: index, language: .traditionalChineseTaiwan,
                converter: missing), SummaryMarkdownLine.classify(lines, at: index))
        }
        let legacy = "## 學習筆記\n這裏。"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(legacy, language: .traditionalChineseTaiwan,
            isLegacyRendered: true, converter: missing), legacy)
        XCTAssertThrowsError(try ClassroomMarkdownRendering.render("这里。", language: .traditionalChineseTaiwan,
            converter: missing))
    }
}
