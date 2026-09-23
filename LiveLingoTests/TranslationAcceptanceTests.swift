import XCTest
@testable import LiveLingo

/// The screenshot bug was an English sentence stored as the Chinese caption.
/// These tests pin the acceptance rules that must stop it, and the technical
/// exceptions that must keep working.
final class TranslationAcceptanceTests: XCTestCase {
    private let echoSource = "Do you know what? I don't think that these summaries at the moment do contain"

    func testExactSourceEchoIsRejected() {
        XCTAssertEqual(
            TranslationAcceptance.rejection(candidate: echoSource, source: echoSource),
            .sourceEcho
        )
    }

    func testEchoDifferenceOnlyInCaseAndPunctuationIsRejected() {
        let candidate = "do you know what i dont think that these summaries at the moment do contain!"
        XCTAssertEqual(
            TranslationAcceptance.rejection(candidate: candidate, source: echoSource),
            .sourceEcho
        )
    }

    func testNearlyVerbatimEnglishIsRejected() {
        let candidate = "Do you know what? I think that these summaries at the moment do contain"
        XCTAssertEqual(
            TranslationAcceptance.rejection(candidate: candidate, source: echoSource),
            .sourceEcho
        )
    }

    func testEnglishSentenceThatIsNotAnEchoIsRejected() {
        let candidate = "This summary covers the main ideas of the lecture today"
        let source = "The lecture continues with a short break before the next part"
        XCTAssertEqual(
            TranslationAcceptance.rejection(candidate: candidate, source: source),
            .englishProse
        )
    }

    func testChineseTranslationIsAccepted() {
        let candidate = "你知道吗？我认为目前这些总结并没有包含这些内容。"
        XCTAssertNil(TranslationAcceptance.rejection(candidate: candidate, source: echoSource))
    }

    func testMixedChineseAndEnglishOutputIsAccepted() {
        let candidate = "机器学习 machine learning 是人工智能的一个分支。"
        XCTAssertNil(TranslationAcceptance.rejection(
            candidate: candidate,
            source: "Machine learning is a branch of artificial intelligence"
        ))
    }

    func testFormulasNumbersUnitsAndAcronymsAreAccepted() {
        let accepted: [(candidate: String, source: String)] = [
            ("2H2 + O2 → 2H2O", "two H two plus O two gives two H two O"),
            ("pH 7.4", "the pH of this solution is 7.4"),
            ("FTIR", "we measured the sample with FTIR"),
            ("Dijkstra", "the shortest path uses Dijkstra"),
            ("NH3", "ammonia is written as NH3"),
            ("4s", "we fill the 4s orbital first"),
            ("298 K", "the temperature is 298 K")
        ]
        for item in accepted {
            XCTAssertNil(
                TranslationAcceptance.rejection(candidate: item.candidate, source: item.source),
                "应当放行的技术性回答：\(item.candidate)"
            )
        }
    }

    func testProtectedFormulaPlaceholdersAreNotTreatedAsAnEcho() {
        let source = "ZXQCHEM0QXZ + ZXQCHEM1QXZ"
        XCTAssertNil(TranslationAcceptance.rejection(candidate: source, source: source))
    }

    func testPromptAndStructureLeakageIsRejected() {
        let leaks = [
            #"{"target_translate_only": "Do you know what?"}"#,
            #"{"context_before_do_not_translate": "..."}"#,
            "```json\n{\"translation\": \"你好\"}\n```",
            "Primary ASR transcript: hello",
            "As an AI language model, I cannot translate this."
        ]
        for leak in leaks {
            XCTAssertEqual(
                TranslationAcceptance.rejection(candidate: leak, source: echoSource),
                .promptLeak,
                "应当识别为提示词或结构泄漏：\(leak.prefix(40))"
            )
        }
    }

