import Foundation
import CryptoKit
import XCTest
@testable import LiveLingo

/// Independent acceptance through existing report/binding APIs only.
/// These are provenance hints, never phone validity, ownership or truth verdicts.
final class NumberLiteralIntegrityTests: XCTestCase {
    private let spokenSource = "2.number equals plus 19494682750 in this case."

    private func report(_ claim: String, source: String) -> LearningNumericProvenance.Report {
        LearningNumericProvenance.report(
            claim: claim, cited: [source], segmentTexts: [source], batchTexts: [source])
    }

    private func assertAdvisory(
        _ result: LearningNumericProvenance.Report, literal: String, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(result.isDecidable, "A number literal alone cannot decide truth: \(context)",
                       file: file, line: line)
        XCTAssertFalse(result.gaps.isEmpty, context, file: file, line: line)
        XCTAssertTrue(result.gaps.joined(separator: " ").contains(literal),
                      "Identify the whole claimed literal, not an isolated digit: \(context): \(result.gaps)",
                      file: file, line: line)
    }

    private func assertSupported(
        _ result: LearningNumericProvenance.Report, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(result.isDecidable, context, file: file, line: line)
        XCTAssertTrue(result.gaps.isEmpty, "\(context): \(result.gaps)", file: file, line: line)
    }

    private func assertBoundAdvisory(
        _ point: LearningPoint, original: LearningPoint, literal: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(Data(point.text.utf8), Data(original.text.utf8),
                       "Never repair or normalize the note body", file: file, line: line)
        XCTAssertEqual(point.kind, original.kind, file: file, line: line)
        XCTAssertEqual(point.sourceIDs, original.sourceIDs, file: file, line: line)
        XCTAssertEqual(point.referenceState, .linked, file: file, line: line)
        XCTAssertNil(point.needsContext, file: file, line: line)
        let gap = try XCTUnwrap(point.numericGap, file: file, line: line)
        XCTAssertTrue(gap.contains(literal), "\(literal): \(gap)", file: file, line: line)
    }

    // Do not pin a new UI sentence; require the advisory to distinguish batch-only evidence.
    private func mentionsOtherSource(_ gap: String) -> Bool {
        ["其他", "其它", "别的", "别段", "另一", "其他字幕", "同批其他"].contains { gap.contains($0) }
    }

    func testObservedPhonePrefixGapPreservesRawBoundPoint() throws {
        let raw = "初始化结构体数组示例（续）：people[2].name 设为 John，phone 号 2-19494682750。"
        let name = "And then lastly, people bracket2.name equals quote unquote John for John Harvard."
        let evidence = [
            TranscriptSegment(startTime: 0, endTime: 10, english: name),
            TranscriptSegment(startTime: 10, endTime: 20, english: spokenSource)
        ]
        let original = LearningPoint(kind: "例子", text: raw, sourceIDs: ["en0s0", "en1s0"])
        let note = LearningNote(topic: "初始化结构体数组", points: [original], sourceVersion: 2)
        assertAdvisory(LearningNumericProvenance.report(
            claim: raw, cited: [name, spokenSource], segmentTexts: [name, spokenSource],
            batchTexts: [name, spokenSource]), literal: "2-19494682750", context: "Observed 9B output")
        let bound = try XCTUnwrap(note.binding(evidence: evidence).points.first)
        try assertBoundAdvisory(bound, original: original, literal: "2-19494682750")
        XCTAssertEqual(bound.sources?.map(\.index), [0, 1])
        XCTAssertEqual(note.points, [original], "Binding cannot mutate the input note")
    }

    func testLongNumberAssignmentsDoNotLoseOrChangeLeadingSigns() {
        for source in [spokenSource, "2.number equals plus19494682750 in this case."] {
            for literal in ["19494682750", "-19494682750", "2-19494682750", "3-19494682750",
                            "+19494682751", "+1949468275", "+019494682750"] {
                for claim in ["phone 号 \(literal)。", "电话号码为 \(literal)。",
                              "people[2].number 设为 \(literal)。"] {
                    assertAdvisory(report(claim, source: source), literal: literal,
                                   context: "\(source) -> \(claim)")
                }
            }
        }
    }

