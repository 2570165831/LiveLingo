import Darwin
import Foundation

/// Replaces only the CLI entry point. AppModel uses injected dependencies, an
/// isolated stopped review queue and no background services, models or audio.
@main
@MainActor
struct CLITranslationFailureTests {
    @MainActor private static var preferenceCleanups: [TestPreferenceCleanup] = []

    @MainActor private static func cleanPreferences() throws {
        while let cleanup = preferenceCleanups.last {
            try cleanup.remove()
            preferenceCleanups.removeLast()
        }
    }
    struct Failure: Error { let check: String }
    typealias Reason = TranscriptSegment.TranslationFailureReason

    // Expected wire values must be literals, never generated from today's enum.
    static let frozenReasons = ["cancelled", "dependencyCancelled", "generationInterrupted", "interrupted",
        "invalidResponse", "outputLimitReached", "processExited", "requestFailed", "requestTimedOut",
        "runtimeUnavailable", "translationRejected", "unknown"]
    static let source = "The room is cold."
    static let target = "房间很冷。"
    static let laterSource = "A bell rings."
    static let laterTarget = "钟响了。"
    static let privateError = "PRIVATE_ERROR_TEXT"
    static let captionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let pendingJSON = #"{"chinese":"","endTime":1,"english":"The room is cold.","id":"00000000-0000-0000-0000-000000000001","inputRevision":0,"sessionID":"00000000-0000-0000-0000-000000000002","startTime":0,"translationState":"pending"}"#
    static let completedJSON = #"{"chinese":"房间很冷。","endTime":1,"english":"The room is cold.","id":"00000000-0000-0000-0000-000000000001","inputRevision":0,"sessionID":"00000000-0000-0000-0000-000000000002","startTime":0,"translationState":"completed"}"#

    static func expect(_ value: Bool, _ check: String) throws {
        if !value { throw Failure(check: check) }
    }

    static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func eventJSON(_ event: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
    }