    func testControlMarkersAndEmptyResultsAreRejected() {
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: "<|im_end|>", source: echoSource), .controlMarker)
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: "   \n ", source: echoSource), .empty)
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: "", source: echoSource), .empty)
    }

    func testValidatedThrowsASubtitleSafeMessage() {
        let error = assertThrows {
            _ = try TranslationAcceptance.validated(echoSource, source: echoSource)
        }
        XCTAssertTrue(error is QwenRuntimeError)
        XCTAssertTrue(error.localizedDescription.contains("原样复述"))
    }

    func testEchoDetectionIgnoresWidthAndDiacritics() {
        let candidate = "Ｄｏ ｙｏｕ ｋｎｏｗ ｗｈａｔ"
        XCTAssertEqual(
            TranslationAcceptance.rejection(candidate: candidate, source: "Do you know what"),
            .sourceEcho
        )
    }

    func testApplicationFormulaNoticeCannotMakeAnEnglishEchoPass() {
        let source = "The partial derivative is positive [Formula transcription uncertain]"
        let notice = TranslationAcceptance.formulaNotice
        for candidate in [notice + source, notice + "\n" + notice + source] {
            XCTAssertEqual(TranslationAcceptance.rejection(candidate: candidate, source: source), .sourceEcho)
            XCTAssertThrowsError(try TranslationAcceptance.validated(candidate, source: source),
                                 "还原及重试路径的二次验收也必须忽略应用添加的中文提示")
        }
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: notice + " \n", source: source), .empty)
    }

    func testChinesePunctuationDoesNotMakeEnglishProsePass() {
        let candidate = "Do you know what？ I think that these summaries at the moment do contain。"
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: candidate, source: echoSource), .sourceEcho)
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: "！？。", source: echoSource), .empty)
    }

    func testFullwidthEnglishProseIsRejectedWithoutAnExactSourceMatch() {
        let candidate = "Ｔｈｉｓ ｓｕｍｍａｒｙ ｃｏｖｅｒｓ ｔｈｅ ｌｅｃｔｕｒｅ ｔｏｄａｙ。"
        XCTAssertEqual(
            TranslationAcceptance.rejection(candidate: candidate, source: "The reaction produces oxygen."),
            .englishProse
        )
    }

    func testKanaAndHangulDoNotSupplyChineseTranslationEvidence() {
        for candidate in ["これはてすとです。", "カタカナ", "ｶﾀｶﾅ", "이것은 번역입니다.",
                          "This summary covers the lecture today。かな"] {
            XCTAssertEqual(TranslationAcceptance.rejection(candidate: candidate, source: echoSource),
                           .nonChineseText, candidate)
        }
    }

    func testFormulaNoticePreservesChineseAndTechnicalExceptions() throws {
        let source = "The partial derivative is positive [Formula transcription uncertain]"
        for body in ["偏导数 partial derivative 为正。", "2H2 + O2 → 2H2O", "pH 7.4", "FTIR",
                     "Dijkstra", "ΔG = ΔH − TΔS", "ｐＨ ７．４"] {
            let candidate = TranslationAcceptance.formulaNotice + body
            XCTAssertEqual(try TranslationAcceptance.validated(candidate, source: source), candidate,
                           "验收不得删掉有效译文的提示、公式、单位或专名")
        }
    }

    private func assertThrows(_ body: () throws -> Void) -> Error {
        do {
            try body()
            XCTFail("预期抛出错误")
            return NSError(domain: "unexpected", code: 0)
        } catch {
            return error
        }
    }

    /// 公式保护的往返与流式安全（`ProtectedChemistryTranslationInput` 此前无任何测试）：
    /// ① 保护→还原必须恒等；② 逐字符喂入的部分输出**任何时刻都不得泄漏占位符**——
    /// 后者直接决定实时字幕会不会闪出 `ZXQCHEM0QXZ` 这种内部标记。
    func testProtectedFormulasRoundTripAndNeverLeakPlaceholdersWhileStreaming() {
        let source = "The ion is Fe3+ and the complex is [FeSCN]2+; lattice energy uses Na+ and SO4^2-."
        let protected = ChemistryTranslationProtector.prepare(source)
        XCTAssertTrue(protected.text.contains("ZXQCHEM"), "这段文本应当触发保护，否则本测试没有意义")

        XCTAssertEqual(protected.restore(in: protected.text), source,
                       "保护→还原必须是恒等：\(protected.restore(in: protected.text))")

        var partial = ""
        var leaks: [String] = []
        for character in protected.text {
            partial.append(character)
            let shown = protected.restorePartial(in: partial)
            // 绊线用**前三个字符**（zxq）与结尾（qxz）：半截占位符（如 ZXQCH）也必须被扣住，
            // 只查完整串是不够的——这正是流式预览最容易闪出内部标记的地方。
            let lowered = shown.lowercased()
            if lowered.contains("zxq") || lowered.contains("qxz") || lowered.contains("chem") {
                leaks.append(shown)
            }
        }
        XCTAssertTrue(leaks.isEmpty, "流式输出泄漏了占位符片段：\(leaks.prefix(3))")

        XCTAssertEqual(protected.restorePartial(in: protected.text), source, "完整喂完后应还原成原文")
    }

    // MARK: - SSE 流式解析（QwenSSEParser，此前无测试）

    private func events(from text: String) throws -> [String] {
        var parser = QwenSSEParser()
        var collected: [String] = []
        for byte in Array(text.utf8) {
            if let event = try parser.consume(byte) { collected.append(event) }
        }
        return collected
    }

    /// 解析错了会让流式字幕乱掉，所以这些边界都要钉住：
    /// CRLF 不能算两个空行、多行 data 要合并、注释/非 data 字段要忽略、首个 BOM 要去掉、
    /// 最后一行没有换行符时**不得**提前吐出半截事件。
    func testSSEParserHandlesTheFramingEdgeCases() throws {
        XCTAssertEqual(try events(from: "data: {\"a\":1}\n\n"), ["{\"a\":1}"], "基本事件")
        XCTAssertEqual(try events(from: "data: x\r\n\r\n"), ["x"], "CRLF 只能算一个事件分隔，不能变成两个")
        XCTAssertEqual(try events(from: "data: a\ndata: b\n\n"), ["a\nb"], "同一事件的多行 data 用换行合并")
        XCTAssertEqual(try events(from: ": keep-alive\n\n"), [], "注释行不产生事件")
        XCTAssertEqual(try events(from: "event: message\ndata: x\n\n"), ["x"], "非 data 字段应忽略")
        XCTAssertEqual(try events(from: "data:x\n\n"), ["x"], "冒号后没有空格也要收")
        XCTAssertEqual(try events(from: "data:  x\n\n"), [" x"], "只吃掉一个空格，多余的要保留")
        XCTAssertEqual(try events(from: "\u{FEFF}data: x\n\n"), ["x"], "首个 BOM 不能进到事件里")
        XCTAssertEqual(try events(from: "data: x"), [], "没有结束空行时不得吐出半截事件")

        // 两个事件连着来
        XCTAssertEqual(try events(from: "data: 1\n\ndata: 2\n\n"), ["1", "2"], "连续事件")
    }

    /// 上限保护：一行过长或一次事件的 data 过大都要报错，而不是无限吃内存。
    func testSSEParserRejectsOversizedInput() throws {
        var parser = QwenSSEParser()
        var threw = false
        do {
            for _ in 0..<1_048_700 { _ = try parser.consume(0x61) }
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "超长行必须报错")
    }
}
