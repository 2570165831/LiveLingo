import Darwin
import Foundation
import XCTest
@testable import LiveLingo

/// Authored lecture text and deterministic request doubles only. No audio or
/// model weights are used. Expected bytes were captured on 1a59adc40a0b5753487b6e4f7909ce73f4f61656.
@MainActor
final class DefaultTargetGoldenTests: XCTestCase {
    struct Request: Codable, Equatable, Sendable {
        let route: String
        let purpose: String
        let model: String
        let systemSHA256: String
        let inputSHA256: String
        let outputBudget: Int
        let thinking: Bool
        var thinkingBudget: Int? = nil
        var completionSHA256: String? = nil
    }

    struct File: Codable, Equatable {
        let text: String
        let sha256: String
        init(_ data: Data) {
            text = String(decoding: data, as: UTF8.self)
            sha256 = SessionArchiveCoding.digest(data)
        }
    }

    struct Golden: Codable, Equatable {
        let baselineRevision: String
        let requests: [Request]
        let captions: [String]
        let files: [String: File]
        let inputFingerprint: String
        let reviewPrefixDigest: String
    }

    private actor Requests {
        private var records: [Request] = []
        func record(route: String, model: String, input: String, prompt: String, budget: Int) {
            records.append(Request(route: route, purpose: "text", model: model,
                systemSHA256: SessionArchiveCoding.digest(Data(prompt.utf8)),
                inputSHA256: SessionArchiveCoding.digest(Data(input.utf8)),
                outputBudget: budget, thinking: false))
        }
        func snapshot() -> [Request] { records }
    }

    private static let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000001000")!
    private static let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000002000")!
    private static let noteResponse = #"{"topic":"合成课堂","sourceVersion":2,"points":[{"kind":"核心结论","text":"加速度为零，但速度不为零。","sourceIDs":["en1s0"]},{"kind":"例子","text":"盒子里有两本书。","sourceIDs":["zh6s0"]}],"noNewKnowledge":false,"followUps":{}}"#
    private static let reviewResponse = #"{"reviewVersion":2,"corrections":[{"index":0,"original":"加速度为零，但速度不为零。","kind":"核心结论","text":"加速度为零，但速度不为零。","reason":"合成复查保持原意。"}],"additions":[]}"#

    private func request(_ recorder: Requests, route: String, model: String,
                         response: String) -> QwenTranslationClient.AdjacentRequest {
        { input, prompt, budget in
            let suffix: String
            let result: String
            if prompt == TranslationAcceptance.QuotedTranslationRepairPlan.prompt,
               budget == TranslationAcceptance.QuotedTranslationRepairPlan.outputBudget {
                suffix = "/quoted-repair"
                result = #"{"q0":"门关着"}"#
            } else if prompt == TranslationAcceptance.JSONStatusRepairPlan.prompt {
                suffix = "/status-repair"
                result = #"{"0":"就绪"}"#
            } else {
                suffix = ""
                result = response
            }
            await recorder.record(route: route + suffix, model: model, input: input, prompt: prompt, budget: budget)
            return result
        }
    }