    func testCompleteDigitsAndLeadingSignAreSymmetric() {
        // A leading zero is part of the literal. Do not turn this into Decimal equality.
        // A negative spelling echoed by the source is supported, not a valid-phone verdict.
        let literals = ["+19494682750", "19494682750", "-19494682750", "+019494682750"]
        for sourceLiteral in literals {
            for claimLiteral in literals {
                let context = "\(sourceLiteral) -> \(claimLiteral)"
                let result = report("entry.number = \(claimLiteral).",
                                    source: "entry.number = \(sourceLiteral).")
                if claimLiteral == sourceLiteral {
                    assertSupported(result, context: context)
                } else {
                    assertAdvisory(result, literal: claimLiteral, context: context)
                }
            }
        }
    }

    func testPlusWordsAndDisplaySeparatorsPreserveSameLiteral() {
        let sources = [
            spokenSource,
            "2.number equals plus19494682750 in this case.",
            "The phone number is PLUS 19494682750.",
            "The phone number is +19494682750.",
            "The phone number is +1-949-468-2750.",
            "The phone number is +1 (949) 468-2750.",
            "The phone number is +1 949 468 2750."
        ]
        for source in sources {
            for literal in ["+19494682750", "+1-949-468-2750", "+1 (949) 468-2750", "+1 949 468 2750"] {
                assertSupported(report("phone 号 \(literal)。", source: source),
                                context: "\(source) -> \(literal)")
            }
        }
    }

    func testIndexNumbersAndSeparateFragmentsCannotSupplyPhonePrefix() {
        for source in [
            spokenSource,
            "Entry 2 has phone number 19494682750.",
            "编号 2；电话号码为 +19494682750。",
            "people[2].number = +19494682750."
        ] {
            assertAdvisory(report("phone 号 2-19494682750。", source: source),
                           literal: "2-19494682750", context: source)
        }
        // All digits and the plus sign occur, but no source contains the whole literal.
        for fragments in [
            ["The phone number is +1", "949", "468", "2750"],
            ["The phone number is plus", "19494682750"],
            ["Entry 2", "The phone number is 19494682750"]
        ] {
            let literal = fragments.count == 2 && fragments[0] == "Entry 2"
                ? "2-19494682750" : "+19494682750"
            assertAdvisory(LearningNumericProvenance.report(
                claim: "phone 号 \(literal)。", cited: fragments, segmentTexts: fragments,
                batchTexts: fragments), literal: literal, context: "Separate fragments: \(fragments)")
        }
    }

    func testCitationAndSameSegmentSupportDoNotLeakAcrossBatch() throws {
        let intro = "The assignment is shown."
        let support = "The phone number is +19494682750."
        let claim = "phone 号 +19494682750。"
        for (cited, sameSegment) in [([support], [support]), ([intro], [intro, support])] {
            assertSupported(LearningNumericProvenance.report(
                claim: claim, cited: cited, segmentTexts: sameSegment, batchTexts: [intro, support]),
                context: "Own citation or same-segment support")
        }
        let elsewhere = LearningNumericProvenance.report(
            claim: claim, cited: [intro], segmentTexts: [intro], batchTexts: [intro, support])
        assertAdvisory(elsewhere, literal: "+19494682750", context: "Only another segment supports it")
        XCTAssertTrue(mentionsOtherSource(elsewhere.gaps.joined()), "\(elsewhere.gaps)")

        let note = LearningNote(topic: "电话号码", points: [
            .init(kind: "例子", text: claim, sourceIDs: ["en0s0"]),
            .init(kind: "例子", text: claim, sourceIDs: ["en1s0"]),
            .init(kind: "例子", text: claim, sourceIDs: ["en0s0"])
        ], sourceVersion: 2)
        let evidence = [
            TranscriptSegment(startTime: 0, endTime: 10, english: intro),
            TranscriptSegment(startTime: 10, endTime: 20, english: support)
        ]
        let bound = note.binding(evidence: evidence)
        XCTAssertEqual(bound.points.count, note.points.count)
        guard bound.points.count == note.points.count else { return }
        for index in [0, 2] {
            try assertBoundAdvisory(bound.points[index], original: note.points[index], literal: "+19494682750")
            XCTAssertTrue(mentionsOtherSource(try XCTUnwrap(bound.points[index].numericGap)))
        }
        XCTAssertNil(bound.points[1].numericGap)
        XCTAssertEqual(bound.points[1].referenceState, .linked)
        var reversed = note
        reversed.points.reverse()
        XCTAssertEqual(reversed.binding(evidence: evidence).points, Array(bound.points.reversed()))

        let own = LearningNote(topic: note.topic, points: [note.points[0]], sourceVersion: 2)
        for segment in [
            TranscriptSegment(startTime: 0, endTime: 10, english: intro + " " + support),
            TranscriptSegment(startTime: 0, endTime: 10, english: intro, chinese: "电话号码为 +19494682750。")
        ] {
            let point = try XCTUnwrap(own.binding(evidence: [segment]).points.first)
            XCTAssertNil(point.numericGap)
            XCTAssertNil(point.needsContext)
            XCTAssertEqual(point.referenceState, .linked)
            XCTAssertEqual(point.text, claim)
        }
    }

