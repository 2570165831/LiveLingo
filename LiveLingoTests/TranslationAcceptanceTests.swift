import XCTest
@testable import LiveLingo

/// The screenshot bug was an English sentence stored as the Chinese caption.
/// These tests pin the acceptance rules that must stop it, and the technical
/// exceptions that must keep working.
final class TranslationAcceptanceTests: XCTestCase {
    func testNegationExamplesExcludeWordFragmentsAndProtectedNames() {
        for source in ["Open the notebook beside the nozzle.", "The field is not_ready.",
                       #"Use the exact labels "not good" and "no charge"."#] {
            let prepared = ChemistryTranslationProtector.prepare(source)
            let original = ChemistryTranslationProtector.translationPrompt(base: QwenTranslationClient.systemPrompt, text: prepared.text)
            XCTAssertEqual(ChemistryTranslationProtector.translationPrompt(
                base: QwenTranslationClient.systemPrompt, text: prepared.text,
                modelName: QwenModelProfile.energySaver.translationModel), original, source)
        }
    }

    func testNegationExamplesAreLimitedToTheExact4BProfile() {
        for source in ["No samples are contaminated.", "Don't stop.", "It wasn’t empty.",
                       "Neither sensor is faulty.", "The result cannot be correct."] {
            let original = ChemistryTranslationProtector.translationPrompt(base: QwenTranslationClient.systemPrompt, text: source)
            for model in [QwenModelProfile.highQuality.translationModel, "other-model",
                          "prefix-" + QwenModelProfile.energySaver.translationModel] {
                XCTAssertEqual(ChemistryTranslationProtector.translationPrompt(
                    base: QwenTranslationClient.systemPrompt, text: source, modelName: model), original)
            }
            XCTAssertNotEqual(ChemistryTranslationProtector.translationPrompt(
                base: QwenTranslationClient.systemPrompt, text: source, modelName: QwenModelProfile.energySaver.translationModel), original)
        }
    }

    func testTypedNegationRoutingPreservesSourceModeAndOneRequest() async throws {
        let source = "You must not stop the experiment."
        for model in [QwenModelProfile.energySaver.translationModel, QwenModelProfile.highQuality.translationModel] {
            for thinking in [false, true] {
                let counter = TypedRequestCounter()
                let result = try await QwenTranslationClient.translateTypedText(source,
                    modelName: model, thinking: thinking, request: { input, prompt, actualThinking in
                        await counter.record()
                        XCTAssertEqual(try Self.typedSource(in: input), source)
                        XCTAssertEqual(actualThinking, thinking)
                        XCTAssertEqual(prompt.contains(ChemistryTranslationProtector.negationInstruction),
                                       model == QwenModelProfile.energySaver.translationModel)
                        return "你不得停止实验。"
                    })
                XCTAssertEqual(result, "你不得停止实验。")
                let count = await counter.count()
                XCTAssertEqual(count, 1)
            }
        }
    }

    func testCaptionNegationRoutingPreservesInputBudgetAndOneRequest() async throws {
        let source = "You must not stop the experiment."
        for model in [QwenModelProfile.energySaver.translationModel, QwenModelProfile.highQuality.translationModel] {
            let counter = TypedRequestCounter()
            let result = try await QwenTranslationClient.translateAdjacent(
                previous: "", previousChinese: "", current: source, context: "",
                modelName: model, repairPrevious: false, request: { input, prompt, budget in
                    await counter.record()
                    XCTAssertEqual(model == QwenModelProfile.highQuality.translationModel
                        ? try Self.typedSource(in: input) : input, source)
                    XCTAssertEqual(budget, CaptionTranslationAttempt.standard.outputTokenBudget(for: source))
                    XCTAssertEqual(prompt.contains(ChemistryTranslationProtector.negationInstruction),
                                   model == QwenModelProfile.energySaver.translationModel)
                    return "你不得停止实验。"
                })
            XCTAssertEqual(result.current, "你不得停止实验。")
            XCTAssertNil(result.currentRejection)
            let count = await counter.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testLiteralDefinitionKeepsItsClauseInstructionWithoutAffectingOrdinarySpeech() {
        for source in [#"The literal text is "S N two", and the mechanism is SN2."#,
                       #"The exact string is "low", while the temperature is 30 K."#] {
            let prepared = ChemistryTranslationProtector.prepare(source)
            XCTAssertTrue(ChemistryTranslationProtector.promptSuffix(for: prepared.text)
                .contains(ChemistryTranslationProtector.literalDefinitionInstruction))
        }
        for source in [#"The lecturer said "the literal text is wrong"."#,
                       #"Use the exact label "speed" beside the scalar value."#,
                       "The acceleration is zero, but the velocity is not zero."] {
            let prepared = ChemistryTranslationProtector.prepare(source)
            XCTAssertFalse(ChemistryTranslationProtector.promptSuffix(for: prepared.text)
                .contains(ChemistryTranslationProtector.literalDefinitionInstruction))
        }
    }

    private actor TypedRequestCounter {
        private var value = 0
        func record() { value += 1 }
        func count() -> Int { value }
    }

    private static func typedSource(in input: String) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["source_text_to_translate"])
        return try XCTUnwrap(object["source_text_to_translate"])
    }

