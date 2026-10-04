import Foundation
import XCTest
@testable import LiveLingo

/// Independent, frozen acceptance of visible code-index provenance only.
/// No new parser seam, no model calls, and no claim of semantic correctness.
final class CodeIndexProvenanceTests: XCTestCase {
    // Exact English subtitle strings from parent/native-validation.json, context-180.
    private let spokenZero = "Field, the name attribute, so to speak, and let's set that equal to Kelly. Then let's go into that same array location, people bracket zero, and set the number."
    private let spokenOne = "Set that person's name to, for instance, mine, David. Then let's do people bracket one dot number equals quote unquote, same as Kelly, because we're both in the directory. So plus one, six."
    private let spokenTwo = "617-495-1000. And then lastly, people bracket2.name equals quote unquote John for John Harvard. People bracket2."

    private func report(_ claim: String, source: String) -> LearningNumericProvenance.Report {
        LearningNumericProvenance.report(
            claim: claim, cited: [source], segmentTexts: [source], batchTexts: [source])
    }

    private func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "`" }
    }

    private func mentionsOtherSource(_ text: String) -> Bool {
        ["其他", "其它", "别的", "别段", "另一", "漏引", "elsewhere", "other source"]
            .contains { text.lowercased().contains($0) }
    }

    private func assertSupported(
        _ result: LearningNumericProvenance.Report, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(result.isDecidable, context, file: file, line: line)
        XCTAssertTrue(result.gaps.isEmpty, "\(context): \(result.gaps)", file: file, line: line)
    }

    private func assertIndexGap(
        _ result: LearningNumericProvenance.Report, key: String, context: String,
        elsewhere: Bool? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(result.isDecidable, "Index provenance alone is advisory: \(context)",
                       file: file, line: line)
        let gap = result.gaps.joined(separator: " ")
        XCTAssertFalse(gap.isEmpty, context, file: file, line: line)
        XCTAssertTrue(compact(gap).contains(compact(key)),
                      "Identify the complete claimed root/index, not a bare digit: \(context): \(gap)",
                      file: file, line: line)
        if let elsewhere {
            XCTAssertEqual(mentionsOtherSource(gap), elsewhere, "\(context): \(gap)", file: file, line: line)
        }
    }

    private func assertPreserved(
        _ point: LearningPoint, original: LearningPoint,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Data(point.text.utf8), Data(original.text.utf8), file: file, line: line)
        XCTAssertEqual(point.kind, original.kind, file: file, line: line)
        XCTAssertEqual(point.sourceIDs, original.sourceIDs, file: file, line: line)
        XCTAssertEqual(point.referenceState, .linked, file: file, line: line)
        XCTAssertNil(point.needsContext, file: file, line: line)
        XCTAssertFalse(point.hasOpenQuestion, file: file, line: line)
    }

    func testObservedSpokenZeroOneAndCompactTwoSupportTheirOwnKeys() {
        for (key, source) in [("people[0]", spokenZero), ("people[1]", spokenOne), ("people[2]", spokenTwo)] {
            assertSupported(report("访问 `\(key).name`。", source: source), context: key)
        }
    }

    func testLiteralPathsBracketWhitespaceAndIdentifierDigitsRemainWhole() {
        for (claim, source) in [
            ("people[0]", "Use people [ 0 ].name."),
            ("store.people[1]", "Use store.people[1].name."),
            ("_store2.people7[03]", "Use _store2.people7 [ 03 ].name."),
            ("grid[0][1]", "Use grid [ 0 ] [ 1 ]."),
            ("store.grid[0][1]", "Use store.grid[0][1].")
        ] {
            assertSupported(report("访问 `\(claim)`。", source: source), context: claim)
        }
    }

    func testEqualDigitsCannotReplaceTheRootIndexOrCase() {
        for (key, source) in [
            ("people[1]", "Use people[0]. The measured value is 1."),
            ("people[1]", "Use records[1]."),
            ("people[0]", "Use people[10]."),
            ("people[1]", "Use People[1]."),
            ("People[1]", "Use people[1]."),
            ("people7[1]", "Use people8[1]."),
            ("store.people[1]", "Use cache.people[1]."),
            ("people[1]", "Use store.people[1]."),
            ("store.people[1]", "Use people[1].")
        ] {
            assertIndexGap(report("访问 `\(key)`。", source: source), key: key, context: source)
        }
    }

    func testSpokenOwnersKeepTheirCaseAndRequireARoot() {
        assertSupported(report("访问 `People[1]`。", source: "Use People bracket one."),
                        context: "Spoken owner retains case")
        for source in ["Use People bracket one.", "Use records bracket one.", "Use bracket one.",
                       "Use [1].", "1.number is shown.", "The index is 1.", "There is one element."] {
            assertIndexGap(report("访问 `people[1]`。", source: source), key: "people[1]", context: source)
        }
        assertIndexGap(report("访问 `People[1]`。", source: "Use people bracket one."),
                       key: "People[1]", context: "Spoken lower-case owner is different")
    }

    func testSignAndLeadingZeroSpellingsAreNotNumericallyNormalized() {
        let spellings = ["1", "+1", "01", "-1", "0", "-0"]
        for original in spellings {
            for claimed in spellings {
                let key = "people[\(claimed)]"
                let result = report("访问 `\(key)`。", source: "Use people[\(original)].")
                if original == claimed {
                    assertSupported(result, context: key)
                } else {
                    assertIndexGap(result, key: key, context: "\(original) -> \(claimed)")
                }
            }
        }
        for claimed in ["+1", "01", "-1"] {
            assertIndexGap(report("访问 `people[\(claimed)]`。", source: "Use people bracket one."),
                           key: "people[\(claimed)]", context: "Spoken one is only the spelling 1")
        }
    }

    func testConsecutiveDimensionsCannotBeTruncatedReorderedOrAssembled() {
        for (key, source) in [
            ("grid[0][1]", "Use grid[0]."),
            ("grid[0]", "Use grid[0][1]."),
            ("grid[0][1]", "Use grid[1][0]."),
            ("grid[0][1]", "Use grid[0][2]."),
            ("grid[0][1]", "Use other[0][1]."),
            ("grid[0][1]", "Use grid[0] and grid[1]."),
            ("grid[0][1]", "Use grid bracket zero. Then grid bracket one.")
        ] {
            assertIndexGap(report("访问 `\(key)`。", source: source), key: key, context: source)
        }
    }

    func testUnsupportedExpressionsCannotSupplyAPartialIntegerKey() {
        for source in ["Use people[1.5].", "Use people[1 + 2].", "Use people[1, 2].",
                       "Use people bracket one point five.", "Use people bracket one plus two.",
                       "The interval is [1, 2].", "See reference [1]."] {
            assertIndexGap(report("访问 `people[1]`。", source: source), key: "people[1]", context: source)
        }
    }

    func testUnsupportedClaimFormsStayOnTheExistingScalarPath() {
        // No new parser obligations for decimals, arithmetic, citations or intervals.
        // They must not be swallowed as complete supported integer accesses.
        for (text, values) in [
            ("访问 people[1.5]。", ["1.5"]),
            ("访问 people[1 + 2]。", ["1", "2"]),
            ("参见 [3] 和 (4)。", ["3", "4"]),
            ("区间为 [1, 2]。", ["1", "2"]),
            ("区间为 (0, 1]。", ["0", "1"])
        ] {
            let mentions = LearningNumericProvenance.mentions(in: text)
            XCTAssertEqual(mentions.map(\.value), values, text)
            let result = report(text, source: "The example is shown.")
            XCTAssertFalse(result.isDecidable, text)
            XCTAssertFalse(result.gaps.isEmpty, text)
        }
    }

    func testDirectCitationAndSameSubtitleSupportButBatchOnlyStillWarns() {
        let intro = "The example is shown."
        let support = "Use people bracket one."
        let claim = "访问 `people[1]`。"
        for (cited, same) in [([support], [support]), ([intro], [intro, support])] {
            assertSupported(LearningNumericProvenance.report(
                claim: claim, cited: cited, segmentTexts: same, batchTexts: [intro, support]),
                context: "Own citation or same subtitle")
        }
        let elsewhere = LearningNumericProvenance.report(
            claim: claim, cited: [intro], segmentTexts: [intro], batchTexts: [intro, support])
        assertIndexGap(elsewhere, key: "people[1]", context: "Uncited subtitle", elsewhere: true)
        let absent = LearningNumericProvenance.report(
            claim: claim, cited: [intro], segmentTexts: [intro], batchTexts: [intro])
        assertIndexGap(absent, key: "people[1]", context: "No supporting key", elsewhere: false)
        for wrongSupport in ["Use records bracket one.", "Use people bracket zero."] {
            assertIndexGap(LearningNumericProvenance.report(
                claim: claim, cited: [intro], segmentTexts: [intro], batchTexts: [intro, wrongSupport]),
                key: "people[1]", context: wrongSupport, elsewhere: false)
        }
    }

    func testSeparateFragmentsNeverJoinIntoAnIndexKey() {
        for fragments in [["Use people bracket", "one."], ["Use people[", "1]."],
                          ["Use people", "bracket one."], ["Use grid[0]", "[1]."]] {
            let key = fragments[0].contains("grid") ? "grid[0][1]" : "people[1]"
            assertIndexGap(LearningNumericProvenance.report(
                claim: "访问 `\(key)`。", cited: fragments, segmentTexts: fragments, batchTexts: fragments),
                key: key, context: "Separate fragments: \(fragments)", elsewhere: false)
        }
    }

    func testIndexDigitsDoNotEscapeAsScalarOrCountMentions() {
        for text in ["people[3]", "people bracket three", "people bracket three elements are shown.",
                     "_store2.people7[03]", "grid[3][4]"] {
            for sourceMode in [false, true] {
                let usable = LearningNumericProvenance.mentions(in: text, preservingCountScalars: sourceMode)
                    .filter { $0.role == .ambiguous || $0.role == .measurement || $0.role == .count }
                XCTAssertTrue(usable.isEmpty, "Index/identifier digits cannot be quantity evidence: \(text): \(usable)")
            }
        }
    }

    func testRecognizedSourceIndicesCannotCertifyCountsOrReadings() {
        // A declaration-shaped token is index-shaped evidence, not a count oracle.
        for source in ["Use people[3].", "Use people bracket three.", "people bracket three elements are shown.",
                       "person people[3];"] {
            for claim in ["共有3个元素。", "共有三个元素。"] {
                let result = report(claim, source: source)
                XCTAssertFalse(result.isDecidable, claim)
                XCTAssertFalse(result.gaps.isEmpty, "\(source) cannot certify \(claim)")
            }
            for claim in ["数值3。", "温度3。", "温度为3摄氏度。"] {
                let result = report(claim, source: source)
                XCTAssertTrue(result.isDecidable, "No actual measurement source: \(source) -> \(claim)")
                XCTAssertFalse(result.gaps.isEmpty, claim)
            }
        }
    }

    func testRealQuantitiesBesideIndicesAreNeitherSuppressedNorInvented() {
        let source = "Use people[3]. There are three elements. Temperature is 3 degrees celsius."
        for claim in ["访问 `people[3]`。", "共有3个元素。", "温度为3摄氏度。"] {
            assertSupported(report(claim, source: source), context: claim)
        }
        let mentions = LearningNumericProvenance.mentions(in: "people[3]；温度3摄氏度；共有3个元素。")
        XCTAssertTrue(mentions.contains { $0.value == "3" && $0.role == .measurement && $0.unit == "C" })
        XCTAssertTrue(mentions.contains { $0.value == "3" && $0.role == .count })
        XCTAssertEqual(mentions.filter { $0.role == .measurement || $0.role == .count || $0.role == .ambiguous }.count, 2)
    }

    func testIndexAdvisoryCannotMaskAnIndependentMeasurementConflict() {
        let result = report("访问 `people[1]`，温度为18摄氏度。",
                            source: "Use records[1]. Pressure is 18 kilopascals.")
        XCTAssertTrue(result.isDecidable)
        XCTAssertTrue(compact(result.gaps.joined()).contains("people[1]"))
        XCTAssertTrue(result.gaps.joined().contains("18"))
        XCTAssertGreaterThanOrEqual(result.gaps.count, 2)
    }

    func testSupportedIndexDoesNotWeakenWholePhoneLiteralChecks() {
        let source = "people[1].number = +19494682750."
        assertSupported(report("people[1].number = +1-949-468-2750。", source: source),
                        context: "Same complete signed phone, display separators only")
        for literal in ["19494682750", "-19494682750", "1-19494682750", "+019494682750", "+19494682751"] {
            let result = report("people[1].number = \(literal)。", source: source)
            XCTAssertFalse(result.isDecidable, literal)
            XCTAssertTrue(result.gaps.joined().contains(literal), "Keep the whole phone warning: \(result.gaps)")
        }
        let fragments = ["Use people[1].", "The phone number is +1", "949", "468", "2750"]
        let split = LearningNumericProvenance.report(
            claim: "people[1].number = +19494682750。", cited: fragments, segmentTexts: fragments, batchTexts: fragments)
        XCTAssertFalse(split.isDecidable)
        XCTAssertTrue(split.gaps.joined().contains("+19494682750"))
    }

    func testPhoneDigitMatchDoesNotFillInAMissingRootOrWrongIndex() {
        for source in ["2.number equals plus 19494682750 in this case.",
                       "people[1].number = +19494682750."] {
            assertIndexGap(report("people[2].number = +19494682750。", source: source),
                           key: "people[2]", context: "Complete phone alone cannot prove the access key")
        }
        let conflicting = "people[1].number = +19494682750. people[1].number = -19494682750."
        for literal in ["+19494682750", "-19494682750"] {
            let result = report("people[1].number = \(literal)。", source: conflicting)
            XCTAssertFalse(result.isDecidable)
            XCTAssertTrue(result.gaps.joined().contains(literal), "Keep existing same-field phone conflicts")
        }
    }

    func testRealSameSubtitleSupportWorksThroughBothBindingFormats() throws {
        let claim = "访问 `people[0].name`。"
        let firstSentence = "Field, the name attribute, so to speak, and let's set that equal to Kelly."
        let evidence = [TranscriptSegment(startTime: 160, endTime: 170, english: spokenZero)]
        let points = [
            LearningPoint(kind: "核心结论", text: claim, sources: [.init(index: 0, quote: firstSentence)]),
            LearningPoint(kind: "核心结论", text: claim, sourceIDs: ["en0s0"])
        ]
        for (index, original) in points.enumerated() {
            let note = LearningNote(topic: "数组访问", points: [original], sourceVersion: index + 1)
            let bound = try XCTUnwrap(note.binding(evidence: evidence).points.first)
            assertPreserved(bound, original: original)
            XCTAssertEqual(bound.sources?.map(\.index), [0])
            XCTAssertNil(bound.numericGap)
        }
    }

    func testBindingKeepsOwnCitationScopesWhenPointsShareTheBatch() throws {
        let evidence = [
            TranscriptSegment(startTime: 0, endTime: 10, english: "The example is shown."),
            TranscriptSegment(startTime: 10, endTime: 20, english: "Use people bracket one.")
        ]
        let note = LearningNote(topic: "数组访问", points: [
            .init(kind: "核心结论", text: "访问 `people[1]`。", sourceIDs: ["en0s0"]),
            .init(kind: "例子", text: "访问 `people[1]`。", sourceIDs: ["en1s0"]),
            .init(kind: "易错点", text: "访问 `people[1]`。", sourceIDs: ["en0s0"])
        ], sourceVersion: 2)
        let bound = note.binding(evidence: evidence)
        XCTAssertEqual(bound.points.count, note.points.count)
        guard bound.points.count == note.points.count else { return }
        for index in bound.points.indices {
            assertPreserved(bound.points[index], original: note.points[index])
            if index == 1 {
                XCTAssertNil(bound.points[index].numericGap)
            } else {
                let gap = try XCTUnwrap(bound.points[index].numericGap)
                XCTAssertTrue(compact(gap).contains("people[1]"))
                XCTAssertTrue(mentionsOtherSource(gap), gap)
            }
        }
        var reversed = note
        reversed.points.reverse()
        XCTAssertEqual(reversed.binding(evidence: evidence).points, Array(bound.points.reversed()))
        XCTAssertTrue(note.points.allSatisfy { $0.numericGap == nil && $0.referenceState == nil })
    }

    func testOtherLanguageInTheSameSubtitleMaySupplyTheCompleteKey() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 10,
                                          english: "The example is shown.", chinese: "使用 people[1]。")]
        let original = LearningPoint(kind: "例子", text: "访问 `people[1]`。", sourceIDs: ["en0s0"])
        let note = LearningNote(topic: "同字幕来源", points: [original], sourceVersion: 2)
        let point = try XCTUnwrap(note.binding(evidence: evidence).points.first)
        assertPreserved(point, original: original)
        XCTAssertNil(point.numericGap)
        XCTAssertEqual(point.sources?.map(\.index), [0])
    }

    func testRebindingRechecksChangedEvidenceAndClearsOldWarnings() throws {
        let identity = UUID(), session = UUID()
        let original = LearningPoint(kind: "例子", text: "访问 `people[1]`。", sourceIDs: ["en0s0"])
        let note = LearningNote(topic: "来源修订", points: [original], sourceVersion: 2)
        var rebound = note
        for (revision, source) in ["Use people bracket one.", "Use people bracket zero.",
                                   "Use People bracket one.", "Use people bracket one."].enumerated() {
            let evidence = [TranscriptSegment(id: identity, startTime: 0, endTime: 10, english: source,
                                              sessionID: session, inputRevision: revision)]
            rebound = rebound.binding(evidence: evidence)
            XCTAssertEqual(rebound.points, note.binding(evidence: evidence).points)
            let point = try XCTUnwrap(rebound.points.first)
            assertPreserved(point, original: original)
            XCTAssertEqual(point.numericGap == nil, source == "Use people bracket one.")
        }
        XCTAssertNil(note.points[0].numericGap)
    }

    func testBatchOnlyHintIsRecomputedWhenTheOtherSubtitleChanges() throws {
        let intro = TranscriptSegment(startTime: 0, endTime: 10, english: "The example is shown.")
        let laterID = UUID()
        let original = LearningPoint(kind: "例子", text: "访问 `people[1]`。", sourceIDs: ["en0s0"])
        var note = LearningNote(topic: "本次输入范围", points: [original], sourceVersion: 2)
        for source in ["Use people bracket one.", "Use people bracket zero.", "Use people bracket one.", ""] {
            var evidence = [intro]
            if !source.isEmpty {
                evidence.append(TranscriptSegment(id: laterID, startTime: 10, endTime: 20,
                                                  english: source, sessionID: UUID()))
            }
            note = note.binding(evidence: evidence)
            let point = try XCTUnwrap(note.points.first)
            assertPreserved(point, original: original)
            let gap = try XCTUnwrap(point.numericGap)
            XCTAssertTrue(compact(gap).contains("people[1]"))
            XCTAssertEqual(mentionsOtherSource(gap), source == "Use people bracket one.", gap)
        }
    }

    func testIndexGapRendersInSourceChecksWithoutRewritingTheBody() throws {
        let original = LearningPoint(kind: "核心结论", text: "访问 `people[1].name`。", sourceIDs: ["en0s0"])
        let note = LearningNote(topic: "数组访问", points: [original], sourceVersion: 2)
        let evidence = [TranscriptSegment(startTime: 10, endTime: 20, english: "Use people bracket zero.")]
        var notebook = LearningNotebook()
        try notebook.append(evidence: evidence, note: note)
        let point = try XCTUnwrap(notebook.batches.first?.note.points.first)
        assertPreserved(point, original: original)
        let gap = try XCTUnwrap(point.numericGap)
        XCTAssertTrue(compact(gap).contains("people[1]"))
        XCTAssertTrue(LearningNotebook.replaySection(notebook.batches).isEmpty)
        XCTAssertTrue(LearningNotebook.sourceCheckSection(notebook.batches).contains(gap))
        let sections = notebook.markdown().components(separatedBy: "## \(LearningNotebook.sourceCheckHeading)")
        XCTAssertEqual(sections.count, 2)
        guard sections.count == 2 else { return }
        XCTAssertTrue(sections[0].contains(original.text))
        XCTAssertFalse(sections[0].contains(gap))
        XCTAssertTrue(sections[1].contains(gap))
    }

    func testMatchedKeyDoesNotPretendToVerifyFieldValueOrLanguage() throws {
        // Intentionally different field, right-hand text and language label.
        // Empty numeric gaps mean visible index support ONLY, not semantic acceptance.
        let source = "In C, use people[0].name = Kelly."
        let claim = "JavaScript 示例 `people[0].number` 为 David。"
        assertSupported(report(claim, source: source), context: "Mechanical scope, not a truth verdict")
        let original = LearningPoint(kind: "例子", text: claim, sourceIDs: ["en0s0"])
        let note = LearningNote(topic: "检查边界", points: [original], sourceVersion: 2)
        let point = try XCTUnwrap(note.binding(evidence: [
            TranscriptSegment(startTime: 0, endTime: 10, english: source)
        ]).points.first)
        assertPreserved(point, original: original)
        XCTAssertNil(point.numericGap)
    }

    // Parent-found counterexample after the independent tests were frozen:
    // whitespace and spoken brackets used to let an index certify a phone.
    func testLongIndexCannotSupplyACompletePhoneLiteral() {
        for source in ["rows[ 19494682750 ]", "rows bracket 19494682750",
                       "rows[ +19494682750 ]", "rows[ -19494682750 ]"] {
            let literal = source.contains("+") ? "+19494682750"
                : source.contains("-") ? "-19494682750" : "19494682750"
            let result = report("电话为\(literal)。", source: source)
            XCTAssertFalse(result.isDecidable)
            XCTAssertTrue(result.gaps.joined().contains(literal), "An index is not a phone: \(source)")
            assertSupported(report("电话为\(literal)。", source: source + " 电话为\(literal)。"),
                            context: "A separate actual phone still supplies the full literal")
        }
    }

    func testCodePathsDoNotJoinAcrossSentencePeriods() {
        let source = "Look at the example. people[2].name is John."
        assertSupported(report("访问 people[2]。", source: source), context: "Root after a sentence break")
        assertIndexGap(report("访问 example.people[2]。", source: source), key: "example.people[2]",
                       context: "A sentence-ending word is not part of the next code root")
    }
}