    func testEachBindingRechecksRevisedEvidenceAndClearsPreviousGap() throws {
        let identity = UUID(), session = UUID()
        let note = LearningNote(topic: "号码修订", points: [
            .init(kind: "例子", text: "phone 号 +19494682750。", sourceIDs: ["en0s0"])
        ], sourceVersion: 2)
        var rebound = note
        for (revision, literal) in ["+19494682750", "19494682750", "-19494682750",
                                    "+19494682751", "+19494682750"].enumerated() {
            let evidence = [TranscriptSegment(id: identity, startTime: 0, endTime: 10,
                english: "The phone number is \(literal).", sessionID: session, inputRevision: revision)]
            let fresh = note.binding(evidence: evidence)
            rebound = rebound.binding(evidence: evidence)
            XCTAssertEqual(rebound.points, fresh.points, "Previously bound warnings are not evidence")
            let point = try XCTUnwrap(rebound.points.first)
            XCTAssertEqual(point.text, note.points[0].text)
            XCTAssertEqual(point.referenceState, .linked)
            XCTAssertNil(point.needsContext)
            if literal == "+19494682750" {
                XCTAssertNil(point.numericGap)
            } else {
                try assertBoundAdvisory(point, original: note.points[0], literal: "+19494682750")
            }
        }
        XCTAssertNil(note.points[0].numericGap)
    }

    func testBatchOnlyHintDoesNotSurviveAnotherBinding() throws {
        let intro = TranscriptSegment(startTime: 0, endTime: 10, english: "The assignment is shown.")
        let laterIdentity = UUID()
        let note = LearningNote(topic: "来源范围", points: [
            .init(kind: "例子", text: "phone 号 +19494682750。", sourceIDs: ["en0s0"])
        ], sourceVersion: 2)
        var rebound = note
        for (revision, literal) in ["+19494682750", "+19494682751", "+19494682750", ""].enumerated() {
            var evidence = [intro]
            if !literal.isEmpty {
                evidence.append(TranscriptSegment(id: laterIdentity, startTime: 10, endTime: 20,
                    english: "The phone number is \(literal).", sessionID: UUID(), inputRevision: revision))
            }
            rebound = rebound.binding(evidence: evidence)
            let point = try XCTUnwrap(rebound.points.first)
            try assertBoundAdvisory(point, original: note.points[0], literal: "+19494682750")
            XCTAssertEqual(mentionsOtherSource(try XCTUnwrap(point.numericGap)), literal == "+19494682750",
                           "The batch-only hint must follow this binding's evidence: \(literal)")
        }
    }