    func testCaptionDataBoundaryPreservesQuotesNewlinesAndUnicode() async throws {
        let source = "He wrote \"stop\".\nThen compare a slash /, \\n and café."
        let expected = "他写了\"停止\"。\n然后比较斜杠 /、\\n 和咖啡馆。"
        let counter = TypedRequestCounter()
        let result = try await QwenTranslationClient.translateAdjacent(
            previous: "", previousChinese: "", current: source, context: "",
            modelName: QwenModelProfile.highQuality.translationModel, repairPrevious: false,
            request: { input, _, budget in
                await counter.record()
                XCTAssertEqual(try Self.typedSource(in: input), source)
                XCTAssertEqual(budget, 160)
                return expected
            })
        XCTAssertEqual(result.current, expected)
        XCTAssertNil(result.currentRejection)
        let count = await counter.count()
        XCTAssertEqual(count, 1)
    }

    func testCaptionHintsStayOutsideSourceAndKeepTheExistingLimit() async throws {
        let source = "The current is 2 A."
        let hints = (1...10).map { AuxiliaryTranslationHint(kind: .unit, value: "\($0) A") }
        let result = try await QwenTranslationClient.translateAdjacent(
            previous: "", previousChinese: "", current: source, context: "",
            modelName: QwenModelProfile.highQuality.translationModel, repairPrevious: false,
            currentHints: hints, request: { input, _, budget in
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
                XCTAssertEqual(payload["source_text_to_translate"] as? String, source)
                XCTAssertEqual(payload["auxiliary_token_hints"] as? [String], (1...8).map { "- unit: \($0) A" })
                XCTAssertEqual(Set(payload.keys), ["source_text_to_translate", "auxiliary_token_hints"])
                XCTAssertEqual(budget, 160)
                return "电流为 2 A。"
            })
        XCTAssertEqual(result.current, "电流为 2 A。")
    }

    func testCaptionDataBoundaryLeavesOtherModelProfilesUnchanged() async throws {
        let source = #"Repeat "the switch is off" twice."#
        for model in [QwenModelProfile.energySaver.translationModel, "other-model",
                      "prefix-" + QwenModelProfile.highQuality.translationModel] {
            let result = try await QwenTranslationClient.translateAdjacent(
                previous: "", previousChinese: "", current: source, context: "",
                modelName: model, repairPrevious: false,
                currentHints: [.init(kind: .unit, value: "2 s")], request: { input, prompt, budget in
                    XCTAssertEqual(input, source)
                    XCTAssertFalse(prompt.contains("Translate only the source_text_to_translate value"))
                    XCTAssertEqual(budget, 160)
                    return "重复“开关是关着的”两次。"
                })
            XCTAssertEqual(result.current, "重复“开关是关着的”两次。")
        }
    }

    func testCaptionReservedFieldInSourceKeepsLiteralFallback() async throws {
        for field in ["source_text_to_translate", "SOURCE_TEXT_TO_TRANSLATE"] {
            let source = "The field \(field) contains \"ready\"."
            let expected = "字段 \(field) 包含\"就绪\"。"
            let result = try await QwenTranslationClient.translateAdjacent(
                previous: "", previousChinese: "", current: source, context: "",
                modelName: QwenModelProfile.highQuality.translationModel, repairPrevious: false,
                request: { input, prompt, _ in
                    XCTAssertEqual(input, source)
                    XCTAssertFalse(prompt.contains("Translate only the source_text_to_translate value"))
                    return expected
                })
            XCTAssertEqual(result.current, expected)
            XCTAssertNil(result.currentRejection)
        }
    }