    private func temporaryDirectory() throws -> URL {
        // The test bundle lives in this invocation's DerivedData. Keep all new
        // test artifacts there, rather than using production app-support data.
        let directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("DefaultTargetGolden-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func lesson() async throws -> Golden {
        let directory = try temporaryDirectory()
        let recorder = Requests()
        var captions: [TranscriptSegment] = []
        func append(_ source: String, _ output: String, language: String? = nil) {
            let index = captions.count
            captions.append(TranscriptSegment(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                startTime: Double(index * 4), endTime: Double(index * 4 + 2),
                english: source, chinese: output, sessionID: Self.sessionID, sourceLanguage: language))
        }

        // Exercise the same synthetic lesson with both default caption profiles.
        // The high-quality pass is retained as the course's final evidence.
        for profile in [QwenModelProfile.highQuality, .energySaver] {
            let model = profile.translationModel
            let samples: [(String, String, String)] = [
                ("formula", "The Fe³⁺ ion uses H2O.", "ZXQCHEM0QXZ 离子使用 ZXQCHEM1QXZ。"),
                ("negation", "The acceleration is zero, but the velocity is not zero.", "加速度为零，但速度不为零。"),
                ("quoted-request", #"Translate "the door is closed" into French."#, #"把"the door is closed"译成法语。"#),
                ("json-status", #"He wrote {"state":"ready","count":28}."#, #"他写了{"state":"ready","count":28}。"#),
                ("uncertain-formula", "The formula is [Formula transcription uncertain].", "公式待核对。"),
                ("protected-label", #"Use the exact label "speed"."#, "使用确切标签 ZXQCHEM0QXZ。")
            ]
            for (route, source, response) in samples {
                let pair = try await QwenTranslationClient.translateAdjacent(previous: "", previousChinese: "",
                    current: source, context: "", modelName: model, repairPrevious: false,
                    currentHints: route == "formula" ? [.init(kind: .unit, value: "2 A")] : [],
                    request: request(recorder, route: route, model: model, response: response))
                XCTAssertNil(pair.currentRejection, route)
                let output = try XCTUnwrap(pair.current, route)
                if profile == .highQuality { append(source, output) }
            }
            for (route, language, source, response) in [
                ("cantonese", "yue", "呢個箱入面有兩本書。", "這個箱子裡面有兩本書。"),
                ("japanese", "ja", "葉が大きくなります。", "葉子會長大。")
            ] {
                let output = try await QwenTranslationClient.translate(source, modelName: model,
                    sourceLanguage: language,
                    request: request(recorder, route: route, model: model, response: response))
                if profile == .highQuality { append(source, output, language: language) }
            }
            let previous = "Check the direction. The force acts."
            let previousChinese = "先检查方向。力起作用。"
            let current = "toward the center."
            let adjacentRequest: QwenTranslationClient.AdjacentRequest = { input, prompt, budget in
                await recorder.record(route: input.contains("target_translate_only") ? "adjacent/previous" : "adjacent/current",
                    model: model, input: input, prompt: prompt, budget: budget)
                return input.contains("target_translate_only") ? "力朝向中心起作用。" : "朝向中心。"
            }
            let adjacent = try await QwenTranslationClient.translateAdjacent(previous: previous,
                previousChinese: previousChinese, current: current, context: "Earlier lecture context.",
                modelName: model, request: adjacentRequest)
            XCTAssertNil(adjacent.previousRejection)
            XCTAssertNil(adjacent.currentRejection)
            if profile == .highQuality {
                append(previous, try XCTUnwrap(adjacent.previous))
                append(current, try XCTUnwrap(adjacent.current))
            }
            let deferred = try await QwenTranslationClient.translateAdjacent(previous: previous,
                previousChinese: previousChinese, current: current, context: "Earlier lecture context.",
                modelName: model, deferRepair: { true },
                request: request(recorder, route: "deferred/current", model: model, response: "朝向中心。"))
            XCTAssertTrue(deferred.previousRepairDeferred)
            XCTAssertNil(deferred.previous)
            let repaired = try await QwenTranslationClient.repairPreviousCaption(previous: previous,
                previousChinese: previousChinese, current: current, context: "Earlier lecture context.",
                modelName: model,
                request: request(recorder, route: "deferred/previous", model: model, response: "力朝向中心起作用。"))
            XCTAssertNil(repaired.rejection)
            XCTAssertEqual(repaired.previous, adjacent.previous)
            for attempt in [CaptionTranslationAttempt.repairContent, .expandedBudget] {
                _ = try await QwenTranslationClient.translate("The current is 2 A.", modelName: model,
                    attempt: attempt, request: request(recorder, route: "retry/\(attempt)", model: model,
                                                      response: "电流为 2 A。"))
            }
        }
        let chineseSource = "這片葉子長大了。"
        append(chineseSource, CaptionTranslationTarget.current.renderPassThrough(chineseSource), language: "zh")

        // Use the real notes/review entry points with a standard-library pipe
        // worker. It captures their actual purpose and budgets without MLX.
        let activeWorkers = await MLXRuntime.shared.resourceStates()
        XCTAssertTrue(activeWorkers.isEmpty, "The golden must own an isolated worker lifecycle")
        let oldEnvironment = try installFakeWorker(in: directory)
        addTeardownBlock {
            await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel)
            await MLXRuntime.shared.unload(QwenModelProfile.energySaver.translationModel)
        }
        defer {
            for (key, value) in oldEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let input = try LearningPrompts.input(evidence: captions, topics: [])
        var note: LearningNote?
        for profile in [QwenModelProfile.highQuality, .energySaver] {
            let response = try await QwenTranslationClient.learningNote(input: input,
                modelName: profile.translationModel, prefix: "", onUpdate: { _ in })
            await MLXRuntime.shared.unload(profile.translationModel)
            var decoded = try LearningNote.decode(response)
            decoded.topic = SimplifiedChineseNormalizer.normalize(decoded.topic)
            for index in decoded.points.indices {
                decoded.points[index].text = SimplifiedChineseNormalizer.normalize(decoded.points[index].text)
            }
            decoded = decoded.binding(evidence: captions)
            if profile == .highQuality { note = decoded } else { XCTAssertEqual(decoded, note) }
        }
        let batch = LearningNoteBatch(id: Self.batchID, evidence: captions, note: try XCTUnwrap(note))
        let snapshot = SessionSnapshot(sessionID: Self.sessionID, segments: captions, batches: [batch],
            notebookRevision: 1, createdAt: Date(timeIntervalSince1970: 0))
        try snapshot.validate()
        let notebook = try LearningNotebook(snapshot: snapshot)
        let prepared = try LearningPrompts.reviewInput(batch)
        let reviewResponse = try await QwenTranslationClient.reviewLearningNote(prepared.json)
        await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel)
        let review = try LearningReview.decode(response: reviewResponse, catalog: prepared.catalog)
        try review.validateAdditions(evidence: captions)
        _ = try review.applying(to: batch.note)

        let wireURL = directory.appendingPathComponent("state/requests.jsonl")
        let wires = try String(contentsOf: wireURL, encoding: .utf8).split(separator: "\n").map { line in
            try JSONDecoder().decode(Request.self, from: Data(line.utf8))
        }
        let summary = notebook.markdown()
        try SessionExporter.export(segments: captions, sessionDirectory: directory,
            summary: summary, createdAt: Date(timeIntervalSince1970: 0))
        var files: [String: File] = [:]
        for name in ["bilingual.jsonl", "bilingual.srt", "transcript-en.txt", "transcript-zh-Hans.txt",
                     "summary-zh-Hans.md", "manifest.json"] {
            files[name] = File(try Data(contentsOf: directory.appendingPathComponent(name)))
        }
        files["snapshot.json"] = File(try SessionArchiveCoding.encode(snapshot))
        files["review-input.json"] = File(Data(prepared.json.utf8))
        files["note-response.json"] = File(Data(Self.noteResponse.utf8))
        files["review-response.json"] = File(Data(reviewResponse.utf8))
        return Golden(baselineRevision: "1a59adc40a0b5753487b6e4f7909ce73f4f61656",
            requests: await recorder.snapshot() + wires, captions: captions.map(\.chinese), files: files,
            inputFingerprint: try snapshot.inputFingerprint(),
            reviewPrefixDigest: LearningReviewQueue.prefixDigest(json: prepared.json, prompt: LearningPrompts.review))
    }

    private func installFakeWorker(in directory: URL) throws -> [String: String?] {
        let script = directory.appendingPathComponent("fake-worker.py")
        try Self.worker.write(to: script, atomically: true, encoding: .utf8)
        let models = directory.appendingPathComponent("models")
        for relative in ["mlx-community/Qwen3.5-4B-MLX-8bit", "lmstudio-community/Qwen3.5-9B-MLX-4bit"] {
            let model = models.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            for name in ["config.json", "tokenizer.json"] {
                try Data("{}".utf8).write(to: model.appendingPathComponent(name))
            }
        }
        try Data(Self.noteResponse.utf8).write(to: directory.appendingPathComponent("note-response.json"))
        try Data(Self.reviewResponse.utf8).write(to: directory.appendingPathComponent("review-response.json"))
        let environment = [
            "LIVELINGO_MLX_PYTHON": URL(fileURLWithPath: "/").appendingPathComponent("usr/bin/python3").path,
            "LIVELINGO_MLX_WORKER": script.path,
            "LIVELINGO_MLX_MODELS": models.path,
            "LIVELINGO_MLX_STATE": directory.appendingPathComponent("state").path
        ]
        var previous: [String: String?] = [:]
        for (key, value) in environment {
            previous[key] = .some(ProcessInfo.processInfo.environment[key])
            setenv(key, value, 1)
        }
        return previous
    }

    func testSyntheticLessonMatchesFrozenDefaultTarget() async throws {
        let actual = try await lesson()
        try assertFrozen(actual, frozenLesson())
    }

    private func frozenLesson() throws -> Golden {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "default-target-golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: fixtureURL))
    }

    private func assertFrozen(_ actual: Golden, _ expected: Golden) throws {
        XCTAssertEqual(actual.baselineRevision, expected.baselineRevision)
        XCTAssertEqual(actual.requests, expected.requests)
        XCTAssertEqual(actual.captions, expected.captions)
        XCTAssertEqual(Set(actual.files.keys), Set(expected.files.keys))
        for name in expected.files.keys.sorted() {
            let file = try XCTUnwrap(actual.files[name], name)
            let frozen = try XCTUnwrap(expected.files[name], name)
            XCTAssertEqual(Data(file.text.utf8), Data(frozen.text.utf8), name)
            XCTAssertEqual(file.sha256, frozen.sha256, name)
        }
        XCTAssertEqual(actual.inputFingerprint, expected.inputFingerprint)
        XCTAssertEqual(actual.reviewPrefixDigest, expected.reviewPrefixDigest)
    }

    private final class GoldenDefaults: UserDefaults, @unchecked Sendable {
        override func string(forKey defaultName: String) -> String? {
            defaultName == "LiveLingo.modelMode" ? "highQuality" : nil
        }
        override func object(forKey defaultName: String) -> Any? { nil }
        override func bool(forKey defaultName: String) -> Bool { false }
        override func set(_ value: Any?, forKey defaultName: String) {
            preconditionFailure("The golden must not persist preferences")
        }
    }

    private static func firstPassResponse(for text: String) throws -> String {
        if text.contains("ion uses") { return "ZXQCHEM0QXZ 离子使用 ZXQCHEM1QXZ。" }
        if text.contains("acceleration") { return "加速度为零，但速度不为零。" }
        if text.contains("into French") { return #"把"the door is closed"译成法语。"# }
        if text.contains("\"state\"") { return #"他写了{"state":"ready","count":28}。"# }
        if text.contains("transcription uncertain") { return "公式待核对。" }
        if text.contains("exact label") { return "使用确切标签 ZXQCHEM0QXZ。" }
        if text.contains("Check the direction") { return "先检查方向。力起作用。" }
        if text == "toward the center." { return "朝向中心。" }
        throw QwenRuntimeError.invalidResponse
    }

    func testAppModelConsumesTheSameSyntheticLessonAndNotes() async throws {
        let expected = try frozenLesson()
        let jsonl = try XCTUnwrap(expected.files["bilingual.jsonl"])
        let sources = try jsonl.text.split(separator: "\n").map {
            try JSONDecoder().decode(TranscriptSegment.self, from: Data($0.utf8))
        }
        let directory = try temporaryDirectory()
        let recorder = Requests()
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in throw CancellationError() }
        await queue.shutdownForTesting()
        let defaults = try XCTUnwrap(GoldenDefaults(suiteName: "DefaultTargetGolden-\(UUID())"))
        var translation = CaptionTranslationDependencies.unavailable
        translation.translate = { text, model, hints, attempt, update in
            try await QwenTranslationClient.translate(text, modelName: model, hints: hints, attempt: attempt,
                onUpdate: update, request: self.request(recorder, route: "app/caption", model: model,
                                                        response: Self.firstPassResponse(for: text)))
        }
        translation.translateSource = { text, model, language, attempt, update in
            let response = language == "yue" ? "這個箱子裡面有兩本書。" : "葉子會長大。"
            return try await QwenTranslationClient.translate(text, modelName: model, sourceLanguage: language,
                attempt: attempt, onUpdate: update,
                request: self.request(recorder, route: "app/\(language)", model: model, response: response))
        }
        translation.adjacent = { previous, translated, current, context, model, repair, hints, update, deferRepair in
            let base = self.request(recorder, route: "app/adjacent", model: model,
                                    response: try Self.firstPassResponse(for: current))
            return try await QwenTranslationClient.translateAdjacent(previous: previous, previousChinese: translated,
                current: current, context: context, modelName: model, repairPrevious: repair, currentHints: hints,
                onCurrent: update, deferRepair: deferRepair, request: { input, prompt, budget in
                    if input.contains("target_translate_only") {
                        await recorder.record(route: "app/repair", model: model, input: input, prompt: prompt, budget: budget)
                        return "力朝向中心起作用。"
                    }
                    return try await base(input, prompt, budget)
                })
        }
        let model = AppModel(reviewQueue: queue, translation: translation,
            notes: .init(generate: { input, model, prefix, update in
                try await QwenTranslationClient.learningNote(input: input, modelName: model,
                                                            prefix: prefix, onUpdate: update)
            }), backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock { await model.resetTranslationSessionForTesting()?.value }
        for source in sources {
            let before = await recorder.snapshot().count
            model.receiveIdentifiedCaptionForTesting(.init(id: source.id, startTime: source.startTime,
                endTime: source.endTime, english: source.english, sourceLanguage: source.sourceLanguage))
            await model.translationTaskForTesting?.value
            if source.sourceLanguage == "zh" {
                let after = await recorder.snapshot().count
                XCTAssertEqual(after, before, "Chinese speech must not issue a model request")
                XCTAssertNil(model.translationTaskForTesting)
                XCTAssertTrue(model.previewTranslationSource.isEmpty)
            }
        }
        XCTAssertEqual(model.segments.map(\.chinese), expected.captions)
        XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
        let previous = try installFakeWorker(in: directory)
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        addTeardownBlock { await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel) }
        await model.generateSummaryForTesting()
        await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel)
        XCTAssertEqual(model.learningNotebookForTesting.batches.count, 1)
        XCTAssertEqual(model.lectureSummary.trimmingCharacters(in: .whitespacesAndNewlines),
                       expected.files["summary-zh-Hans.md"]?.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let wire = try String(contentsOf: directory.appendingPathComponent("state/requests.jsonl"), encoding: .utf8)
        let actualRequest = try JSONDecoder().decode(Request.self, from: Data(wire.trimmingCharacters(in: .newlines).utf8))
        let expectedRequest = try XCTUnwrap(expected.requests.first { $0.purpose == "note" && $0.model == "qwen/qwen3.5-9b" })
        XCTAssertEqual(actualRequest, expectedRequest)
    }

    private static let worker = #"""
    import argparse, hashlib, json, pathlib, sys
    parser = argparse.ArgumentParser()
    parser.add_argument('--model')
    parser.add_argument('--state-directory')
    args = parser.parse_args()
    root = pathlib.Path(__file__).parent
    state = pathlib.Path(args.state_directory).parent
    state.mkdir(parents=True, exist_ok=True)
    model = 'qwen3.5-4b-mlx' if pathlib.Path(args.model).name == 'Qwen3.5-4B-MLX-8bit' else 'qwen/qwen3.5-9b'
    def digest(text):
        return hashlib.sha256(text.encode('utf-8')).hexdigest()
    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)
    emit({'event': 'ready', 'version': 2})
    for line in sys.stdin:
        command = json.loads(line)
        op = command['op']
        if op == 'generate':
            system = command['prompt'].split('<|im_start|>system\n', 1)[1].split('<|im_end|>', 1)[0]
            record = {'route': command['purpose'], 'purpose': command['purpose'], 'model': model,
                      'systemSHA256': digest(system), 'inputSHA256': digest(command['input']),
                      'outputBudget': command['finalBudget'], 'thinking': command['thinking'],
                      'thinkingBudget': command['thinkingBudget'], 'completionSHA256': digest(command['prompt'])}
            with (state / 'requests.jsonl').open('a') as output:
                output.write(json.dumps(record, ensure_ascii=False) + '\n')
            text = (root / (command['purpose'] + '-response.json')).read_text()
            wire = 'Synthetic reasoning is complete.\n</think>\n' + text if command['thinking'] else text
            emit({'event': 'done', 'id': command['id'], 'wire': wire, 'text': text})
        else:
            emit({'event': 'paused' if op == 'pause' else op, 'controlID': command['controlID'], 'state': 'saved'})
            if op == 'shutdown':
                break
    """#
}
