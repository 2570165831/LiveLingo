import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class SpanishFrenchCaptionTests: XCTestCase {
    private final class TargetDefaults: UserDefaults, @unchecked Sendable {
        var locale = "es"
        override func string(forKey key: String) -> String? {
            key == "LiveLingo.outputLanguage" ? locale : super.string(forKey: key)
        }
    }
    private actor Requests {
        var prompts: [String] = []
        var inputs: [String] = []
        func record(_ input: String, _ prompt: String, reply: String) -> String {
            inputs.append(input); prompts.append(prompt); return reply
        }
    }
    private func model(_ target: CaptionTranslationTarget,
                       dependencies: CaptionTranslationDependencies = .unavailable) async throws -> AppModel {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SpanishFrenchCaption-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "SpanishFrenchTarget-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TargetDefaults(suiteName: suite)); defaults.locale = target.rawValue
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in throw CancellationError() }
        let model = AppModel(reviewQueue: queue, translation: dependencies,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .spanish, .french])
        try await model.beginSavedCourseForTesting(directory: root.appendingPathComponent("course"))
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove(defaults)
            try FileManager.default.removeItem(at: root)
        }
        return model
    }
    private func reply(_ target: CaptionTranslationTarget) -> String {
        target == .spanish ? "El agua está fría y la presión disminuye." : "L’eau est froide et la pression diminue."
    }
    func testProfilesRemainHiddenAndPendingChoicesAreCentralized() {
        XCTAssertEqual(OutputLanguage.released, [.simplifiedChinese])
        XCTAssertEqual(LatinOutputDefaults.translationRoute, .direct)
        for target in [CaptionTranslationTarget.spanish, .french] {
            let language = OutputLanguage(rawValue: target.rawValue)!
            XCTAssertFalse(language.isReleased)
            XCTAssertNil(OutputLanguage.releasedLanguage(target.rawValue))
            XCTAssertEqual(language.generationTarget, target)
            XCTAssertEqual(language.profile.promptName, target == .spanish ? "Spanish" : "French")
            XCTAssertEqual(language.profile.passThroughSources, [target.rawValue])
            XCTAssertTrue(target.keepsSourceAsCaption(language: target.rawValue))
            XCTAssertFalse(target.keepsSourceAsCaption(language: nil))
            XCTAssertEqual(language.profile.appleLanguagePair, .init(source: "en", target: target.rawValue))
        }
    }
    func testDirectAndPivotCallsGoThroughTheRealTranslationClient() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            for route in [CaptionTranslationRoute.direct, .viaEnglish] {
                let requests = Requests(), expected = reply(target)
                let value = try await QwenTranslationClient.translate("水很冷，压力下降。",
                    modelName: QwenModelProfile.energySaver.translationModel, sourceLanguage: "zh", target: target,
                    request: { input, prompt, _ in
                        await requests.record(input, prompt,
                            reply: prompt.contains(QwenTranslationClient.englishSourceFaithfulCaptionPrompt)
                                ? "The water is cold and the pressure decreases." : expected)
                    }, route: route)
                XCTAssertEqual(value, expected)
                let prompts = await requests.prompts
                XCTAssertEqual(prompts.count, route == .direct ? 1 : 2)
                XCTAssertTrue(prompts.last?.contains(LatinCaptionPrompts.system(for: target, faithful: true)) == true)
                if route == .viaEnglish { XCTAssertTrue(prompts.first?.contains(QwenTranslationClient.englishSourceFaithfulCaptionPrompt) == true) }
            }
            for language in [Optional<String>.none, "en"] {
                let requests = Requests(), expected = reply(target)
                _ = try await QwenTranslationClient.translate("The water is cold and the pressure decreases.",
                    modelName: QwenModelProfile.highQuality.translationModel, sourceLanguage: language, target: target,
                    request: { input, prompt, _ in await requests.record(input, prompt, reply: expected) }, route: .viaEnglish)
                let prompts = await requests.prompts
                XCTAssertEqual(prompts.count, 1)
                XCTAssertTrue(prompts[0].contains(LatinCaptionPrompts.system(for: target)))
            }
        }
    }
    func testAppTranslationAndSameLanguageReceptionUseTheCourseTarget() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            var calls: [String] = [], repairs = 0
            let requests = Requests(), expected = reply(target)
            var dependencies = CaptionTranslationDependencies.unavailable
            dependencies.translateTarget = { source, name, language, actualTarget, hints, attempt, _ in
                calls.append(language ?? "en")
                XCTAssertEqual(actualTarget, target)
                return try await QwenTranslationClient.translate(source, modelName: name, sourceLanguage: language,
                    target: actualTarget, hints: hints, attempt: attempt,
                    request: { input, prompt, _ in
                        XCTAssertTrue(prompt.contains(LatinCaptionPrompts.system(for: target,
                            faithful: name == QwenModelProfile.energySaver.translationModel)))
                        return await requests.record(input, prompt, reply: expected)
                    })
            }
            dependencies.adjacentTarget = { _, _, _, _, _, _, _, _, _, _ in
                repairs += 1; return .init(previous: nil, current: nil, previousRejection: nil, currentRejection: nil)
            }
            dependencies.repairTarget = { _, actualTarget in
                XCTAssertEqual(actualTarget, target); repairs += 1; return .init(previous: nil, rejection: nil)
            }
            let app = try await model(target, dependencies: dependencies)
            for (index, pair) in [(nil, "The water is cold and the pressure decreases."),
                                  (Optional("zh"), "水很冷，压力下降。"),
                                  (Optional("ja"), "水は冷たく、圧力が下がります。"),
                                  (Optional(target == .spanish ? "fr" : "es"), reply(target == .spanish ? .french : .spanish)),
                                  (Optional(target.rawValue), expected)].enumerated() {
                app.receiveIdentifiedCaptionForTesting(.init(startTime: Double(index), endTime: Double(index + 1),
                    english: pair.1, sourceLanguage: pair.0))
                await app.translationTaskForTesting?.value
            }
            XCTAssertEqual(calls, ["en", "zh", "ja", target == .spanish ? "fr" : "es"])
            XCTAssertEqual(repairs, 0)
            XCTAssertEqual(app.segments.map(\.chinese), Array(repeating: expected, count: 5))
            let prompts = await requests.prompts
            XCTAssertEqual(prompts.count, 4)
            XCTAssertTrue(prompts.allSatisfy { $0.hasPrefix(LatinOutputDefaults.styleInstruction(for: target)) })
        }
    }
    func testMissingApplePackageSkipsPreparationAndWaitsForFormalTranslation() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let app = try await model(target)
            var prepared = 0
            for availability in [AppModel.PreviewPackageAvailability.supported, .unsupported] {
                let result = try await app.preparePreviewTranslationIfEligible(availability: availability) { prepared += 1 }
                XCTAssertFalse(result)
                XCTAssertEqual(app.previewTranslationStatus, "初译语言包未就绪，只等正式译文")
                XCTAssertEqual(app.previewChinese, "")
            }
            XCTAssertEqual(prepared, 0)
            let result = try await app.preparePreviewTranslationIfEligible(availability: .installed) { prepared += 1 }
            XCTAssertTrue(result)
            XCTAssertEqual(prepared, 1)
        }
    }
    func testTailRepairKeepsExactlyOneLatinSentenceBoundarySpace() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let prefix = target == .spanish ? "La masa es constante." : "La masse est constante."
            let tail = target == .spanish ? "La velocidad está aumentando." : "La vitesse augmente."
            let result = try await QwenTranslationClient.repairPreviousCaption(
                previous: "The mass is constant. The speed increases.", previousChinese: prefix + " Old tail.",
                current: "The change continues.", context: "", modelName: QwenModelProfile.energySaver.translationModel,
                target: target, request: { input, prompt, _ in
                    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
                    XCTAssertEqual(payload["target_translate_only"], "The speed increases.")
                    XCTAssertTrue(prompt.contains(LatinCaptionPrompts.repairInstruction(for: target)))
                    return "  " + tail + "  "
                })
            XCTAssertEqual(result.previous, prefix + " " + tail)
            XCTAssertNil(result.rejection)
            XCTAssertEqual(target.acceptancePolicy.joinStablePrefix(prefix + "  ", tail: "  " + tail), prefix + " " + tail)
        }
    }
    func testLatinRepairPlansAreDisabledAndNumericVetoOnlyProposesDigits() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            XCTAssertNil(target.acceptancePolicy.quotedTranslationRepairPlan(candidate: "Translate: x", source: "Translate: x"))
            XCTAssertNil(target.acceptancePolicy.jsonStatusRepairPlan(candidate: #"{"status":"pending"}"#, source: #"{"status":"pending"}"#))
            let existing = target == .spanish ? "La cantidad es 20." : "La quantité est 20."
            let bad = target == .spanish ? "La cantidad es 30." : "La quantité est 30."
            let rejected = try await QwenTranslationClient.repairPreviousCaption(previous: "The count is 20.",
                previousChinese: existing, current: "Keep that count.", context: "", modelName: QwenModelProfile.energySaver.translationModel,
                target: target, request: { _, _, _ in bad })
            XCTAssertNil(rejected.previous)
            XCTAssertTrue(rejected.rejection?.contains("新数值") == true)
            XCTAssertEqual(RepairNumericNovelty.assess(candidate: target == .spanish ? "La cantidad es treinta." : "La quantité est trente.",
                support: ["The count is 20."], targetCode: target.rawValue).unsupported, [])
        }
    }
    func testTypedTranslationUsesIndependentTargetPromptsAndPreservesAccents() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let expected = reply(target)
            let value = try await QwenTranslationClient.translateTypedText("The water is cold and the pressure decreases.",
                modelName: QwenModelProfile.highQuality.translationModel, target: target,
                request: { _, prompt, _ in
                    XCTAssertTrue(prompt.contains(LatinCaptionPrompts.system(for: target)))
                    XCTAssertTrue(prompt.contains(LatinCaptionPrompts.wrapper(for: target, smallModel: false)))
                    XCTAssertFalse(prompt.contains("into Chinese"))
                    return expected
                })
            XCTAssertEqual(value, expected)
        }
    }
    func testAppAdjacentRequestFiltersForeignContextAndForwardsTheTarget() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let prefix = target == .spanish ? "La masa es constante." : "La masse est constante."
            let tail = target == .spanish ? "La velocidad está aumentando." : "La vitesse augmente."
            var repairs = 0
            var dependencies = CaptionTranslationDependencies.unavailable
            dependencies.translateTarget = { source, _, _, actual, _, _, _ in
                XCTAssertEqual(actual, target)
                return source.contains("mass") ? prefix + " " + tail
                    : (target == .spanish ? "La presión es constante." : "La pression est constante.")
            }
            dependencies.adjacentTarget = { previous, translated, current, context, name, repair, actual, hints, _, _ in
                XCTAssertEqual(actual, target)
                XCTAssertTrue(context.contains("The pressure is constant."))
                XCTAssertFalse(context.contains("压力"))
                return try await QwenTranslationClient.translateAdjacent(previous: previous, previousChinese: translated,
                    current: current, context: context, modelName: name, repairPrevious: repair,
                    target: actual, currentHints: hints, request: { input, _, _ in
                        if let payload = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String],
                           let before = payload["context_before_do_not_translate"] {
                            XCTAssertTrue(before.contains("The pressure is constant."))
                            XCTAssertFalse(before.contains("压力"))
                        }
                        return tail
                    })
            }
            dependencies.repairTarget = { _, actual in
                XCTAssertEqual(actual, target); repairs += 1; return .init(previous: nil, rejection: nil)
            }
            let app = try await model(target, dependencies: dependencies)
            for (index, pair) in [(nil, "The pressure is constant."), (Optional("zh"), "压力不变。"),
                (nil, "The mass is constant. The speed increases."), (nil, "The speed increases.")].enumerated() {
                app.receiveIdentifiedCaptionForTesting(.init(startTime: Double(index), endTime: Double(index + 1),
                    english: pair.1, sourceLanguage: pair.0))
                await app.translationTaskForTesting?.value
            }
            XCTAssertEqual(app.segments[2].chinese, prefix + " " + tail)
            XCTAssertEqual(app.segments[3].chinese, tail)
            XCTAssertEqual(repairs, 0)
        }
    }
    func testProductionClientsRejectShortEnglishEchoesAndFoldTraditionalLeaks() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            for bad in ["The pressure.", "源語言是英語，翻譯元數據。"] {
                do {
                    _ = try await QwenTranslationClient.translate("The pressure.",
                        modelName: QwenModelProfile.energySaver.translationModel, target: target,
                        request: { _, _, _ in bad })
                    XCTFail("A foreign echo or leaked metadata must not be accepted")
                } catch QwenRuntimeError.translationRejected { }
            }
            let app = try await model(target), expected = reply(target)
            app.setTypedTranslationRequestForTesting { _, prompt, _ in
                XCTAssertTrue(prompt.contains(LatinCaptionPrompts.system(for: target)))
                return expected
            }
            app.manualTranslationInput = "The water is cold and the pressure decreases."
            app.translateTypedText()
            for _ in 0..<100 where app.isManualTranslating { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(app.manualTranslationOutput, expected)
        }
    }
    func testCaptionPromptDigestsAreFrozen() {
        let values: [(String, String)] = [
            (LatinCaptionPrompts.system(for: .spanish), "13f0b5c331a5a80f595d77c769f7b09edde3ca67767b5c48baacf35eeb38fd02"),
            (LatinCaptionPrompts.system(for: .spanish, faithful: true), "0b6f9fde637eb3ca255442009838697429c1e1a4ae0ee15c9c157990ab9e9d1f"),
            (LatinCaptionPrompts.system(for: .french), "eb2eb316f7f715c1a2c5cbd745d0dd5f6ff8620a67c9491ffc35227ecf884714"),
            (LatinCaptionPrompts.system(for: .french, faithful: true), "af1de3b4473ec090f733439ae9fe4d08d0d273c8a2ebdc06e8ee076b4ec5b0c5"),
            (LatinCaptionPrompts.spanishSystem, "9f32f2fb8495477d1e9379e9c805dc33aca3700877c42a5c615718baeee0186c"),
            (LatinCaptionPrompts.spanishFaithful, "f24cde87591fbf8d3b187eff5853fa9fbb74e028675c649f40ed19029416eea4"),
            (LatinCaptionPrompts.spanishWrapper4B, "a01cb7a9ff47f1ecdb6a5513944a8369d9da5868eff2427569481cc1ce1492cc"),
            (LatinCaptionPrompts.spanishWrapper9B, "a7f5ccfc803555e4d550ede407dfbd9eb9b23afd9fd375492f1078c6826cfa1c"),
            (LatinCaptionPrompts.spanishRecovery, "8ca99808d4abe8d5f30aee67035c0237001fe32349e6328c226b0ca121408713"),
            (LatinCaptionPrompts.frenchSystem, "8ed0fa1212c3f08af05da23cdfdcb0d27b1fb33047d180a3c88d0e5e17895c64"),
            (LatinCaptionPrompts.frenchFaithful, "32713b24845fe3d177284e3bc67dec1581d221cd31638a0e69100a6afc37ad7c"),
            (LatinCaptionPrompts.frenchWrapper4B, "d28fe49e177ccc6a2a2f13f7097e993890e1f5e974b9f9a08986e0a8e7b21773"),
            (LatinCaptionPrompts.frenchWrapper9B, "1e85e3c79f0605f2473f322a4d44e581cce28e7889e06895b4be36abd499cb7d"),
            (LatinCaptionPrompts.frenchRecovery, "091c9472bac227ed3868c117937623e87ac4388e21d6fd546cbdbf9aff56b940"),
        ]
        for (prompt, digest) in values { XCTAssertEqual(SessionArchiveCoding.digest(Data(prompt.utf8)), digest) }
    }
}