    func testBilingualConflictsCannotSilentlyCertifyEitherVariant() throws {
        let english = "people[2].number equals plus19494682750."
        for alternative in ["19494682750", "-19494682750", "2-19494682750", "+19494682751"] {
            let chinese = "people[2].number 设为 \(alternative)。"
            let evidence = [TranscriptSegment(startTime: 0, endTime: 10, english: english, chinese: chinese)]
            for literal in ["+19494682750", alternative] {
                let claim = "people[2].number 设为 \(literal)。"
                // Check both citation directions, both segment orders, and an inline bilingual source.
                for (cited, segmentTexts) in [
                    ([english], [english, chinese]), ([chinese], [chinese, english]),
                    ([english + " " + chinese], [english + " " + chinese])
                ] {
                    assertAdvisory(LearningNumericProvenance.report(
                        claim: claim, cited: cited, segmentTexts: segmentTexts, batchTexts: segmentTexts),
                        literal: literal, context: "Conflicting bilingual assignment: \(chinese)")
                }
                for sourceID in ["en0s0", "zh0s0"] {
                    let original = LearningPoint(kind: "例子", text: claim, sourceIDs: [sourceID])
                    let note = LearningNote(topic: "中英来源冲突", points: [original], sourceVersion: 2)
                    let point = try XCTUnwrap(note.binding(evidence: evidence).points.first)
                    try assertBoundAdvisory(point, original: original, literal: literal)
                }
            }
        }
    }

    func testEquivalentBilingualSpellingsAreNotConflicts() throws {
        let english = "The phone number is plus19494682750."
        for chinese in ["电话号码为 +19494682750。", "电话号码为 +1-949-468-2750。",
                        "电话号码为 +1 (949) 468-2750。"] {
            for sourceID in ["en0s0", "zh0s0"] {
                let original = LearningPoint(kind: "例子", text: "phone 号 +19494682750。", sourceIDs: [sourceID])
                let note = LearningNote(topic: "等价格式", points: [original], sourceVersion: 2)
                let point = try XCTUnwrap(note.binding(evidence: [
                    TranscriptSegment(startTime: 0, endTime: 10, english: english, chinese: chinese)
                ]).points.first)
                XCTAssertNil(point.numericGap, chinese)
                XCTAssertNil(point.needsContext, chinese)
                XCTAssertEqual(point.referenceState, .linked)
                XCTAssertEqual(point.text, original.text)
            }
        }
    }

    func testNonPhoneFormulaRangeDateVersionAndDesignatorControlsStayUnchanged() {
        for (claim, source) in [
            ("公式 y = 19494682750 - 2。", "Use y = 19494682750 - 2."),
            ("公式 y = +19494682750。", "Use y = 19494682750."),
            ("范围为 19494682750-19494682760。", "The range is 19494682750-19494682760."),
            ("区间为 -3 到 +2。", "The interval is -3 to +2."),
            ("日期为 2026-10-04。", "The date is 2026-10-04."),
            ("版本 v2026.10.04。", "Use version v2026.10.04."),
            ("编号 19494682750；标签 K7、M2。", "The example is shown."),
            ("第 2 项。", "The example is shown."),
            ("entry.number = -2。", "entry.number = +2.")
        ] {
            assertSupported(report(claim, source: source), context: "Non-phone control: \(claim)")
        }
    }

    // Parent additions after reviewing the sidecar's saved, unbuilt tests.
    func testUnarySignWhitespaceAndLiteralOnlyQuotesRemainSupported() {
        for source in ["entry.number = - 19494682750.", "entry.number = − 19494682750.",
                       "-19494682750", "👩🏽‍💻 -19494682750"] {
            assertSupported(report("entry.number = -19494682750。", source: source), context: source)
        }
        assertSupported(report("phone 号 +19494682750。", source: "+1-949-468-2750"),
                        context: "A complete quoted number needs no repeated phone label")
    }

    func testDifferentExplicitFieldsDoNotCreateFalseConflictsOrSupplyEachOther() {
        let source = "people[0].number = +11111111111. people[1].number = +19494682750."
        for claim in ["people[0].number = +11111111111。", "people[1].number = +19494682750。"] {
            assertSupported(report(claim, source: source), context: claim)
        }
        let mismatch = report("people[0].number = +19494682750。", source: source)
        assertAdvisory(mismatch, literal: "+19494682750", context: "Correct digits belong to another explicit field")
        XCTAssertTrue(mismatch.gaps.joined().contains("people[0].number"))
    }

