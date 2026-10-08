import Foundation
import XCTest
@testable import LiveLingo

/// Authored short captions only; no audio, generators or system translation.
@MainActor
final class MultilingualCaptionGateTests: XCTestCase {
    private func caption(sourceLanguage: String? = nil, start: Double = 0, end: Double = 1,
                         usable: Bool = true) -> CaptionNoteGate.Caption {
        let source: String
        switch sourceLanguage {
        case "zh": source = "叶子长大了。"
        case "yue": source = "塊葉長大咗。"
        case "es": source = "La hoja crece."
        default: source = "A leaf grows."
        }
        return .init(id: UUID(), revision: 0, start: start, end: end,
                     english: source, chinese: usable ? "叶子长大了。" : "",
                     usable: usable, sourceLanguage: sourceLanguage)
    }

    private func presentationModel() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultilingualCaptionGate-\(UUID().uuidString)",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLingo-MultilingualCaptionGate-\(UUID().uuidString)"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
                                       observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
            XCTFail("Caption display tests must not invoke a generator")
            throw CancellationError()
        }
        addTeardownBlock {
            await queue.shutdownForTesting()
            try preferenceCleanup.remove()
            try FileManager.default.removeItem(at: directory)
        }
        // No preference setters: the isolated suite is read without persisting values.
        return AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                        backgroundServices: false, scheduledNotes: false, defaults: defaults)
    }

    func testEnglishAdjacentCaptionsKeepBoundedHold() {
        for previousLanguage in [nil, "en"] as [String?] {
            for successorLanguage in [nil, "en"] as [String?] {
                let previous = caption(sourceLanguage: previousLanguage)
                let successor = caption(sourceLanguage: successorLanguage, start: 1.5, end: 2.5, usable: false)
                let context = CaptionNoteGate.Context(captions: [previous, successor],
                                                      unsettledSuccessors: [successor.id])
                XCTAssertEqual(CaptionNoteGate.risks(context), [previous.id])
                var gate = CaptionNoteGate()
                let initial = gate.evaluate(context, now: 10)
                XCTAssertEqual(initial.held, [previous.id])
                XCTAssertTrue(initial.eligible.isEmpty)
                XCTAssertTrue(initial.admittedAtLimit.isEmpty)
                XCTAssertEqual(initial.nextWake, 30)
                XCTAssertEqual(initial.oldestUncoveredDeadline, 30)
                XCTAssertFalse(initial.sealed)
                XCTAssertEqual(gate.evaluate(context, now: 29).held, [previous.id])
                let limit = gate.evaluate(context, now: 30)
                XCTAssertEqual(limit.eligible, [previous.id])
                XCTAssertEqual(limit.admittedAtLimit, [previous.id])
                XCTAssertTrue(limit.held.isEmpty)
                XCTAssertNil(limit.nextWake)
            }
        }
    }

    func testEnglishAdjacencyKeepsTwoSecondBoundary() {
        let previous = caption()
        for (start, shouldHold) in [(3.0, true), (3.01, false)] {
            let successor = caption(start: start, end: start + 1, usable: false)
            let context = CaptionNoteGate.Context(captions: [previous, successor],
                                                  unsettledSuccessors: [successor.id])
            var gate = CaptionNoteGate()
            let decision = gate.evaluate(context, now: 0)
            XCTAssertEqual(decision.held.contains(previous.id), shouldHold)
            XCTAssertEqual(decision.eligible.contains(previous.id), !shouldHold)
        }
    }

    func testEnglishTailWaitsForProducerDrain() {
        for language in [nil, "en"] as [String?] {
            let tail = caption(sourceLanguage: language)
            var context = CaptionNoteGate.Context(captions: [tail])
            var gate = CaptionNoteGate()
            XCTAssertEqual(gate.evaluate(context, now: 10).held, [tail.id])
            context.producerDrained = true
            let drained = gate.evaluate(context, now: 11)
            XCTAssertEqual(drained.eligible, [tail.id])
            XCTAssertTrue(drained.held.isEmpty)
            XCTAssertTrue(drained.admittedAtLimit.isEmpty)
            XCTAssertNil(drained.nextWake)
            XCTAssertTrue(drained.sealed)
        }
    }

    func testMixedLanguageAdjacencyDoesNotHoldPreviousCaption() {
        let pairs: [(String?, String?)] = [("zh", nil), (nil, "zh"), ("es", "en")]
        for (previousLanguage, successorLanguage) in pairs {
            let previous = caption(sourceLanguage: previousLanguage)
            let successor = caption(sourceLanguage: successorLanguage, start: 1.5, end: 2.5, usable: false)
            let context = CaptionNoteGate.Context(captions: [previous, successor],
                                                  unsettledSuccessors: [successor.id])
            XCTAssertTrue(CaptionNoteGate.risks(context).isEmpty)
            var gate = CaptionNoteGate()
            let decision = gate.evaluate(context, now: 10)
            XCTAssertEqual(decision.eligible, [previous.id])
            XCTAssertTrue(decision.held.isEmpty)
            XCTAssertTrue(decision.admittedAtLimit.isEmpty)
            XCTAssertNil(decision.nextWake)
            XCTAssertFalse(decision.sealed)
        }
    }

    func testNonEnglishTailDoesNotWaitForFutureRepair() {
        for language in ["zh", "yue", "es"] {
            let tail = caption(sourceLanguage: language)
            let context = CaptionNoteGate.Context(captions: [tail])
            XCTAssertTrue(CaptionNoteGate.risks(context).isEmpty)
            var gate = CaptionNoteGate()
            let decision = gate.evaluate(context, now: 10)
            XCTAssertEqual(decision.eligible, [tail.id])
            XCTAssertTrue(decision.held.isEmpty)
            XCTAssertTrue(decision.admittedAtLimit.isEmpty)
            XCTAssertNil(decision.nextWake)
            XCTAssertFalse(decision.sealed)
        }
    }

    func testExplicitRepairTargetsStillHoldCaptions() {
        for language in [nil, "en", "zh", "yue", "es"] as [String?] {
            let target = caption(sourceLanguage: language)
            var context = CaptionNoteGate.Context(captions: [target], repairTargets: [target.id],
                                                  producerDrained: true)
            XCTAssertEqual(CaptionNoteGate.risks(context), [target.id])
            var gate = CaptionNoteGate()
            let initial = gate.evaluate(context, now: 10)
            XCTAssertEqual(initial.held, [target.id])
            XCTAssertTrue(initial.eligible.isEmpty)
            XCTAssertEqual(initial.nextWake, 30)
            XCTAssertFalse(initial.sealed)
            let limit = gate.evaluate(context, now: 30)
            XCTAssertEqual(limit.eligible, [target.id])
            XCTAssertEqual(limit.admittedAtLimit, [target.id])
            XCTAssertTrue(limit.held.isEmpty)
            XCTAssertFalse(limit.sealed)
            context.repairTargets = []
            let repaired = gate.evaluate(context, now: 31)
            XCTAssertEqual(repaired.eligible, [target.id])
            XCTAssertTrue(repaired.admittedAtLimit.isEmpty)
            XCTAssertTrue(repaired.sealed)
        }
    }

    func testChineseSourceDisplaysWithoutPreviewOrFormalTranslation() throws {
        let model = try presentationModel()
        let source = "小船靠岸了。"
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: source, sourceLanguage: "zh")
        XCTAssertFalse(segment.hasUsableTranslation)
        model.loadPresentationForTesting(phase: .idle, evidence: [segment])
        for enabled in [false, true] {
            model.previewTranslationEnabled = enabled
            model.receiveLivePreviewForTesting("", chinese: "过时的初译。")
            XCTAssertEqual(model.previewEnglishDisplay, source)
            XCTAssertEqual(model.previewChineseDisplay, source)
        }
    }

    func testCantoneseDisplaysTraditionalOriginalAndSimplifiedFormalTranslation() throws {
        let model = try presentationModel()
        let source = "隻小船泊好咗。"
        let translation = "小船已经停好了。"
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: source,
                                        chinese: translation, sourceLanguage: "yue")
        XCTAssertTrue(segment.hasUsableTranslation)
        model.loadPresentationForTesting(phase: .idle, evidence: [segment])
        for enabled in [false, true] {
            model.previewTranslationEnabled = enabled
            model.receiveLivePreviewForTesting("", chinese: "过时的初译。")
            XCTAssertEqual(model.previewEnglishDisplay, source)
            XCTAssertEqual(model.previewChineseDisplay, translation)
        }
    }

    func testOtherNonEnglishSourcesWaitForFormalTranslation() throws {
        let model = try presentationModel()
        for (language, source) in [("yue", "隻小船泊好咗。"), ("es", "La barca está quieta.")] {
            let pending = TranscriptSegment(startTime: 0, endTime: 1, english: source, sourceLanguage: language)
            var translating = TranscriptSegment(startTime: 0, endTime: 1, english: source,
                                                 chinese: "小船停住了。", sourceLanguage: language)
            translating.beginTranslation()
            for segment in [pending, translating] {
                XCTAssertFalse(segment.hasUsableTranslation)
                model.loadPresentationForTesting(phase: .idle, evidence: [segment])
                for enabled in [false, true] {
                    model.previewTranslationEnabled = enabled
                    XCTAssertEqual(model.previewEnglishDisplay, source)
                    XCTAssertEqual(model.previewChineseDisplay, "等待正式译文…")
                }
            }
        }
    }

    func testFailedNonEnglishTranslationDoesNotDisplayDiagnostic() throws {
        let model = try presentationModel()
        var segment = TranscriptSegment(startTime: 0, endTime: 1, english: "La hoja crece.", sourceLanguage: "es")
        segment.failTranslation("Synthetic failure detail")
        model.loadPresentationForTesting(phase: .idle, evidence: [segment])
        for enabled in [false, true] {
            model.previewTranslationEnabled = enabled
            XCTAssertEqual(model.previewEnglishDisplay, segment.english)
            XCTAssertEqual(model.previewChineseDisplay, "本段翻译未完成")
        }
    }

    func testVolatileEnglishOverridesConfirmedNonEnglishCaption() throws {
        let model = try presentationModel()
        let cases = [("zh", "小船靠岸了。", "小船靠岸了。"),
                     ("yue", "隻小船泊好咗。", "小船已经停好了。"),
                     ("es", "La barca está quieta.", "小船停住了。")]
        for (language, source, translation) in cases {
            model.previewTranslationEnabled = true
            let segment = TranscriptSegment(startTime: 0, endTime: 1, english: source,
                                            chinese: translation, sourceLanguage: language)
            model.loadPresentationForTesting(phase: .idle, evidence: [segment])
            model.receiveLivePreviewForTesting("A bell rings.", chinese: "铃响了。")
            XCTAssertEqual(model.previewEnglishDisplay, "A bell rings.")
            XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                ? "初译 · 铃响了。" : "当前系统不支持初译；正式译文随后显示")
            model.previewTranslationEnabled = false
            XCTAssertEqual(model.previewChineseDisplay, "初译已关闭")
            model.previewTranslationEnabled = true
            XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                ? "等待初译…" : "当前系统不支持初译；正式译文随后显示")
            model.receiveLivePreviewForTesting("", chinese: "过时的初译。")
            XCTAssertEqual(model.previewEnglishDisplay, source)
            XCTAssertEqual(model.previewChineseDisplay, translation)
        }
    }

    func testEnglishPreviewKeepsAllExistingDisplayBranches() throws {
        let model = try presentationModel()
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        XCTAssertEqual(model.previewEnglishDisplay, "等待英文语音…")
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
            ? "等待语音…" : "当前系统不支持初译；正式译文随后显示")
        model.previewTranslationEnabled = false
        XCTAssertEqual(model.previewEnglishDisplay, "等待英文语音…")
        XCTAssertEqual(model.previewChineseDisplay, "初译已关闭")
        for language in [nil, "en"] as [String?] {
            model.previewTranslationEnabled = true
            let earlier = TranscriptSegment(startTime: 0, endTime: 1, english: "小船靠岸了。", sourceLanguage: "zh")
            let latest = TranscriptSegment(startTime: 1, endTime: 2, english: "The wind blows.",
                                           chinese: "风吹来了。", sourceLanguage: language)
            model.loadPresentationForTesting(phase: .idle, evidence: [earlier, latest])
            XCTAssertEqual(model.previewEnglishDisplay, latest.english)
            XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                ? "等待初译…" : "当前系统不支持初译；正式译文随后显示")
            model.receiveLivePreviewForTesting("", chinese: "风吹着。")
            XCTAssertEqual(model.previewEnglishDisplay, latest.english)
            XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                ? "初译 · 风吹着。" : "当前系统不支持初译；正式译文随后显示")
            model.receiveLivePreviewForTesting("A bell rings.", chinese: "铃响了。")
            XCTAssertEqual(model.previewEnglishDisplay, "A bell rings.")
            XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                ? "初译 · 铃响了。" : "当前系统不支持初译；正式译文随后显示")
            model.previewTranslationEnabled = false
            XCTAssertEqual(model.previewEnglishDisplay, "A bell rings.")
            XCTAssertEqual(model.previewChineseDisplay, "初译已关闭")
            model.previewTranslationEnabled = true
            XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                ? "等待初译…" : "当前系统不支持初译；正式译文随后显示")
        }
    }
}
