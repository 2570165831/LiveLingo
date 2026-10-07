import Foundation
import XCTest
@testable import LiveLingo

/// Literal decisions captured from the unmodified 1a59adc policies. Inputs are
/// authored cases from the three named suites plus deterministic variants.
/// No audio, models, network or mutable expected-value generator is used.
final class AcceptanceVerdictSnapshotTests: XCTestCase {
    struct Translation: Codable {
        let id: String
        let origin: String
        let source: String
        let candidate: String
        let sourceLanguage: String?
        let existingChinese: String
        let before: String
        let after: String
        let expected: Verdict
    }
    struct Verdict: Codable, Equatable {
        let rawCategory: String
        let normalizedCategory: String
        let normalizedOutput: String
        let validatedOutput: String?
        let captionOutput: String?
        let captionError: String?
        let lengthPlausible: Bool
        let targetMaximumOutputCharacters: Double?
        let stableTranslationPrefix: String
        let rawStableTranslationPrefix: String
        let numericUnsupported: [String]
        let numericUndecidable: Bool
        let numericRejection: String?
    }
    struct CountCase: Codable {
        let id: String
        let claim: String
        let cited: [String]
        let segmentTexts: [String]
        let batchTexts: [String]
        let expected: CountVerdict
    }
    struct CountVerdict: Codable, Equatable {
        let isDecidable: Bool
        let gaps: [String]
    }
    struct GateCase: Codable {
        struct Caption: Codable {
            let sourceLanguage: String?
            let start: Double
            let end: Double
            let source: String
            let chinese: String
            let usable: Bool
        }
        struct Action: Codable {
            let now: Double
            let producerDrained: Bool
            let repairTargets: [Int]
            let unsettledSuccessors: [Int]
        }
        let id: String
        let captions: [Caption]
        let actions: [Action]
        let expected: [GateVerdict]
    }
    struct GateVerdict: Codable, Equatable {
        let risks: [Int]
        let eligible: [Int]
        let held: [Int]
        let admittedAtLimit: [Int]
        let nextWake: Double?
        let oldestUncoveredDeadline: Double?
        let sealed: Bool
    }
    struct BindingCase: Codable {
        struct Evidence: Codable {
            let source: String
            let chinese: String
        }
        let id: String
        let evidence: [Evidence]
        let claims: [String]
        let sourceIDs: [[String]]
        let expected: [BindingVerdict]
    }
    struct BindingVerdict: Codable, Equatable {
        let text: String
        let referenceState: String?
        let numericGap: String?
        let needsContext: String?
    }
    struct Snapshot: Codable {
        let baselineRevision: String
        let originalSuiteSHA256: [String: String]
        let translations: [Translation]
        let counts: [CountCase]
        let gates: [GateCase]
        let bindings: [BindingCase]
    }