    func testShortAssignmentsKeepLegacyWarningsAndMeasurementsKeepTheirVerdicts() {
        // These intentionally freeze the old scalar warning, not a new requirement to fix it.
        for (claim, source, excerpt) in [
            ("entry.number = 42。", "entry.number = 41.", "42"),
            ("公式 x = 7。", "Use x = 8.", "7"),
            ("日期为 2026-10-04。", "The date is 2026-10-03.", "04"),
            ("版本 v1.2.3。", "Use version v1.2.4.", "3"),
            ("范围为 10-20。", "The range is 10-30.", "20")
        ] {
            let result = report(claim, source: source)
            XCTAssertFalse(result.isDecidable, claim)
            XCTAssertEqual(result.gaps, [
                "正文里的“\(excerpt)”没有单位或属性说明，也没有出现在本次原文中；请人工确认它是编号还是测量值，并补上单位或来源。"
            ], "Do not add number-literal policy to this old scalar path: \(claim)")
        }
        let measurement = report("温度为18摄氏度。", source: "Pressure is 18 kilopascals.")
        XCTAssertTrue(measurement.isDecidable, "Existing unit conflicts must remain independently decidable")
        XCTAssertEqual(measurement.gaps.count, 1)
        XCTAssertTrue(measurement.gaps.joined().contains("单位不同"))
    }

    // Issue #15: a measurement that differs from its source only by sign is a
    // decidable conflict, like a unit mismatch. Ranges and designators keep no sign.
    private func assertSignConflict(
        _ result: LearningNumericProvenance.Report, claimed: String, source: String, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(result.isDecidable, "\(context): \(result.gaps)", file: file, line: line)
        XCTAssertEqual(result.gaps.count, 1, "\(context): \(result.gaps)", file: file, line: line)
        let gap = result.gaps.joined()
        XCTAssertTrue(gap.contains("正负号"), "\(context): \(gap)", file: file, line: line)
        XCTAssertTrue(gap.contains("“\(claimed)”"), "\(context): \(gap)", file: file, line: line)
        XCTAssertTrue(gap.contains(source), "\(context): \(gap)", file: file, line: line)
    }

    func testDroppedOrAddedMinusSignOnAMeasurementIsADecidableConflict() {
        assertSignConflict(report("温度为 5°C。", source: "The temperature is -5°C."),
                           claimed: "5°C", source: "-5°C", context: "dropped sign")
        assertSignConflict(report("温度为 -5°C。", source: "The temperature is 5°C."),
                           claimed: "-5°C", source: "5°C", context: "added sign")
        assertSignConflict(report("温度为零下5摄氏度。", source: "The temperature is 5°C."),
                           claimed: "零下5摄氏度", source: "5°C", context: "Chinese sign word")
        assertSignConflict(report("温度为 5°C。", source: "The temperature is minus 5 degrees celsius."),
                           claimed: "5°C", source: "minus 5", context: "English sign word")
        assertSignConflict(report("电压为 1.5e3 V。", source: "The voltage is -1.5e3 V."),
                           claimed: "1.5e3V", source: "-1.5e3V", context: "scientific notation")
        // The same value and unit only with the opposite sign elsewhere in the batch
        // is not "cite that sentence too": it is still a sign conflict.
        let batch = LearningNumericProvenance.report(
            claim: "温度为 5°C。", cited: ["The tank is sealed."], segmentTexts: ["The tank is sealed."],
            batchTexts: ["The tank is sealed.", "The temperature is -5°C."])
        assertSignConflict(batch, claimed: "5°C", source: "-5°C", context: "batch-only opposite sign")
    }

    func testEquivalentNegativeSpellingsSupportEachOther() {
        for claim in ["温度为 -5°C。", "温度为 −5°C。", "温度为－5℃。", "温度为零下5摄氏度。", "温度为零下 5 摄氏度。",
                      "温度为负5摄氏度。", "温度为（-5°C）。", "温度为 minus 5°C。"] {
            for source in ["The temperature is -5°C.", "The temperature is −5°C.",
                           "The temperature is minus 5 degrees celsius.", "The temperature is Negative 5°C.",
                           "温度为零下5摄氏度。", "The range is -5~-3°C, mostly -5°C."] {
                assertSupported(report(claim, source: source), context: "\(source) -> \(claim)")
            }
        }
        assertSupported(report("温度为 +5°C。", source: "The temperature is 5°C."), context: "explicit plus")
        assertSupported(report("温度为 5°C。", source: "The temperature is positive 5°C."), context: "positive word")
    }

