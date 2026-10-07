import Darwin
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class TargetPipelineRefactorTests: XCTestCase {
    func testExplicitPurposeOverridesLegacyPromptInference() {
        XCTAssertEqual(QwenTranslationClient.completionPurpose(systemPrompt: LearningPrompts.generate), .note)
        XCTAssertEqual(QwenTranslationClient.completionPurpose(systemPrompt: LearningPrompts.review), .review)
        XCTAssertEqual(QwenTranslationClient.completionPurpose(systemPrompt: "synthetic prompt"), .text)
        XCTAssertEqual(QwenTranslationClient.completionPurpose(systemPrompt: "synthetic prompt", explicit: .note), .note)
        XCTAssertEqual(QwenTranslationClient.completionPurpose(systemPrompt: LearningPrompts.generate, explicit: .text), .text)
        XCTAssertEqual(CaptionTranslationTarget.simplifiedChinese.learningNotePrompt, LearningPrompts.generate)
        XCTAssertEqual(CaptionTranslationTarget.simplifiedChinese.learningReviewPrompt, LearningPrompts.review)
    }

    func testDraftBindsItsActualPromptAndRejectsOtherPromptOrTarget() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1, english: "Heat moves.", chinese: "热量传递。")]
        var snapshot = SessionSnapshot(segments: evidence)
        let prompt = "Synthetic non-default note instructions."
        var draft = LearningDraft(evidence: evidence, model: "synthetic", input: "synthetic input",
                                  systemPrompt: prompt, text: "unfinished")
        draft.freezeBinding(sessionID: snapshot.sessionID, inputRevision: snapshot.inputRevision,
                            generation: snapshot.generation)
        let checkpoint = draft.checkpoint(sessionID: snapshot.sessionID, inputRevision: snapshot.inputRevision,
                                          generation: snapshot.generation)
        XCTAssertEqual(checkpoint.promptDigest, SessionArchiveCoding.digest(Data(prompt.utf8)))
        XCTAssertTrue(draft.matches(snapshot: snapshot, model: "synthetic", systemPrompt: prompt))
        XCTAssertFalse(draft.matches(snapshot: snapshot, model: "synthetic"))
        let restored = try XCTUnwrap(LearningDraft(checkpoint: checkpoint, snapshot: snapshot,
                                                   model: "synthetic", systemPrompt: prompt))
        XCTAssertEqual(restored.systemPrompt, prompt)
        XCTAssertEqual(restored.promptDigest, checkpoint.promptDigest)
        XCTAssertEqual(restored.text, "unfinished")
        XCTAssertNil(LearningDraft(checkpoint: checkpoint, snapshot: snapshot, model: "synthetic"))
        snapshot.targetLocale = "en"
        XCTAssertFalse(draft.matches(snapshot: snapshot, model: "synthetic", systemPrompt: prompt))
        XCTAssertNil(LearningDraft(checkpoint: checkpoint, snapshot: snapshot, model: "synthetic", systemPrompt: prompt))
    }

    func testNonDefaultNoteAndReviewPromptsKeepTheirWorkerPurposes() async throws {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("TargetPipeline-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let workers = await MLXRuntime.shared.resourceStates()
        XCTAssertTrue(workers.isEmpty)
        let script = root.appendingPathComponent("fake-worker.py")
        try Self.worker.write(to: script, atomically: true, encoding: .utf8)
        let models = root.appendingPathComponent("models")
        for relative in ["mlx-community/Qwen3.5-4B-MLX-8bit", "lmstudio-community/Qwen3.5-9B-MLX-4bit"] {
            let model = models.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            for name in ["config.json", "tokenizer.json"] { try Data("{}".utf8).write(to: model.appendingPathComponent(name)) }
        }
        let environment = ["LIVELINGO_MLX_PYTHON": "/usr/bin/python3", "LIVELINGO_MLX_WORKER": script.path,
                           "LIVELINGO_MLX_MODELS": models.path, "LIVELINGO_MLX_STATE": root.appendingPathComponent("state").path]
        let previous = environment.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (key, value) in environment { setenv(key, value, 1) }
        addTeardownBlock {
            await MLXRuntime.shared.unload(QwenModelProfile.energySaver.translationModel)
            await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel)
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let notePrompt = "Synthetic custom note prompt."
        let reviewPrompt = "Synthetic custom review prompt."
        _ = try await QwenTranslationClient.learningNote(input: "synthetic note input",
            modelName: QwenModelProfile.energySaver.translationModel, prefix: "", systemPrompt: notePrompt, onUpdate: { _ in })
        _ = try await QwenTranslationClient.reviewLearningNote("synthetic review input", systemPrompt: reviewPrompt)
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(requests.compactMap { $0["purpose"] as? String }, ["note", "review"])
        XCTAssertTrue((requests[0]["prompt"] as? String)?.contains(notePrompt) == true)
        XCTAssertTrue((requests[1]["prompt"] as? String)?.contains(reviewPrompt) == true)
    }

    private static let worker = #"""
    import json, pathlib, sys
    root = pathlib.Path(__file__).parent
    def emit(value):
        print(json.dumps(value), flush=True)
    emit({'event': 'ready', 'version': 2})
    for line in sys.stdin:
        command = json.loads(line)
        if command['op'] == 'generate':
            with (root / 'requests.jsonl').open('a') as output:
                output.write(json.dumps(command) + '\n')
            text = '{"synthetic":true}'
            wire = 'Synthetic check.\n</think>\n' + text if command['thinking'] else text
            emit({'event': 'done', 'id': command['id'], 'wire': wire, 'text': text})
        else:
            emit({'event': 'paused' if command['op'] == 'pause' else command['op'],
                  'controlID': command['controlID'], 'state': 'saved'})
            if command['op'] == 'shutdown':
                break
    """#
}
