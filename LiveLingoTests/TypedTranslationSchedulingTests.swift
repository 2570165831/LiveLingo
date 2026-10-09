import XCTest
@testable import LiveLingo

/// Holds every caption and typed request until the test releases it by label,
/// recording the order in which the model was entered.
@MainActor
private final class TypedSchedulingGate {
    private var continuations: [String: CheckedContinuation<String, Error>] = [:]
    private(set) var order: [String] = []

    func hold(_ label: String) async throws -> String {
        try await withCheckedThrowingContinuation {
            order.append(label)
            continuations[label] = $0
        }
    }

    func isHeld(_ label: String) -> Bool { continuations[label] != nil }

    func release(_ label: String, _ value: String) {
        continuations.removeValue(forKey: label)?.resume(returning: value)
    }

    func cancelAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}

private let typedSchedulingLabels = ["alpha", "bravo", "charlie", "delta"]
private let typedSchedulingReplies = ["alpha": "甲样品已就绪。", "bravo": "乙样品已就绪。",
                                      "charlie": "丙样品已就绪。", "delta": "丁样品已就绪。"]

@MainActor
final class TypedTranslationSchedulingTests: XCTestCase {

    private func eventually(within timeout: Duration = .seconds(5),
                            _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Synthetic typed-translation scheduling did not reach the asserted stage")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeModel(_ gate: TypedSchedulingGate) throws -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-TypedScheduling-\(UUID())", isDirectory: true)
        let suite = "LiveLingo-Test-\(UUID())"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let preferences = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Typed scheduling tests must not invoke review models")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: .init(translate: { input, _, _, _, _ in
            let label = try XCTUnwrap(typedSchedulingLabels.first { input.contains($0) })
            return try await gate.hold(label)
        }, adjacent: { _, _, _, _, _, _, _, _, _ in
            XCTFail("Spaced synthetic captions must not request adjacent repair")
            throw CancellationError()
        }), notes: nil, backgroundServices: false, defaults: preferences)
        model.resetTranslationSessionForTesting()
        model.setTypedTranslationRequestForTesting { _, _, _ in try await gate.hold("typed") }
        addTeardownBlock { @MainActor in
            model.cancelTypedTranslation()
            gate.cancelAll()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while model.isManualTranslating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let worker = model.resetTranslationSessionForTesting()
            gate.cancelAll()
            await worker?.value
            await queue.shutdownForTesting()
            try preferenceCleanup.remove()
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return model
    }

    /// Captions are 12 s apart so each one takes the isolated translate path.
    private func receive(_ model: AppModel, _ label: String) {
        let index = Double(typedSchedulingLabels.firstIndex(of: label)!)
        model.receiveCaptionForTesting("The \(label) sample is ready.", start: index * 20, end: index * 20 + 8)
    }

    private func release(_ gate: TypedSchedulingGate, _ label: String) async throws {
        try await eventually { gate.isHeld(label) }
        gate.release(label, typedSchedulingReplies[label] ?? "压力降低。")
    }

    func testNormalTypedTranslationCutsInAfterCurrentCaptionAndQueueResumes() async throws {
        let gate = TypedSchedulingGate()
        let model = try makeModel(gate)
        for label in ["alpha", "bravo", "charlie"] { receive(model, label) }
        try await eventually { gate.isHeld("alpha") }
        model.manualTranslationInput = "The pressure decreases."
        model.translateTypedText()
        XCTAssertEqual(model.manualTranslationStatus, "等待当前字幕翻译或摘要完成…")
        gate.release("alpha", typedSchedulingReplies["alpha"]!)
        // A caption arriving after the worker yields must not restart it
        // before the waiting typed request takes the model.
        try await eventually { gate.order.count > 1 || model.translationTaskForTesting == nil }
        receive(model, "delta")
        try await eventually { gate.order.count > 1 }
        XCTAssertEqual(gate.order, ["alpha", "typed"], "The typed request must run right after the current caption")
        XCTAssertNil(model.translationTaskForTesting)
        XCTAssertTrue(model.isManualTranslating)
        try await release(gate, "typed")
        for label in ["bravo", "charlie", "delta"] { try await release(gate, label) }
        try await eventually { !model.isManualTranslating && model.translationTaskForTesting == nil }
        XCTAssertEqual(gate.order, ["alpha", "typed", "bravo", "charlie", "delta"])
        XCTAssertEqual(model.manualTranslationOutput, "压力降低。")
        XCTAssertTrue(model.manualTranslationStatus.hasPrefix("已完成"))
        XCTAssertEqual(model.segments.map(\.chinese), typedSchedulingLabels.map { typedSchedulingReplies[$0]! })
        XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
    }

    func testCancelledTypedTranslationResumesCaptionQueue() async throws {
        let gate = TypedSchedulingGate()
        let model = try makeModel(gate)
        for label in ["alpha", "bravo"] { receive(model, label) }
        try await eventually { gate.isHeld("alpha") }
        model.manualTranslationInput = "The pressure decreases."
        model.translateTypedText()
        gate.release("alpha", typedSchedulingReplies["alpha"]!)
        try await eventually { gate.isHeld("typed") }
        receive(model, "charlie")
        XCTAssertNil(model.translationTaskForTesting)
        model.cancelTypedTranslation()
        gate.release("typed", "压力降低。")
        for label in ["bravo", "charlie"] { try await release(gate, label) }
        try await eventually { !model.isManualTranslating && model.translationTaskForTesting == nil }
        XCTAssertEqual(gate.order, ["alpha", "typed", "bravo", "charlie"])
        XCTAssertEqual(model.manualTranslationStatus, "已取消")
        XCTAssertEqual(model.manualTranslationOutput, "")
        XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
    }

    func testPreciseTypedTranslationStillWaitsForWholeCaptionBacklog() async throws {
        let gate = TypedSchedulingGate()
        let model = try makeModel(gate)
        for label in ["alpha", "bravo", "charlie"] { receive(model, label) }
        try await eventually { gate.isHeld("alpha") }
        model.manualTranslationInput = "The pressure decreases."
        model.translateTypedText(thinking: true)
        XCTAssertEqual(model.manualTranslationStatus, "精确翻译：等待字幕翻译队列清空和摘要完成…")
        for label in ["alpha", "bravo", "charlie"] { try await release(gate, label) }
        try await release(gate, "typed")
        try await eventually { !model.isManualTranslating }
        XCTAssertEqual(gate.order, ["alpha", "bravo", "charlie", "typed"])
        XCTAssertEqual(model.manualTranslationOutput, "压力降低。")
        XCTAssertTrue(model.manualTranslationStatus.hasPrefix("精确翻译完成"))
    }
}