    func testHyphenRangesDesignatorsAndToleranceAreNotNegativeSigns() {
        for (claim, source) in [
            ("温度为20到25°C。", "The range is 20-25°C."),
            ("温度为20到25°C。", "The range is 20 - 25°C."),
            ("第3-5步的温度为5°C。", "Steps 3-5 run at 5°C."),
            ("样品K-5的温度为5°C。", "Sample K-5 is held at 5°C."),
            ("CO-2 的温度为 2°C。", "CO-2 is stored at 2°C."),
            ("x-5处的温度为5°C。", "At x-5 the temperature is 5°C."),
            ("温度为正负5°C。", "The tolerance is ±5°C."),
            ("误差为5°C。", "The error is plus or minus 5°C."),
            ("温度差为5°C。", "The difference is 10°C minus 5°C."),
            ("温度差为5°C。", "Take 10 minus 5°C."),
            ("people[-1] 的温度为 5°C。", "people[-1] is at 5°C.")
        ] {
            assertSupported(report(claim, source: source), context: "\(source) -> \(claim)")
        }
    }

    func testBoundTranslationCannotMaskADroppedSign() throws {
        let segment = TranscriptSegment(startTime: 0, endTime: 10, english: "The temperature is -5°C.",
                                        chinese: "温度为零下5摄氏度。")
        let wrong = LearningPoint(kind: "核心结论", text: "温度为5°C。", sourceIDs: ["en0s0"])
        let right = LearningPoint(kind: "核心结论", text: "温度为零下5°C。", sourceIDs: ["en0s0"])
        let note = LearningNote(topic: "温度", points: [wrong, right], sourceVersion: 2)
        let bound = note.binding(evidence: [segment]).points
        XCTAssertEqual(bound.map(\.referenceState), [.numericDifference, .linked])
        let gap = try XCTUnwrap(bound.first?.numericGap)
        XCTAssertTrue(gap.contains("正负号") && gap.contains("“5°C”"), gap)
        XCTAssertNil(bound.last?.numericGap)
        XCTAssertEqual(bound.map(\.text), [wrong.text, right.text], "Never rewrite the note body")
    }
}

