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

    func testScheduleEvidenceRequiresExactUTF8Boundaries() throws {
        let cases = [("e\u{0301}", "é", "头发在这里。", "头发在这里。"),
                     ("é", "e\u{0301}", "头发在这里。", "头发在这里。"),
                     ("Synthetic", "Synthetic", "e\u{0301}头发在这里。", "é头发在这里。")]
        for (archivedSource, rawSource, archivedTarget, rawTarget) in cases {
            let evidence = TranscriptSegment(startTime: 1, endTime: 2,
                english: archivedSource, chinese: archivedTarget)
            let line = "- [00:01] " + rawSource + " — " + rawTarget
            let fields = ClassroomMarkdownRendering.scheduleFields(line, evidence: [evidence])
            XCTAssertNil(fields, "Canonical Unicode equality must not supply byte offsets")
            // The red version would slice past the input. Preserve the failure
            // assertion without crashing the rest of the regression suite.
            guard fields == nil else { continue }
            for (language, prose) in [(OutputLanguage.traditionalChineseTaiwan, "頭髮在這裡。"),
                                       (.traditionalChineseHongKong, "頭髮在這裏。")] {
                let raw = "## 课程安排与待办\n" + line
                let target = rawTarget.hasPrefix("é") ? "é" + prose : prose
                let expected = "## 課程安排與待辦\n- [00:01] " + rawSource + " — " + target
                XCTAssertEqual(Data(try ClassroomMarkdownRendering.render(raw, language: language,
                    scheduleEvidence: [evidence]).utf8), Data(expected.utf8))
            }
        }
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

    func testFencedBacktickAndTildeCodeIsPreservedInWholeAndPerLineRendering() throws {
        let technical = "````python\r\nrecord = {\"头发\": 3}\r\nrecord[\"头发\"] # e\u{0301} 😀\r\n```\r\n这里仍然是代码\r\n```` \t\r\n~~~json\r\n{\"头发\": \"这里\"}\r\n~~~\r\n"
        for (language, prose) in [(OutputLanguage.traditionalChineseTaiwan, "頭髮在這裡。\r\n"),
                                  (.traditionalChineseHongKong, "頭髮在這裏。\r\n") ] {
            let input = "头发在这里。\r\n" + technical + "头发在这里。\r\n"
            let expected = prose + technical + prose
            XCTAssertEqual(Data(try ClassroomMarkdownRendering.render(input, language: language).utf8), Data(expected.utf8))
            let lines = input.components(separatedBy: "\n")
            let expectedLines = expected.components(separatedBy: "\n")
            for index in lines.indices {
                XCTAssertEqual(Data(try ClassroomMarkdownRendering.line(lines, at: index, language: language).utf8),
                               Data(expectedLines[index].utf8), "line \(index)")
            }
        }
    }

    func testDisplayedUsesFenceContextBeforeConvertingClassifiedFields() {
        let input = "头发在这里。\r\n  ```text\r\nrecord[\"头发\"]\r\n## 头发在这里。\r\n- 头发在这里。\r\n  - 原文：头发在这里。\r\n  ```\r\n头发在这里。"
        // SummaryMarkdownView uses .newlines, which creates empty CRLF entries.
        let lines = input.components(separatedBy: .newlines)
        for language in [OutputLanguage.traditionalChineseTaiwan, .traditionalChineseHongKong] {
            for index in lines.indices where index > 0 && index < lines.count - 1 {
                XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: index, language: language),
                               SummaryMarkdownLine.classify(lines, at: index), "line \(index)")
            }
            let prose = language == .traditionalChineseTaiwan ? "頭髮在這裡。" : "頭髮在這裏。"
            XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: 0, language: language), .paragraph(prose))
            XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: lines.count - 1, language: language), .paragraph(prose))
        }
    }

    func testUnclosedAndMismatchedFencesDoNotLeakConversionIntoCode() throws {
        let input = "头发在这里。\n~~~python\nrecord[\"头发\"]\n```\n这里仍然是代码\n~~\n后面仍然是代码\n"
        let expected = "頭髮在這裡。\n~~~python\nrecord[\"头发\"]\n```\n这里仍然是代码\n~~\n后面仍然是代码\n"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(input, language: .traditionalChineseTaiwan), expected)
        let lines = input.components(separatedBy: "\n")
        for index in lines.indices.dropFirst() {
            XCTAssertEqual(try ClassroomMarkdownRendering.line(lines, at: index, language: .traditionalChineseTaiwan), lines[index])
            XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: index, language: .traditionalChineseTaiwan),
                           SummaryMarkdownLine.classify(lines, at: index))
        }
    }

    func testIndentedCodeIsPreservedWhileOrdinaryBulletsAndProseConvert() throws {
        let input = "头发在这里。\n\n    record[\"头发\"]\n\tprint(record[\"头发\"])\n\n- 头发在这里。\n  头发在这里。\n    - 头发在这里。\n"
        let expected = "頭髮在這裡。\n\n    record[\"头发\"]\n\tprint(record[\"头发\"])\n\n- 頭髮在這裡。\n  頭髮在這裡。\n    - 頭髮在這裡。\n"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(input, language: .traditionalChineseTaiwan), expected)
        let lines = input.components(separatedBy: "\n")
        for index in [2, 3] {
            XCTAssertEqual(try ClassroomMarkdownRendering.line(lines, at: index, language: .traditionalChineseTaiwan), lines[index])
            XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: index, language: .traditionalChineseTaiwan),
                           SummaryMarkdownLine.classify(lines, at: index))
        }
        XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: 7, language: .traditionalChineseTaiwan),
                       .bullet(text: "頭髮在這裡。", indentation: 2))
    }

    func testMultilineInlineCodeAndDisplayMathRetainContextAtEveryDisplayedLine() throws {
        let input = "头发在这里。``record[\r\n\"头发\"]``\r\n$$\r\nx_{头发}=1\r\n\\label{eq:头发}\r\n$$\r\n头发在这里。"
        let expected = "頭髮在這裡。``record[\r\n\"头发\"]``\r\n$$\r\nx_{头发}=1\r\n\\label{eq:头发}\r\n$$\r\n頭髮在這裡。"
        XCTAssertEqual(Data(try ClassroomMarkdownRendering.render(input, language: .traditionalChineseTaiwan).utf8), Data(expected.utf8))
        let lines = input.components(separatedBy: "\n")
        let expectedLines = expected.components(separatedBy: "\n")
        for index in lines.indices {
            XCTAssertEqual(Data(try ClassroomMarkdownRendering.line(lines, at: index, language: .traditionalChineseTaiwan).utf8),
                           Data(expectedLines[index].utf8))
            XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: index, language: .traditionalChineseTaiwan),
                           .paragraph(expectedLines[index]))
        }
    }

    func testReviewChangeAndScheduleRenderingPreserveTechnicalIdentifiers() throws {
        let code = #"`record["头发"]`"#
        let lines = ["- **原笔记 · 要点 1**：头发在这里。" + code,
                     "- **9B 建议（待核对）**：头发在后面。" + code]
        XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: 0, language: .traditionalChineseTaiwan),
                       .reviewChange(original: "頭髮在這裡。" + code, proposed: "頭髮在後面。" + code))
        let evidence = TranscriptSegment(startTime: 1, endTime: 2, english: "図書館で登记。",
            chinese: "头发在这里。" + code, sourceLanguage: "ja")
        let input = "## 课程安排与待办\r\n- [00:01] 図書館で登记。 — 头发在这里。" + code + "\r\n"
        XCTAssertEqual(try ClassroomMarkdownRendering.render(input, language: .traditionalChineseTaiwan,
            scheduleEvidence: [evidence]), "## 課程安排與待辦\r\n- [00:01] 図書館で登记。 — 頭髮在這裡。" + code + "\r\n")
    }

    func testDisplayedReviewFieldsStayAlignedAfterWhitespaceTrimming() {
        let code = #"`record["头发"]`"# + " e\u{0301} 😀"
        for (language, here) in [(OutputLanguage.traditionalChineseTaiwan, "頭髮在這裡。"),
                                 (.traditionalChineseHongKong, "頭髮在這裏。") ] {
            let lines = ["- **原笔记 · 要点 1**：头发在这里。" + code + " \t",
                         "- **9B 建议（待核对）**：头发在后面。" + code + " \t"]
            XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: 0, language: language),
                           .reviewChange(original: here + code, proposed: "頭髮在後面。" + code + " \t"))
            for suffix in ["\r", " \t\r"] {
                let crlf = ["- **原笔记 · 要点 1**：头发在这里。" + code + suffix,
                            "- **9B 建议（待核对）**：头发在后面。" + code + suffix]
                XCTAssertEqual(SummaryMarkdownLine.displayed(crlf, at: 0, language: language),
                               .reviewChange(original: here + code + suffix,
                                             proposed: "頭髮在後面。" + code + suffix))
            }
        }
    }

    func testFencedHeadingDoesNotEndRealScheduleSection() throws {
        let source = "図書館で登记します。"
        let evidence = TranscriptSegment(startTime: 1, endTime: 2,
            english: source, chinese: "头发在这里。", sourceLanguage: "ja")
        let code = "```text\r\n## 学习笔记\r\n```\r\n"
        let input = "## 课程安排与待办\r\n" + code + "- [00:01] \(source) — 头发在这里。\r\n"
        for (language, target) in [(OutputLanguage.traditionalChineseTaiwan, "頭髮在這裡。"),
                                   (.traditionalChineseHongKong, "頭髮在這裏。") ] {
            let expected = "## 課程安排與待辦\r\n" + code + "- [00:01] \(source) — \(target)\r\n"
            XCTAssertEqual(Data(try ClassroomMarkdownRendering.render(input, language: language,
                scheduleEvidence: [evidence]).utf8), Data(expected.utf8))
            let lines = input.components(separatedBy: "\n")
            XCTAssertEqual(try ClassroomMarkdownRendering.line(lines, at: 4, language: language,
                scheduleEvidence: [evidence]), "- [00:01] \(source) — \(target)\r")
            let displayed = input.components(separatedBy: .newlines)
            let index = try XCTUnwrap(displayed.firstIndex { $0.hasPrefix("- [") })
            XCTAssertEqual(SummaryMarkdownLine.displayed(displayed, at: index, language: language,
                scheduleEvidence: [evidence]), .bullet(text: "[00:01] \(source) — \(target)", indentation: 0))
        }
    }

    func testFencedScheduleHeadingDoesNotStartScheduleHandling() throws {
        let code = "~~~text\r\n## 课程安排与待办\r\n~~~\r\n"
        let input = "## 学习笔记\r\n" + code + "- [00:01] 头发在这里。 — 头发在这里。\r\n"
        for (language, target) in [(OutputLanguage.traditionalChineseTaiwan, "頭髮在這裡。"),
                                   (.traditionalChineseHongKong, "頭髮在這裏。") ] {
            let expected = "## 學習筆記\r\n" + code + "- [00:01] \(target) — \(target)\r\n"
            XCTAssertEqual(Data(try ClassroomMarkdownRendering.render(input, language: language).utf8), Data(expected.utf8))
            let lines = input.components(separatedBy: "\n")
            XCTAssertEqual(try ClassroomMarkdownRendering.line(lines, at: 4, language: language),
                           "- [00:01] \(target) — \(target)\r")
            let displayed = input.components(separatedBy: .newlines)
            let index = try XCTUnwrap(displayed.firstIndex { $0.hasPrefix("- [") })
            XCTAssertEqual(SummaryMarkdownLine.displayed(displayed, at: index, language: language),
                           .bullet(text: "[00:01] \(target) — \(target)", indentation: 0))
            XCTAssertFalse(ClassroomMarkdownRendering.hasUnresolvedScheduleBoundary(input, evidence: []))
        }
    }

    private func assertStructuralRendering(_ input: String, taiwan: String,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        for language in [OutputLanguage.traditionalChineseTaiwan, .traditionalChineseHongKong] {
            let expected = language == .traditionalChineseTaiwan ? taiwan
                : taiwan.replacingOccurrences(of: "這裡", with: "這裏")
            XCTAssertEqual(Data(try ClassroomMarkdownRendering.render(input, language: language).utf8),
                           Data(expected.utf8), file: file, line: line)
            let lines = input.components(separatedBy: "\n")
            let expectedLines = expected.components(separatedBy: "\n")
            for index in lines.indices {
                XCTAssertEqual(Data(try ClassroomMarkdownRendering.line(lines, at: index, language: language).utf8),
                               Data(expectedLines[index].utf8), "line \(index)", file: file, line: line)
                XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: index, language: language),
                               SummaryMarkdownLine.classify(expectedLines, at: index), "display line \(index)",
                               file: file, line: line)
            }
        }
    }

    func testOrderedListFencePreservesKeysAndConvertsFollowingParagraph() throws {
        let code = "1. ```python\n   record[\"头发\"]\n   ```\n\n"
        try assertStructuralRendering(code + "头发在这里。", taiwan: code + "頭髮在這裡。")
    }

    func testListParagraphIndentationIsRelativeToItsContainer() throws {
        try assertStructuralRendering("- 课程内容：\n\n    头发在这里。\n\n- 后面是结论。",
            taiwan: "- 課程內容：\n\n    頭髮在這裡。\n\n- 後面是結論。")
    }

    func testInlineBackticksCannotPairAcrossBlankParagraphs() throws {
        try assertStructuralRendering("这里有一个未闭合标记 `record[\n\n头发在这里。\n\n` 后面是正文。",
            taiwan: "這裡有一個未閉合標記 `record[\n\n頭髮在這裡。\n\n` 後面是正文。")
    }

    func testBlockquoteFenceEndsWhenItsContainerEnds() throws {
        try assertStructuralRendering("这里。\n> ```python\n> record[\"头发\"]\n\n头发在这里。",
            taiwan: "這裡。\n> ```python\n> record[\"头发\"]\n\n頭髮在這裡。")
    }

    func testNestedContainerFencesAndIndentedCodeKeepOriginalBytes() throws {
        for code in ["12) ~~~python\n    record[\"头发\"]\n    ~~~\n\n",
                     "> 1. ```python\n>    record[\"头发\"]\n>    ```\n\n",
                     "- 内容：\n\n      record[\"头发\"]\n\n"] {
            let expectedCode = code.replacingOccurrences(of: "内容", with: "內容")
            try assertStructuralRendering(code + "头发在这里。", taiwan: expectedCode + "頭髮在這裡。")
        }
    }

    func testInlineCodeUsesMarkdownBlockBoundariesAndKeepsSoftLineBreaks() throws {
        let code = "> 这里 `record[\r\n> \"头发\"]` 后面。"
        try assertStructuralRendering(code, taiwan: "> 這裡 `record[\r\n> \"头发\"]` 後面。")
        for input in ["这里 `头发\n# 头发` 后面。", "这里 `头发\n- 头发` 后面。",
                      "> 这里 `头发\n- 头发` 后面。"] {
            try assertStructuralRendering(input,
                taiwan: input.replacingOccurrences(of: "这里", with: "這裡")
                    .replacingOccurrences(of: "头发", with: "頭髮")
                    .replacingOccurrences(of: "后面", with: "後面"))
        }
    }

    func testPreparedDocumentAndDefaultDisplayedEntrypointsAgree() {
        let lines = ["## 课程安排与待办", "```text", "## 学习笔记", "record[\"头发\"]", "```",
                     "- [00:01] 図書館で登记します。 — 头发在这里。", "## 学习笔记",
                     "- **原笔记 · 要点 1**：这里。`record[\"头发\"]` \t",
                     "- **9B 建议（待核对）**：后面。`record[\"头发\"]` \t", "$$", "x_{头发}=1", "$$", ""]
        let evidence = TranscriptSegment(startTime: 1, endTime: 2,
            english: "図書館で登记します。", chinese: "头发在这里。", sourceLanguage: "ja")
        let document = ChineseScriptConverter.RenderText(lines.joined(separator: "\n"))
        for language in [OutputLanguage.traditionalChineseTaiwan, .traditionalChineseHongKong,
                         .simplifiedChinese, .english, .spanish, .french] {
            for index in lines.indices {
                XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: index, language: language,
                    scheduleEvidence: [evidence], document: document),
                    SummaryMarkdownLine.displayed(lines, at: index, language: language, scheduleEvidence: [evidence]))
                XCTAssertEqual(SummaryMarkdownLine.displayed(lines, at: index, language: language,
                    isLegacyRendered: true, document: document), SummaryMarkdownLine.classify(lines, at: index))
            }
        }
    }
}