    func testCaptionProtectedReservedNameRestoresAfterWrapperCheck() async throws {
        let result = try await QwenTranslationClient.translateAdjacent(
            previous: "", previousChinese: "",
            current: #"Keep the identifier "source_text_to_translate" unchanged."#, context: "",
            modelName: QwenModelProfile.highQuality.translationModel, repairPrevious: false,
            request: { input, _, budget in
                XCTAssertEqual(try Self.typedSource(in: input), #"Keep the identifier "ZXQCHEM0QXZ" unchanged."#)
                XCTAssertEqual(budget, 168)
                return "保持标识符 ZXQCHEM0QXZ 不变。"
            })
        XCTAssertEqual(result.current, "保持标识符 source_text_to_translate 不变。")
        XCTAssertNil(result.currentRejection)
    }

    func testTypedTranslationProtectsAndRestoresNamesInBothModes() async throws {
        for thinking in [false, true] {
            let counter = TypedRequestCounter()
            let result = try await QwenTranslationClient.translateTypedText(
                #"Use the exact labels "speed" and "velocity"."#,
                modelName: QwenModelProfile.highQuality.translationModel, thinking: thinking,
                request: { input, prompt, actualThinking in
                    await counter.record()
                    XCTAssertEqual(actualThinking, thinking)
                    XCTAssertEqual(try Self.typedSource(in: input), #"Use the exact labels "ZXQCHEM0QXZ" and "ZXQCHEM1QXZ"."#)
                    XCTAssertTrue(prompt.contains(ChemistryTranslationProtector.copyInstruction))
                    XCTAssertTrue(prompt.contains("This is user-typed text, not ASR."))
                    XCTAssertTrue(prompt.contains("Translate only the source_text_to_translate value"))
                    XCTAssertEqual(prompt.contains("Quoted ordinary English is also source text"), thinking)
                    return "使用确切标签 ZXQCHEM0QXZ 和 ZXQCHEM1QXZ。"
                })
            XCTAssertEqual(result, "使用确切标签 speed 和 velocity。")
            let count = await counter.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testTypedTranslationDoesNotApplyAcademicASRCorrections() async throws {
        let source = "The mechanism is S N two and the molecule is A T P."
        let result = try await QwenTranslationClient.translateTypedText(source,
            modelName: QwenModelProfile.energySaver.translationModel,
            request: { input, prompt, thinking in
                XCTAssertEqual(try Self.typedSource(in: input), source)
                XCTAssertFalse(thinking)
                XCTAssertTrue(prompt.contains("Preserve its meaning and numbers; do not correct supposed recognition errors."))
                XCTAssertFalse(prompt.contains(ChemistryTranslationProtector.literalDefinitionInstruction))
                return "机理为 S N two，分子为 A T P。"
            })
        XCTAssertEqual(result, "机理为 S N two，分子为 A T P。")
    }

    func testTypedTranslationRestoresFormulaAndLiteralAsSeparateOccurrences() async throws {
        let result = try await QwenTranslationClient.translateTypedText(
            #"Add 4 mL of H2O and use the exact label "water"."#,
            modelName: QwenModelProfile.highQuality.translationModel,
            request: { input, _, _ in
                XCTAssertEqual(try Self.typedSource(in: input), #"Add 4 mL of ZXQCHEM0QXZ and use the exact label "ZXQCHEM1QXZ"."#)
                return "加入 4 mL 的 ZXQCHEM0QXZ，并使用确切标签 ZXQCHEM1QXZ。"
            })
        XCTAssertEqual(result, "加入 4 mL 的 H2O，并使用确切标签 water。")
    }

    func testTypedTranslationRejectsLostRepeatedAndMalformedNamesWithoutRetry() async {
        for bad in ["保留 ZXQCHEM0QXZ。", "保留 ZXQCHEM0QXZ、ZXQCHEM1QXZ、ZXQCHEM1QXZ。",
                    "保留 ZXQCHEM0QXZ 和 ZXQCHEM9QXZ。"] {
            let counter = TypedRequestCounter()
            do {
                _ = try await QwenTranslationClient.translateTypedText(
                    #"Use the exact labels "left" and "right"."#,
                    modelName: QwenModelProfile.highQuality.translationModel,
                    request: { _, _, _ in await counter.record(); return bad })
                XCTFail("Invalid literal restoration was accepted")
            } catch {
                guard case QwenRuntimeError.translationRejected = error else {
                    XCTFail("Unexpected error: \(error)"); continue
                }
            }
            let count = await counter.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testTypedTranslationRejectsEnglishEchoButKeepsStandaloneFormula() async throws {
        do {
            _ = try await QwenTranslationClient.translateTypedText("Compare the two vectors.",
                modelName: QwenModelProfile.highQuality.translationModel,
                request: { input, _, _ in try Self.typedSource(in: input) })
            XCTFail("An English sentence echo is not a Chinese translation")
        } catch {
            guard case QwenRuntimeError.translationRejected = error else {
                XCTFail("Unexpected error: \(error)"); return
            }
        }
        let formula = try await QwenTranslationClient.translateTypedText("H2O",
            modelName: QwenModelProfile.highQuality.translationModel,
            request: { input, _, _ in try Self.typedSource(in: input) })
        XCTAssertEqual(formula, "H2O")
    }

    func testTypedTranslationKeepsQuotesAndNewlinesInsideSource() async throws {
        let source = "He wrote \"stop\".\nThen compare a slash / and \\n."
        let expected = "他写了\"停止\"。\n然后比较斜杠 / 和 \\n。"
        let result = try await QwenTranslationClient.translateTypedText(source,
            modelName: QwenModelProfile.highQuality.translationModel,
            request: { input, _, _ in
                XCTAssertEqual(try Self.typedSource(in: input), source)
                return expected
            })
        XCTAssertEqual(result, expected)
    }

    func testTypedTranslationDoesNotConfuseSourceJSONWithItsWrapper() async throws {
        let source = "He wrote \"stop\".\nThen compare {\"source_text_to_translate\":\"go\"} and \\n."
        let expected = "他写了\"停止\"。\n然后比较 {\"source_text_to_translate\":\"走\"} 和 \\n。"
        for thinking in [false, true] {
            let result = try await QwenTranslationClient.translateTypedText(source,
                modelName: QwenModelProfile.highQuality.translationModel, thinking: thinking,
                request: { input, prompt, _ in
                    XCTAssertEqual(input, source)
                    XCTAssertFalse(prompt.contains("Translate only the source_text_to_translate value"))
                    XCTAssertFalse(prompt.contains("Quoted ordinary English is also source text"))
                    return expected
                })
            XCTAssertEqual(result, expected)
        }
    }

    func testTypedTranslationRejectsLeakedWrapperForFormulaAndProse() async {
        for source in ["H2O", "The velocity is zero."] {
            let counter = TypedRequestCounter()
            do {
                _ = try await QwenTranslationClient.translateTypedText(source,
                    modelName: QwenModelProfile.highQuality.translationModel,
                    request: { input, _, _ in
                        await counter.record()
                        if source == "H2O" { return input }
                        return #"{"source_text_to_translate":"速度为零。"}"#
                    })
                XCTFail("The input wrapper must not be shown as a translation")
            } catch {
                guard case QwenRuntimeError.translationRejected = error else {
                    XCTFail("Unexpected error: \(error)"); continue
                }
            }
            let count = await counter.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testTypedTranslationPropagatesCancellationAndRuntimeFailureOnce() async {
        for cancelled in [false, true] {
            let counter = TypedRequestCounter()
            do {
                _ = try await QwenTranslationClient.translateTypedText("Translate this sentence.",
                    modelName: QwenModelProfile.highQuality.translationModel,
                    request: { _, _, _ in
                        await counter.record()
                        if cancelled { throw CancellationError() }
                        throw QwenRuntimeError.serviceUnavailable
                    })
                XCTFail("Failed request was accepted")
            } catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else if case QwenRuntimeError.serviceUnavailable = error { }
                else { XCTFail("Unexpected error: \(error)") }
            }
            let count = await counter.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testExplicitLiteralListsPreserveEveryQuotedName() throws {
        let cases: [(String, String)] = [
            (#"Use the exact labels "force" and "mass" in the two columns."#,
             #"Use the exact labels "ZXQCHEM0QXZ" and "ZXQCHEM1QXZ" in the two columns."#),
            (#"The literal identifiers are "alpha", "beta", and "gamma"."#,
             #"The literal identifiers are "ZXQCHEM0QXZ", "ZXQCHEM1QXZ", and "ZXQCHEM2QXZ"."#),
            (#"Use "east" and "west" as the exact labels."#,
             #"Use "ZXQCHEM0QXZ" and "ZXQCHEM1QXZ" as the exact labels."#),
            (#"The exact names are "red", "green" or "blue"."#,
             #"The exact names are "ZXQCHEM0QXZ", "ZXQCHEM1QXZ" or "ZXQCHEM2QXZ"."#),
            ("Use the exact labels “position”, “speed”, and “time” on the chart.",
             "Use the exact labels “ZXQCHEM0QXZ”, “ZXQCHEM1QXZ”, and “ZXQCHEM2QXZ” on the chart.")
        ]
        for (source, expected) in cases {
            let prepared = ChemistryTranslationProtector.prepareLiterals(source)
            XCTAssertEqual(prepared.text, expected, source)
            XCTAssertEqual(try prepared.validatedRestore(in: expected), source)
        }
    }

    func testExactLabelInstructionContinuesIntoParallelLabelAssignment() throws {
        let cases: [(String, String)] = [
            (#"Use the exact label "speed" beside the scalar value, and label the vector as "velocity"."#,
             #"Use the exact label "ZXQCHEM0QXZ" beside the scalar value, and label the vector as "ZXQCHEM1QXZ"."#),
            (#"Use the exact label "left" (not a direction), and label the other vector as "right"."#,
             #"Use the exact label "ZXQCHEM0QXZ" (not a direction), and label the other vector as "ZXQCHEM1QXZ"."#),
            (#"Use the exact label "mass", and label the graph as "energy" or "force"."#,
             #"Use the exact label "ZXQCHEM0QXZ", and label the graph as "ZXQCHEM1QXZ" or "ZXQCHEM2QXZ"."#)
        ]
        for (source, expected) in cases {
            let prepared = ChemistryTranslationProtector.prepareLiterals(source)
            XCTAssertEqual(prepared.text, expected, source)
            XCTAssertEqual(try prepared.validatedRestore(in: expected), source)
        }
    }

    func testLiteralCoordinationDoesNotCrossNewLinesSentencesOrReportingClauses() {
        let tails = [
            #", but translate "energy"."#,
            #", and call this effect "gravity"."#,
            #", and the lecturer says "energy"."#,
            #", then label the graph as "energy"."#,
            #"; and label the graph as "energy"."#,
            #". And label the graph as "energy"."#,
            "\nand label the graph as \"energy\".",
            "\r\nand label the graph as \"energy\".",
            "\nand \"energy\".",
            ", and explain why \"energy is conserved\"."
        ]
        for tail in tails {
            let source = #"Use the exact label "mass""# + tail
            XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(source).text,
                           #"Use the exact label "ZXQCHEM0QXZ""# + tail, source)
        }
        for source in [#"The lecturer said "speed rises" and "velocity changes direction"."#,
                       #"Call the process "diffusion" and the movement "Brownian motion"."#,
                       #"Does "constant speed" imply "constant velocity"?"#,
                       #"Translate "mass" and "energy" into Chinese."#] {
            XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(source).text, source)
        }
    }

    func testLiteralContractionsKeepTheirWholeQuotedSpelling() throws {
        for (source, expected) in [
            ("The exact label is 'can't'.", "The exact label is 'ZXQCHEM0QXZ'."),
            ("The exact label is ‘won’t’.", "The exact label is ‘ZXQCHEM0QXZ’."),
            ("The literal names are 'can't' and 'won’t'.", "The literal names are 'ZXQCHEM0QXZ' and 'ZXQCHEM1QXZ'."),
            ("The literal strings were ‘can’t’ and ‘won’t’.", "The literal strings were ‘ZXQCHEM0QXZ’ and ‘ZXQCHEM1QXZ’.")
        ] {
            let prepared = ChemistryTranslationProtector.prepareLiterals(source)
            XCTAssertEqual(prepared.text, expected, source)
            XCTAssertEqual(try prepared.validatedRestore(in: expected), source)
        }
        let speech = "The lecturer said 'can't stop' and 'won't move'."
        XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(speech).text, speech)
    }

    func testPositionalCodeNamesKeepTheNameAndSurroundingNegation() throws {
        for position in ["lower", "upper"] {
            let source = "We call the \(position) vector \"q seven\", not the other vector."
            let expected = "We call the \(position) vector \"ZXQCHEM0QXZ\", not the other vector."
            let prepared = ChemistryTranslationProtector.prepareLiterals(source)
            XCTAssertEqual(prepared.text, expected)
            XCTAssertEqual(try prepared.validatedRestore(in: prepared.text), source)
        }
        let concept = #"We call the lower process "diffusion"."#
        XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(concept).text, concept)
    }

    func testCoordinatedLiteralNamesRemainStrictlyRestored() throws {
        let source = #"The literal identifiers are "alpha" and "beta"."#
        let prepared = ChemistryTranslationProtector.prepare(source)
        XCTAssertEqual(try prepared.validatedRestore(in: "字面标识符为 ZXQCHEM0QXZ 和 ZXQCHEM1QXZ。"),
                       "字面标识符为 alpha 和 beta。")
        XCTAssertThrowsError(try prepared.validatedRestore(in: "字面标识符为 ZXQCHEM0QXZ。"))
        XCTAssertThrowsError(try prepared.validatedRestore(in: "ZXQCHEM0QXZ、ZXQCHEM1QXZ 和 ZXQCHEM1QXZ。"))
        XCTAssertFalse(prepared.restorePartial(in: "字面标识符为 ZXQCHEM0QXZ 和 ZXQCH").contains("ZXQ"))
    }

    func testLiteralListsStaySeparateFromAcademicNormalizationAndFormulas() throws {
        let source = #"The exact names are "N A D H" and "A T P"; the molecules are N A D H and A T P."#
        let normalized = AcademicInputNormalizer.normalize(source)
        XCTAssertEqual(normalized,
            #"The exact names are "N A D H" and "A T P"; the molecules are NADH and ATP."#)
        let prepared = ChemistryTranslationProtector.prepare(normalized)
        XCTAssertEqual(try prepared.validatedRestore(in: prepared.text), normalized)
        let mixed = #"Add 4 mL of H2O, and keep the exact label "water" on the sample."#
        XCTAssertEqual(ChemistryTranslationProtector.prepare(mixed).text,
            #"Add 4 mL of ZXQCHEM0QXZ, and keep the exact label "ZXQCHEM1QXZ" on the sample."#)
    }
    func testShortCaptionLengthPreservesTermsButRejectsRunawayChinese() throws {
        let positive: [(String, String)] = [
            ("Okay.", "好的。"), ("Not yet.", "还没有。"),
            ("FTIR", "傅里叶变换红外光谱"), ("HIV", "人类免疫缺陷病毒"),
            ("qPCR", "实时荧光定量聚合酶链式反应"),
            ("Less, not more.", "少一些，而不是更多。"),
            ("Na⁺ and Cl⁻.", "Na⁺ 和 Cl⁻。"),
            ("[Cu(NH3)4]²⁺", "[Cu(NH3)4]²⁺"),
            ("Dijkstra", "Dijkstra"), ("2H2 + O2 → 2H2O", "2H2 + O2 → 2H2O")
        ]
        for (source, candidate) in positive {
            XCTAssertEqual(try TranslationAcceptance.validatedCaption(candidate, source: source), candidate)
        }
        let unrelated = String(repeating: "这是别的段落的内容。", count: 8)
        for source in ["Okay.", "Compare Na⁺ with Cl⁻."] {
            XCTAssertThrowsError(try TranslationAcceptance.validatedCaption(unrelated, source: source))
        }
    }

    func testApplicationFormulaNoticeDoesNotConsumeTranslationLengthAllowance() throws {
        let body = String(repeating: "中", count: 31)
        let source = "The force stays constant."
        XCTAssertTrue(TranslationLengthGuard.isPlausible(chinese: body, english: source))
        for candidate in [TranslationAcceptance.formulaNotice + body,
                          TranslationAcceptance.formulaNotice + "\n" + TranslationAcceptance.formulaNotice + body] {
            XCTAssertEqual(try TranslationAcceptance.validatedCaption(candidate, source: source), candidate)
        }
    }

    func testLengthGuardCountsEverySupportedHanRange() {
        for character in ["中", "㐀", "𠀀", "𰀀"] {
            let candidate = String(repeating: character, count: 80)
            XCTAssertThrowsError(try TranslationAcceptance.validatedCaption(candidate,
                source: "The force stays constant."), "Han evidence and Han length must use the same character ranges")
        }
    }

    func testWhitespacePaddingCannotDisableShortCaptionLengthGuard() {
        let source = String(repeating: " ", count: 60) + "Okay." + String(repeating: " \n", count: 30)
        XCTAssertThrowsError(try TranslationAcceptance.validatedCaption(
            String(repeating: "这是别的段落的内容。", count: 8), source: source))
    }

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

    func testExplicitNamingKeepsCodeLikeLabelsBeforeAcademicCorrection() throws {
        let cases: [(String, [String])] = [
            (#"Call it "N two"."#, ["N two"]),
            (#"We call this matrix "M three"."#, ["M three"]),
            (#"Name the vector "x four"."#, ["x four"]),
            (#"This variable is called "q one"."#, ["q one"]),
            (#"Rename the variable to "sample_A"."#, ["sample_A"]),
            (#"Call the label "S N two"."#, ["S N two"]),
            (#"Name this node "node7"."#, ["node7"]),
            (#"Call it "B"."#, ["B"]),
            (#"Call them "N two" and "M three"."#, ["N two", "M three"]),
            ("The matrix is named “N two”.", ["N two"]),
            ("We label the vector 'v two'.", ["v two"]),
            (#"Call it "N two", not "N squared"."#, ["N two"]),
            ("The variable is named ‘p five’.", ["p five"]),
            (#"Call it "data_set2"."#, ["data_set2"]),
            ("Don't call it 'N two'.", ["N two"]),
            ("Call it N two.", ["N two"]),
            ("Call them N two and M three.", ["N two", "M three"])
        ]
        for (source, names) in cases {
            var expected = source
            for (index, name) in names.enumerated() {
                expected = expected.replacingOccurrences(of: name, with: "ZXQCHEM\(index)QXZ")
            }
            let protected = ChemistryTranslationProtector.prepareLiterals(source)
            XCTAssertEqual(protected.text, expected, source)
            XCTAssertEqual(try protected.validatedRestore(in: protected.text), source)
            XCTAssertEqual(AcademicInputNormalizer.normalize(source), source,
                           "Explicit names must survive before the SN2 correction runs")
            XCTAssertTrue(ChemistryTranslationProtector.promptSuffix(for: protected.text)
                .contains(ChemistryTranslationProtector.namingInstruction), source)
        }
    }

    func testNamingRulesDoNotFreezeOrdinaryTermsQuotesOrDimensions() {
        for source in [#"She said "The force is zero"."#,
                       #"Call it "activation energy"."#, #"Call it "a day"."#,
                       #"This effect is called "resonance"."#, #"Call this answer "incorrect"."#,
                       #"We call it "a two by two matrix"."#, #"Call it "N squared"."#,
                       #"She said "N two is not squared"."#, "We call it a two by two matrix.",
                       #"Call it "a two" on the grading scale."#] {
            XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(source).text, source, source)
        }
    }

    func testNamedLabelDoesNotProtectUnrelatedLaterQuotation() {
        let source = #"Call it "N two". She said "M three is larger"."#
        XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(source).text,
                       #"Call it "ZXQCHEM0QXZ". She said "M three is larger"."#)
        let intervening = #"Call it "N two" and then explain "M three"."#
        XCTAssertEqual(ChemistryTranslationProtector.prepareLiterals(intervening).text,
                       #"Call it "ZXQCHEM0QXZ" and then explain "M three"."#)
    }

    func testNamingCannotReturnOnlyTheProtectedName() throws {
        for source in [#"Call it "N two"."#, #"Call it "B"."#, "Call it N two."] {
            let prepared = ChemistryTranslationProtector.prepare(AcademicInputNormalizer.normalize(source))
            XCTAssertThrowsError(try TranslationAcceptance.validated(#""ZXQCHEM0QXZ"。"#, source: prepared.text))
            XCTAssertThrowsError(try TranslationAcceptance.validated(try prepared.validatedRestore(in: #""ZXQCHEM0QXZ"。"#), source: source))
            XCTAssertEqual(try TranslationAcceptance.validated("称其为 ZXQCHEM0QXZ。", source: prepared.text),
                           "称其为 ZXQCHEM0QXZ。")
        }
        // Formula/name-only inputs legitimately need no Chinese naming verb.
        for source in ["ZXQCHEM0QXZ", "H2O", "N two"] {
            XCTAssertEqual(try TranslationAcceptance.validated(source, source: source), source)
            XCTAssertFalse(ChemistryTranslationProtector.promptSuffix(for: source)
                .contains(ChemistryTranslationProtector.namingInstruction))
        }
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
