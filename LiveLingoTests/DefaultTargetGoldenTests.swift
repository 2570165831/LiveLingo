import Darwin
import Foundation
import XCTest
@testable import LiveLingo

/// Authored lecture text and deterministic request doubles only. No audio or
/// model weights are used. Expected bytes use the unchanged 1a59adc40a0b5753487b6e4f7909ce73f4f61656 pipeline.
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
        let thinkingBudget: Int
        let completionSHA256: String
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
        let appRequests: [Request]
        let captions: [String]
        let englishTraditionalOutputs: [String: String]
        let files: [String: File]
        let inputFingerprint: String
        let reviewPrefixDigest: String
    }

    private static let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000001000")!
    private static let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000002000")!
    private static let noteResponse = #"{"topic":"合成课堂","sourceVersion":2,"points":[{"kind":"核心结论","text":"加速度为零，但速度不为零。","sourceIDs":["en1s0"]},{"kind":"例子","text":"盒子里有两本书。","sourceIDs":["zh6s0"]}],"noNewKnowledge":false,"followUps":{}}"#
    private static let reviewResponse = #"{"reviewVersion":2,"corrections":[{"index":0,"original":"加速度为零，但速度不为零。","kind":"核心结论","text":"加速度为零，但速度不为零。","reason":"合成复查保持原意。"}],"additions":[]}"#

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
        let runtime = try installFakeWorker(in: directory)
        return try await MLXRuntime.$testRuntime.withValue(runtime) {
            try await lesson(in: directory)
        }
    }

    private func lesson(in directory: URL) async throws -> Golden {
        var captions: [TranscriptSegment] = []
        var englishTraditionalOutputs: [String: String] = [:]
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
            let samples: [(String, String)] = [
                ("formula", "The Fe³⁺ ion uses H2O."),
                ("negation", "The acceleration is zero, but the velocity is not zero."),
                ("quoted-request", #"Translate "the door is closed" into French."#),
                ("json-status", #"He wrote {"state":"ready","count":28}."#),
                ("uncertain-formula", "The formula is [Formula transcription uncertain]."),
                ("protected-label", #"Use the exact label "speed"."#)
            ]
            for (route, source) in samples {
                let pair = try await QwenTranslationClient.translateAdjacent(previous: "", previousChinese: "",
                    current: source, context: "", modelName: model, repairPrevious: false,
                    currentHints: route == "formula" ? [.init(kind: .unit, value: "2 A")] : [])
                XCTAssertNil(pair.currentRejection, route)
                let output = try XCTUnwrap(pair.current, route)
                if profile == .highQuality { append(source, output) }
            }
            for (language, source) in [
                ("yue", "呢個箱入面有兩本書。"),
                ("ja", "葉が大きくなります。")
            ] {
                let output = try await QwenTranslationClient.translate(source, modelName: model,
                    sourceLanguage: language)
                if profile == .highQuality { append(source, output, language: language) }
            }
            let previous = "Check the direction. The force acts."
            let previousChinese = "先检查方向。力起作用。"
            let current = "toward the center."
            let adjacent = try await QwenTranslationClient.translateAdjacent(previous: previous,
                previousChinese: previousChinese, current: current, context: "Earlier lecture context.",
                modelName: model)
            XCTAssertNil(adjacent.previousRejection)
            XCTAssertNil(adjacent.currentRejection)
            if profile == .highQuality {
                append(previous, try XCTUnwrap(adjacent.previous))
                append(current, try XCTUnwrap(adjacent.current))
            }
            let deferred = try await QwenTranslationClient.translateAdjacent(previous: previous,
                previousChinese: previousChinese, current: current, context: "Earlier lecture context.",
                modelName: model, deferRepair: { true })
            XCTAssertTrue(deferred.previousRepairDeferred)
            XCTAssertNil(deferred.previous)
            let repaired = try await QwenTranslationClient.repairPreviousCaption(previous: previous,
                previousChinese: previousChinese, current: current, context: "Earlier lecture context.",
                modelName: model)
            XCTAssertNil(repaired.rejection)
            XCTAssertEqual(repaired.previous, adjacent.previous)
            for attempt in [CaptionTranslationAttempt.repairContent, .expandedBudget] {
                _ = try await QwenTranslationClient.translate("The current is 2 A.", modelName: model,
                    attempt: attempt)
            }
            // English deliberately keeps a model's Traditional Chinese spelling
            // in translate(); AppModel's later presentation normalization is separate.
            for language in [nil, "en"] as [String?] {
                englishTraditionalOutputs[model + "/" + (language ?? "implicit-en")] =
                    try await QwenTranslationClient.translate("The temperature is measured in kelvin.",
                        modelName: model, sourceLanguage: language)
            }
            await MLXRuntime.shared.unload(model)
        }
        let chineseSource = "這片葉子長大了。"
        append(chineseSource, CaptionTranslationTarget.simplifiedChinese.renderPassThrough(chineseSource), language: "zh")
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

        let wires = try workerRequests(in: directory)
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
        // Take the report body from the real queue rather than reconstructing
        // its Markdown here. A fixed job freezes the remaining renderer inputs;
        // actual generation timings stay in the queue's own report, not this golden.
        var job = LearningReviewQueue.Job(id: Self.batchID, directory: directory,
            batches: [batch], original: summary)
        job.next = 1
        job.identity = try ReviewIdentity(sessionID: Self.sessionID, scope: .wholeLesson,
            inputRevision: snapshot.inputRevision, notebookRevision: snapshot.notebookRevision)
        job.inputDigest = SessionArchiveCoding.digest(Data(prepared.json.utf8))
        job.reports = [try await reviewReportBody(notebook: notebook, response: reviewResponse,
            input: prepared.json, in: directory)]
        var entry = LearningReviewQueue.reportEntry(for: job)
        entry.updatedAt = Date(timeIntervalSince1970: 0)
        try ReviewReportCollection.save(entry, in: directory)
        files["summary-review.md"] = File(try Data(contentsOf: directory.appendingPathComponent("summary-review.md")))
        files["review-collection.md"] = File(Data(try XCTUnwrap(ReviewReportCollection.markdown(
            in: directory, queueReports: [], sessionID: Self.sessionID)).utf8))
        return Golden(baselineRevision: "1a59adc40a0b5753487b6e4f7909ce73f4f61656",
            requests: wires, appRequests: [], captions: captions.map(\.chinese),
            englishTraditionalOutputs: englishTraditionalOutputs, files: files,
            inputFingerprint: try snapshot.inputFingerprint(),
            reviewPrefixDigest: LearningReviewQueue.prefixDigest(json: prepared.json, prompt: LearningPrompts.review))
    }

    private func reviewReportBody(notebook: LearningNotebook, response: String, input: String,
                                  in directory: URL) async throws -> String {
        let reportDirectory = directory.appendingPathComponent("review-queue", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try (notebook.markdown() + "\n").write(
            to: reportDirectory.appendingPathComponent("summary-zh-Hans.md"), atomically: true, encoding: .utf8)
        let queue = LearningReviewQueue(journalURL: reportDirectory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { actualInput, prefix, _, _, _ in
                XCTAssertEqual(actualInput, input)
                XCTAssertTrue(prefix.isEmpty)
                return response
            }
        addTeardownBlock { await queue.shutdownForTesting() }
        try queue.enqueue(directory: reportDirectory, notebook: notebook)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while queue.hasWork {
            guard ContinuousClock.now < deadline else {
                XCTFail("The synthetic review did not finish")
                throw QwenRuntimeError.invalidResponse
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        let reports = try ReviewReportCollection.read(in: reportDirectory)
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.total, 1)
        let body = try XCTUnwrap(report.markdown.range(of: "## 第 1 批 · "))
        return String(report.markdown[body.lowerBound...])
    }

    private func installFakeWorker(in directory: URL) throws -> MLXRuntime {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python.path),
                          "The synthetic protocol worker requires the system Python interpreter")
        let script = directory.appendingPathComponent("fake-worker.py")
        try Self.worker.write(to: script, atomically: true, encoding: .utf8)
        let models = directory.appendingPathComponent("models")
        let relativeModels = [
            QwenModelProfile.energySaver.translationModel: "mlx-community/Qwen3.5-4B-MLX-8bit",
            QwenModelProfile.highQuality.translationModel: "lmstudio-community/Qwen3.5-9B-MLX-4bit"
        ]
        for relative in relativeModels.values {
            let model = models.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            for name in ["config.json", "tokenizer.json"] {
                try Data("{}".utf8).write(to: model.appendingPathComponent(name))
            }
        }
        try Data(Self.noteResponse.utf8).write(to: directory.appendingPathComponent("note-response.json"))
        try Data(Self.reviewResponse.utf8).write(to: directory.appendingPathComponent("review-response.json"))
        try JSONEncoder().encode(Self.captionResponses).write(to: directory.appendingPathComponent("caption-responses.json"))
        var configuration = MLXRuntime.TestConfiguration(python: python, script: script,
            models: models, state: directory.appendingPathComponent("state/fixture"))
        configuration.modelDirectories = relativeModels.mapValues { models.appendingPathComponent($0) }
        configuration.interpreterArguments = ["-I", "-u"]
        let runtime = MLXRuntime(testConfiguration: configuration)
        addTeardownBlock {
            await runtime.unload(QwenModelProfile.highQuality.translationModel)
            await runtime.unload(QwenModelProfile.energySaver.translationModel)
        }
        return runtime
    }

    func testSyntheticLessonMatchesFrozenDefaultTarget() async throws {
        let actual = try await lesson()
        try assertFrozen(actual, frozenLesson())
    }

    private func workerRequests(in directory: URL) throws -> [Request] {
        let url = directory.appendingPathComponent("state/requests.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(Request.self, from: Data($0.utf8))
        }
    }

    private func frozenLesson() throws -> Golden {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "default-target-golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: fixtureURL))
    }

    private func assertFrozen(_ actual: Golden, _ expected: Golden) throws {
        XCTAssertEqual(actual.baselineRevision, expected.baselineRevision)
        XCTAssertEqual(actual.requests, expected.requests)
        XCTAssertEqual(actual.captions, expected.captions)
        XCTAssertEqual(actual.englishTraditionalOutputs, expected.englishTraditionalOutputs)
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

    private final class GoldenDefaults: TestUserDefaults, @unchecked Sendable {
        override func string(forKey defaultName: String) -> String? {
            defaultName == "LiveLingo.modelMode" ? "highQuality" : nil
        }
        override func object(forKey defaultName: String) -> Any? { nil }
        override func bool(forKey defaultName: String) -> Bool { false }
        override func set(_ value: Any?, forKey defaultName: String) {
            preconditionFailure("The golden must not persist preferences")
        }
    }

    func testAppModelConsumesTheSameSyntheticLessonAndNotes() async throws {
        let expected = try frozenLesson()
        let jsonl = try XCTUnwrap(expected.files["bilingual.jsonl"])
        let sources = try jsonl.text.split(separator: "\n").map {
            try JSONDecoder().decode(TranscriptSegment.self, from: Data($0.utf8))
        }
        let directory = try temporaryDirectory()
        let runtime = try installFakeWorker(in: directory)
        try await MLXRuntime.$testRuntime.withValue(runtime) {
            try await assertAppModelLesson(expected: expected, sources: sources, directory: directory, runtime: runtime)
        }
    }

    private func assertAppModelLesson(expected: Golden, sources: [TranscriptSegment], directory: URL,
                                     runtime: MLXRuntime) async throws {
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in throw CancellationError() }
        await queue.shutdownForTesting()
        let suite = "DefaultTargetGolden-\(UUID())"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(GoldenDefaults(suiteName: suite))
        addTeardownBlock { try preferenceCleanup.remove() }
        // Live adapters include retry and deferred-repair routing. Only the
        // process at the end of that production path is replaced by a double.
        let model = AppModel(reviewQueue: queue, translation: .live, notes: .live,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            await MLXRuntime.$testRuntime.withValue(runtime) {
                await model.resetTranslationSessionForTesting()?.value
            }
        }
        for source in sources {
            let before = try workerRequests(in: directory).count
            model.receiveIdentifiedCaptionForTesting(.init(id: source.id, startTime: source.startTime,
                endTime: source.endTime, english: source.english, sourceLanguage: source.sourceLanguage))
            await model.translationTaskForTesting?.value
            if source.sourceLanguage == "zh" {
                let after = try workerRequests(in: directory).count
                XCTAssertEqual(after, before, "Chinese speech must not issue a model request")
                XCTAssertNil(model.translationTaskForTesting)
                XCTAssertTrue(model.previewTranslationSource.isEmpty)
            }
        }
        XCTAssertEqual(model.segments.map(\.chinese), expected.captions)
        XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
        await model.generateSummaryForTesting()
        await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel)
        XCTAssertEqual(model.learningNotebookForTesting.batches.count, 1)
        XCTAssertEqual(model.lectureSummary.trimmingCharacters(in: .whitespacesAndNewlines),
                       expected.files["summary-zh-Hans.md"]?.text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(try workerRequests(in: directory), expected.appRequests)
    }

    // Literal synthetic replies indexed by the *wire* input's SHA-256, including
    // the 9B formula transport. Unknown inputs fail instead of inventing a reply.
    private static let captionResponses: [String: String] = [
        "01bcfd9ce7a98f86abc82ab2c35df05cc0acb87b27b35b06cd2eab77ce5bd82e": "使用确切标签 ZXQCHEM0QXZ。",
        "02aba4c837a8d9df0c2077cb78e92e9c3d475704c929d52e92c35c4ff0865730": "ZX0QXZ 离子使用 ZX1QXZ。",
        "0e6c35c3986ef79fdfae30a0b46d7ba8dbe6216ee55a09c0cc9d6e67a8c21658": "公式待核对。",
        "1733af63a11b84bee08b33135ec8740a80e34c8d391ca26ebe25e6db5f5a4e61": "溫度以開爾文量測。",
        "2fd887ab8dd580277f6e6e7b56b54a1b620e676118010eedd91e6dae2f95a723": "他写了{\"state\":\"ready\",\"count\":28}。",
        "3450b8ccc050ee51212f2949fa0d3f92dee614247545f57ee0ff7eac62e12737": "{\"q0\":\"门关着\"}",
        "395678177c0cd577a5860c4b1fbb13a0cf77a13e2dd7d7068ee7525f8a0d71c0": "{\"0\":\"就绪\"}",
        "3ede78bfcbbdd3ca576718988a5c4d46379e98170c1e4067c10237a4ce8a4a25": "葉子會長大。",
        "5cf646787030715718dac6ee20cb67c8f98756388aa4966b865a87533239a813": "他写了{\"state\":\"ready\",\"count\":28}。",
        "64b018c488ef5b2b97b17741d7874de7e438428fee8dc3b691305ad91776bdb1": "电流为 2 A。",
        "660320050f65ac2e9a591c5fe6e13f71ec093305acf53e481cb2464ff65d08ae": "這個箱子裡面有兩本書。",
        "6a7050af1565533c33dada4c2ad69c8e48db0d400566340f7fe6f32fe981cfa4": "朝向中心。",
        "754084f195a505fb99550993d27fce17ba35b821d879d6228217b6e8375174c1": "溫度以開爾文量測。",
        "7ad78056db6832a28d83b1a4a9a28c1e38bedfb67e2bf1363c058f1dff34da9d": "加速度为零，但速度不为零。",
        "950e1bab5022eac6839b0618e425281ceacd7292cece6abe0b369bdf97723801": "葉子會長大。",
        "97adae902ce3424885ec4a1ff8aabd9638ab907f02947076bd26b3e13e259987": "把\"the door is closed\"译成法语。",
        "97f40b184b56ddedbb41bec5d2a29cb59fad8f0310377410545f93945f45b196": "ZXQCHEM0QXZ 离子使用 ZXQCHEM1QXZ。",
        "9b4e946e9dc68c50669ebc78c99c7074d0aac0c593f3c4ac9d064cde1907d504": "ZX0QXZ 离子使用 ZX1QXZ。",
        "a443cd87e8aa2ddd2a161896a6d5dd3968cab2882ef0571b7c5751e8fae3ae70": "加速度为零，但速度不为零。",
        "a881c02ac528ce4ef755ca36ecdb30936f44a1534d9c99ec7eb1ec7faa6e3e31": "公式待核对。",
        "b555d03dcc3bbf22dcf4bdef51d5bcb7d30f74ecbe7d92052846660963ebe670": "电流为 2 A。",
        "b68b4df2f723be2c62fae965cb1bd15bee8b9e9461a136ec99263b15230f87d0": "把\"the door is closed\"译成法语。",
        "b8d4e2ac00d0d4d112ecd88d66d71d44ca27070e5579553047171d315f4f2614": "朝向中心。",
        "cd5d578a848b5cf232894b07becef51725bd6b38a254ddc63848c86f6a609b45": "力朝向中心起作用。",
        "d2fc7f67864def46188f0d9f562ed424be41acdab889147fbf2cb234a7ee9da6": "力朝向中心起作用。",
        "d76464a3950d118b4805b07e8eeeb9db0a839973dc7fa20a94c920f42ac2225d": "這個箱子裡面有兩本書。",
        "dc1d6a5383d48fe7fb6b3ccd557cf4c1ae50f8e49b06a00a81066aac699906d2": "先检查方向。力起作用。",
        "e7fab3be02f8b4edd15a23d9ab35d7531c67197914ffa8c7e37292cdf1486671": "使用确切标签 ZX0QXZ。"
    ]

    private static let worker = #"""
    import argparse, hashlib, json, pathlib, sys
    parser = argparse.ArgumentParser()
    parser.add_argument('--model')
    parser.add_argument('--state-directory')
    args = parser.parse_args()
    root = pathlib.Path(__file__).parent
    state = pathlib.Path(args.state_directory).parent
    state.mkdir(parents=True, exist_ok=True)
    model = {'Qwen3.5-4B-MLX-8bit': 'qwen3.5-4b-mlx',
             'Qwen3.5-9B-MLX-4bit': 'qwen/qwen3.5-9b'}[pathlib.Path(args.model).name]
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
            if command['purpose'] == 'text':
                text = json.loads((root / 'caption-responses.json').read_text()).get(record['inputSHA256'])
                if text is None:
                    emit({'event': 'error', 'id': command['id'],
                          'message': 'Unfrozen synthetic caption input: ' + record['inputSHA256']})
                    continue
            else:
                text = (root / (command['purpose'] + '-response.json')).read_text()
            wire = 'Synthetic reasoning is complete.\n</think>\n' + text if command['thinking'] else text
            emit({'event': 'done', 'id': command['id'], 'wire': wire, 'text': text})
        else:
            emit({'event': 'paused' if op == 'pause' else op, 'controlID': command['controlID'], 'state': 'saved'})
            if op == 'shutdown':
                break
    """#
}
