import Foundation
import XCTest
@testable import LiveLingo

/// The existing-API probes passed on step 15 before the source-policy refactor.
/// All evidence is synthetic; expectations are literals from that baseline.
@MainActor
final class TargetSourcePolicyRefactorTests: XCTestCase {
    private struct FrozenRow: Sendable {
        let sourceLanguage: String?
        let keepsSourceAsCaption: Bool
        let previewFallbackEligible: Bool
        let academicNormalizerEligible: Bool
        let chemistryProtectorEligible: Bool
        let hintsStored: Bool
        let adjacentRepairLanguageEligible: Bool
        let deferredRepairLanguageEligible: Bool
        let automaticNoteGateRiskEligible: Bool
        let learningGroups: [String]
        let reviewWarningEligible: Bool
        let indexedPendingEvidence: Bool

        var label: String { sourceLanguage ?? "nil" }
    }

    // Literal copy of step16-baseline-source-policies.json (revision 32d8c0a).
    // Do not derive expectations from production APIs or load that JSON at runtime.
    private static let baseline: [FrozenRow] = [
        .init(sourceLanguage: nil, keepsSourceAsCaption: false, previewFallbackEligible: true,
              academicNormalizerEligible: true, chemistryProtectorEligible: true, hintsStored: true,
              adjacentRepairLanguageEligible: true, deferredRepairLanguageEligible: true, automaticNoteGateRiskEligible: true,
              learningGroups: ["en", "zh"], reviewWarningEligible: true, indexedPendingEvidence: false),
        .init(sourceLanguage: "zh", keepsSourceAsCaption: true, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "yue", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "ja", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "ko", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "es", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "fr", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "ru", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "ar", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "th", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
        .init(sourceLanguage: "hi", keepsSourceAsCaption: false, previewFallbackEligible: false,
              academicNormalizerEligible: false, chemistryProtectorEligible: false, hintsStored: false,
              adjacentRepairLanguageEligible: false, deferredRepairLanguageEligible: false, automaticNoteGateRiskEligible: false,
              learningGroups: ["zh"], reviewWarningEligible: false, indexedPendingEvidence: true),
    ]

    // Previous/successor order is nil, zh, yue, ja, ko, es, fr, ru, ar, th, hi.
    // Frozen automatic predecessor-risk matrix, independent of implementation.
    private static let adjacentRiskMatrix: [[Bool]] = [
        [true,  false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
        [false, false, false, false, false, false, false, false, false, false, false],
    ]

    private func segment(_ language: String?, english: String = "Heat.",
                         chinese: String = "热量传递。") -> TranscriptSegment {
        .init(id: UUID(), startTime: 0, endTime: 1, english: english,
              chinese: chinese, sourceLanguage: language)
    }

    private func caption(_ language: String?, start: Double = 0,
                         usable: Bool = true) -> CaptionNoteGate.Caption {
        .init(id: UUID(), revision: 0, start: start, end: start + 1,
              english: "Heat.", chinese: usable ? "热量传递。" : "",
              usable: usable, sourceLanguage: language)
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func pendingPoint() -> LearningNotebook.PendingPoint {
        .init(id: UUID().uuidString, question: "Synthetic question.",
              quotes: ["Earlier heat."], candidateQuotes: ["热量传递。"], referenceCheck: true)
    }

    private func batch(_ evidence: [TranscriptSegment]) -> LearningNoteBatch {
        .init(id: UUID(), evidence: evidence,
              note: LearningNote(topic: "合成热量", points: [.init(kind: "核心结论", text: "热量传递。")]))
    }

    func testTargetQueriesMatchEveryFrozenSourceDecision() {
        for row in Self.baseline {
            let policy = CaptionTranslationTarget.simplifiedChinese.sourcePolicy(for: row.sourceLanguage)
            XCTAssertEqual(policy.keepsSourceAsCaption, row.keepsSourceAsCaption, row.label)
            XCTAssertEqual(policy.usesEnglishTranslationPipeline, row.previewFallbackEligible, row.label)
            XCTAssertEqual(policy.usesEnglishTranslationPipeline, row.academicNormalizerEligible, row.label)
            XCTAssertEqual(policy.usesEnglishTranslationPipeline, row.chemistryProtectorEligible, row.label)
            XCTAssertEqual(policy.usesEnglishTranslationPipeline, row.hintsStored, row.label)
            XCTAssertEqual(policy.usesEnglishTranslationPipeline, row.adjacentRepairLanguageEligible, row.label)
            XCTAssertEqual(policy.usesEnglishTranslationPipeline, row.deferredRepairLanguageEligible, row.label)
            XCTAssertEqual(policy.hasAutomaticNoteGateRisk, row.automaticNoteGateRiskEligible, row.label)
            XCTAssertEqual(policy.learningEvidenceLanguages, row.learningGroups, row.label)
            XCTAssertEqual(policy.includesReviewWarning, row.reviewWarningEligible, row.label)
            XCTAssertEqual(policy.usesIndexedPendingEvidence, row.indexedPendingEvidence, row.label)
        }
        let explicitEnglish = CaptionTranslationTarget.simplifiedChinese.sourcePolicy(for: "en")
        XCTAssertFalse(explicitEnglish.usesEnglishTranslationPipeline)
        XCTAssertTrue(explicitEnglish.hasAutomaticNoteGateRisk)
        XCTAssertTrue(explicitEnglish.usesIndexedPendingEvidence)
    }

    func testCaptionPassThroughAndSpokenLanguageMatchFrozenRows() throws {
        let target = CaptionTranslationTarget.simplifiedChinese
        for row in Self.baseline {
            XCTAssertEqual(target.keepsSourceAsCaption(language: row.sourceLanguage),
                           row.keepsSourceAsCaption, row.label)
            let language = try XCTUnwrap(SpokenLanguage.find(row.sourceLanguage ?? "en"))
            XCTAssertEqual(language.avoidsTranslation, row.keepsSourceAsCaption, row.label)
            XCTAssertEqual(language.avoidsTranslation(target: target), row.keepsSourceAsCaption, row.label)
        }
    }

    func testLearningTextGroupsMatchFrozenRows() {
        for row in Self.baseline {
            let item = segment(row.sourceLanguage)
            for groups in [LearningSourceUnit.textGroups(for: item),
                           LearningSourceUnit.textGroups(for: item, target: .simplifiedChinese)] {
                XCTAssertEqual(groups.map(\.language), row.learningGroups, row.label)
                XCTAssertEqual(groups.last?.text, "热量传递。", row.label)
                if row.learningGroups.contains("en") {
                    XCTAssertEqual(groups.first?.text, "Heat.", row.label)
                }
            }
        }
    }

    func testChineseLearningTextRetainsUsableBytesAndNormalizesOnlyFallback() throws {
        let original = "這片葉子長大了。"
        let stored = " \n這段譯文保留原始位元。\t"
        let completed = segment("zh", english: original, chinese: stored)
        XCTAssertTrue(completed.hasUsableTranslation)
        let kept = try XCTUnwrap(LearningSourceUnit.textGroups(for: completed).first)
        XCTAssertEqual(kept.language, "zh")
        XCTAssertEqual(Data(kept.text.utf8), Data(stored.utf8))

        let empty = segment("zh", english: original, chinese: "")
        var inFlight = completed
        inFlight.beginTranslation()
        var failed = completed
        failed.failTranslation("Synthetic failure.")
        for item in [empty, inFlight, failed] {
            XCTAssertFalse(item.hasUsableTranslation)
            let groups = LearningSourceUnit.textGroups(for: item)
            XCTAssertEqual(groups.map(\.language), ["zh"])
            XCTAssertEqual(groups.first?.text, "这片叶子长大了。")
        }
    }

    func testAutomaticNoteGateTailRisksMatchFrozenRows() {
        for row in Self.baseline {
            let tail = caption(row.sourceLanguage)
            let expected: Set<UUID> = row.automaticNoteGateRiskEligible ? [tail.id] : []
            XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [tail])), expected, row.label)
            XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [tail], producerDrained: true)), [], row.label)
            let unavailable = caption(row.sourceLanguage, usable: false)
            XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [unavailable])), [], row.label)
        }
    }

    func testAutomaticNoteGateAdjacentRisksMatchAllFrozenSourcePairs() {
        for (previousIndex, previousRow) in Self.baseline.enumerated() {
            for (successorIndex, successorRow) in Self.baseline.enumerated() {
                let previous = caption(previousRow.sourceLanguage)
                let message = "\(previousRow.label) -> \(successorRow.label)"
                let expected: Set<UUID> = Self.adjacentRiskMatrix[previousIndex][successorIndex] ? [previous.id] : []
                // An unusable successor isolates predecessor risk from tail risk.
                for start in [1.5, 3.0] {
                    let successor = caption(successorRow.sourceLanguage, start: start, usable: false)
                    let context = CaptionNoteGate.Context(captions: [previous, successor],
                                                          unsettledSuccessors: [successor.id])
                    XCTAssertEqual(CaptionNoteGate.risks(context), expected, message)
                    XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [previous, successor])), [], message)
                }
                let distant = caption(successorRow.sourceLanguage, start: 3.01, usable: false)
                XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [previous, distant],
                    unsettledSuccessors: [distant.id])), [], message)
            }
        }
    }

    func testExplicitRepairTargetsApplyToEveryFrozenSource() {
        for row in Self.baseline {
            for usable in [false, true] {
                let item = caption(row.sourceLanguage, usable: usable)
                XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [item], repairTargets: [item.id],
                    producerDrained: true)), [item.id], row.label)
            }
        }
    }

    func testReviewWarningAndQuoteLanguagesMatchFrozenRows() throws {
        let longTarget = String(repeating: "热量", count: 20) + "。"
        let warning = "⚠️ 此译文明显长于英文，可能混入相邻内容；请勿据此推断，必要时可标注存疑"
        XCTAssertEqual(LearningPrompts.chineseWarning(chinese: longTarget, english: "Heat."), warning)
        for row in Self.baseline {
            let prepared = try LearningPrompts.reviewInput(batch([segment(row.sourceLanguage, chinese: longTarget)]))
            let root = try object(prepared.json)
            let evidence = try XCTUnwrap((root["evidence"] as? [[String: Any]])?.first)
            let quotes = try XCTUnwrap(evidence["quotes"] as? [[String: Any]])
            XCTAssertEqual(evidence["index"] as? Int, 0, row.label)
            XCTAssertEqual(quotes.compactMap { $0["language"] as? String }, row.learningGroups, row.label)
            XCTAssertEqual(prepared.quotes.map(\.language), row.learningGroups, row.label)
            XCTAssertEqual(evidence["chineseWarning"] as? String,
                           row.reviewWarningEligible ? warning : nil, row.label)
            XCTAssertEqual(prepared.catalog["e0.zh.0"]?.text, longTarget, row.label)
            if row.learningGroups.contains("en") {
                XCTAssertEqual(prepared.catalog["e0.en.0"]?.text, "Heat.", row.label)
            } else {
                XCTAssertNil(prepared.catalog["e0.en.0"], row.label)
            }
            XCTAssertTrue(prepared.quotes.allSatisfy { !$0.text.contains(warning) }, row.label)

            // Eligibility alone must not add a warning to a plausible translation.
            let shortReview = try LearningPrompts.reviewInput(batch([segment(row.sourceLanguage)]))
            let shortRoot = try object(shortReview.json)
            let shortEvidence = try XCTUnwrap((shortRoot["evidence"] as? [[String: Any]])?.first)
            XCTAssertNil(shortEvidence["chineseWarning"], row.label)
        }
    }

    func testPendingInputBranchMatchesFrozenRows() throws {
        let pending = pendingPoint()
        for row in Self.baseline {
            let evidence = [segment(row.sourceLanguage)]
            let root = try object(LearningPrompts.input(evidence: evidence, topics: [], pending: [pending]))
            let units = try XCTUnwrap(root["evidence"] as? [[String: Any]])
            XCTAssertEqual(units.compactMap { $0["language"] as? String }, row.learningGroups, row.label)
            let points = try XCTUnwrap(root["pendingPoints"] as? [[String: Any]])
            XCTAssertEqual(points.count, 1, row.label)
            let point = try XCTUnwrap(points.first)
            XCTAssertEqual(point["id"] as? String, "q0", row.label)
            XCTAssertEqual(point["referenceCheck"] as? Bool, true, row.label)
            if row.indexedPendingEvidence {
                XCTAssertEqual(Set(root.keys), ["evidence", "pendingPoints", "priorEvidence", "pendingEvidenceRule"], row.label)
                let prior = try XCTUnwrap(root["priorEvidence"] as? [[String: Any]])
                XCTAssertEqual(prior.count, 1, row.label)
                let old = try XCTUnwrap(prior.first)
                XCTAssertEqual(old["id"] as? String, "h0", row.label)
                XCTAssertEqual(old["scope"] as? String, "prior", row.label)
                XCTAssertEqual(old["text"] as? String, "Earlier heat.", row.label)
                XCTAssertEqual((old["locations"] as? [[String: Any]])?.count, 0, row.label)
                XCTAssertEqual(point["quoteIDs"] as? [String], ["h0"], row.label)
                XCTAssertEqual(point["candidateQuoteIDs"] as? [String], ["zh0s0"], row.label)
                XCTAssertEqual(point["quotes"] as? [String], [], row.label)
                XCTAssertEqual(point["candidateQuotes"] as? [String], [], row.label)
            } else {
                XCTAssertEqual(Set(root.keys), ["evidence", "pendingPoints"], row.label)
                XCTAssertNil(point["quoteIDs"], row.label)
                XCTAssertNil(point["candidateQuoteIDs"], row.label)
                XCTAssertEqual(point["quotes"] as? [String], ["Earlier heat."], row.label)
                XCTAssertEqual(point["candidateQuotes"] as? [String], ["热量传递。"], row.label)
            }

            let withoutPending = try object(LearningPrompts.input(evidence: evidence, topics: []))
            XCTAssertEqual(Set(withoutPending.keys), ["evidence", "pendingPoints"], row.label)
            XCTAssertEqual((withoutPending["pendingPoints"] as? [[String: Any]])?.count, 0, row.label)
        }
    }

    func testPreviewFallbackMatchesFrozenRowsAndNonemptyLiveTextWins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TargetSourcePolicy-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // This prefix is accepted by the existing TestPreferenceCleanup helper.
        let suite = "ClassroomPresentation-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        addTeardownBlock { try cleanup.remove() }
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("unused-queue.json"),
                                       observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
            XCTFail("Synthetic preview probes must not invoke a generator")
            throw CancellationError()
        }
        // Stop the empty queue before presentation setters can reconcile it.
        // No journal directory or course files need to be created.
        await queue.shutdownForTesting()
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Preview probes must not write a journal")
        }
        for row in Self.baseline {
            let earlier = segment(nil, english: "An older sentence.")
            let last = segment(row.sourceLanguage, english: "The final sentence.")
            model.loadPresentationForTesting(phase: .idle, evidence: [earlier, last])
            let expected = row.previewFallbackEligible ? "The final sentence." : ""
            XCTAssertEqual(model.previewTranslationSource, expected, row.label)
            for live in ["Live synthetic speech.", " "] {
                model.receiveLivePreviewForTesting(live)
                XCTAssertEqual(model.previewTranslationSource, live, row.label)
            }
            model.receiveLivePreviewForTesting("")
            XCTAssertEqual(model.previewTranslationSource, expected, row.label)
        }
        model.loadPresentationForTesting(phase: .idle, evidence: [segment("en", english: "Explicit English.")])
        XCTAssertEqual(model.previewTranslationSource, "Explicit English.")
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        XCTAssertEqual(model.previewTranslationSource, "")
        XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
    }

    func testExplicitEnglishCanonicalizationAndRawGateBoundary() throws {
        let constructed = segment("en")
        XCTAssertNil(constructed.sourceLanguage)
        var payload = try object(String(decoding: JSONEncoder().encode(constructed), as: UTF8.self))
        payload["sourceLanguage"] = "en"
        let decoded = try JSONDecoder().decode(TranscriptSegment.self,
                                              from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(decoded.sourceLanguage)
        XCTAssertEqual(decoded, constructed)
        XCTAssertFalse(CaptionTranslationTarget.simplifiedChinese.keepsSourceAsCaption(language: "en"))
        XCTAssertFalse(try XCTUnwrap(SpokenLanguage.find("en")).avoidsTranslation)
        for item in [constructed, decoded] {
            XCTAssertEqual(LearningSourceUnit.textGroups(for: item).map(\.language), ["en", "zh"])
            let root = try object(LearningPrompts.input(evidence: [item], topics: [], pending: [pendingPoint()]))
            XCTAssertEqual(Set(root.keys), ["evidence", "pendingPoints"])
        }
        for previousLanguage in [nil, "en"] as [String?] {
            let previous = caption(previousLanguage)
            XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [previous])), [previous.id])
            XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [previous], producerDrained: true)), [])
            for successorLanguage in [nil, "en"] as [String?] {
                let successor = caption(successorLanguage, start: 1.5, usable: false)
                XCTAssertEqual(CaptionNoteGate.risks(.init(captions: [previous, successor],
                    unsettledSuccessors: [successor.id])), [previous.id])
            }
        }
    }
}
