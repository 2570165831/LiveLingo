import Foundation
import XCTest
@testable import LiveLingo

/// Language acceptance cases, independent of the parser's implementation.
/// Calls only existing report/binding entry points; no model, audio or UI work.
final class CountLanguageAcceptanceTests: XCTestCase {
    private func report(_ claim: String, source: String) -> LearningNumericProvenance.Report {
        LearningNumericProvenance.report(
            claim: claim, cited: [source], segmentTexts: [source], batchTexts: [source])
    }

    private func assertCountGap(
        _ result: LearningNumericProvenance.Report, excerpt: String, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(result.isDecidable, context, file: file, line: line)
        XCTAssertEqual(result.gaps.count, 1,
                       "Only the actual count should need support: \(context): \(result.gaps)",
                       file: file, line: line)
        XCTAssertTrue(result.gaps.joined().contains("计数“\(excerpt)”"),
                      "\(context): \(result.gaps)", file: file, line: line)
    }

    func testUniversalUnitsNeitherAssertOneNorSupportATotalOfOne() {
        // The same phrase must behave consistently in the claim and in its source.
        for (universal, english, total, excerpt) in [
            ("遍历每一个元素。", "Visit every element.", "总共只有一个元素。", "一个"),
            ("检查每一组样品。", "Inspect each group of samples.", "样品总共分为一组。", "一组"),
            ("记录每一次运行的结果。", "Record the result of each run.", "实验总共运行一次。", "一次")
        ] {
            let harmless = report(universal, source: english)
            XCTAssertFalse(harmless.isDecidable, universal)
            XCTAssertTrue(harmless.gaps.isEmpty, "\(universal): \(harmless.gaps)")

            assertCountGap(report(total, source: universal), excerpt: excerpt,
                           context: "A universal unit cannot establish a total: \(universal) -> \(total)")
        }
    }

    func testAllocationAndExclusiveCountsStillRequireTheirOwnEvidence() {
        // The 'one' after 每组/每次 is a quantity; the 'one' inside 每一组 is not.
        // Repeating 一个 later in the claim must not make that real count disappear.
        for (claim, supportedSource, excerpt) in [
            ("每组一个样品。", "Assign one sample to each group.", "一个"),
            ("每次一个样品。", "Process one sample on each run.", "一个"),
            ("每一组只有一个样品。", "Each group has only one sample.", "一个"),
            ("每一组有5个样品。", "Each group has five samples.", "5个"),
            ("列表中只有一个元素。", "The list contains only one element.", "一个"),
            ("遍历每一个元素后，列表中只剩一个元素。",
             "Visit every element; after that, only one element remains in the list.", "一个")
        ] {
            assertCountGap(report(claim, source: "The procedure is demonstrated."),
                           excerpt: excerpt, context: claim)
            let supported = report(claim, source: supportedSource)
            XCTAssertFalse(supported.isDecidable, claim)
            XCTAssertTrue(supported.gaps.isEmpty, "\(claim): \(supported.gaps)")
        }
    }

    func testUniversalSampleDoesNotHideOrPolluteTheVolumeCheck() {
        let claim = "从每一个样品中取2毫升。"
        let supported = report(claim, source: "Take 2 millilitres from each sample.")
        XCTAssertTrue(supported.gaps.isEmpty, "\(supported.gaps)")
        XCTAssertFalse(supported.isDecidable)

        for source in [
            "Take 5 millilitres from each sample.",
            "Take 2 grams from each sample."
        ] {
            let mismatch = report(claim, source: source)
            XCTAssertTrue(mismatch.isDecidable, source)
            XCTAssertEqual(mismatch.gaps.count, 1, "\(source): \(mismatch.gaps)")
            XCTAssertTrue(mismatch.gaps.joined().contains("2毫升"), source)
            XCTAssertFalse(mismatch.gaps.joined().contains("计数"),
                           "每一个 must not add a count warning: \(mismatch.gaps)")
        }
    }