    private func fixture() throws -> Snapshot {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "acceptance-verdicts-zh-Hans", withExtension: "json"))
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    private func verdict(_ input: Translation) throws -> Verdict {
        let normalized = CaptionTranslationTarget.current.normalize(input.candidate)
        let raw = TranslationAcceptance.rejection(candidate: input.candidate, source: input.source,
                                                 sourceLanguage: input.sourceLanguage)
        let normalizedRejection = TranslationAcceptance.rejection(candidate: normalized, source: input.source,
                                                                 sourceLanguage: input.sourceLanguage)
        let validated: String?
        if raw == nil {
            validated = try TranslationAcceptance.validated(input.candidate, source: input.source,
                                                           sourceLanguage: input.sourceLanguage)
        } else {
            validated = nil
        }
        let caption: String?
        let captionError: String?
        do {
            caption = try TranslationAcceptance.validatedCaption(input.candidate, source: input.source,
                                                                sourceLanguage: input.sourceLanguage)
            captionError = nil
        } catch QwenRuntimeError.translationRejected(let message) {
            caption = nil
            captionError = message
        }
        let numeric = RepairNumericNovelty.assess(candidate: input.candidate,
            support: [input.source, input.existingChinese, input.before, input.after])
        let repairJSON = String(decoding: try JSONSerialization.data(withJSONObject: [
            "target_translate_only": input.source, "context_before_do_not_translate": input.before,
            "context_after_do_not_translate": input.after
        ], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let language = input.sourceLanguage.flatMap(SpokenLanguage.find)
        return Verdict(rawCategory: raw.map { String(describing: $0) } ?? "accepted",
            normalizedCategory: normalizedRejection.map { String(describing: $0) } ?? "accepted",
            normalizedOutput: normalized, validatedOutput: validated, captionOutput: caption,
            captionError: captionError,
            lengthPlausible: TranslationLengthGuard.isPlausible(chinese: input.candidate, english: input.source),
            targetMaximumOutputCharacters: language.map {
                CaptionTranslationTarget.current.maximumOutputCharacters(source: input.source, language: $0)
            }, stableTranslationPrefix: QwenTranslationClient.stableTranslationPrefix(normalized),
            rawStableTranslationPrefix: QwenTranslationClient.stableTranslationPrefix(input.candidate),
            numericUnsupported: numeric.unsupported, numericUndecidable: numeric.undecidable,
            numericRejection: RepairNumericNovelty.rejection(candidate: input.candidate,
                requestJSON: repairJSON, existingChinese: input.existingChinese))
    }

    private func countVerdict(_ input: CountCase) -> CountVerdict {
        let actual = LearningNumericProvenance.report(claim: input.claim, cited: input.cited,
            segmentTexts: input.segmentTexts, batchTexts: input.batchTexts)
        return CountVerdict(isDecidable: actual.isDecidable, gaps: actual.gaps)
    }

    private func gateVerdicts(_ input: GateCase) -> [GateVerdict] {
        let ids = input.captions.indices.map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))!
        }
        let captions = input.captions.enumerated().map { index, item in
            CaptionNoteGate.Caption(id: ids[index], revision: 0, start: item.start, end: item.end,
                english: item.source, chinese: item.chinese, usable: item.usable,
                sourceLanguage: item.sourceLanguage)
        }
        func indices(_ values: Set<UUID>) -> [Int] { ids.indices.filter { values.contains(ids[$0]) } }
        var gate = CaptionNoteGate()
        return input.actions.map { action in
            let context = CaptionNoteGate.Context(captions: captions,
                unsettledSuccessors: Set(action.unsettledSuccessors.map { ids[$0] }),
                repairTargets: Set(action.repairTargets.map { ids[$0] }), producerDrained: action.producerDrained)
            let decision = gate.evaluate(context, now: action.now)
            return GateVerdict(risks: indices(CaptionNoteGate.risks(context)),
                eligible: indices(decision.eligible), held: indices(decision.held),
                admittedAtLimit: indices(decision.admittedAtLimit), nextWake: decision.nextWake,
                oldestUncoveredDeadline: decision.oldestUncoveredDeadline, sealed: decision.sealed)
        }
    }

    private func bindingVerdicts(_ input: BindingCase) -> [BindingVerdict] {
        let evidence = input.evidence.enumerated().map { index, item in
            TranscriptSegment(startTime: Double(index * 10), endTime: Double(index * 10 + 10),
                              english: item.source, chinese: item.chinese)
        }
        let points = input.claims.enumerated().map { index, claim in
            LearningPoint(kind: "核心结论", text: claim, sourceIDs: input.sourceIDs[index])
        }
        let note = LearningNote(topic: "遍历与数量", points: points, sourceVersion: 2).binding(evidence: evidence)
        return note.points.map { BindingVerdict(text: $0.text, referenceState: $0.referenceState?.rawValue,
                                                numericGap: $0.numericGap, needsContext: $0.needsContext) }
    }

    private func assertFrozen<T: Encodable & Equatable>(_ actual: T, _ expected: T, id: String,
                                                       file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual, expected, id, file: file, line: line)
        // Swift String equality ignores canonical Unicode spelling differences;
        // compare encoded bytes too so normalization drift cannot hide there.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(try encoder.encode(actual), try encoder.encode(expected), id, file: file, line: line)
    }

    func testTranslationVerdictsNormalizationLengthsPrefixesAndNumericRepair() throws {
        for input in try fixture().translations {
            try assertFrozen(verdict(input), input.expected, id: input.id + " · " + input.origin)
        }
    }

    func testCountLanguageVerdictsKeepTheirCitationScope() throws {
        for input in try fixture().counts {
            try assertFrozen(countVerdict(input), input.expected, id: input.id)
        }
    }

    func testMultilingualCaptionGateVerdictsAtEveryRecordedTime() throws {
        for input in try fixture().gates {
            try assertFrozen(gateVerdicts(input), input.expected, id: input.id)
        }
    }

    func testNoteBindingVerdictsKeepUniversalWordingAndRealCounts() throws {
        for input in try fixture().bindings {
            try assertFrozen(bindingVerdicts(input), input.expected, id: input.id)
        }
    }

    func testFixtureRetainsBaselineProvenanceAndEveryRejectionCategory() throws {
        let snapshot = try fixture()
        XCTAssertEqual(snapshot.baselineRevision, "1a59adc40a0b5753487b6e4f7909ce73f4f61656")
        XCTAssertEqual(snapshot.originalSuiteSHA256, [
            "TranslationAcceptanceTests.swift": "3c1d7778b547cd2946d27e9d9ae0ff2a288faa8338940981243f31d6afc5d39b",
            "MultilingualCaptionGateTests.swift": "057799a09d2ff2a7845497c506d6f6a1223a9501351649886af4b24cc40fe413",
            "CountLanguageAcceptanceTests.swift": "3e97ca4757fd6eb305aad9158d92a8266ce7cfd0868aa01316c118529aaebcb5"
        ])
        XCTAssertEqual(snapshot.translations.count, 453)
        XCTAssertEqual(snapshot.counts.count, 28)
        XCTAssertEqual(snapshot.gates.count, 142)
        XCTAssertEqual(snapshot.bindings.count, 3)
        let identifiers = snapshot.translations.map(\.id) + snapshot.counts.map(\.id)
            + snapshot.gates.map(\.id) + snapshot.bindings.map(\.id)
        XCTAssertEqual(Set(identifiers).count, 626)
        XCTAssertEqual(Set(snapshot.translations.map { $0.expected.rawCategory }), [
            "accepted", "empty", "controlMarker", "promptLeak", "modelReply", "sourceEcho",
            "englishProse", "mixedEnglishProse", "nonChineseText", "incompleteProse",
            "jsonStructure", "jsonQuantity", "sourceProse", "sourceCopy", "disproportionateLength"
        ])
    }
}
