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
                       dependencies: CaptionTranslationDependencies = .unavailable,
                       notes: LearningGenerationDependencies = .unavailable) async throws -> AppModel {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SpanishFrenchCaption-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "SpanishFrenchTarget-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TargetDefaults(suiteName: suite)); defaults.locale = target.rawValue
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in throw CancellationError() }
        let model = AppModel(reviewQueue: queue, translation: dependencies, notes: notes,
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
    func testAppActuallyGeneratesAndBindsSpanishFrenchNotes() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let line = target == .spanish ? "La variable almacena un valor." : "La variable contient une valeur."
            var calls = 0
            let notes = LearningGenerationDependencies { input, _, prefix, prompt, _ in
                calls += 1
                XCTAssertEqual(prompt, target.learningNotePrompt); XCTAssertEqual(prefix, "")
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
                let evidence = try XCTUnwrap(object["evidence"] as? [[String: Any]])
                XCTAssertTrue(evidence.allSatisfy { $0["language"] as? String == target.rawValue })
                let points = evidence.map { ["kind": "例子", "text": $0["text"] as! String, "sourceIDs": [$0["id"] as! String]] as [String: Any] }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["sourceVersion": 2, "topic": "Variables", "points": points, "followUps": [:], "noNewKnowledge": false], options: .sortedKeys), as: UTF8.self)
            }
            let model = try await model(target, notes: notes)
            for time in [0.0, 2.0] {
                model.receiveIdentifiedCaptionForTesting(.init(startTime: time, endTime: time + 1, english: line, sourceLanguage: target.rawValue))
            }
            await model.generateSummaryForTesting()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(model.learningNotebookForTesting.target, target)
            XCTAssertEqual(model.learningNotebookForTesting.batches.first?.note.points.first?.referenceState, .linked)
            XCTAssertEqual(model.learningNotebookForTesting.batches.first?.note.points.first?.sourceIDs, [target.rawValue + "0s0"])
            XCTAssertTrue(model.lectureSummary.contains(target == .spanish ? "**Ejemplo**" : "**Exemple**"))
        }
    }
    func testLegacySpanishFrenchImportRebuildAndReopenUseManifestTarget() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let line = target == .spanish ? "La variable almacena un valor." : "La variable contient une valeur."
            var calls = 0
            let notes = LearningGenerationDependencies { _, _, _, prompt, _ in
                calls += 1; XCTAssertEqual(prompt, target.learningNotePrompt)
                return String(decoding: try JSONSerialization.data(withJSONObject: ["sourceVersion": 2, "topic": "Variables",
                    "points": [["kind": "例子", "text": line, "sourceIDs": [target.rawValue + "0s0"]]], "noNewKnowledge": false], options: .sortedKeys), as: UTF8.self)
            }
            let app = try await model(target, notes: notes)
            let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpanishFrenchLegacy-\(UUID())")
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
            let source = TranscriptSegment(startTime: 0, endTime: 1, english: line, chinese: line, sourceLanguage: target.rawValue)
            try SessionExporter.export(segments: [source], sessionDirectory: root, summary: "Preserved old notes.", target: OutputLanguage(rawValue: target.rawValue)!)
            let loaded = try SessionStore(directory: root).loadDetailed()
            XCTAssertEqual(loaded.origin, .legacy)
            let snapshot = try XCTUnwrap(loaded.snapshot)
            XCTAssertEqual(snapshot.targetLocale, target.rawValue)
            let draft = LearningDraft(evidence: snapshot.segments, model: "synthetic",
                input: try LearningPrompts.input(evidence: snapshot.segments, topics: [], target: target), target: target, systemPrompt: target.learningNotePrompt)
            XCTAssertTrue(draft.matches(snapshot: snapshot, model: "synthetic", systemPrompt: target.learningNotePrompt))
            app.loadPresentationForTesting(phase: .saved(root), evidence: [])
            try await app.openSavedSession(root, allowAutomaticProcessing: false)
            XCTAssertEqual(app.learningNotebookForTesting.target, target)
            app.rebuildSavedNotes()
            for _ in 0..<200 where app.learningNotebookForTesting.batches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            await app.savedProcessingTaskForTesting?.value
            try await app.flushSavedCourseForTesting()
            XCTAssertEqual(calls, 1, "status=\(app.summaryStatus); error=\(app.archiveError ?? "none")")
            XCTAssertEqual(app.learningNotebookForTesting.batches.count, 1)
            XCTAssertEqual(try SessionStore(directory: root).load()?.targetLocale, target.rawValue)
            try await app.openSavedSession(root, allowAutomaticProcessing: false)
            XCTAssertEqual(app.learningNotebookForTesting.target, target)
            XCTAssertEqual(app.learningNotebookForTesting.batches.count, 1)
        }
    }
    func testAppOutputLimitRecoveryUsesTargetPromptOnFreshSmallerInputs() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let line = target == .spanish ? "La variable almacena un valor." : "La variable contient une valeur."
            var calls = 0, lengths: [Int] = []
            let notes = LearningGenerationDependencies { input, _, prefix, prompt, _ in
                calls += 1
                let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
                let units = try XCTUnwrap(parsed["evidence"] as? [[String: Any]])
                lengths.append(units.count)
                XCTAssertEqual(prefix, "")
                XCTAssertEqual(prompt, LearningPrompts.generationPrompt(target: target, recoveringAfterOutputLimit: calls > 1))
                if calls == 1 { throw QwenRuntimeError.outputLimitReached("Synthetic output limit") }
                let points = units.map { ["kind": "例子", "text": $0["text"] as! String, "sourceIDs": [$0["id"] as! String]] as [String: Any] }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["sourceVersion": 2, "topic": "Variables", "points": points, "followUps": [:], "noNewKnowledge": false], options: .sortedKeys), as: UTF8.self)
            }
            let app = try await model(target, notes: notes)
            for time in [0.0, 2.0] {
                app.receiveIdentifiedCaptionForTesting(.init(startTime: time, endTime: time + 1, english: line, sourceLanguage: target.rawValue))
            }
            await app.generateSummaryForTesting()
            XCTAssertEqual(lengths, [2, 1, 1])
            XCTAssertEqual(calls, 3)
            XCTAssertEqual(app.learningNotebookForTesting.batches.count, 2)
            XCTAssertEqual(app.noteBatchCharacters, 4_000)
        }
    }
    func testUnreleasedSavedCoursesCannotStartThroughOpenEntry() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let app = try await model(target)
            let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpanishFrenchClosed-\(UUID())")
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
            try SessionExporter.export(segments: [.init(startTime: 0, endTime: 1, english: reply(target), chinese: reply(target), sourceLanguage: target.rawValue)],
                sessionDirectory: root, target: OutputLanguage(rawValue: target.rawValue)!)
            app.loadPresentationForTesting(phase: .saved(root), evidence: [])
            app.setReleasedOutputLanguagesForTesting([.simplifiedChinese])
            do { try await app.openSavedSession(root, allowAutomaticProcessing: false); XCTFail("Unreleased saved course must stay closed") }
            catch SessionStoreError.invalidState { }
        }
    }
    func testProfilesRemainHiddenAndUserDecisionsAreCentralized() {
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
            XCTAssertEqual(language.profile.appleLanguagePair,
                .init(source: "en", target: target == .spanish ? "es" : "fr-FR"))
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
    func testSelectedStandardsReachBothModelsAndEveryCaptionAttempt() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            for model in [QwenModelProfile.energySaver.translationModel, QwenModelProfile.highQuality.translationModel] {
                for attempt in [CaptionTranslationAttempt.standard, .repairContent, .expandedBudget] {
                    let expected = reply(target)
                    let result = try await QwenTranslationClient.translate("The water is cold and the pressure decreases.",
                        modelName: model, target: target, attempt: attempt,
                        request: { _, prompt, _ in
                            if target == .spanish {
                                XCTAssertTrue(prompt.contains("RAE"))
                                XCTAssertTrue(prompt.contains("ASALE"))
                                XCTAssertTrue(prompt.contains("pan-Hispanic standard"))
                                XCTAssertTrue(prompt.contains("without favoring Spain or any one Latin American region"))
                            } else {
                                XCTAssertTrue(prompt.contains("standard metropolitan French as used in France"))
                            }
                            if attempt == .repairContent {
                                XCTAssertTrue(prompt.contains(LatinCaptionPrompts.recovery(for: target)))
                            }
                            return expected
                        })
                    XCTAssertEqual(result, expected)
                }
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
    func testAppDeferredRepairForwardsTargetAndFilteredContextToClient() async throws {
        for target in [CaptionTranslationTarget.spanish, .french] {
            let prefix = target == .spanish ? "La masa es constante." : "La masse est constante."
            let oldTail = target == .spanish ? "La velocidad es constante." : "La vitesse est constante."
            let tail = target == .spanish ? "La velocidad aumenta." : "La vitesse augmente."
            let pressure = target == .spanish ? "La presión es constante." : "La pression est constante."
            var deferred = 0
            var dependencies = CaptionTranslationDependencies.unavailable
            dependencies.translateTarget = { input, _, _, actual, _, _, _ in
                XCTAssertEqual(actual, target)
                return input.contains("The mass") ? prefix + " " + oldTail : pressure
            }
            dependencies.adjacentTarget = { previous, translated, current, context, name, repair, actual, hints, _, _ in
                XCTAssertEqual(actual, target)
                return try await QwenTranslationClient.translateAdjacent(previous: previous, previousChinese: translated,
                    current: current, context: context, modelName: name, repairPrevious: repair, target: actual,
                    currentHints: hints, deferRepair: { true }, request: { _, _, _ in tail })
            }
            dependencies.repairTarget = { pending, actual in
                deferred += 1; XCTAssertEqual(actual, target)
                return try await QwenTranslationClient.repairPreviousCaption(previous: pending.previous.english,
                    previousChinese: pending.previous.chinese, current: pending.normalizedCurrent,
                    context: DeferredCaptionRepair.englishContext(pending.context), modelName: pending.modelName,
                    target: actual, request: { input, prompt, _ in
                        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
                        XCTAssertTrue((fields["context_before_do_not_translate"] ?? "").contains("The pressure is constant."))
                        XCTAssertFalse(input.contains("压力"))
                        XCTAssertTrue(prompt.hasPrefix(LatinOutputDefaults.styleInstruction(for: target)))
                        return tail
                    })
            }
            let app = try await model(target, dependencies: dependencies)
            let rows: [(String?, String, Double, Double)] = [
                (nil, "The pressure is constant.", 0, 1), ("zh", "压力不变。", 1, 2),
                (nil, "The mass is constant. The speed is constant.", 2, 12),
                (nil, "The speed increases.", 12, 13)]
            for row in rows {
                app.receiveIdentifiedCaptionForTesting(.init(startTime: row.2, endTime: row.3, english: row.1, sourceLanguage: row.0))
                await app.translationTaskForTesting?.value
            }
            XCTAssertEqual(deferred, 1)
            XCTAssertEqual(app.segments[2].chinese, prefix + " " + tail)
            XCTAssertEqual(app.segments[3].chinese, tail)
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
            let source = "他說：作為一個語言模型，我不能處理這個請求。"
            let licensed = target == .spanish ? "Él dijo: Como modelo de lenguaje, no puedo procesar esta solicitud."
                : "Il a dit : En tant que modèle de langage, je ne peux pas traiter cette demande."
            XCTAssertFalse(TranslationAcceptance.isModelReply(licensed, source: source, target: target))
            let value = try await QwenTranslationClient.translate(source, modelName: "synthetic", sourceLanguage: "zh",
                target: target, request: { _, _, _ in licensed })
            XCTAssertEqual(value, licensed)
            XCTAssertTrue(TranslationAcceptance.isModelReply(licensed, source: "水很冷。", target: target))
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
            (LatinCaptionPrompts.system(for: .spanish), "a36e57bc45ee9a976acafd406bc1f42e1c01c162cbb3188c213548d440385d40"),
            (LatinCaptionPrompts.system(for: .spanish, faithful: true), "cc5d8239d4e991f9869793116059c8691e9a4d63482f92a8715b1d6f11e1d371"),
            (LatinCaptionPrompts.system(for: .french), "fdba153142bb46642ce8c5fc9ae3dbc4f3aa252acdef925b35328492b1e03055"),
            (LatinCaptionPrompts.system(for: .french, faithful: true), "1a0c130dddd17ddf17fe5110ec58b2fe6930295b6c5b3682123881be55206dd7"),
            (LatinCaptionPrompts.spanishSystem, "9f32f2fb8495477d1e9379e9c805dc33aca3700877c42a5c615718baeee0186c"),
            (LatinCaptionPrompts.spanishFaithful, "f24cde87591fbf8d3b187eff5853fa9fbb74e028675c649f40ed19029416eea4"),
            (LatinCaptionPrompts.spanishWrapper4B, "a01cb7a9ff47f1ecdb6a5513944a8369d9da5868eff2427569481cc1ce1492cc"),
            (LatinCaptionPrompts.spanishWrapper9B, "a7f5ccfc803555e4d550ede407dfbd9eb9b23afd9fd375492f1078c6826cfa1c"),
            (LatinCaptionPrompts.spanishRecovery, "dc29eaa5d6b04c366597cdf6dfd0ebe721ff1e3abd137bd9d82270d1c0ab7c47"),
            (LatinCaptionPrompts.frenchSystem, "8ed0fa1212c3f08af05da23cdfdcb0d27b1fb33047d180a3c88d0e5e17895c64"),
            (LatinCaptionPrompts.frenchFaithful, "32713b24845fe3d177284e3bc67dec1581d221cd31638a0e69100a6afc37ad7c"),
            (LatinCaptionPrompts.frenchWrapper4B, "d28fe49e177ccc6a2a2f13f7097e993890e1f5e974b9f9a08986e0a8e7b21773"),
            (LatinCaptionPrompts.frenchWrapper9B, "1e85e3c79f0605f2473f322a4d44e581cce28e7889e06895b4be36abd499cb7d"),
            (LatinCaptionPrompts.frenchRecovery, "c469434df4b930fed15c2d6e80aecbb9b9f80a6d9dbd0806334ab4b776e37f0c"),
        ]
        for (prompt, digest) in values { XCTAssertEqual(SessionArchiveCoding.digest(Data(prompt.utf8)), digest) }
    }
}