    static func captions() -> [TranscriptSegment] {
        [.init(id: captionID, startTime: 0, endTime: 1, english: source, sessionID: sessionID),
         .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, startTime: 4, endTime: 5,
               english: laterSource, sessionID: sessionID)]
    }

    @MainActor final class Capture {
        var names: [String] = []
        var fields: [[String: Any]] = []
        var events: [[String: Any]] = []
        var cancelled: [Bool] = []

        func report(_ name: String, _ fields: [String: Any]) {
            names.append(name)
            self.fields.append(fields)
            cancelled.append(Task.isCancelled)
            // This is the same reporter-to-whitelist boundary as the real CLI.
            events.append(LiveLingoCLI.safeEvent(name, fields: fields, elapsed: 0.5))
        }

        func expectFrozen(_ frozen: [String], _ check: String) throws {
            try CLITranslationFailureTests.expect(names == Array(repeating: "translation_failure", count: frozen.count), check + "_names")
            try CLITranslationFailureTests.expect(!cancelled.contains(true), check + "_worker_still_active")
            try CLITranslationFailureTests.expect(events.count == frozen.count, check + "_count")
            for index in events.indices {
                try CLITranslationFailureTests.expect(Set(fields[index].keys) == ["translationFailureReason", "translationFailureCount"], check + "_reporter_keys")
                try CLITranslationFailureTests.expect(type(of: fields[index]["translationFailureCount"]!) == Int.self, check + "_reporter_integer")
                try CLITranslationFailureTests.expect(try CLITranslationFailureTests.eventJSON(events[index]) == frozen[index], check + "_bytes")
            }
        }
    }

    static func newTestDirectory() throws -> URL {
        try expect(CommandLine.arguments.count <= 2, "optional_new_test_directory_only")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let directory = CommandLine.arguments.count == 2
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
            : executable.deletingLastPathComponent().appendingPathComponent("cli-translation-failure-" + UUID().uuidString, isDirectory: true)
        let parent = directory.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        try expect(directory.resolvingSymlinksInPath().path == directory.path
            && FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory)
            && isDirectory.boolValue, "test_directory_requires_existing_canonical_parent")
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure(check: "requires_new_test_directory") }
        return directory
    }

    static func fixture(_ dependencies: CaptionTranslationDependencies, root: URL, name: String) async throws -> AppModel {
        let suite = "LiveLingo-Test-" + UUID().uuidString
        let cleanup = try TestPreferenceCleanup(suite: suite)
        preferenceCleanups.append(cleanup)
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(check: "isolated_preferences_unavailable")
        }
        defaults.setVolatileDomain(["LiveLingo.modelMode": ModelMode.energySaver.rawValue], forName: UserDefaults.argumentDomain)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent(name + "-queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                throw QwenRuntimeError.runtimeUnavailable
            }
        await queue.shutdownForTesting()
        let pipeline = SpeechPipeline(transcriber: { _, _, _, _ in throw QwenRuntimeError.runtimeUnavailable },
            enableAudioAnalysis: false, enableMicrophoneWatchdog: false)
        return AppModel(reviewQueue: queue, pipeline: pipeline, translation: dependencies, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
    }

    static func testFrozenPersistence() throws {
        try expect(Reason.allCases.map(\.rawValue).sorted() == frozenReasons, "frozen_reason_strings")
        var caption = captions()[0]
        try expect(try encoded(caption) == pendingJSON, "frozen_normal_english_pending_bytes")
        caption.beginTranslation()
        caption.recordTranslationFailure(.processExited)
        caption.recordTranslationFailure(.dependencyCancelled)
        caption.recordTranslationFailure(.dependencyCancelled)
        caption.finishFailedTranslation()
        let frozen = #"{"chinese":"","endTime":1,"english":"The room is cold.","id":"00000000-0000-0000-0000-000000000001","inputRevision":0,"sessionID":"00000000-0000-0000-0000-000000000002","startTime":0,"translationFailures":[{"count":1,"reason":"processExited"},{"count":2,"reason":"dependencyCancelled"}],"translationState":"failed"}"#
        try expect(try encoded(caption) == frozen, "frozen_two_reason_trail_bytes")
        let loaded = try JSONDecoder().decode(TranscriptSegment.self, from: Data(frozen.utf8))
        try expect(try encoded(loaded) == frozen, "frozen_trail_round_trip")
        let legacyJSON = #"[{"count":1,"reason":"cancelled"},{"count":2,"reason":"interrupted"}]"#
        let legacy = try JSONDecoder().decode([TranscriptSegment.TranslationFailure].self, from: Data(legacyJSON.utf8))
        try expect(legacy.map(\.reason.rawValue) == ["cancelled", "interrupted"], "legacy_reason_strings_readable")
        try expect(try encoded(legacy) == legacyJSON, "legacy_reason_json_round_trip")
    }

    static func testEventAllowlist() throws {
        for raw in frozenReasons {
            try expect(Reason(rawValue: raw) != nil, "frozen_reason_readable")
            let fields: [String: Any] = ["translationFailureReason": raw, "translationFailureCount": 3,
                "message": privateError, "text": "PRIVATE_SOURCE_TEXT", "path": "/PRIVATE_PATH",
                "segments": 8, "sessionID": sessionID.uuidString, "summaryRunning": true]
            let event = LiveLingoCLI.safeEvent("translation_failure", fields: fields, elapsed: 0.5)
            try expect(event["translationFailureCount"].map { type(of: $0) == Int.self } == true, "native_integer_count")
            try expect(try eventJSON(event) ==
                #"{"event":"translation_failure","translationFailureCount":3,"translationFailureReason":"\#(raw)"}"#,
                "frozen_failure_event_bytes")
        }
        let eventOnly = #"{"event":"translation_failure"}"#
        for count in [true, false, -1, 0, 1.0, "1", NSNumber(value: 1), [1]] as [Any] {
            let event = LiveLingoCLI.safeEvent("translation_failure", fields:
                ["translationFailureReason": "processExited", "translationFailureCount": count], elapsed: 0)
            try expect(try eventJSON(event) == eventOnly, "reject_non_integer_or_non_positive_count")
        }
        for reason in [privateError, "futureReason", 1, true, ["processExited"]] as [Any] {
            let event = LiveLingoCLI.safeEvent("translation_failure", fields:
                ["translationFailureReason": reason, "translationFailureCount": 1], elapsed: 0)
            try expect(try eventJSON(event) == eventOnly, "reject_non_enum_reason")
        }
        let missingFields: [[String: Any]] = [[:], ["translationFailureReason": "processExited"], ["translationFailureCount": 1]]
        for fields in missingFields {
            try expect(try eventJSON(LiveLingoCLI.safeEvent("translation_failure", fields: fields, elapsed: 0)) == eventOnly,
                "reason_and_count_required_together")
        }
        let normal = LiveLingoCLI.safeEvent("state", fields: ["segments": 1, "translated": 1, "summarized": 0,
            "otherLanguageTranscription": 0, "translationFailureReason": "processExited", "translationFailureCount": 2], elapsed: 1.25)
        try expect(try eventJSON(normal) ==
            #"{"elapsedSeconds":1.25,"event":"state","otherLanguageTranscription":0,"segments":1,"summarized":0,"translated":1}"#,
            "frozen_normal_english_event_bytes")
    }

    static func testSuccessfulEnglish(root: URL) async throws {
        var calls = 0, retries = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { text, _, hints, attempt, update in
            calls += 1
            try expect(text == source && hints.isEmpty && attempt == .standard, "unchanged_english_request")
            await update?(target)
            return target
        }
        dependencies.retrySleep = { _ in retries += 1 }
        dependencies.prepareRetry = { _ in retries += 1 }
        let model = try await fixture(dependencies, root: root, name: "success")
        let capture = Capture()
        await model.cliTranslateForTesting([captions()[0]], report: capture.report)
        try capture.expectFrozen([], "normal_success_has_no_failure_event")
        try expect(calls == 1 && retries == 0 && model.segments.count == 1, "successful_english_one_request")
        try expect(try encoded(model.segments[0]) == completedJSON, "frozen_successful_english_bytes")
    }

    static func testRuntimeFailureWiring(root: URL) async throws {
        var calls: [String] = [], firstAttempts = 0, sleeps = 0, preparations = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { text, _, _, _, _ in
            calls.append(text)
            if text == source {
                firstAttempts += 1
                if firstAttempts <= 2 { throw QwenRuntimeError.requestFailed(privateError) }
                return target
            }
            return laterTarget
        }
        dependencies.retrySleep = { _ in sleeps += 1 }
        dependencies.prepareRetry = { _ in preparations += 1 }
        let model = try await fixture(dependencies, root: root, name: "runtime-failure")
        let capture = Capture()
        await model.cliTranslateForTesting(captions(), report: capture.report)
        try capture.expectFrozen([
            #"{"event":"translation_failure","translationFailureCount":1,"translationFailureReason":"requestFailed"}"#,
            #"{"event":"translation_failure","translationFailureCount":2,"translationFailureReason":"requestFailed"}"#
        ], "appmodel_runtime_failure_reporter")
        try expect(calls == [source, source, laterSource, source] && sleeps == 1 && preparations == 1,
            "bounded_runtime_retry_then_queue_recovery")
        try expect(model.segments.count == 2 && model.segments.allSatisfy(\.hasUsableTranslation), "runtime_failure_recovers")
        try expect(model.segments[0].translationFailures == [.init(reason: .requestFailed, count: 2)], "runtime_trail_count")
        let bytes = try encoded(model.segments[0])
        try expect(model.segments[0].translationError == nil && !bytes.contains(privateError),
            "runtime_diagnostic_text_not_persisted")
    }

    static func testDependencyCancellation(root: URL, persistent: Bool) async throws {
        var calls: [String] = [], firstAttempts = 0, retries = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { text, _, _, _, _ in
            calls.append(text)
            try expect(!Task.isCancelled, "dependency_error_does_not_cancel_worker")
            if text == source {
                firstAttempts += 1
                if persistent || firstAttempts == 1 { throw CancellationError() }
                return target
            }
            return laterTarget
        }
        dependencies.retrySleep = { _ in retries += 1 }
        dependencies.prepareRetry = { _ in retries += 1 }
        let model = try await fixture(dependencies, root: root, name: persistent ? "persistent-cancellation" : "dependency-cancellation")
        let capture = Capture()
        await model.cliTranslateForTesting(captions(), report: capture.report)
        var frozen = [#"{"event":"translation_failure","translationFailureCount":1,"translationFailureReason":"dependencyCancelled"}"#]
        if persistent {
            frozen.append(#"{"event":"translation_failure","translationFailureCount":2,"translationFailureReason":"dependencyCancelled"}"#)
        }
        try capture.expectFrozen(frozen, persistent ? "persistent_dependency_reporter" : "dependency_recovery_reporter")
        try expect(calls == [source, laterSource, source] && retries == 0, "dependency_cancellation_bounded_queue_retry")
        try expect(!Task.isCancelled && model.segments.count == 2 && model.segments[1].hasUsableTranslation,
            "dependency_cancellation_preserves_remaining_queue")
        try expect(model.segments[0].translationState == (persistent ? .failed : .completed), "dependency_final_state")
        try expect(model.segments[0].translationFailures == [.init(reason: .dependencyCancelled, count: persistent ? 2 : 1)],
            "dependency_trail_uses_new_reason")
        try expect(model.segments[0].translationError == nil, "dependency_error_text_absent")
    }

    static func testActualWorkerCancellation(root: URL) async throws {
        var calls = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { _, _, _, _, _ in
            calls += 1
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
            return target
        }
        let model = try await fixture(dependencies, root: root, name: "worker-cancellation")
        let capture = Capture()
        await model.cliTranslateForTesting([captions()[0]], report: capture.report)
        try capture.expectFrozen([], "actual_worker_cancellation_has_no_failure_event")
        try expect(calls == 1 && !Task.isCancelled && model.segments.count == 1, "worker_cancellation_is_owned")
        try expect(try encoded(model.segments[0]) == pendingJSON, "cancelled_worker_adds_no_persisted_failure")
    }

    static func main() async {
        var passed: [String] = []
        do {
            let root = try newTestDirectory()
            let previousTesting = ProcessInfo.processInfo.environment["LIVELINGO_UNIT_TESTING"]
            try expect(setenv("LIVELINGO_UNIT_TESTING", "1", 1) == 0, "unit_test_environment")
            defer {
                if let previousTesting { setenv("LIVELINGO_UNIT_TESTING", previousTesting, 1) }
                else { unsetenv("LIVELINGO_UNIT_TESTING") }
            }
            try testFrozenPersistence(); passed.append("frozen_persistence")
            try testEventAllowlist(); passed.append("event_allowlist")
            try await testSuccessfulEnglish(root: root); passed.append("successful_english")
            try await testRuntimeFailureWiring(root: root); passed.append("appmodel_runtime_failure_wiring")
            try await testDependencyCancellation(root: root, persistent: false); passed.append("dependency_cancellation_recovery")
            try await testDependencyCancellation(root: root, persistent: true); passed.append("persistent_dependency_cancellation")
            try await testActualWorkerCancellation(root: root); passed.append("actual_worker_cancellation")
            try expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "no_review_or_session_files_written")
            try cleanPreferences()
            LiveLingoCLI.writeEvent(["event": "translation_failure_cli_tests_passed", "groups": passed.count])
        } catch let failure as Failure {
            do { try cleanPreferences() }
            catch { LiveLingoCLI.writeEvent(["event": "test_preference_cleanup_failed"], to: .standardError) }
            LiveLingoCLI.writeEvent(["event": "translation_failure_cli_tests_failed", "check": failure.check], to: .standardError)
            exit(1)
        } catch {
            do { try cleanPreferences() }
            catch { LiveLingoCLI.writeEvent(["event": "test_preference_cleanup_failed"], to: .standardError) }
            LiveLingoCLI.writeEvent(["event": "translation_failure_cli_tests_failed", "check": "unexpected_error"], to: .standardError)
            exit(1)
        }
    }
}