/// P2a: run only against the repaired source. Old crash cases have static red
/// evidence in work/sbx2/p2a-red.json; never execute them on the old Swift code.
/// Kept in this already registered numeric test file without project changes.
final class LearningNumericBoundaryTests: XCTestCase {
    private func superscript(_ value: String) -> String {
        let characters: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻", "+": "⁺"
        ]
        return String(value.map { characters[$0] ?? $0 })
    }

    private func report(_ claim: String, source: String) -> LearningNumericProvenance.Report {
        LearningNumericProvenance.report(claim: claim, cited: [source], segmentTexts: [source], batchTexts: [source])
    }

    func testExtremeScientificExponentsStayOneRawMention() throws {
        for exponent in ["-9223372036854775808", String(Int.max), "9223372036854775808",
                         "-9223372036854775809", String(repeating: "9", count: 80), "-" + String(repeating: "9", count: 80)] {
            let raw = "1e\(exponent)"
            let text = "长度为\(raw) m。"
            let mentions = LearningNumericProvenance.mentions(in: text, preservingCountScalars: true)
            XCTAssertEqual(mentions.count, 1, raw)
            let mention = try XCTUnwrap(mentions.first)
            XCTAssertEqual(mention.value, raw)
            XCTAssertEqual(mention.unit, "m")
            XCTAssertEqual(mention.role, .measurement)
            XCTAssertTrue(report(text, source: text).gaps.isEmpty, raw)
            XCTAssertTrue(report("长度为1 m。", source: text).isDecidable, raw)
        }
    }

    func testExtremeExponentSpellingsDoNotLeakExponentDigits() throws {
        for raw in ["1 × 10^-9223372036854775808", "1×10" + superscript(String(Int.min)),
                    "10^-9223372036854775808", "10" + superscript(String(Int.max)),
                    "2^-9223372036854775808"] {
            let mentions = LearningNumericProvenance.mentions(in: "读数为\(raw) Hz。", preservingCountScalars: true)
            XCTAssertEqual(mentions.count, 1, raw)
            XCTAssertEqual(try XCTUnwrap(mentions.first).value, raw.filter { !$0.isWhitespace })
            XCTAssertEqual(mentions.first?.unit, "Hz")
        }
    }

    func testScientificNormalizationIncludesBothClosedIntervalEndpoints() throws {
        for (raw, decimal) in [
            ("1e-30", "0.000000000000000000000000000001"),
            ("1e30", "1000000000000000000000000000000")
        ] {
            let result = report("长度为\(decimal) m。", source: "The length is \(raw) m.")
            XCTAssertFalse(result.isDecidable, raw)
            XCTAssertTrue(result.gaps.isEmpty, "\(raw): \(result.gaps)")
        }
        for raw in ["1e-31", "1e31"] {
            let mentions = LearningNumericProvenance.mentions(in: "长度为\(raw) m。")
            XCTAssertEqual(try XCTUnwrap(mentions.first).value, raw)
        }
    }

    func testIntMaxScalarAndSignedUnitPowersRemainReadable() throws {
        let scalar = LearningNumericProvenance.mentions(in: "长度为\(Int.max) m。")
        XCTAssertEqual(scalar.count, 1)
        XCTAssertEqual(try XCTUnwrap(scalar.first).value, String(Int.max))
        for value in [String(Int.min), String(Int.max)] {
            let raw = "m" + superscript(value)
            let unit = try XCTUnwrap(LearningNumericProvenance.provenanceUnit(after: raw))
            XCTAssertEqual(unit.token, raw)
            XCTAssertEqual(unit.family, raw, "Formatting Int.min must not take a signed absolute value")
            let mentions = LearningNumericProvenance.mentions(in: "长度为5 \(raw)。")
            XCTAssertEqual(mentions.count, 1)
            XCTAssertEqual(mentions.first?.unit, raw)
        }
    }

    func testOverflowingUnitPrefixProductsKeepAnUnreadablePower() throws {
        for prefix in ["square ", "cubic ", "平方", "立方"] {
            for exponent in [String(Int.min), String(Int.max)] {
                let raw = prefix + "m" + superscript(exponent)
                let unit = try XCTUnwrap(LearningNumericProvenance.provenanceUnit(after: raw))
                XCTAssertEqual(unit.token, raw)
                XCTAssertEqual(unit.family, "m…")
                let result = report("长度为5 m。", source: "The length is 5 \(raw).")
                XCTAssertTrue(result.isDecidable, raw)
                XCTAssertFalse(result.gaps.isEmpty, raw)
                let mentions = LearningNumericProvenance.mentions(in: "长度为5 \(raw)。")
                XCTAssertEqual(mentions.count, 1, raw)
                XCTAssertEqual(mentions.first?.unit, "m…", raw)
            }
        }
    }

    func testRepresentablePrefixProductsAtIntegerEdgesStillNormalize() throws {
        for (raw, expected) in [
            ("square m" + superscript(String(Int.min / 2)), "m" + superscript(String(Int.min))),
            ("cubic m" + superscript(String(Int.max / 3)), "m" + superscript(String((Int.max / 3) * 3)))
        ] {
            let unit = try XCTUnwrap(LearningNumericProvenance.provenanceUnit(after: raw))
            XCTAssertEqual(unit.token, raw)
            XCTAssertEqual(unit.family, expected)
        }
    }

    func testRepeatedDenominatorOverflowKeepsBothDenominators() throws {
        let maximum = superscript(String(Int.max))
        for raw in ["m/s\(maximum)/s", "m/s\(maximum)/s\(maximum)"] {
            let unit = try XCTUnwrap(LearningNumericProvenance.provenanceUnit(after: raw))
            XCTAssertEqual(unit.token, raw)
            XCTAssertEqual(unit.family, raw, "Keep the unfused full unit when its power cannot fit in Int")
            let result = report("速度为1 m/s。", source: "The speed is 1 \(raw).")
            XCTAssertTrue(result.isDecidable, raw)
            XCTAssertFalse(result.gaps.isEmpty, raw)
        }
        let raw = "m/s" + superscript(String(Int.max - 1)) + "/s"
        let unit = try XCTUnwrap(LearningNumericProvenance.provenanceUnit(after: raw))
        XCTAssertEqual(unit.token, raw)
        XCTAssertEqual(unit.family, "m/s" + maximum, "A representable sum at Int.max still folds")
        let negative = "m/s" + superscript(String(Int.min)) + "/s"
        XCTAssertEqual(LearningNumericProvenance.provenanceUnit(after: negative)?.family, negative)
    }

    func testOverlongOrOutOfRangeUnitPowersCannotBecomeBareUnits() throws {
        for exponent in ["9223372036854775808", "-9223372036854775809", String(repeating: "9", count: 80)] {
            let raw = "m" + superscript(exponent)
            let unit = try XCTUnwrap(LearningNumericProvenance.provenanceUnit(after: raw))
            XCTAssertEqual(unit.token, raw)
            XCTAssertEqual(unit.family, "m…")
            let mentions = LearningNumericProvenance.mentions(in: "长度为5 \(raw)。")
            XCTAssertEqual(mentions.count, 1, raw)
            XCTAssertEqual(mentions.first?.unit, "m…", raw)
            XCTAssertTrue(report("长度为5 m。", source: "The length is 5 \(raw).").isDecidable, raw)
        }
    }

    func testSpokenCountArithmeticRetainsItsExistingBounds() {
        for (claim, source) in [
            ("共有1000000000个样品。", "There are one billion samples."),
            ("共有999000000个样品。", "There are nine hundred and ninety-nine million samples."),
            ("共有10000000个样品。", "共有一千万个样品。")
        ] {
            let result = report(claim, source: source)
            XCTAssertFalse(result.isDecidable, source)
            XCTAssertTrue(result.gaps.isEmpty, "\(source): \(result.gaps)")
        }
        for source in ["There are nine billion samples.",
                       "共有" + String(repeating: "九", count: 80) + "个样品。",
                       "共有" + String(repeating: "千万", count: 80) + "个样品。"] {
            let result = report("共有1个样品。", source: source)
            XCTAssertFalse(result.isDecidable, source)
            XCTAssertFalse(result.gaps.isEmpty, source)
        }
    }

    func testNormalChineseNumericNotePointMarkdownMatchesUTF8Fixture() throws {
        // Source-derived pre-change fixture, not an executed old Swift snapshot.
        // No trailing LF: compare Data, then verify the fixed SHA-256 as well.
        let expected = """
        - 加速度为9.8 m/s²。
        - **例子**：面积为5平方米。
        - **易错点**：长度为1.5×10⁻³ m。
        - 密度为2 kg/m³。
        - 共有523个样品。
        """
        let sources = [
            "The acceleration is 9.8 meters per second per second.",
            "The area is 5 square metres.",
            "The length is 1.5e-3 m.",
            "The density is 2 kilograms per cubic metre.",
            "There are five hundred and twenty-three samples."
        ]
        let points = [
            LearningPoint(kind: "核心结论", text: "加速度为9.8 m/s²。", sourceIDs: ["en0s0"]),
            LearningPoint(kind: "例子", text: "面积为5平方米。", sourceIDs: ["en1s0"]),
            LearningPoint(kind: "易错点", text: "长度为1.5×10⁻³ m。", sourceIDs: ["en2s0"]),
            LearningPoint(kind: "核心结论", text: "密度为2 kg/m³。", sourceIDs: ["en3s0"]),
            LearningPoint(kind: "核心结论", text: "共有523个样品。", sourceIDs: ["en4s0"])
        ]
        let evidence = sources.enumerated().map { index, source in
            TranscriptSegment(startTime: Double(index * 10), endTime: Double(index * 10 + 9), english: source)
        }
        let note = LearningNote(topic: "数值核查基线", points: points, sourceVersion: 2)
        let bound = note.binding(evidence: evidence)
        XCTAssertTrue(bound.points.allSatisfy { $0.referenceState == .linked })
        XCTAssertTrue(bound.points.allSatisfy { $0.numericGap == nil && $0.needsContext == nil })
        XCTAssertEqual(bound.points.map(\.text), points.map(\.text))
        XCTAssertEqual(note.points, points)
        let rendered = bound.points.map { $0.markdown(target: .simplifiedChinese) }.joined(separator: "\n")
        XCTAssertEqual(Data(rendered.utf8), Data(expected.utf8))
        let hash = SHA256.hash(data: Data(rendered.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "b2b8764605ee1ec45a5f473537df8d0438c28e378dee0d40fec70fd7745fca4d")
    }
}
