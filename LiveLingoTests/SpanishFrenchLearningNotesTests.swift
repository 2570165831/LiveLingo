import Darwin
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class SpanishFrenchLearningNotesTests: XCTestCase {
    private let targets: [CaptionTranslationTarget] = [.spanish, .french]

    func testDefaultReviewClientForwardsSpanishPromptAndNonemptyResumePrefixToWorker() async throws {
        try await assertDefaultReviewClient(target: .spanish)
    }

    func testDefaultReviewClientForwardsFrenchPromptAndNonemptyResumePrefixToWorker() async throws {
        try await assertDefaultReviewClient(target: .french)
    }

    private func assertDefaultReviewClient(target: CaptionTranslationTarget) async throws {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("DefaultSpanishFrenchReview-\(target.rawValue)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try await installDefaultReviewWorker(in: root)
        var book = LearningNotebook(target: target)
        try book.append(evidence: [foreign(target)], note: note(target))
        let course = root.appendingPathComponent("course")
        var snapshot = SessionSnapshot(segments: book.batches.flatMap(\.evidence), targetLocale: target.rawValue)
        book.writeState(to: &snapshot)
        try SessionStore(directory: course).save(snapshot)
        let journal = root.appendingPathComponent("queue.json")
        // Exercise the default Qwen client and streaming adapter. Only the
        // final subprocess is replaced; no Generator is injected into the queue.
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled)
        addTeardownBlock { await queue.shutdownForTesting() }
        queue.allowUnreleasedTargetsForTesting()
        try queue.enqueue(directory: course, notebook: book, targetLocale: target.rawValue)
        let prefix = "Checking the frozen mass evidence: masa / masse, 3,14.\n"
        for _ in 0..<200 where queue.journalForTesting.jobs.first?.prefix != prefix {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(queue.journalForTesting.jobs.first?.prefix, prefix)
        XCTAssertTrue(queue.running)
        await queue.pauseAndWait()
        XCTAssertFalse(queue.running)
        XCTAssertTrue(queue.hasWork, "Pausing must retain the unfinished batch")
        let paused = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        let job = try XCTUnwrap(paused.jobs.first)
        XCTAssertTrue(paused.userPaused)
        XCTAssertEqual(job.targetLocale, target.rawValue)
        XCTAssertEqual(job.prefix, prefix)
        XCTAssertEqual(job.next, 0)
        XCTAssertTrue(job.reports.isEmpty)
        XCTAssertEqual(job.prompt, target.learningReviewPrompt)
        XCTAssertEqual(try XCTUnwrap(job.prefixInputDigest), LearningReviewQueue.prefixDigest(for: job))
        let prepared = try LearningReviewQueue.prepareInput(job, allowUnreleased: true)
        XCTAssertEqual(prepared.prompt, target.learningReviewPrompt)
        XCTAssertEqual(prepared.input.catalog.keys.sorted(), ["e0." + target.rawValue + ".0"])
        XCTAssertEqual(prepared.input.catalog["e0." + target.rawValue + ".0"]?.text, text(target))
        XCTAssertFalse(prepared.input.json.contains("质量为"))
        let pausedCommands = try reviewWorkerCommands(in: root)
        let initialRequests = pausedCommands.filter { $0["op"] as? String == "generate" }
        XCTAssertEqual(initialRequests.count, 1, "No resumed request may run while paused")
        let initialID = try XCTUnwrap(initialRequests.first?["id"] as? String)
        let pauses = pausedCommands.filter { $0["op"] as? String == "pause" }
        XCTAssertEqual(pauses.count, 1, "Observe the real subprocess pause control")
        XCTAssertEqual(pauses.first?["id"] as? String, initialID)
        XCTAssertFalse(try XCTUnwrap(pauses.first?["controlID"] as? String).isEmpty)
        queue.startAwaitingJob()
        XCTAssertFalse(queue.userPaused)
        for _ in 0..<200 where queue.hasWork { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.hasWork, queue.status)
        let commands = try reviewWorkerCommands(in: root)
        let requests = commands.filter { $0["op"] as? String == "generate" }
        XCTAssertEqual(requests.count, 2, "Observe an initial request and a real resumed request")
        for request in requests {
            XCTAssertEqual(request["system"] as? String, target.learningReviewPrompt)
            XCTAssertEqual(request["input"] as? String, prepared.input.json)
            XCTAssertEqual(request["purpose"] as? String, "review")
            XCTAssertEqual(request["thinking"] as? Bool, true)
            XCTAssertEqual(request["thinkingBudget"] as? Int, 16_384)
            XCTAssertEqual(request["finalBudget"] as? Int, 4_096)
            XCTAssertEqual(request["prompt"] as? String,
                "<|im_start|>system\n" + target.learningReviewPrompt + "<|im_end|>\n"
                + "<|im_start|>user\n" + prepared.input.json + "<|im_end|>\n<|im_start|>assistant\n<think>\n")
        }
        XCTAssertEqual(requests.first?["prefix"] as? String, "")
        XCTAssertEqual(requests.last?["prefix"] as? String, prefix)
        XCTAssertEqual(requests.first?["id"] as? String, initialID)
        let resumedID = try XCTUnwrap(requests.last?["id"] as? String)
        XCTAssertNotEqual(initialID, resumedID)
        let acknowledgements = commands.filter { $0["op"] as? String == "ack" }
        XCTAssertEqual(acknowledgements.count, 1)
        XCTAssertEqual(acknowledgements.first?["id"] as? String, resumedID)
        let completed = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertTrue(completed.jobs.isEmpty)
        XCTAssertFalse(completed.userPaused)
        let reports = try ReviewReportCollection.read(in: course)
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.jobID, job.id)
        XCTAssertEqual(report.identity, job.identity)
        XCTAssertEqual(report.completed, 1)
        XCTAssertEqual(report.total, 1)
        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.appendingPathComponent("summary-review.md").path))
        XCTAssertFalse(try XCTUnwrap(OutputLanguage(rawValue: target.rawValue)).isReleased)
        XCTAssertNil(LearningReviewQueue.reviewPrompt(for: target.rawValue))
    }

    private func reviewWorkerCommands(in root: URL) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("commands.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try object(String($0)) }
    }

    private func installDefaultReviewWorker(in root: URL) async throws {
        guard await MLXRuntime.shared.resourceStates().isEmpty else {
            XCTFail("The test must own an isolated worker lifecycle")
            throw CancellationError()
        }
        let script = root.appendingPathComponent("worker.py")
        try Self.defaultReviewWorker.write(to: script, atomically: true, encoding: .utf8)
        let models = root.appendingPathComponent("models")
        let model = models.appendingPathComponent("lmstudio-community/Qwen3.5-9B-MLX-4bit")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json"] { try Data("{}".utf8).write(to: model.appendingPathComponent(name)) }
        try Data().write(to: model.appendingPathComponent("model.safetensors"))
        let overrides = [
            "LIVELINGO_MLX_PYTHON": "/usr/bin/python3",
            "LIVELINGO_MLX_WORKER": script.path,
            "LIVELINGO_MLX_MODELS": models.path,
            "LIVELINGO_MLX_STATE": root.appendingPathComponent("state").path
        ]
        // Retain only these four overrides for teardown; never dump or persist
        // the process environment. No preference domain is created by this test.
        let previous = overrides.keys.map { key in (key, getenv(key).map { String(cString: $0) }) }
        addTeardownBlock {
            await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel)
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for (key, value) in overrides {
            guard setenv(key, value, 1) == 0 else { throw CocoaError(.fileWriteUnknown) }
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
            command['system'] = command['prompt'].split('<|im_start|>system\n', 1)[1].split('<|im_end|>', 1)[0]
        with (root / 'commands.jsonl').open('a', encoding='utf-8') as output:
            output.write(json.dumps(command, ensure_ascii=False) + '\n')
        if op == 'generate':
            if not command['prefix']:
                emit({'event': 'token', 'id': command['id'], 'wire': 'Checking the frozen mass evidence: masa / masse, 3,14.\n'})
            else:
                text = '{"reviewVersion":2,"corrections":[],"additions":[]}'
                wire = command['prefix'] + 'No corrections are needed.\n</think>\n' + text
                emit({'event': 'done', 'id': command['id'], 'wire': wire, 'text': text})
        else:
            emit({'event': 'paused' if op == 'pause' else op, 'controlID': command['controlID'], 'state': 'saved'})
            if op == 'shutdown':
                break
    """#

    private func text(_ target: CaptionTranslationTarget) -> String {
        target == .spanish ? "Su masa es 3,14 gramos." : "Sa masse est de 3,14 grammes."
    }
    private func foreign(_ target: CaptionTranslationTarget, at time: Double = 0) -> TranscriptSegment {
        .init(startTime: time, endTime: time + 1, english: "质量为 3.14 克。", chinese: text(target), sourceLanguage: "zh")
    }
    private func note(_ target: CaptionTranslationTarget, ids: [String]? = nil) -> LearningNote {
        .init(topic: "Masa / Masse", points: [.init(kind: "例子", text: text(target),
            sourceIDs: ids ?? [target.rawValue + "0s0"])], sourceVersion: 2, noNewKnowledge: false)
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func testLiteralPromptsRemainUnreleasedAndUseChosenStandards() {
        for target in targets {
            XCTAssertFalse(target.learningNotePrompt.isEmpty)
            XCTAssertTrue(target.learningNotePrompt.contains(target.promptName))
            XCTAssertTrue(target.learningReviewPrompt.contains("en/" + target.rawValue))
            XCTAssertNil(LearningReviewQueue.reviewPrompt(for: target.rawValue))
            XCTAssertEqual(LearningReviewQueue.reviewPrompt(for: target.rawValue, allowUnreleased: true), target.learningReviewPrompt)
            XCTAssertEqual(LearningPrompts.generationPrompt(target: target), target.learningNotePrompt)
            XCTAssertFalse(OutputLanguage(rawValue: target.rawValue)!.isReleased)
            for prompt in [target.learningNotePrompt, target.learningReviewPrompt,
                LearningPrompts.generationPrompt(target: target, recoveringAfterOutputLimit: true)] {
                if target == .spanish {
                    XCTAssertTrue(prompt.contains("RAE"))
                    XCTAssertTrue(prompt.contains("ASALE"))
                    XCTAssertTrue(prompt.contains("pan-Hispanic standard"))
                } else {
                    XCTAssertTrue(prompt.contains("standard metropolitan French as used in France"))
                }
            }
        }
    }
    func testArabicLocaleValuesBindAcrossEnglishAndTargetGroups() {
        for target in targets {
            let grouped = target == .spanish ? "1.000" : "1\u{202F}000"
            let caption = target == .spanish ? "La masa es " + grouped + " gramos." : "La masse est de " + grouped + " grammes."
            let source = TranscriptSegment(startTime: 0, endTime: 1, english: "The mass is 1,000 grams.", chinese: caption, sourceLanguage: "en")
            let n = LearningNote(topic: "Mass", points: [.init(kind: "核心结论", text: caption,
                sourceIDs: ["en0s0"])], sourceVersion: 2, noNewKnowledge: false).binding(evidence: [source], target: target)
            XCTAssertEqual(n.points[0].referenceState, .linked)
            XCTAssertNil(n.points[0].numericGap)
            let same = note(target).binding(evidence: [foreign(target)], target: target)
            XCTAssertEqual(same.points[0].referenceState, .linked)
            XCTAssertNil(same.points[0].numericGap)
            var wrong = note(target); wrong.points[0].text = text(target).replacingOccurrences(of: "3,14", with: "314")
            XCTAssertEqual(wrong.binding(evidence: [foreign(target)], target: target).points[0].referenceState, .numericDifference)
            XCTAssertEqual(LatinNumericParser.numbers(in: grouped + ",50", language: target.rawValue), ["10005e-1"])
            XCTAssertEqual(LatinNumericParser.numbers(in: "-3,14 +9,01e2", language: target.rawValue), ["-314e-2", "901e0"])
            XCTAssertTrue(LatinNumericParser.numbers(in: "1,2,3", language: target.rawValue).isEmpty)
        }
    }
    func testSourceIDsAndNumericScopeRejectForeignAndHistoricalColumns() {
        for target in targets {
            for invalid in ["zh0s0", "h0", "de0s0"] {
                XCTAssertEqual(note(target, ids: [invalid]).binding(evidence: [foreign(target)], target: target).points[0].referenceState, .unlinked)
            }
            let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "质量为 314 克。", chinese: text(target), sourceLanguage: "zh")
            var claim = note(target); claim.points[0].text = text(target).replacingOccurrences(of: "3,14", with: "314")
            XCTAssertEqual(claim.binding(evidence: [segment], target: target).points[0].referenceState, .numericDifference)
            XCTAssertEqual(LearningSourceUnit.make([segment], target: target).map(\.language), [target.rawValue])
        }
    }
    func testSameLanguagePassThroughIgnoresStoredChineseAndPronounsFollowSourceLanguage() {
        for target in targets {
            let own = TranscriptSegment(startTime: 0, endTime: 1, english: text(target), chinese: "旧中文", sourceLanguage: target.rawValue)
            XCTAssertEqual(LearningSourceUnit.textGroups(for: own, target: target).map(\.text), [text(target)])
            XCTAssertTrue(note(target).binding(evidence: [own], target: target).points[0].sourceHasPronoun == true)
        }
        let en = TranscriptSegment(startTime: 0, endTime: 1, english: "The son studies mass.", chinese: "Le fils étudie la masse.", sourceLanguage: "en")
        let n = LearningNote(topic: "Mass", points: [.init(kind: "例子", text: "Le fils étudie la masse.", sourceIDs: ["en0s0"])], sourceVersion: 2, noNewKnowledge: false)
        XCTAssertEqual(n.binding(evidence: [en], target: .french).points[0].sourceHasPronoun, false)
        for pronoun in ["son", "sa", "ses", "leur", "leurs"] {
            let own = TranscriptSegment(startTime: 0, endTime: 1, english: pronoun + " masse change.", sourceLanguage: "fr")
            var n = note(.french); n.points[0].sourceIDs = ["fr0s0"]
            XCTAssertEqual(n.binding(evidence: [own], target: .french).points[0].sourceHasPronoun, true)
        }
    }
    func testAccentedRetrievalAndStopWordsReachPendingAndLaterEvidence() throws {
        for target in targets {
            let accent = target == .spanish ? "presión" : "température"
            let stop = target == .spanish ? "el la los las de en y su sus" : "le la les des de en et sa ses leur"
            XCTAssertEqual(LearningNotebook.terms(stop + " " + accent, target: target), [accent])
            let decomposed = accent.decomposedStringWithCanonicalMapping
            XCTAssertEqual(LearningNotebook.terms(decomposed, target: target), [accent])
            let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "来源", chinese: accent + " change.", sourceLanguage: "zh")
            var book = LearningNotebook(target: target)
            try book.append(evidence: [segment], note: .init(topic: accent, points: [.init(kind: "待确认", text: accent,
                needsContext: "?", referenceState: .pending)]))
            let next = TranscriptSegment(startTime: 2, endTime: 3, english: "后文", chinese: accent + " stable.", sourceLanguage: "zh")
            XCTAssertEqual(book.selectPendingPoints(for: [next]).count, 1)
            let later = LearningNoteBatch(id: UUID(), evidence: [next], note: .init(topic: accent, points: []))
            let review = try object(LearningPrompts.reviewInput(book.batches[0], laterBatches: [later], target: target).json)
            XCTAssertFalse((review["laterEvidence"] as? [Any] ?? []).isEmpty)
        }
    }
    func testLegacyPendingFallbackAndQuoteOriginsAreTargetBound() throws {
        for target in targets {
            let evidence = [foreign(target)]
            let old = LearningNote(topic: "Mass", points: [.init(kind: "待确认", text: "?",
                sources: [.init(index: 0, quote: "质量为 3.14 克。")], needsContext: "?", referenceState: .pending)])
            let batch = LearningNoteBatch(id: UUID(), evidence: evidence, note: old)
            let book = try LearningNotebook(snapshot: SessionSnapshot(segments: evidence, batches: [batch], targetLocale: target.rawValue))
            let pending = try XCTUnwrap(book.pendingPoints.first)
            XCTAssertEqual(pending.quotes, [text(target)])
            XCTAssertEqual(pending.quoteOrigins.flatMap { $0 }.map(\.language), [target.rawValue])
            let input = try LearningPrompts.input(evidence: [foreign(target, at: 3)], topics: [], pending: [pending], target: target)
            XCTAssertFalse(input.contains("质量为"))
            let root = try object(input)
            XCTAssertEqual((root["priorEvidence"] as? [[String: Any]])?.first?["text"] as? String, text(target))
            XCTAssertFalse((root["pendingEvidenceRule"] as? String ?? "").contains("旧原文"))
        }
    }
    func testEnglishFallbackKeepsSeparateGroupsAndTheirOrigins() throws {
        for target in targets {
            let source = TranscriptSegment(startTime: 0, endTime: 1, english: "Its mass is 3.14 grams.", chinese: text(target), sourceLanguage: "en")
            var book = LearningNotebook(target: target)
            try book.append(evidence: [source], note: .init(topic: "Mass", points: [.init(kind: "待确认", text: "?", needsContext: "?", referenceState: .pending)]))
            let pending = try XCTUnwrap(book.pendingPoints.first)
            XCTAssertEqual(pending.quotes, [source.english, text(target)])
            XCTAssertEqual(pending.quoteOrigins.flatMap { $0 }.map(\.index), [0, 0])
            XCTAssertEqual(pending.quoteOrigins.flatMap { $0 }.map(\.language), ["en", target.rawValue])
            let json = try object(LearningPrompts.input(evidence: [foreign(target, at: 3)], topics: [], pending: [pending], target: target))
            let history = try XCTUnwrap(json["priorEvidence"] as? [[String: Any]])
            XCTAssertEqual(history.compactMap { ($0["locations"] as? [[String: Any]])?.first?["language"] as? String }, ["en", target.rawValue])
        }
    }
    func testIndependentLearningPromptDigestsAreFrozen() {
        let expected: [(CaptionTranslationTarget, [String])] = [
            (.spanish, ["724a0b4f6b6b92ea4b36ee56adde3e7ab6cb22594e1147a25ad550e061b6262f", "30465762263d6707329719fdfc951a831d95b5a4639b69ad53dde259bb2b55fc", "ef8513ed29136e6caced4ef3d34eb9d1eecbd3bbd4c826f569a1d6279cc28f68"]),
            (.french, ["cf66bd0eb21d21e69436727802e35acf84b07229ecbca826ac2fb41165f6131b", "881190538b94ba9866c58afc125a14783e096effe25f244bbaaf6bba44bb1510", "05f7eb408bb098a30fdded60c3c064126ef78a39733d6a7181d73f28102be43b"])]
        for (target, hashes) in expected {
            let prompts = [target.learningNotePrompt, target.learningReviewPrompt,
                LearningPrompts.generationPrompt(target: target, recoveringAfterOutputLimit: true)]
            XCTAssertEqual(prompts.map { SessionArchiveCoding.digest(Data($0.utf8)) }, hashes)
        }
    }
    func testNotebookCommitsFollowUpsWithoutRewritingEarlierNote() throws {
        for target in targets {
            var book = LearningNotebook(target: target)
            var first = note(target); first.points[0].kind = "待确认"; first.points[0].needsContext = "?"
            try book.append(evidence: [foreign(target)], note: first)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let frozen = try encoder.encode(book.batches[0].note)
            let pending = try XCTUnwrap(book.pendingPoints.first)
            var next = note(target)
            next.followUps = [.init(alias: "q0", target: pending.id, state: .supplemented, sourceIDs: [target.rawValue + "0s0"], detail: text(target))]
            try book.append(evidence: [foreign(target, at: 3)], note: next)
            XCTAssertEqual(try encoder.encode(book.batches[0].note), frozen)
            XCTAssertEqual(book.batches[1].followUps?.first?.state, .supplemented)
            XCTAssertTrue(book.pendingPoints.isEmpty)
            XCTAssertTrue(book.markdown().contains(LearningFollowUp.State.supplemented.label(target: target)))
        }
    }
    func testActualReviewQueueForwardsPromptInputAndPrefix() async throws {
        for target in targets {
            let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpanishFrenchReview-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var book = LearningNotebook(target: target); try book.append(evidence: [foreign(target)], note: note(target))
            var snapshot = SessionSnapshot(segments: book.batches.flatMap(\.evidence), targetLocale: target.rawValue)
            book.writeState(to: &snapshot); try SessionStore(directory: root).save(snapshot)
            let journal = root.appendingPathComponent("queue.json")
            var calls = 0
            let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled) { input, prefix, prompt, _, _ in
                calls += 1
                XCTAssertEqual(prompt, target.learningReviewPrompt)
                let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
                let job = try XCTUnwrap(saved.jobs.first)
                XCTAssertEqual(prefix, job.prefix)
                XCTAssertEqual(input, try LearningReviewQueue.prepareInput(job, allowUnreleased: true).input.json)
                XCTAssertEqual(try LearningReviewQueue.prepareInput(job, allowUnreleased: true).input.catalog.keys.sorted(), ["e0." + target.rawValue + ".0"])
                return #"{"reviewVersion":2,"corrections":[],"additions":[]}"#
            }
            addTeardownBlock { await queue.shutdownForTesting(); try FileManager.default.removeItem(at: root) }
            queue.allowUnreleasedTargetsForTesting()
            try queue.enqueue(directory: root, notebook: book, targetLocale: target.rawValue)
            for _ in 0..<200 where queue.hasWork { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(calls, 1); XCTAssertFalse(queue.hasWork)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("summary-review.md").path))
        }
    }
    func testRecoveryCheckpointAcceptsOnlyMatchingTargetPrompt() throws {
        for target in targets {
            let evidence = [foreign(target)], snapshot = SessionSnapshot(segments: [foreign(target)], targetLocale: target.rawValue)
            let stableSnapshot = SessionSnapshot(sessionID: snapshot.sessionID, segments: evidence, targetLocale: target.rawValue)
            let input = try LearningPrompts.input(evidence: evidence, topics: [], target: target)
            for recovering in [false, true] {
                let prompt = LearningPrompts.generationPrompt(target: target, recoveringAfterOutputLimit: recovering)
                let draft = LearningDraft(evidence: evidence, model: "proposal-stub", input: input, target: target, systemPrompt: prompt, text: "Frozen prefix", attempts: 2)
                let checkpoint = draft.checkpoint(sessionID: stableSnapshot.sessionID, inputRevision: stableSnapshot.inputRevision, generation: stableSnapshot.generation)
                let restored = try XCTUnwrap(LearningDraft(checkpoint: checkpoint, snapshot: stableSnapshot, model: "proposal-stub"))
                XCTAssertEqual(restored.target, target); XCTAssertEqual(restored.systemPrompt, prompt); XCTAssertEqual(restored.text, "Frozen prefix")
                XCTAssertNil(LearningDraft(checkpoint: checkpoint, snapshot: stableSnapshot, model: "proposal-stub", systemPrompt: "Unknown"))
            }
        }
    }
    func testNarrowKindLabelsLeaveWireAndClassroomDefaultsIntact() {
        for target in targets {
            let point = LearningPoint(kind: "例子", text: text(target))
            XCTAssertEqual(point.kind, "例子")
            XCTAssertTrue(point.markdown(target: target).contains(target == .spanish ? "**Ejemplo**" : "**Exemple**"))
            XCTAssertEqual(ClassroomFixedText.replayHeading.noteText(target: target), "需要回听")
            XCTAssertEqual(ClassroomFixedText.sourceLine.noteFormat([text(target)], target: target), "原文：" + text(target))
        }
        XCTAssertFalse(ClassroomFixedText.usesTargetLanguage)
        XCTAssertEqual(SummaryRefreshPolicy.automaticBatchCharacters, 4_000)
    }
    func testRepairNumericVetoRecognizesCommaDecimalsWithoutVetoingWrittenCandidates() {
        for target in targets {
            XCTAssertEqual(RepairNumericNovelty.assess(candidate: "3,14 g", support: ["3.14 g"], targetCode: target.rawValue, supportLanguages: ["en"]).unsupported, [])
            XCTAssertEqual(RepairNumericNovelty.assess(candidate: "3,15 g", support: ["3.14 g"], targetCode: target.rawValue, supportLanguages: ["en"]).unsupported, ["3,15"])
            XCTAssertTrue(RepairNumericNovelty.assess(candidate: target == .spanish ? "tres" : "trois", support: ["2"], targetCode: target.rawValue).unsupported.isEmpty)
        }
    }
}
