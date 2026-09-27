import XCTest
@testable import LiveLingo

/// The screenshot bug was an English sentence stored as the Chinese caption.
/// These tests pin the acceptance rules that must stop it, and the technical
/// exceptions that must keep working.
final class TranslationAcceptanceTests: XCTestCase {
    func testRecoveryRequestBudgetsAccountForProtectedIDsAndStayBounded() {
        let plain = "The temperature rises."
        let dense = (0..<24).map { "ZXQCHEM\($0)QXZ" }.joined(separator: ", ")
        XCTAssertEqual(CaptionTranslationAttempt.standard.outputTokenBudget(for: plain), 160)
        XCTAssertEqual(CaptionTranslationAttempt.standard.outputTokenBudget(for: dense), 352)
        XCTAssertEqual(CaptionTranslationAttempt.expandedBudget.outputTokenBudget(for: dense), 704)
        let many = String(repeating: "ZXQCHEM0QXZ ", count: 1000)
        XCTAssertEqual(CaptionTranslationAttempt.standard.outputTokenBudget(for: many), 640)
        XCTAssertEqual(CaptionTranslationAttempt.expandedBudget.outputTokenBudget(for: many), 1280)
        XCTAssertEqual(CaptionTranslationAttempt.standard.promptSuffix, "")
        XCTAssertEqual(CaptionTranslationAttempt.expandedBudget.promptSuffix, "")
        XCTAssertFalse(CaptionTranslationAttempt.repairContent.promptSuffix.isEmpty)
        XCTAssertNil(CaptionTranslationAttempt.recovery(for: CancellationError()))
    }

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
            ("pH 7.4", "pH 7.4"),
            ("FTIR", "FTIR"),
            ("Dijkstra", "Dijkstra"),
            ("NH3", "NH3"),
            ("4s", "4s"),
            ("298 K", "three hundred Kelvin")
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
        for body in ["偏导数 partial derivative 为正。", "2H2 + O2 → 2H2O", "pH 7.4", "FTIR",
                     "Dijkstra", "ΔG = ΔH − TΔS", "ｐＨ ７．４"] {
            let candidate = TranslationAcceptance.formulaNotice + body
            XCTAssertEqual(try TranslationAcceptance.validated(candidate, source: body + " [Formula transcription uncertain]"), candidate,
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

    func testWholeSpeciesAndChargesAreProtectedButReactionCoefficientsStayVisible() throws {
        let source = "2H₂ + O₂ → 2H₂O; [FeSCN]²⁺ forms from Fe³⁺ and SCN⁻."
        let protected = ChemistryTranslationProtector.prepare(source)
        XCTAssertEqual(protected.text,
                       "2ZXQCHEM0QXZ + ZXQCHEM1QXZ → 2ZXQCHEM2QXZ; ZXQCHEM3QXZ forms from ZXQCHEM4QXZ and ZXQCHEM5QXZ.")
        XCTAssertEqual(try protected.validatedRestore(in: protected.text), source)
        for term in ["[Cu(NH3)4]²⁺", "[Fe(CN)6]3-", "Ca(OH)2", "K₄[Fe(CN)₆]",
                     "CuSO4·5H2O", "¹⁴C", "NH₄⁺", "SO₄²⁻"] {
            let item = ChemistryTranslationProtector.prepare(term)
            XCTAssertEqual(item.text, "ZXQCHEM0QXZ", term)
            XCTAssertEqual(try item.validatedRestore(in: item.text), term)
        }
    }

    func testAlreadyProtectedFormulasDoNotReappearAsAuxiliaryHints() {
        let protected = ChemistryTranslationProtector.prepare("[FeSCN]²⁺ forms from Fe³⁺ and SCN⁻.")
        let hints: [AuxiliaryTranslationHint] = [.init(kind: .formula, value: "Fe³⁺"),
                                                .init(kind: .unit, value: "2 mL"),
                                                .init(kind: .acronym, value: "NMR")]
        XCTAssertEqual(protected.translationHints(from: hints), Array(hints.dropFirst()))
        let plain = ChemistryTranslationProtector.prepare("The lecturer says F E three plus.")
        XCTAssertEqual(plain.translationHints(from: hints), hints)
    }

    func testExplicitLiteralNamesSurviveNormalizationAndTranslationProtection() throws {
        for (source, literal) in [
            (#"Use "S N two" as the exact text in the source code."#, "S N two"),
            ("Use S N twofold as the exact label in the source code.", "S N twofold"),
            ("The literal identifier 'A T P' is different from ATP.", "A T P"),
            ("The exact label is “N two”.", "N two"),
            ("Call the function 'read_file'.", "read_file"),
            ("The variable \"value_two\" differs from value_squared.", "value_two"),
            ("Use `S N two` in the code.", "S N two")
        ] {
            let normalized = AcademicInputNormalizer.normalize(source)
            XCTAssertTrue(normalized.contains(literal), source)
            let protected = ChemistryTranslationProtector.prepare(normalized)
            XCTAssertFalse(protected.text.contains(literal), source)
            XCTAssertEqual(try protected.validatedRestore(in: protected.text), normalized)
        }
        let mixed = #"Use "S N two" as the exact label. The mechanism is S N two."#
        XCTAssertEqual(AcademicInputNormalizer.normalize(mixed),
                       #"Use "S N two" as the exact label. The mechanism is SN2."#)
    }

    func testOrdinaryQuotesAndPronounsDoNotBecomeLiteralNames() {
        for source in ["The lecturer said 'S N two attacks the carbon'.",
                       "The code comments say \"S N two attacks the carbon\"."] {
            let normalized = AcademicInputNormalizer.normalize(source)
            XCTAssertTrue(normalized.contains("SN2 attacks the carbon"))
            XCTAssertEqual(ChemistryTranslationProtector.prepare(normalized).text, normalized)
        }
        for source in ["Use it as the exact text in the source code.",
                       "Use the previous result as the exact label.",
                       "Use this value as the exact name."] {
            XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(source).text, source)
        }
    }

    func testSpokenNamesArePreservedWithoutInventingPowers() throws {
        for source in ["This N two matrix has nonzero entries.",
                       "Compare the vectors N two and M three separately.",
                       "The vector v two is twice v one.",
                       "Vector q four points left; vector q five points right.",
                       "The label x twenty one is not x squared."] {
            let protected = ChemistryTranslationProtector.prepareLiterals(source)
            XCTAssertNotEqual(protected.text, source, source)
            XCTAssertEqual(try protected.validatedRestore(in: protected.text), source)
        }
        XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals("Compare the vectors N two and M three separately.").text,
                       "Compare the vectors ZXQCHEM0QXZ and ZXQCHEM1QXZ separately.")
        XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals("The vector v two is twice v one.").text,
                       "The vector ZXQCHEM0QXZ is twice ZXQCHEM1QXZ.")
        for source in ["Compute x squared plus y cubed.", "Raise z to the fourth power.",
                       "Nitrogen gas is N two.", "A two by two matrix is square."] {
            XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(source).text, source)
        }
        XCTAssertEqual(AcademicInputNormalizer.normalize("The mechanism is S N two."), "The mechanism is SN2.")
    }

