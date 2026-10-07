import Darwin
import Foundation
import XCTest
@testable import LiveLingo

/// New step-22 tests. No old test is edited; all generation is substituted.
@MainActor
final class EnglishLearningNotesTests: XCTestCase {
    func testDefaultReviewClientForwardsEnglishPromptAndNonemptyResumePrefixToWorker() async throws {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("DefaultEnglishReview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try await installDefaultReviewWorker(in: root)
        var book = LearningNotebook(target: .english)
        try book.append(evidence: [foreign()], note: note())
        let course = root.appendingPathComponent("course")
        var snapshot = SessionSnapshot(segments: book.batches.flatMap(\.evidence), targetLocale: "en")
        book.writeState(to: &snapshot)
        try SessionStore(directory: course).save(snapshot)
        let journal = root.appendingPathComponent("queue.json")
        // No injected Generator: exercise the default Qwen client and its
        // streaming adapter. Only the subprocess at the very end is a double.
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled)
        addTeardownBlock { await queue.shutdownForTesting() }
        queue.allowUnreleasedTargetsForTesting()
        try queue.enqueue(directory: course, notebook: book, targetLocale: "en")
        let prefix = "Checking the frozen water evidence.\n"
        for _ in 0..<200 where queue.journalForTesting.jobs.first?.prefix != prefix {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queue.journalForTesting.jobs.first?.prefix, prefix)
        await queue.pauseAndWait()
        let paused = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        let job = try XCTUnwrap(paused.jobs.first)
        XCTAssertTrue(paused.userPaused)
        XCTAssertEqual(job.prefix, prefix)
        XCTAssertEqual(job.next, 0)
        XCTAssertEqual(job.prompt, LearningPrompts.reviewEnglish)
        XCTAssertEqual(job.prefixInputDigest, LearningReviewQueue.prefixDigest(for: job))
        let prepared = try LearningReviewQueue.prepareInput(job, allowUnreleased: true)
        XCTAssertEqual(prepared.input.catalog.keys.sorted(), ["e0.en.0"])
        XCTAssertFalse(prepared.input.json.contains("水会流动"))
        queue.startAwaitingJob()
        for _ in 0..<200 where queue.hasWork { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.hasWork, queue.status)
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        XCTAssertEqual(requests.count, 2, "Observe an initial request and a real resumed request")
        for request in requests {
            XCTAssertEqual(request["system"] as? String, LearningPrompts.reviewEnglish)
            XCTAssertEqual(request["input"] as? String, prepared.input.json)
            XCTAssertEqual(request["purpose"] as? String, "review")
            XCTAssertEqual(request["thinking"] as? Bool, true)
            XCTAssertEqual(request["prompt"] as? String,
                "<|im_start|>system\n" + LearningPrompts.reviewEnglish + "<|im_end|>\n"
                + "<|im_start|>user\n" + prepared.input.json + "<|im_end|>\n<|im_start|>assistant\n<think>\n")
        }
        XCTAssertEqual(requests.first?["prefix"] as? String, "")
        XCTAssertEqual(requests.last?["prefix"] as? String, prefix)
        let completed = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertTrue(completed.jobs.isEmpty, "Completed jobs must leave the active queue")
        XCTAssertNotEqual(requests.first?["id"] as? String, requests.last?["id"] as? String)
        let report = try XCTUnwrap(ReviewReportCollection.read(in: course).first)
        XCTAssertEqual(report.jobID, job.id)
        XCTAssertEqual(report.identity, job.identity)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.total, 1)
        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.appendingPathComponent("summary-review.md").path))
        XCTAssertFalse(OutputLanguage.english.isReleased)
    }

    private func installDefaultReviewWorker(in root: URL) async throws {
        let workers = await MLXRuntime.shared.resourceStates()
        XCTAssertTrue(workers.isEmpty, "The test must own an isolated worker lifecycle")
        let script = root.appendingPathComponent("worker.py")
        try Self.defaultReviewWorker.write(to: script, atomically: true, encoding: .utf8)
        let models = root.appendingPathComponent("models")
        let model = models.appendingPathComponent("lmstudio-community/Qwen3.5-9B-MLX-4bit")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json"] { try Data("{}".utf8).write(to: model.appendingPathComponent(name)) }
        let environment = [
            "LIVELINGO_MLX_PYTHON": "/usr/bin/python3",
            "LIVELINGO_MLX_WORKER": script.path,
            "LIVELINGO_MLX_MODELS": models.path,
            "LIVELINGO_MLX_STATE": root.appendingPathComponent("state").path
        ]
        var previous: [String: String?] = [:]
        for (key, value) in environment {
            previous[key] = .some(ProcessInfo.processInfo.environment[key])
            setenv(key, value, 1)
        }
        let restore = previous
        addTeardownBlock {
            await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel)
            for (key, value) in restore {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
    }

    // Standard-library-only protocol double: no MLX import, weights, GPU or HTTP.
    private static let defaultReviewWorker = #"""
    import argparse, json, pathlib, sys
    parser = argparse.ArgumentParser()
    parser.add_argument('--model')
    parser.add_argument('--state-directory')
    args = parser.parse_args()
    root = pathlib.Path(__file__).parent
    def emit(event):
        print(json.dumps(event, ensure_ascii=False), flush=True)
    emit({'event': 'ready', 'version': 2})
    for line in sys.stdin:
        command = json.loads(line)
        op = command['op']
        if op == 'generate':
            system = command['prompt'].split('<|im_start|>system\n', 1)[1].split('<|im_end|>', 1)[0]
            with (root / 'requests.jsonl').open('a') as output:
                output.write(json.dumps(dict(command, system=system), ensure_ascii=False) + '\n')
            if not command['prefix']:
                emit({'event': 'token', 'id': command['id'], 'wire': 'Checking the frozen water evidence.\n'})
            else:
                text = '{"reviewVersion":2,"corrections":[],"additions":[]}'
                wire = command['prefix'] + 'No corrections are needed.\n</think>\n' + text
                emit({'event': 'done', 'id': command['id'], 'wire': wire, 'text': text})
        else:
            emit({'event': 'paused' if op == 'pause' else op, 'controlID': command['controlID'], 'state': 'saved'})
            if op == 'shutdown':
                break
    """#

    private typealias ObserveReview = @MainActor @Sendable (String, String, String?) throws -> Void
    private func observingGenerator(_ observe: @escaping ObserveReview) -> LearningReviewQueue.Generator {
        { input, prefix, prompt, _, _ in
            try observe(input, prefix, prompt)
            return #"{"reviewVersion":2,"corrections":[],"additions":[]}"#
        }
    }

    func testReviewQueueForwardsFrozenEnglishPromptInputAndPrefixToGenerator() async throws {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("EnglishReviewForwarding-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook(target: .english)
        try book.append(evidence: [foreign()], note: note())
        var snapshot = SessionSnapshot(segments: book.batches.flatMap(\.evidence), targetLocale: "en")
        book.writeState(to: &snapshot)
        try SessionStore(directory: root).save(snapshot)
        let journal = root.appendingPathComponent("queue.json")
        var calls = 0
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled,
            generate: observingGenerator { input, prefix, prompt in
                calls += 1
                XCTAssertEqual(prompt, LearningPrompts.reviewEnglish)
                let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
                let job = try XCTUnwrap(saved.jobs.first)
                XCTAssertEqual(job.prompt, LearningPrompts.reviewEnglish)
                XCTAssertEqual(job.prefix, prefix)
                let inputDigest = LearningReviewQueue.prefixDigest(json: input,
                    prompt: LearningPrompts.reviewEnglish, targetLocale: "en")
                let identity = try XCTUnwrap(job.identity)
                XCTAssertEqual(job.prefixInputDigest, ReviewInputBinding.digest(
                    Data((identity.key + "\n" + (job.inputDigest ?? "") + "\n" + inputDigest).utf8)))
                let prepared = try LearningReviewQueue.prepareInput(job, allowUnreleased: true)
                XCTAssertEqual(input, prepared.input.json)
                XCTAssertEqual(prepared.input.catalog.keys.sorted(), ["e0.en.0"])
                XCTAssertFalse(input.contains("水会流动"))
            })
        addTeardownBlock { await queue.shutdownForTesting(); try FileManager.default.removeItem(at: root) }
        queue.allowUnreleasedTargetsForTesting()
        try queue.enqueue(directory: root, notebook: book, targetLocale: "en")
        for _ in 0..<100 where queue.hasWork { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(queue.hasWork)
        XCTAssertFalse(OutputLanguage.english.isReleased)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("summary-review.md").path))
    }

    private func foreign(_ caption: String = "Water flows.", at time: Double = 0) -> TranscriptSegment {
        TranscriptSegment(startTime: time, endTime: time + 1,
            english: "水会流动。", chinese: caption, sourceLanguage: "zh")
    }

    private func note(_ text: String = "Water flows.", ids: [String] = ["en0s0"],
                      kind: String = "核心结论", question: String? = nil) -> LearningNote {
        LearningNote(topic: "Water", points: [.init(kind: kind, text: text,
            needsContext: question, sourceIDs: ids)], sourceVersion: 2, noNewKnowledge: false)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testEnglishBindingUsesEnglishIDsAndRejectsHansAndHistoricalIDs() throws {
        let evidence = [foreign()]
        let bound = note().binding(evidence: evidence, target: .english)
        XCTAssertEqual(bound.points[0].referenceState, .linked)
        XCTAssertEqual(bound.points[0].sources, [.init(index: 0, quote: "Water flows.")])
        XCTAssertEqual(note().binding(evidence: evidence).points[0].referenceState, .unlinked)
        for id in ["zh0s0", "h0", "en8s0"] {
            let rejected = note(ids: [id]).binding(evidence: evidence, target: .english)
            XCTAssertEqual(rejected.points[0].referenceState, .unlinked)
            XCTAssertEqual(rejected.points[0].sources, [])
        }
    }

    func testEnglishGenerationInputDecodeAndMissingFollowUpAreCallable() throws {
        var book = LearningNotebook(target: .english)
        try book.append(evidence: [foreign()], note: note(kind: "待确认", question: "Which object flows?"))
        let current = [foreign("Aurora contains flowing water.", at: 3)]
        let offered = book.selectPendingPoints(for: current)
        let input = try object(LearningPrompts.input(evidence: current, topics: book.topics,
                                                   pending: offered, target: .english))
        let evidence = try XCTUnwrap(input["evidence"] as? [[String: Any]])
        XCTAssertEqual(evidence.first?["language"] as? String, "en")
        XCTAssertEqual(evidence.first?["id"] as? String, "en0s0")
        let response = #"{"sourceVersion":2,"topic":"Flowing water","points":[{"kind":"核心结论","text":"Aurora contains flowing water.","sourceIDs":["en0s0"],"needsContext":null}],"followUps":{},"noNewKnowledge":false}"#
        let generated = try LearningNote.decode(response)
        let resolved = LearningPrompts.resolvingFollowUps(generated, targets: offered.map(\.id), target: .english)
        XCTAssertEqual(resolved.followUps?.first?.state, .missing)
        XCTAssertEqual(resolved.followUps?.first?.target, offered.first?.id)
        XCTAssertEqual(resolved.followUps?.first?.detail, "本次响应没有给出这条跟进判断，旧问题仍然保留。")
        XCTAssertEqual(resolved.binding(evidence: current, target: .english).points.first?.referenceState, .linked)
        try book.append(evidence: current, note: resolved)
        XCTAssertEqual(book.batches.count, 2)
        XCTAssertEqual(book.pendingPoints.count, 1, "A missing follow-up cannot retire an old question")
    }

    func testEnglishSourcePassThroughIgnoresStaleHansCounterpart() throws {
        let source = TranscriptSegment(startTime: 0, endTime: 1,
            english: "Water flows.", chinese: "旧中文译文。", sourceLanguage: "en")
        let units = LearningSourceUnit.make([source], target: .english)
        XCTAssertEqual(units.map(\.id), ["en0s0"])
        XCTAssertEqual(units.map(\.text), ["Water flows."])
        XCTAssertEqual(note().binding(evidence: [source], target: .english).points[0].referenceState, .linked)
        let prepared = try LearningPrompts.reviewInput(.init(id: UUID(), evidence: [source], note: note()), target: .english)
        XCTAssertEqual(prepared.catalog.keys.sorted(), ["e0.en.0"])
        XCTAssertEqual(prepared.catalog["e0.en.0"]?.text, "Water flows.")
    }

    func testEnglishFollowUpStateLabelsReachNotebookAndExportRendering() throws {
        for state in [LearningFollowUp.State.supplemented, .conflict, .unclear] {
            var book = LearningNotebook(target: .english)
            try book.append(evidence: [foreign("A pressure reading was taken.")],
                note: note("A pressure reading has no identified owner.", kind: "待确认", question: "Which tank?"))
            let original = try encoded(book.batches[0])
            let target = try XCTUnwrap(book.pendingPoints.first?.id)
            var later = note("The earlier reading belongs to Aurora.")
            later.followUps = [.init(target: target, state: state, sourceIDs: ["en0s0"],
                pointIndex: state == .supplemented ? 0 : nil,
                detail: "The later source identifies the tank.")]
            try book.append(evidence: [foreign("The earlier reading belongs to Aurora.", at: 3)], note: later)
            XCTAssertEqual(try encoded(book.batches[0]), original)
            XCTAssertTrue(book.markdown().contains(state.label(target: .english)), state.rawValue)
            let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("EnglishFollowUpExport-\(UUID())")
            try SessionExporter.export(segments: book.batches.flatMap(\.evidence),
                sessionDirectory: root, summary: book.markdown(), target: .english)
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
            let exported = try String(contentsOf: root.appendingPathComponent("summary-en.md"), encoding: .utf8)
            XCTAssertTrue(exported.contains(state.label(target: .english)))
            XCTAssertEqual(book.batches[1].followUps?.first?.state, state)
        }
    }

    func testNotebookAppendCommitsEnglishFollowUpAndRetainsOldBytes() throws {
        var book = LearningNotebook(target: .english)
        let first = foreign("A pressure reading was taken.")
        try book.append(evidence: [first], note: note("A pressure reading has no identified owner.",
            kind: "待确认", question: "Which tank owns the reading?"))
        let original = try encoded(book.batches[0])
        let pending = try XCTUnwrap(book.pendingPoints.first?.id)
        var later = note("The earlier reading belongs to Aurora.")
        later.followUps = [.init(alias: "q0", state: .supplemented,
            sourceIDs: ["en0s0"], detail: "The later source identifies Aurora as the owner.")]
        let resolved = LearningPrompts.resolvingFollowUps(later, targets: [pending], target: .english)
        try book.append(evidence: [foreign("The earlier reading belongs to Aurora.", at: 3)], note: resolved)
        XCTAssertEqual(try encoded(book.batches[0]), original)
        XCTAssertEqual(book.batches[1].followUps?.first?.state, .supplemented)
        XCTAssertEqual(book.batches[1].followUps?.first?.sourceIDs, ["en0s0"])
        XCTAssertEqual(book.batches[1].followUps?.first?.pointIndex, 0)
        XCTAssertEqual(book.batches[1].followUps?.first?.notebookRevision, 1)
        XCTAssertTrue(book.pendingPoints.isEmpty)
        XCTAssertTrue(book.markdown().contains("后文补充"))
        XCTAssertFalse(book.markdown().contains("## 需要回听"))
        let wire = try object(String(decoding: encoded(book.batches[1]), as: UTF8.self))
        let records = try XCTUnwrap(wire["followUps"] as? [[String: Any]])
        XCTAssertEqual(records[0]["state"] as? String, "后文补充")
    }

    func testCommitCannotRetireAQuestionWithForeignOrUnknownIDs() {
        let evidence = [foreign()]
        let linked = note().binding(evidence: evidence, target: .english)
        for id in ["zh0s0", "en8s0", "h0"] {
            let records = LearningNotebook.commit(followUps: [.init(target: "prior:0", state: .supplemented,
                sourceIDs: [id], detail: "A claimed clarification.")], evidence: evidence,
                note: linked, pending: ["prior:0"], revision: 2, target: .english)
            XCTAssertEqual(records.first?.state, .unclear)
            XCTAssertNil(records.first?.pointIndex)
            XCTAssertNil(records.first?.sourceIDs)
        }
    }

    func testPendingContextOriginsAndInputAreEnglishOnly() throws {
        var book = LearningNotebook(target: .english)
        // Legacy-style missing source metadata exercises the context fallback.
        let unresolved = LearningNote(topic: "Water", points: [.init(kind: "待确认",
            text: "An ownership relationship is unclear.", needsContext: "Which object?", referenceState: .pending)])
        try book.append(evidence: [foreign()], note: unresolved)
        let pending = try XCTUnwrap(book.pendingPoints.first)
        XCTAssertEqual(pending.quotes, ["Water flows."])
        XCTAssertEqual(pending.quoteOrigins.flatMap { $0 }.map(\.language), ["en"])
        let input = try LearningPrompts.input(evidence: [foreign("Water freezes.", at: 3)],
            topics: book.topics, pending: [pending], target: .english)
        let root = try object(input)
        let primary = try XCTUnwrap(root["evidence"] as? [[String: Any]])
        XCTAssertEqual(primary.map { $0["id"] as? String }, ["en0s0"])
        XCTAssertEqual(primary.map { $0["language"] as? String }, ["en"])
        let history = try XCTUnwrap(root["priorEvidence"] as? [[String: Any]])
        XCTAssertEqual(history.first?["text"] as? String, "Water flows.")
        let origins = try XCTUnwrap(history.first?["locations"] as? [[String: Any]])
        XCTAssertEqual(origins.first?["language"] as? String, "en")
        let offered = try XCTUnwrap(root["pendingPoints"] as? [[String: Any]])
        XCTAssertEqual(offered.first?["quoteIDs"] as? [String], ["h0"])
        XCTAssertFalse(input.contains("水会流动"))
        XCTAssertTrue((root["pendingEvidenceRule"] as? String)?.contains("Historical h IDs") == true)
    }

    func testRestoredEnglishPendingCannotReuseForeignStoredQuote() throws {
        let evidence = [foreign()]
        let old = LearningNote(topic: "Water", points: [.init(kind: "待确认", text: "A relationship is unclear.",
            sources: [.init(index: 0, quote: "水会流动。")], needsContext: "Which object?", referenceState: .pending)])
        let batch = LearningNoteBatch(id: UUID(), evidence: evidence, note: old)
        let book = try LearningNotebook(snapshot: SessionSnapshot(segments: evidence, batches: [batch], targetLocale: "en"))
        let pending = try XCTUnwrap(book.pendingPoints.first)
        XCTAssertEqual(pending.quotes, ["Water flows."])
        XCTAssertEqual(pending.quoteOrigins.flatMap { $0 }.map(\.language), ["en"])
        let input = try LearningPrompts.input(evidence: [foreign("Water freezes.", at: 3)],
            topics: book.topics, pending: [pending], target: .english)
        XCTAssertFalse(input.contains("水会流动"))
    }

    func testEnglishMarkdownTranslatesLabelsWithoutEditingPayloadOrEnums() throws {
        let payload = "原文 {1} stays as supplied."
        let point = LearningPoint(kind: "例子", text: payload)
        XCTAssertEqual(point.markdown, "- **例子**：" + payload)
        XCTAssertEqual(point.markdown(target: .english), "- **Example**: " + payload)
        XCTAssertEqual(try object(String(decoding: encoded(point), as: UTF8.self))["kind"] as? String, "例子")
        XCTAssertEqual(LearningFollowUp.State.conflict.label(target: .english), "Conflicting accounts")
        XCTAssertEqual(LearningFollowUp.State.conflict.rawValue, "前后冲突")
        let rendered = ClassroomFixedText.sourceLine.noteFormat([payload], target: .english)
        XCTAssertEqual(rendered, "原文：" + payload, "Argument placeholders must not be reprocessed")
        XCTAssertFalse(ClassroomFixedText.usesTargetLanguage)
        XCTAssertEqual(ClassroomFixedText.replayHeading.text(targetCode: "en"), "需要回听")
        XCTAssertEqual(ClassroomFixedText.replayHeading.noteText(target: .english), "需要回听")
        for fixed in [ClassroomFixedText.sourceCheckHeading, .sourceText, .earlierSourceText,
                      .notesHeading, .logisticsHeading, .sourceUnlinked, .reviewDisclaimer,
                      .reviewWholeScope, .reviewNoSuggestions, .retiredExplanation] {
            XCTAssertEqual(fixed.noteText(target: .english), fixed.text(targetCode: "zh-Hans"))
        }
        XCTAssertEqual(ClassroomFixedText.reviewBatchHeading.noteFormat(["2", "Water"], target: .english), "第 2 批 · Water")
        XCTAssertEqual(LearningPoint(kind: "待确认", text: "Which object?").markdown(target: .english),
                       "- **Needs clarification**: Which object?")
    }

    func testEnglishNotebookKeepsFixedClassroomTextChineseAndUsesEnglishEvidence() throws {
        var book = LearningNotebook(target: .english)
        var invalid = note("A claim needs checking.", ids: ["zh0s0"], kind: "待确认", question: "Which object?")
        invalid.points.append(.init(kind: "例子", text: "An unsupported example.", sourceIDs: ["zh0s0"]))
        try book.append(evidence: [foreign("The assignment is due on Friday.")], note: invalid)
        let rendered = book.markdown()
        XCTAssertTrue(rendered.contains("## 需要回听"))
        XCTAssertTrue(rendered.contains("## 来源检查"))
        XCTAssertTrue(rendered.contains("## 课程安排与待办"))
        XCTAssertFalse(rendered.contains("## Listen again"))
        XCTAssertFalse(rendered.contains("## Source checks"))
        XCTAssertFalse(rendered.contains("## Course arrangements and tasks"))
        XCTAssertTrue(rendered.contains("The assignment is due on Friday."))
        XCTAssertFalse(rendered.contains("水会流动"))
        XCTAssertTrue(rendered.contains("**Example**"))
    }

    func testNotebookRestoresFixedSnapshotTargetAndWriteStateDoesNotStampTarget() throws {
        let frozen = SessionSnapshot(targetLocale: "en")
        let restored = try LearningNotebook(snapshot: frozen)
        XCTAssertEqual(restored.target, .english)
        var hans = SessionSnapshot()
        let original = try encoded(hans)
        LearningNotebook(target: .english).writeState(to: &hans)
        XCTAssertNil(hans.targetLocale)
        XCTAssertEqual(try encoded(hans), original)
        var english = frozen
        LearningNotebook().writeState(to: &english)
        XCTAssertEqual(english.targetLocale, "en")
        XCTAssertEqual(try encoded(english), try encoded(frozen))
    }

    func testPreparationAndWorkerReviewCatalogUseEnglishPromptAndEnglishOnlyEvidence() throws {
        let evidence = [foreign()]
        let batch = LearningNoteBatch(id: UUID(), evidence: evidence,
            note: note().binding(evidence: evidence, target: .english))
        XCTAssertNil(LearningReviewQueue.reviewPrompt(for: "en"))
        XCTAssertThrowsError(try LearningReviewQueue.prepareInput(batch, targetLocale: "en"))
        let request = try LearningReviewQueue.prepareInput(batch, targetLocale: "en", allowUnreleased: true)
        XCTAssertEqual(request.prompt, LearningPrompts.reviewEnglish)
        XCTAssertEqual(request.input.catalog.keys.sorted(), ["e0.en.0"])
        XCTAssertEqual(request.input.catalog["e0.en.0"]?.text, "Water flows.")
        XCTAssertFalse(request.input.json.contains("水会流动"))
        let response = #"{"reviewVersion":2,"corrections":[],"additions":[{"evidenceIndex":0,"quoteID":"e0.en.0","kind":"例子","text":"Water can flow.","reason":"This source claim is useful."}]}"#
        let decoded = try LearningReview.decode(response: response, catalog: request.input.catalog)
        XCTAssertNoThrow(try decoded.validateAdditions(evidence: evidence, target: .english))
        XCTAssertEqual(decoded.additions.first?.quote, "Water flows.")
        var forged = decoded
        forged.additions = [.init(evidenceIndex: 0, quoteID: nil, quote: "水会流动。",
            kind: "例子", text: "A forged source.", reason: "Not in the English evidence.")]
        XCTAssertThrowsError(try forged.validateAdditions(evidence: evidence, target: .english))
        XCTAssertEqual(request.prefixInputDigest, LearningReviewQueue.prefixDigest(
            json: request.input.json, prompt: LearningPrompts.reviewEnglish, targetLocale: "en"))
        XCTAssertNotEqual(request.prefixInputDigest, LearningReviewQueue.prefixDigest(
            json: request.input.json, prompt: LearningPrompts.review, targetLocale: "en"))
        let directory = URL(fileURLWithPath: "/synthetic-english-course")
        XCTAssertThrowsError(try LearningReviewQueue.prepareJob(directory: directory, batches: [batch],
            original: "Frozen English notes.", targetLocale: "en"))
        var job = try LearningReviewQueue.prepareJob(directory: directory, batches: [batch],
            original: "Frozen English notes.", targetLocale: "en", allowUnreleased: true)
        XCTAssertEqual(job.targetLocale, "en")
        XCTAssertEqual(job.prompt, LearningPrompts.reviewEnglish)
        XCTAssertEqual(job.prefix, "")
        let jobRequest = try LearningReviewQueue.prepareInput(job, allowUnreleased: true)
        XCTAssertEqual(jobRequest.input.json, request.input.json)
        XCTAssertEqual(job.prefixInputDigest, jobRequest.prefixInputDigest)
        let report = LearningReviewQueue.reportMarkdown(for: job)
        XCTAssertTrue(report.contains("以下是模型复查意见，仅供核对，可能有误；没有修改笔记正文。"))
        XCTAssertTrue(report.contains("# 9B 思考复查 0/1 批（约 5 分钟/批）"))
        XCTAssertFalse(report.contains("These model review suggestions"))
        job.prompt = "Unknown frozen custom prompt."
        job.prefix = "Unknown frozen prefix."
        XCTAssertThrowsError(try LearningReviewQueue.prepareInput(job, allowUnreleased: true))
        XCTAssertEqual(job.prompt, "Unknown frozen custom prompt.")
        XCTAssertEqual(job.prefix, "Unknown frozen prefix.")
    }

    func testGenerationRecoveryIsForFreshSmallerEnglishInputOnly() {
        XCTAssertEqual(LearningPrompts.generationPrompt(target: .english), LearningPrompts.generateEnglish)
        XCTAssertEqual(LearningPrompts.generationPrompt(target: .english, recoveringAfterOutputLimit: true), LearningPrompts.recoveryEnglish)
        XCTAssertEqual(LearningPrompts.generationPrompt(target: .simplifiedChinese, recoveringAfterOutputLimit: true), LearningPrompts.generate)
        XCTAssertTrue(LearningPrompts.recoveryEnglish.contains("smaller batch after an output limit"))
        XCTAssertNotEqual(LearningPrompts.generateEnglish, LearningPrompts.generate)
        XCTAssertNotEqual(LearningPrompts.reviewEnglish, LearningPrompts.review)
    }

    func testFrozenEnglishPromptDigests() {
        XCTAssertEqual(SessionArchiveCoding.digest(Data(LearningPrompts.generateEnglish.utf8)),
            "9ede004793676b8bb62f63b9f6803701196a8113fba38b4f46321cc7cfc3d20a")
        XCTAssertEqual(SessionArchiveCoding.digest(Data(LearningPrompts.reviewEnglish.utf8)),
            "3a5190736db9b5130f41bf7a8877162f8a8fe3187c3ffbddc67802ba4391683b")
        XCTAssertEqual(SessionArchiveCoding.digest(Data(LearningPrompts.recoveryEnglish.utf8)),
            "abc7beb55c1fafe3ba93acbe5a54f04434f2f0bd728b54b6b90101232076c56a")
    }

    func testEnglishRecoveryCheckpointRestoresOnlyKnownFrozenPrompt() throws {
        let evidence = [foreign()]
        let snapshot = SessionSnapshot(segments: evidence, targetLocale: "en")
        let input = try LearningPrompts.input(evidence: evidence, topics: [], target: .english)
        func checkpoint(_ prompt: String) -> SessionGenerationCheckpoint {
            LearningDraft(evidence: evidence, model: "proposal-stub", input: input, target: .english,
                systemPrompt: prompt, text: "Frozen unfinished JSON.", attempts: 2)
                .checkpoint(sessionID: snapshot.sessionID, inputRevision: snapshot.inputRevision, generation: snapshot.generation)
        }
        let recovery = checkpoint(LearningPrompts.recoveryEnglish)
        let restored = try XCTUnwrap(LearningDraft(checkpoint: recovery, snapshot: snapshot, model: "proposal-stub"))
        XCTAssertEqual(restored.target, .english)
        XCTAssertEqual(restored.systemPrompt, LearningPrompts.recoveryEnglish)
        XCTAssertEqual(restored.text, "Frozen unfinished JSON.")
        XCTAssertEqual(restored.attempts, 2)
        XCTAssertNil(LearningDraft(checkpoint: recovery, snapshot: snapshot, model: "proposal-stub", systemPrompt: LearningPrompts.generateEnglish))
        XCTAssertEqual(LearningDraft(checkpoint: checkpoint(LearningPrompts.generateEnglish),
            snapshot: snapshot, model: "proposal-stub")?.systemPrompt, LearningPrompts.generateEnglish)
        XCTAssertNil(LearningDraft(checkpoint: checkpoint("Unknown custom prompt."), snapshot: snapshot, model: "proposal-stub"))
        let hansSnapshot = SessionSnapshot(segments: evidence)
        XCTAssertNil(LearningDraft(checkpoint: recovery, snapshot: hansSnapshot, model: "proposal-stub"))
        let hansDraft = LearningDraft(evidence: evidence, model: "proposal-stub", input: input,
            systemPrompt: LearningPrompts.generate, text: "旧前缀")
        let hansCheckpoint = hansDraft.checkpoint(sessionID: hansSnapshot.sessionID,
            inputRevision: hansSnapshot.inputRevision, generation: hansSnapshot.generation)
        XCTAssertNil(hansCheckpoint.targetLocale)
        XCTAssertEqual(LearningDraft(checkpoint: hansCheckpoint, snapshot: hansSnapshot, model: "proposal-stub")?.systemPrompt,
                       LearningPrompts.generate)
        for locale in ["zh-Hant-TW", "zh-Hant-HK"] {
            var traditional = hansSnapshot
            traditional.targetLocale = locale
            XCTAssertEqual(LearningDraft(checkpoint: hansCheckpoint, snapshot: traditional,
                model: "proposal-stub")?.systemPrompt, LearningPrompts.generate,
                "Traditional courses retain the shared historical generator")
        }
    }

    func testUnknownCustomPromptAndUnreleasedEnglishJournalKeepFrozenPrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EnglishNotesProposal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for locale in ["zh-Hans", "en"] {
            let directory = root.appendingPathComponent(locale)
            let source = foreign()
            let target: CaptionTranslationTarget = locale == "en" ? .english : .simplifiedChinese
            let batch = LearningNoteBatch(id: UUID(), evidence: [source], note: note().binding(evidence: [source], target: target))
            let snapshot = try SessionStore(directory: directory).save(SessionSnapshot(segments: [source],
                batches: [batch], createdAt: Date(timeIntervalSince1970: 1000), targetLocale: locale == "en" ? locale : nil))
            let job = LearningReviewQueue.Job(directory: directory, batches: [batch], original: "Frozen original notes.",
                prefix: "Frozen unfinished prefix.", prompt: "Unknown custom prompt.", targetLocale: locale == "en" ? locale : nil,
                prefixInputDigest: "Frozen custom binding.", awaitingManualStart: true,
                identity: try ReviewIdentity(sessionID: snapshot.sessionID, scope: .wholeLesson, inputRevision: 0),
                inputDigest: try ReviewInputBinding.digest([batch]))
            let journal = LearningReviewQueue.Journal(jobs: [job], userPaused: true, version: 3)
            let url = root.appendingPathComponent(locale + ".json")
            try encoded(journal).write(to: url)
            let queue = LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
                generate: { _, _, _, _, _ in XCTFail("Unrecognized/unreleased tasks cannot generate"); throw CancellationError() })
            await queue.shutdownForTesting()
            let kept = try XCTUnwrap(queue.journalForTesting.jobs.first)
            XCTAssertEqual(kept.prompt, job.prompt)
            XCTAssertEqual(kept.prefix, job.prefix)
            XCTAssertEqual(kept.prefixInputDigest, job.prefixInputDigest)
            XCTAssertEqual(kept.next, job.next)
            XCTAssertEqual(kept.reports, job.reports)
            XCTAssertNotNil(kept.failure)
            XCTAssertFalse(queue.running)
        }
    }

    func testFrozenHansPromptAndWireCodeDigestsRemainUnchanged() {
        XCTAssertEqual(SessionArchiveCoding.digest(Data(LearningPrompts.generate.utf8)),
            "b7429da5ca0fff3d4817ffaefcc05991186f90026a567d42c7092ec91cfb5d38")
        XCTAssertEqual(SessionArchiveCoding.digest(Data(LearningPrompts.review.utf8)),
            "ab5bce580c7f4ba53cb7ac419e51dbfdcf1517315e0869cc16272ae8fd916fcd")
        XCTAssertEqual(LearningPoint.kinds, ["核心结论", "概念关系", "例子", "易错点", "补充理解", "待确认"])
        XCTAssertEqual(LearningFollowUp.State.allCases.map(\.rawValue), ["缺信息", "后文补充", "前后冲突", "关系不明"])
    }
}