    func testEveryWithARealBatchSizeAndSpokenDecimalKeepsItsMeaning() {
        // 每 does not make an explicit batch size disappear, even when it begins with 一.
        for (claim, supportedSource, excerpt) in [
            ("每10个样品装盒。", "Pack each group of ten samples into a box.", "10个"),
            ("每一百个样品装盒。", "Pack each group of one hundred samples into a box.", "一百个")
        ] {
            assertCountGap(report(claim, source: "Pack the samples into boxes."),
                           excerpt: excerpt, context: claim)
            let supported = report(claim, source: supportedSource)
            XCTAssertTrue(supported.gaps.isEmpty, "\(claim): \(supported.gaps)")
            XCTAssertFalse(supported.isDecidable, claim)
        }

        // A fractional normalization unit is not a total of either one or five.
        // This does NOT require new support for parsing Chinese spoken decimals.
        let fractionalSource = "能量按每一点五个标准单元归一化。"
        for (claim, excerpt) in [("总共1个标准单元。", "1个"), ("总共5个标准单元。", "5个")] {
            assertCountGap(report(claim, source: fractionalSource), excerpt: excerpt,
                           context: "Do not split 一点五 into whole counts: \(claim)")
        }
    }

    func testBindingKeepsUniversalWordingAndRealCountsInTheirCitationScope() throws {
        let universal = TranscriptSegment(startTime: 0, endTime: 10,
                                          english: "Visit every element.", chinese: "遍历每一个元素。")
        let counted = TranscriptSegment(startTime: 10, endTime: 20,
                                        english: "There is one element.", chinese: "")
        let note = LearningNote(topic: "遍历与数量", points: [
            .init(kind: "核心结论", text: "总共只有一个元素。", sourceIDs: ["en0s0"]),
            .init(kind: "核心结论", text: "总共只有一个元素。", sourceIDs: ["en1s0"]),
            .init(kind: "核心结论", text: "遍历每一个元素。", sourceIDs: ["en0s0"]),
            .init(kind: "核心结论", text: "总共只有一个元素。", sourceIDs: ["zh0s0"])
        ], sourceVersion: 2)

        let bound = note.binding(evidence: [universal, counted])
        XCTAssertEqual(bound.points.count, note.points.count)
        XCTAssertEqual(bound.points.map(\.text), note.points.map(\.text))
        XCTAssertEqual(bound.points.map(\.referenceState), [.linked, .linked, .linked, .linked])
        for index in [0, 3] {
            let gap = try XCTUnwrap(bound.points[index].numericGap)
            XCTAssertTrue(gap.contains("计数“一个”"), gap)
            XCTAssertTrue(gap.contains("其他句子出现过相同数量"),
                          "The true count is in another segment, not this citation: \(gap)")
            XCTAssertNil(bound.points[index].needsContext)
        }
        XCTAssertNil(bound.points[1].numericGap)
        XCTAssertNil(bound.points[2].numericGap)

        // Without the other segment, even the 'elsewhere' count hint must disappear.
        let ownOnlyNote = LearningNote(topic: note.topic, points: [note.points[0]], sourceVersion: 2)
        let absent = try XCTUnwrap(ownOnlyNote.binding(evidence: [universal]).points.first)
        let absentGap = try XCTUnwrap(absent.numericGap)
        XCTAssertTrue(absentGap.contains("计数“一个”"), absentGap)
        XCTAssertFalse(absentGap.contains("其他句子出现过相同数量"), absentGap)

        // Real same-segment support is still allowed by the established contract.
        let sameSegment = TranscriptSegment(startTime: 0, endTime: 10,
                                            english: "Visit every element. There is one element.",
                                            chinese: "遍历每一个元素。")
        let supported = try XCTUnwrap(ownOnlyNote.binding(evidence: [sameSegment]).points.first)
        XCTAssertEqual(supported.referenceState, .linked)
        XCTAssertNil(supported.numericGap)
        XCTAssertNil(supported.needsContext)
    }
}
