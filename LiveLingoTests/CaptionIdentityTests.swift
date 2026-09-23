import XCTest
@testable import LiveLingo

@MainActor
private final class CaptionIdentityGate<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?
    var entered = false

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            entered = true
        }
    }

    func finish(_ result: Result<Value, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor
final class CaptionIdentityTests: XCTestCase {
    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等待测试任务到达指定阶段超时")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeModel(_ translation: CaptionTranslationDependencies,
                           notes: LearningGenerationDependencies? = nil) throws -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-CaptionIdentity-\(UUID())", isDirectory: true)
        let suite = "LiveLingo-CaptionIdentity-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("字幕生命周期测试不能发起复查")
                throw CancellationError()
            }
        addTeardownBlock {
            await queue.shutdownForTesting()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        let model = AppModel(reviewQueue: queue, translation: translation,
                             notes: notes, backgroundServices: false, defaults: preferences)
        model.resetTranslationSessionForTesting()
        return model
    }

    func testSummaryCommitSurvivesUnrelatedRevisionButRejectsDependencyRevision() async throws {
        for dependsOnEarlier in [false, true] {
            let gate = CaptionIdentityGate<String>()
            addTeardownBlock { await gate.finish(.failure(CancellationError())) }
            var calls = 0
            let model = try makeModel(.unavailable, notes: .init(generate: { _, _, _, update in
                calls += 1
                await update("{\"topic\":")
                return try await gate.wait()
            }))
            let earlier = TranscriptSegment(startTime: 0, endTime: 8,
                english: dependsOnEarlier ? "Its speed is not known yet." : "The cup is made of glass.",
                chinese: dependsOnEarlier ? "速度仍待后文说明。" : "杯子由玻璃制成。")
            let current = TranscriptSegment(startTime: 8, endTime: 16,
                english: "Cart B moves at two metres per second.", chinese: "B 车的速度为每秒两米。")
            let next = TranscriptSegment(startTime: 16, endTime: 24,
                english: "Cart B keeps this speed for the whole journey.", chinese: "B 车全程保持该速度。")
            var notebook = LearningNotebook()
            try notebook.append(evidence: [earlier], note: .init(topic: "先前记录", points: [
                .init(kind: dependsOnEarlier ? "待确认" : "核心结论", text: earlier.chinese,
                      needsContext: dependsOnEarlier ? "速度属于哪辆车？" : nil, sourceIDs: ["en0s0"])
            ], sourceVersion: 2))
            model.loadPresentationForTesting(phase: .saved(FileManager.default.temporaryDirectory),
                evidence: [earlier, current, next], notebook: notebook)
            let task = Task { await model.generateSummaryForTesting() }
            try await eventually { gate.entered }
            model.reviseCaptionForTesting(id: earlier.id, english: "The earlier statement has been revised.")
            gate.finish(.success(#"{"topic":"小车运动","points":[{"kind":"核心结论","text":"B 车全程保持每秒两米的速度。","sourceIDs":["en0s0","en1s0"]}]}"#))
            await task.value
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(model.lectureSummary.contains("B 车全程保持每秒两米的速度。"), !dependsOnEarlier)
        }
    }

    func testAdjacentRepairFollowsCaptionIdentityAfterEarlierInsertion() async throws {
        let gate = CaptionIdentityGate<QwenTranslationClient.AdjacentTranslation>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        let first = TranscriptSegment(startTime: 10, endTime: 20,
                                      english: "The pressure changes when we heat the gas.")
        let current = TranscriptSegment(startTime: 20, endTime: 28,
                                        english: "The temperature also changes during heating.")
        let earlier = TranscriptSegment(startTime: 0, endTime: 8,
                                        english: "This earlier sentence was recovered later.")
        let model = try makeModel(.init(
            translate: { text, _, _, _ in text.contains("earlier") ? "较早补转的译文。" : "先前句子的译文。" },
            adjacent: { _, _, _, _, _, _ in try await gate.wait() }))
        model.receiveIdentifiedCaptionForTesting(first)
        await model.translationTaskForTesting?.value
        model.receiveIdentifiedCaptionForTesting(current)
        try await eventually { gate.entered }
        model.receiveIdentifiedCaptionForTesting(earlier)
        gate.finish(.success(.init(previous: "加热使气体压力发生变化。", current: "加热时温度也发生变化。",
                                  previousRejection: nil, currentRejection: nil)))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(model.segments.map(\.id), [earlier.id, first.id, current.id])
        XCTAssertEqual(model.segments[0].chinese, "较早补转的译文。")
        XCTAssertEqual(model.segments[1].chinese, "加热使气体压力发生变化。")
        XCTAssertEqual(model.segments[2].chinese, "加热时温度也发生变化。")
        XCTAssertEqual(model.segments[0].inputRevision, 0)
        XCTAssertEqual(model.segments[1].inputRevision, 1)
    }

    func testOriginalRevisionRejectsOldStreamingAndCompletedTranslation() async throws {
        let gate = CaptionIdentityGate<String>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var oldUpdate: CaptionTranslationDependencies.Update?
        let model = try makeModel(.init(translate: { text, _, _, update in
            if text.contains("revised") { return "确认修订后的译文。" }
            oldUpdate = update
            return try await gate.wait()
        }, adjacent: { _, _, _, _, _, _ in throw CancellationError() }))
        let caption = TranscriptSegment(startTime: 0, endTime: 8,
                                        english: "The original sentence says that pressure increases.")
        model.receiveIdentifiedCaptionForTesting(caption)
        try await eventually { gate.entered }
        model.reviseCaptionForTesting(id: caption.id,
            english: "The revised sentence says that pressure decreases.")
        await oldUpdate?("这是已经失效的流式译文。")
        XCTAssertEqual(model.streamingChinese, "")
        gate.finish(.success("旧原文已经完成的译文。"))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.segments[0].chinese, "确认修订后的译文。")
        XCTAssertEqual(model.segments[0].inputRevision, 1)
        XCTAssertEqual(model.segments[0].translationState, .completed)
    }

    func testRevisionDuringBothRetryPathsRejectsObsoleteResults() async throws {
        for firstFails in [false, true] {
            let gate = CaptionIdentityGate<String>()
            addTeardownBlock { await gate.finish(.failure(CancellationError())) }
            var calls = 0
            let model = try makeModel(.init(translate: { text, _, _, _ in
                calls += 1
                if text.contains("revised") { return "新原文对应的译文。" }
                if calls == 1 {
                    if firstFails { throw QwenRuntimeError.invalidResponse }
                    return String(repeating: "这是过长的中文译文。", count: 60)
                }
                return try await gate.wait()
            }, adjacent: { _, _, _, _, _, _ in throw CancellationError() }))
            let caption = TranscriptSegment(startTime: 0, endTime: 8,
                english: "The system gains energy and its temperature increases.")
            model.receiveIdentifiedCaptionForTesting(caption)
            try await eventually { gate.entered }
            model.reviseCaptionForTesting(id: caption.id,
                english: "The revised system loses energy and its temperature decreases.")
            gate.finish(.success("旧原文重试得到的译文。"))
            await model.translationTaskForTesting?.value
            XCTAssertEqual(calls, 3)
            XCTAssertEqual(model.segments.first?.chinese, "新原文对应的译文。")
            XCTAssertEqual(model.segments.first?.translationState, .completed)
        }
    }

    func testPreviousRevisionInvalidatesAdjacentRequestAndRetranslatesCurrent() async throws {
        let gate = CaptionIdentityGate<QwenTranslationClient.AdjacentTranslation>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var pairCalls = 0
        let model = try makeModel(.init(translate: { text, _, _, _ in
            text.contains("revised") ? "确认后的前句译文。" : "前句原有译文。"
        }, adjacent: { _, _, _, _, _, _ in
            pairCalls += 1
            if pairCalls == 1 { return try await gate.wait() }
            return .init(previous: nil, current: "根据新上下文翻译当前句。",
                         previousRejection: nil, currentRejection: nil)
        }))
        let first = TranscriptSegment(startTime: 0, endTime: 10,
                                      english: "The original sentence describes an increase.")
        let second = TranscriptSegment(startTime: 10, endTime: 18,
                                       english: "This change follows the described condition.")
        model.receiveIdentifiedCaptionForTesting(first)
        await model.translationTaskForTesting?.value
        model.receiveIdentifiedCaptionForTesting(second)
        try await eventually { gate.entered }
        model.reviseCaptionForTesting(id: first.id,
                                      english: "The revised sentence describes a decrease.")
        gate.finish(.success(.init(previous: "已失效的前句修复。", current: "已失效的当前句译文。",
                                  previousRejection: nil, currentRejection: nil)))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(pairCalls, 2)
        XCTAssertEqual(model.segments[0].chinese, "确认后的前句译文。")
        XCTAssertEqual(model.segments[1].chinese, "根据新上下文翻译当前句。")
    }

    func testSavedPauseWaitsForOldWorkerBeforeResume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-SavedPause-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let identity = UUID()
        let caption = TranscriptSegment(startTime: 0, endTime: 8,
            english: "A single saved sentence waits for translation.", sessionID: identity)
        var snapshot = SessionSnapshot(sessionID: identity)
        snapshot.segments = [caption]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        snapshot.processing.pendingSegmentIDs = [caption.id]
        _ = try SessionStore(directory: root).save(snapshot)
        let gate = CaptionIdentityGate<String>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var calls = 0
        let model = try makeModel(.init(translate: { _, _, _, _ in
            calls += 1
            if calls == 1 { return try await gate.wait() }
            return "恢复后完成的译文。"
        }, adjacent: { _, _, _, _, _, _ in throw CancellationError() }))
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root)
        XCTAssertTrue(model.savedProcessingIsPaused)
        model.resumeSavedProcessing()
        try await eventually { gate.entered }
        model.pauseSavedProcessing()
        try await eventually { model.savedProcessingIsPaused }
        model.resumeSavedProcessing()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1, "恢复必须等待已取消的请求实际退出")
        gate.finish(.success("暂停前的失效结果。"))
        try await eventually { model.segments.first?.chinese == "恢复后完成的译文。" }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(calls, 2)
        let restored = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(restored.segments.first?.chinese, "恢复后完成的译文。")
    }

    func testSavedWriteRetryRebuildsExportsAndRetainsCaptureInterruption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-SavedWriteRetry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var snapshot = SessionSnapshot()
        snapshot.segments = [TranscriptSegment(startTime: 0, endTime: 8,
            english: "Saved text before the capture interruption.", chinese: "采集中断前保存的正文。",
            sessionID: snapshot.sessionID)]
        snapshot.processing.paused = true
        snapshot.processing.recordFailure("Capture ended at frame 1024", source: .capture)
        snapshot.processing.recordFailure("Earlier readable export failed", source: .storage)
        _ = try SessionStore(directory: root).save(snapshot)
        let model = try makeModel(.unavailable)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root)
        let blocker = root.appendingPathComponent("transcript-en.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        model.retrySavedSessionWrite()
        try await eventually { !model.archiveLoading }
        XCTAssertNotNil(model.archiveError)
        XCTAssertTrue(model.savedProcessingIsPaused)
        let blocked = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(blocked.processing.captureError, "Capture ended at frame 1024")
        // Remove only the synthetic obstruction created immediately above.
        try FileManager.default.removeItem(at: blocker)
        model.retrySavedSessionWrite()
        try await eventually { !model.archiveLoading }
        let restored = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(restored.processing.lastErrorSource, .capture)
        XCTAssertEqual(restored.processing.lastError, "Capture ended at frame 1024")
        XCTAssertEqual(model.archiveError, "Capture ended at frame 1024")
        XCTAssertTrue(restored.processing.paused)
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8),
                       snapshot.segments[0].english + "\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript-zh-Hans.txt"), encoding: .utf8),
                       snapshot.segments[0].chinese + "\n")
    }
}