    func testLiteralAndFormulaUseSeparateMarkersAndRejectDroppedLiteral() throws {
        let source = #"Use "S N two" as the exact label next to H2O."#
        let protected = ChemistryTranslationProtector.prepare(AcademicInputNormalizer.normalize(source))
        XCTAssertEqual(protected.text, #"Use "ZXQCHEM0QXZ" as the exact label next to ZXQCHEM1QXZ."#)
        XCTAssertEqual(try protected.validatedRestore(in: "在 ZXQCHEM1QXZ 旁边使用 ZXQCHEM0QXZ 作为确切标签。"),
                       "在 H2O 旁边使用 S N two 作为确切标签。")
        XCTAssertThrowsError(try protected.validatedRestore(in: "使用 S N 二作为标签，旁边是 ZXQCHEM1QXZ。"))
    }

    func testMissingDuplicateChangedAndUnknownMarkersCannotBecomeFinalText() {
        let protected = ChemistryTranslationProtector.prepare("Compare Na⁺ with Cl⁻.")
        let broken = [
            "比较 ZXQCHEM0QXZ。",
            "比较 ZXQCHEM0QXZ 和 ZXQCHEM0QXZ。",
            "比较 ZnQCHEM0QXZ 和 ZXQCHEM1QXZ。",
            "比较 ZXQCHEM0QXZ 和 ZXQCHEM10QXZ。",
            "比较 ZXQCHEM0QXZ 和 ZXQCHEM1QXZ，以及 ZXQCHEM2QXZ。",
            "比较 ZXQCHEM0QXZ 和 ZXQCHEM1QXZ QXZ。",
            "比较 ZXQCHEM0QXZ 和 ZXQCHEM1"
        ]
        for output in broken {
            XCTAssertNotNil(protected.restorationFailure(in: output), output)
            XCTAssertThrowsError(try protected.validatedRestore(in: output), output)
        }
        XCTAssertEqual(try protected.validatedRestore(in: "比较 zxqchem0qxz 和 ZXQCHEM1QXZ。"),
                       "比较 Na⁺ 和 Cl⁻。")
        // Chinese can reorder phrases; the structural check does not prove
        // that a formula is attached to the correct subject.
        XCTAssertNil(protected.restorationFailure(in: "ZXQCHEM1QXZ 与 ZXQCHEM0QXZ 不同。"))
    }

    func testSourceLiteralMarkerDoesNotCollideWithGeneratedFormulaMarker() throws {
        let source = "The literal ZXQCHEM0QXZ is not H2O."
        let protected = ChemistryTranslationProtector.prepare(source)
        XCTAssertEqual(protected.text, "The literal ZXQCHEM0QXZ is not ZXQCHEM1QXZ.")
        XCTAssertEqual(try protected.validatedRestore(in: "字面标签 ZXQCHEM0QXZ 不是 ZXQCHEM1QXZ。"),
                       "字面标签 ZXQCHEM0QXZ 不是 H2O。")
        XCTAssertEqual(protected.restorePartial(in: "ZXQCHEM1QXZ 与 ZXQCHEM0QXZ"),
                       "H2O 与 ZXQCHEM0QXZ")
    }

    func testObservedMalformedMarkerIsHeldThroughoutStreaming() {
        let protected = ChemistryTranslationProtector.prepare("[FeSCN]²⁺ forms from Fe³⁺ and SCN⁻.")
        let output = "[ZnQCHEM0QXZ]²⁺ 由 ZXQCHEM1QXZ 和 ZXQCHEM2QXZ 形成。"
        var partial = ""
        for character in output {
            partial.append(character)
            let shown = protected.restorePartial(in: partial).lowercased()
            XCTAssertFalse(shown.contains("zn") || shown.contains("chem") || shown.contains("qxz"), shown)
        }
        XCTAssertThrowsError(try protected.validatedRestore(in: output))
        let ordinary = ChemistryTranslationProtector.prepare("Zero is a number.")
        XCTAssertEqual(ordinary.restorePartial(in: "Zinc"), "Zinc")
    }

    func testCopyInstructionOnlyAppliesToProtectedInput() {
        XCTAssertEqual(ChemistryTranslationProtector.promptSuffix(for: "The velocity is negative."), "")
        XCTAssertEqual(ChemistryTranslationProtector.promptSuffix(for: "Use ZXQCHEM0QXZ."),
                       ChemistryTranslationProtector.copyInstruction)
        let plain = QwenTranslationClient.systemPrompt
        XCTAssertEqual(ChemistryTranslationProtector.translationPrompt(base: plain, text: "Use FTIR first."), plain)
        let masked = ChemistryTranslationProtector.translationPrompt(base: plain, text: "ZXQCHEM0QXZ reacts.")
        XCTAssertTrue(masked.contains(ChemistryTranslationProtector.copyInstruction))
        XCTAssertTrue(masked.hasSuffix("Return only the complete Simplified Chinese translation. Do not use markdown."))
    }

    func testAdjacentContextIsSeparateFromProtectedTarget() throws {
        let protected = ChemistryTranslationProtector.prepare("Na⁺ stays in sample A.")
        let input = try protected.contextualJSON(before: "K⁺ was in sample B.", after: "Next, discuss Cl⁻.")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
        XCTAssertEqual(fields["target_translate_only"], "ZXQCHEM0QXZ stays in sample A.")
        XCTAssertEqual(fields["context_before_do_not_translate"], "K⁺ was in sample B.")
        XCTAssertEqual(fields["context_after_do_not_translate"], "Next, discuss Cl⁻.")
        XCTAssertEqual(try protected.validatedRestore(in: "ZXQCHEM0QXZ 留在 A 样品中。"), "Na⁺ 留在 A 样品中。")
        XCTAssertThrowsError(try protected.validatedRestore(in: "K⁺ 留在 A 样品中。"))
    }

    func testTechnicalListCannotReplaceAnEnglishInstruction() {
        let source = "Use FTIR first, then NMR, and finally LC-MS."
        for output in ["FTIR NMR LC-MS", TranslationAcceptance.formulaNotice + "FTIR NMR LC-MS"] {
            XCTAssertEqual(TranslationAcceptance.rejection(candidate: output, source: source), .incompleteProse)
        }
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: "Dijkstra", source: "The shortest path uses Dijkstra"), .incompleteProse)
        XCTAssertNil(TranslationAcceptance.rejection(candidate: "先用 FTIR，再用 NMR，最后用 LC-MS。", source: source))
    }

    func testUnmaskedRepairPreservesSpeciesBeforeReplacingTheOldCaption() throws {
        let prepared = ChemistryTranslationProtector.prepare("Na⁺ and Cl⁻ are different ions.")
        let json = try prepared.contextualJSON(before: "Earlier context.", after: "Later context.", protectTarget: false)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertEqual(fields["target_translate_only"], "Na⁺ and Cl⁻ are different ions.")
        XCTAssertNil(prepared.unmaskedFailure(in: "Na⁺ 和 Cl⁻ 是不同的离子。"))
        XCTAssertNotNil(prepared.unmaskedFailure(in: "Na⁺ 和 K⁺ 是不同的离子。"))
        XCTAssertNotNil(prepared.unmaskedFailure(in: "Na⁺ 是离子。"))
        XCTAssertNotNil(prepared.unmaskedFailure(in: "Na⁺、Na⁺ 和 Cl⁻ 是离子。"))
        // This first guard is strict about notation; it keeps the previous
        // caption even when an alternative notation might be equivalent.
        XCTAssertNotNil(prepared.unmaskedFailure(in: "Na+ 和 Cl- 是不同的离子。"))
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
