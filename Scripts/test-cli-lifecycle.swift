import Foundation
import AVFoundation
import CryptoKit
import Darwin

/// Uses only synthetic exports and a standard-library Python pipe worker.
/// No AppModel, real review queue, audio device or model weights are opened.
@main struct CLILifecycleTests {
    struct Failure: Error { let name: String }
    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure(name: name) }
    }
    static func rejects(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(name: name)
    }
    static func wav(at directory: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.floatChannelData![0].initialize(repeating: 0, count: 160)
        let audio = try AVAudioFile(forWriting: directory.appendingPathComponent("recording.wav"), settings: format.settings)
        try audio.write(from: buffer)
    }
    static func fixture(_ root: URL, _ name: String, segments: [TranscriptSegment]) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try wav(at: directory)
        try SessionExporter.export(segments: segments, sessionDirectory: directory)
        return directory
    }
    static func fileBytes(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            result[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return result
    }

    @MainActor static func main() async {
        var passed: [String] = []
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure(name: "requires_new_evidence_directory") }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            guard !FileManager.default.fileExists(atPath: root.path) else { throw Failure(name: "evidence_exists") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let secret = "PRIVATE_CLASSROOM_TEXT_不要写入常规日志"
            let safe = LiveLingoCLI.safeEvent("state", fields: ["summaryStatus": secret, "message": secret,
                "phase": secret, "file": secret, "name": secret, "error": secret, "reason": secret,
                "sessionID": secret, "kind": secret, "format": secret, "segments": 7,
                "translated": 2, "summaryRunning": true, "unknown": ["prompt": secret]], elapsed: 1.25)
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: safe), as: UTF8.self)
            try expect(!encoded.contains(secret), "event_redacts_text")
            try expect(safe["segments"] as? Int == 7 && safe["translated"] as? Int == 2, "event_keeps_counts")
            try expect(safe["sessionID"] == nil && safe["kind"] == nil, "event_validates_identifiers")
            try expect(LiveLingoCLI.safeEvent("finished", fields: [:], elapsed: 0)["event"] as? String == "processing_finished", "finish_is_not_verification")
            passed.append("event_allowlist")
            let failure = LiveLingoCLI.safeFailure(QwenRuntimeError.requestFailed(secret))
            let failureText = String(decoding: try JSONSerialization.data(withJSONObject: failure), as: UTF8.self)
            try expect(!failureText.contains(secret), "error_redacts_model_text")
            passed.append("error_redaction")

            let missing = TranscriptSegment(startTime: 0, endTime: 0.01, english: "Synthetic speech", chinese: "[翻译失败：" + secret + "]")
            let exported = try fixture(root, "missing-translation", segments: [missing])
            let before = try fileBytes(exported)
            let count = try LiveLingoCLI.verifySaved(exported, emit: false)
            try expect(count == 1, "missing_translation_is_valid_export")
            let after = try fileBytes(exported)
            try expect(before == after, "verify_does_not_write")
            passed.append("missing_translation_and_read_only_verify")
            var failed = TranscriptSegment(startTime: 0, endTime: 0.01, english: "New failure state")
            failed.failTranslation(secret)
            let failedDirectory = try fixture(root, "structured-failure", segments: [failed])
            try expect(try LiveLingoCLI.verifySaved(failedDirectory, emit: false) == 1, "structured_failure_matches_exporter")
            passed.append("structured_translation_failure")
            let empty = try fixture(root, "zero-captions", segments: [])
            let emptyBefore = try fileBytes(empty)
            try expect(try LiveLingoCLI.verifySaved(empty, emit: false) == 0, "zero_captions_preserve_valid_audio")
            try expect(try fileBytes(empty) == emptyBefore, "zero_caption_verify_read_only")
            passed.append("zero_captions")
            let identity = UUID()
            func state(pending: Int = 0, unresolved: Int = 0, sessionID: UUID? = nil) -> TranscriptionProcessingState {
                .init(sessionID: sessionID ?? identity, isCapturing: false, isPaused: false,
                      activeCount: 0, pendingCount: pending, backlogSeconds: 0, unresolvedCount: unresolved)
            }
            let complete = TranscriptSegment(startTime: 0, endTime: 0.01, english: "Synthetic", chinese: "合成", sessionID: identity)
            var snapshot = SessionSnapshot(sessionID: identity, segments: [complete])
            try LiveLingoCLI.verifyProcessing(state: state(), snapshot: snapshot, segmentCount: 1)
            try rejects("pending_transcription_not_complete") {
                try LiveLingoCLI.verifyProcessing(state: state(pending: 1), snapshot: snapshot, segmentCount: 1)
            }
            try rejects("unresolved_candidate_not_complete") {
                try LiveLingoCLI.verifyProcessing(state: state(unresolved: 1), snapshot: snapshot, segmentCount: 1)
            }
            try rejects("foreign_session_not_complete") {
                try LiveLingoCLI.verifyProcessing(state: state(sessionID: UUID()), snapshot: snapshot, segmentCount: 1)
            }
            snapshot.processing.pendingSegmentIDs = [complete.id]
            try rejects("missing_translation_not_complete") {
                try LiveLingoCLI.verifyProcessing(state: state(), snapshot: snapshot, segmentCount: 1)
            }
            snapshot.processing.pendingSegmentIDs = []
            snapshot.processing.captureError = "Synthetic interruption"
            try rejects("capture_error_not_complete") {
                try LiveLingoCLI.verifyProcessing(state: state(), snapshot: snapshot, segmentCount: 1)
            }
            snapshot.processing.captureError = nil
            snapshot.segments = []
            do {
                try LiveLingoCLI.verifyProcessing(state: state(), snapshot: snapshot, segmentCount: 0)
                throw Failure(name: "no_captions_should_fail_full_run")
            } catch LiveLingoCLI.CLIError.noCaptions { }
            passed.append("processing_completion_separate_from_integrity")
            let corrupt = try fixture(root, "bad-srt", segments: [missing])
            try "wrong\n".write(to: corrupt.appendingPathComponent("bilingual.srt"), atomically: true, encoding: .utf8)
            try rejects("corrupt_srt_rejected") { try LiveLingoCLI.verifySaved(corrupt, emit: false) }
            passed.append("corrupt_srt")
            let bytes = Data(repeating: 0x6b, count: 2_300_017)
            let digestFile = root.appendingPathComponent("hash-input.bin")
            try bytes.write(to: digestFile)
            let digest = try LiveLingoCLI.hashFile(digestFile)
            try expect(digest.bytes == bytes.count && digest.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "streamed_hash")
            passed.append("streamed_hash")

            // Save/restore only these keys; never log the process environment.
            let keys = ["LIVELINGO_ASR_ENDPOINT", "LIVELINGO_ASR_TOKEN", "LIVELINGO_PREFERENCES_SUITE",
                "LIVELINGO_DATA_DIRECTORY", "LIVELINGO_MLX_STATE", "LIVELINGO_MLX_PYTHON",
                "LIVELINGO_MLX_WORKER", "LIVELINGO_MLX_MODELS"]
            let old = ProcessInfo.processInfo.environment.filter { keys.contains($0.key) }
            defer { for key in keys { if let value = old[key] { setenv(key, value, 1) } else { unsetenv(key) } } }
            for key in keys { unsetenv(key) }
            let rejected = root.appendingPathComponent("foreign-endpoint")
            setenv("LIVELINGO_ASR_ENDPOINT", "http://127.0.0.1:18765", 1)
            try rejects("foreign_endpoint_rejected") { try LiveLingoCLI.configureIsolation(output: rejected) }
            try expect(!FileManager.default.fileExists(atPath: rejected.path), "foreign_endpoint_no_side_effect")
            unsetenv("LIVELINGO_ASR_ENDPOINT")
            passed.append("foreign_endpoint_rejected_before_writes")
            try rejects("existing_output_preserved") { try LiveLingoCLI.configureIsolation(output: empty) }
            try expect(try fileBytes(empty) == emptyBefore, "existing_output_unchanged")
            passed.append("existing_output_preserved")
            let link = root.appendingPathComponent("dangling-output")
            let target = root.appendingPathComponent("unclaimed-link-target")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try rejects("symlink_output_rejected") { try LiveLingoCLI.configureIsolation(output: link) }
            try expect(!FileManager.default.fileExists(atPath: target.path), "symlink_target_not_created")
            passed.append("symlink_output_preserved")
            let isolated = try LiveLingoCLI.configureIsolation(output: root.appendingPathComponent("isolated-run"))
            let current = ProcessInfo.processInfo.environment
            try expect(current["LIVELINGO_PREFERENCES_SUITE"]?.hasPrefix("com.jianhongli.LiveLingo.CLI.") == true, "unique_preferences")
            try expect(current["LIVELINGO_DATA_DIRECTORY"] == isolated.appendingPathComponent(".cli-runtime/data").path, "isolated_data")
            try expect(current["LIVELINGO_MLX_STATE"] == isolated.appendingPathComponent(".cli-runtime/checkpoints").path, "isolated_checkpoints")
            passed.append("independent_runtime_paths")

            // A fake worker exercises actual pipes, request ACKs and child exit.
            // It imports no inference package and receives no real model files.
            let fake = root.appendingPathComponent("fake-worker.py")
            try fakeWorker.write(to: fake, atomically: true, encoding: .utf8)
            let models = root.appendingPathComponent("fake-models")
            let model = models.appendingPathComponent("mlx-community/Qwen3.5-4B-MLX-8bit")
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            for name in ["config.json", "tokenizer.json"] { try Data("{}".utf8).write(to: model.appendingPathComponent(name)) }
            setenv("LIVELINGO_MLX_PYTHON", "/opt/homebrew/bin/python3", 1)
            setenv("LIVELINGO_MLX_WORKER", fake.path, 1)
            setenv("LIVELINGO_MLX_MODELS", models.path, 1)
            let result = try await MLXRuntime.shared.generate(model: "qwen3.5-4b-mlx", prompt: "synthetic",
                input: "success", prefix: "", thinking: false, purpose: "text", finalBudget: 8, timeout: 10, onUpdate: { _ in })
            try expect(result == "synthetic result", "fake_generation_completed")
            let firstWorkers = await MLXRuntime.shared.resourceStates()
            try expect(firstWorkers.count == 1, "fake_worker_owned")
            try expect(await LiveLingoCLI.cleanupOwnedRuntimes(), "successful_run_cleanup")
            for state in firstWorkers.values { try expect(kill(state.processIdentifier, 0) == -1 && errno == ESRCH, "owned_worker_exited") }
            passed.append("actual_fake_worker_success_cleanup")

            do {
                _ = try await MLXRuntime.shared.generate(model: "qwen3.5-4b-mlx", prompt: "synthetic", input: "failure",
                    prefix: "", thinking: false, purpose: "text", finalBudget: 8, timeout: 10, onUpdate: { _ in })
                throw Failure(name: "fake_failure_expected")
            } catch is QwenRuntimeError { }
            try expect(await LiveLingoCLI.cleanupOwnedRuntimes(), "failed_run_cleanup")
            passed.append("actual_fake_worker_failure_cleanup")
            let generation = Task { @MainActor in
                try await MLXRuntime.shared.generate(model: "qwen3.5-4b-mlx", prompt: "synthetic", input: "hold",
                    prefix: "", thinking: false, purpose: "learning", finalBudget: 8, timeout: 10, onUpdate: { _ in })
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !(await MLXRuntime.shared.resourceStates()).values.contains(where: { $0.modelLoaded }) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(name: "fake_worker_did_not_start") }
                try await Task.sleep(for: .milliseconds(20))
            }
            generation.cancel()
            do { _ = try await generation.value; throw Failure(name: "cancellation_expected") }
            catch is CancellationError { }
            try expect(await LiveLingoCLI.cleanupOwnedRuntimes(), "cancelled_run_cleanup")
            try expect(FileManager.default.fileExists(atPath: isolated.appendingPathComponent(".cli-runtime/checkpoints/4b/synthetic-checkpoint.json").path), "cancelled_progress_retained")
            passed.append("actual_fake_worker_cancel_cleanup")
            // Internal acceptance entries. All of this is synthetic: no AppModel,
            // no model runtime, no audio device and no classroom text.
            var stepName = "argument_grammar"
            do {
            try expect(try LiveLingoCLI.parse(["--help"]) == .help, "help_parses")
            try expect(try LiveLingoCLI.parse(["--open-saved", "/tmp/x"]) == .openSaved("/tmp/x"), "open_saved_parses")
            try expect(try LiveLingoCLI.parse(["--resume-saved", "/tmp/x", "--high-quality", "--export-notes", "--run-review"])
                == .resumeSaved(path: "/tmp/x", highQuality: true, exportNotes: true, runReview: true), "resume_saved_parses")
            try expect(try LiveLingoCLI.parse(["--replay", "/tmp/a.wav", "--output", "/tmp/o", "--import", "--export-notes"])
                == .generate(LiveLingoCLI.GenerateCommand(source: .replay("/tmp/a.wav"), output: "/tmp/o",
                    highQuality: false, fileImport: true, exportNotes: true, runReview: false)), "generate_parses")
            for (name, arguments) in [
                ("open_rejects_review", ["--open-saved", "/tmp/x", "--run-review"]),
                ("open_rejects_exports", ["--open-saved", "/tmp/x", "--export-notes"]),
                ("open_rejects_output", ["--open-saved", "/tmp/x", "--output", "/tmp/o"]),
                ("resume_rejects_output", ["--resume-saved", "/tmp/x", "--output", "/tmp/o"]),
                ("resume_rejects_import", ["--resume-saved", "/tmp/x", "--import"]),
                ("two_modes_rejected", ["--replay", "/tmp/a.wav", "--output", "/tmp/o", "--open-saved", "/tmp/x"]),
                ("missing_mode_value", ["--open-saved"]),
                ("missing_output", ["--replay", "/tmp/a.wav"]),
                ("duplicate_option", ["--replay", "/tmp/a.wav", "--output", "/tmp/o", "--output", "/tmp/p"]),
                ("duplicate_switch", ["--replay", "/tmp/a.wav", "--output", "/tmp/o", "--import", "--import"]),
                ("import_without_replay", ["--system-audio", "5", "--output", "/tmp/o", "--import"]),
                ("verify_rejects_flags", ["--verify-saved", "/tmp/x", "--high-quality"]),
                ("translate_rejects_review", ["--translate-text", "hello", "--run-review"]),
                ("zero_seconds", ["--system-audio", "0", "--output", "/tmp/o"]),
                ("too_many_seconds", ["--system-audio", "3601", "--output", "/tmp/o"]),
                ("unknown_flag", ["--replay", "/tmp/a.wav", "--output", "/tmp/o", "--unknown"]),
                ("mode_value_is_flag", ["--open-saved", "--run-review"])] {
                try rejects(name) { _ = try LiveLingoCLI.parse(arguments) }
            }
            try expect(try LiveLingoCLI.parse(["--system-audio", "5", "--output", "/tmp/o"])
                == .generate(LiveLingoCLI.GenerateCommand(source: .systemAudio(5), output: "/tmp/o",
                    highQuality: false, fileImport: false, exportNotes: false, runReview: false)), "system_audio_parses")
            passed.append("cli_argument_grammar_is_unambiguous")
            stepName = "isolation_marker"

            // Isolation identity: only a checksummed, self-consistent marker may
            // be reopened, and only from a directory this CLI isolated.
            // Distinct from the process-level restart fixtures below, which
            // reuse the same names with a different session identity.
            let course = root.appendingPathComponent("identity-course")
            try FileManager.default.createDirectory(at: course.appendingPathComponent(".cli-runtime/data", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: course.appendingPathComponent(".cli-runtime/checkpoints", isDirectory: true), withIntermediateDirectories: true)
            let markerURL = course.appendingPathComponent(".cli-runtime/run.json")
            let runID = UUID()
            let marker = try LiveLingoCLI.newMarker(directory: course, runID: runID, source: .pending)
            try LiveLingoCLI.writeMarker(marker, directory: course)
            try expect(try LiveLingoCLI.readMarker(course) == marker, "marker_roundtrip")
            try expect(try LiveLingoCLI.readMarker(course).session == nil, "unbound_marker_has_no_session")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var tampered = marker; tampered.data = ".cli-runtime/elsewhere"
            try encoder.encode(tampered).write(to: markerURL)
            try rejects("tampered_marker_rejected") { _ = try LiveLingoCLI.readMarker(course) }
            var relabeled = marker; relabeled.runID = UUID().uuidString
            try encoder.encode(relabeled).write(to: markerURL)
            try rejects("relabeled_run_rejected") { _ = try LiveLingoCLI.readMarker(course) }
            try Data("{\"runID\":\"\(runID.uuidString)\",\"preferencesSuite\":\"legacy\"}".utf8).write(to: markerURL)
            do { _ = try LiveLingoCLI.readMarker(course); throw Failure(name: "legacy_marker_accepted") }
            catch LiveLingoCLI.CLIError.legacyMarkerUnsupported { }
            try LiveLingoCLI.writeMarker(marker, directory: course)
            let markerBytes = try Data(contentsOf: markerURL)
            try rejects("foreign_app_target_rejected") { try LiveLingoCLI.validateReopenTarget(URL(fileURLWithPath: "/Applications/LiveLingo.app", isDirectory: true)) }
            try rejects("system_target_rejected") { try LiveLingoCLI.validateReopenTarget(URL(fileURLWithPath: "/System/Library", isDirectory: true)) }
            try rejects("user_support_target_rejected") { try LiveLingoCLI.validateReopenTarget(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveLingo", isDirectory: true)) }
            let bundleCourse = root.appendingPathComponent("SyntheticBundle.app/Session")
            try FileManager.default.createDirectory(at: bundleCourse, withIntermediateDirectories: true)
            try rejects("bundle_target_rejected") { try LiveLingoCLI.validateReopenTarget(bundleCourse) }
            try LiveLingoCLI.validateReopenTarget(course)
            var missingIsolation = marker; missingIsolation.checkpoints = ".cli-runtime/other-checkpoints"
            try rejects("missing_isolation_rejected") { try LiveLingoCLI.applyMarkerIsolation(missingIsolation, directory: course) }
            try expect(try Data(contentsOf: markerURL) == markerBytes, "marker_untouched_by_refusals")
            passed.append("isolation_marker_binding")
            stepName = "session_binding"

            // Bound session state: rewrite, loss and identity drift must fail.
            let boundSession = UUID()
            var first = TranscriptSegment(startTime: 0, endTime: 1, english: "First synthetic caption", sessionID: boundSession)
            first.chinese = "第一段合成译文"
            var second = TranscriptSegment(startTime: 1, endTime: 2, english: "Second synthetic caption", sessionID: boundSession)
            second.chinese = "第二段合成译文"
            let third = TranscriptSegment(startTime: 2, endTime: 3, english: "Third synthetic caption", sessionID: boundSession)
            let boundSegments = [first, second, third]
            let note = LearningNote(topic: "合成主题", points: [LearningPoint(kind: "核心结论", text: "合成要点。")])
            let batch = LearningNoteBatch(id: UUID(), evidence: [first, second], note: note)
            var boundSnapshot = SessionSnapshot(sessionID: boundSession, segments: boundSegments, batches: [batch])
            boundSnapshot.latestEvidenceIDs = [first.id, second.id]
            boundSnapshot.processing.phase = .completed
            try wav(at: course)
            _ = try SessionStore(directory: course).save(boundSnapshot)
            let bound = try LiveLingoCLI.bindSession(directory: course, source: .pending)
            try expect(bound.sessionID == boundSession.uuidString && bound.segmentIDs.count == 3, "binding_records_identity")
            try expect(bound.completedIDs.count == 2 && bound.batchIDs == [batch.id.uuidString], "binding_records_progress")
            try expect(try LiveLingoCLI.readMarker(course).session == bound, "binding_is_persisted")
            let notes = batch.note.markdown

            func observation(paused: Bool = true, phase: SessionProcessingState.Phase = .paused,
                             segments: [TranscriptSegment]? = nil, batches: [LearningNoteBatch]? = nil,
                             revision: Int? = nil, candidates: Int = 0, reviewWork: Bool = false,
                             frames: Int? = nil, capture: Bool = false, archiveError: Bool = false,
                             workers: Int = 0, translated: Int = 2, summarized: Int = 2,
                             transcription: Bool = true,
                             notes overrideNotes: String? = nil) -> LiveLingoCLI.CLIObservedSession {
                var snapshot = boundSnapshot
                snapshot.segments = segments ?? boundSegments
                snapshot.batches = batches ?? [batch]
                snapshot.inputRevision = revision ?? bound.inputRevision
                snapshot.processing.phase = phase
                snapshot.processing.paused = paused
                if phase != .completed { snapshot.processing.pendingSegmentIDs = [third.id] }
                return LiveLingoCLI.CLIObservedSession(
                    sessionID: (segments ?? boundSegments).first?.sessionID ?? boundSession,
                    snapshot: snapshot, notes: overrideNotes ?? notes, processingPaused: paused,
                    captureActive: capture,
                    transcription: transcription ? TranscriptionProcessingState(
                        sessionID: (segments ?? boundSegments).first?.sessionID ?? boundSession,
                        isCapturing: capture, isPaused: paused, activeCount: 0, pendingCount: 0,
                        backlogSeconds: 0, unresolvedCount: 0) : nil,
                    candidates: candidates, reviewHasWork: reviewWork, reviewRunning: false,
                    reviewFailure: nil, summarizedCount: summarized, translatedCount: translated,
                    pendingWorkers: workers, archiveErrorPresent: archiveError,
                    journalIncompleteTailBytes: 0, exportPaths: [], exports: [],
                    audioFrames: frames ?? bound.audioFrames, audioSampleRate: bound.audioSampleRate)
            }
            try LiveLingoCLI.verifyReopened(marker: marker, observed: observation(), bound: bound)
            // A course with no restored transcription queue is still a valid reopen.
            try LiveLingoCLI.verifyReopened(marker: marker, observed: observation(transcription: false), bound: bound)
            var changedSession = boundSegments
            changedSession[0] = TranscriptSegment(id: first.id, startTime: 0, endTime: 1,
                english: "First synthetic caption", chinese: "第一段合成译文", sessionID: UUID())
            for (name, value) in [("reopen_rejects_foreign_session", observation(segments: changedSession)),
                                  ("reopen_rejects_lost_caption", observation(segments: Array(boundSegments.prefix(1)))),
                                  ("reopen_rejects_new_revision", observation(revision: bound.inputRevision + 1)),
                                  ("reopen_rejects_lost_batch", observation(batches: [])),
                                  ("reopen_rejects_changed_audio", observation(frames: bound.audioFrames + 160)),
                                  ("reopen_rejects_running", observation(paused: false)),
                                  ("reopen_rejects_capture", observation(capture: true)),
                                  ("reopen_rejects_candidates", observation(candidates: 1)),
                                  ("reopen_rejects_review_backlog", observation(reviewWork: true)),
                                  ("reopen_rejects_archive_error", observation(archiveError: true)),
                                  ("reopen_rejects_workers", observation(workers: 1))] {
                try rejects(name) { try LiveLingoCLI.verifyReopened(marker: marker, observed: value, bound: bound) }
            }
            var rewritten = boundSegments
            rewritten[0] = TranscriptSegment(id: first.id, startTime: 0, endTime: 1,
                english: "Rewritten caption", chinese: "第一段合成译文", sessionID: boundSession)
            try rejects("reopen_rejects_rewritten_caption") {
                try LiveLingoCLI.verifyReopened(marker: marker, observed: observation(segments: rewritten), bound: bound)
            }
            var retranslated = boundSegments
            retranslated[0] = TranscriptSegment(id: first.id, startTime: 0, endTime: 1,
                english: first.english, chinese: "被改写的译文", sessionID: boundSession)
            try rejects("reopen_rejects_rewritten_translation") {
                try LiveLingoCLI.verifyReopened(marker: marker, observed: observation(segments: retranslated), bound: bound)
            }
            passed.append("bound_reopen_verification")
            stepName = "bound_resume_verification"

            var allTranslated = boundSegments
            allTranslated[2] = TranscriptSegment(id: third.id, startTime: 2, endTime: 3,
                english: third.english, chinese: "第三段合成译文", sessionID: boundSession)
            try LiveLingoCLI.verifyResumed(marker: marker,
                observed: observation(paused: false, phase: .completed, segments: allTranslated), bound: bound)
            try LiveLingoCLI.verifyResumed(marker: marker,
                observed: observation(paused: false, phase: .completed, segments: allTranslated,
                                      transcription: false), bound: bound)
            for (name, value) in [("resume_rejects_paused", observation(paused: true)),
                                  ("resume_rejects_draining", observation(paused: false, phase: .draining)),
                                  ("resume_rejects_notes", observation(paused: false, phase: .completed, summarized: 1)),
                                  ("resume_rejects_empty_notes", observation(paused: false, phase: .completed, notes: " ")),
                                  ("resume_rejects_workers", observation(paused: false, phase: .completed, workers: 2)),
                                  ("resume_rejects_review_backlog", observation(paused: false, phase: .completed, reviewWork: true))] {
                try rejects(name) { try LiveLingoCLI.verifyResumed(marker: marker, observed: value, bound: bound) }
            }
            try rejects("resume_rejects_untranslated") {
                try LiveLingoCLI.verifyResumed(marker: marker,
                    observed: observation(paused: false, phase: .completed, segments: [first, second, third]), bound: bound)
            }
            passed.append("bound_resume_verification")
            stepName = "export_fingerprints"

            // Export fingerprints read real bytes, not reported names.
            func exportFile(_ name: String, _ data: Data) throws -> String {
                let url = root.appendingPathComponent(name)
                try data.write(to: url)
                return url.path
            }
            let four = [try exportFile("synthetic-notes.md", Data("# 学习笔记\n合成\n".utf8)),
                        try exportFile("synthetic-notes.txt", Data("学习笔记\n合成\n".utf8)),
                        try exportFile("synthetic-notes.docx", Data([0x50, 0x4b, 0x03, 0x04, 0x00])),
                        try exportFile("synthetic-notes.pdf", Data("%PDF-1.4\n".utf8))]
            let fingerprints = try LiveLingoCLI.fingerprintExports(four)
            try expect(Set(fingerprints.map(\.fileExtension)) == ["md", "txt", "docx", "pdf"], "four_exports_fingerprinted")
            try expect(fingerprints.allSatisfy { $0.bytes > 0 && !$0.sha256.isEmpty }, "export_fingerprints_hashed")
            let emptyExport = try exportFile("synthetic-empty.md", Data())
            try rejects("empty_export_rejected") { _ = try LiveLingoCLI.fingerprintExports([emptyExport]) }
            let bogusPdf = try exportFile("synthetic-bogus.pdf", Data("not a pdf".utf8))
            try rejects("bogus_pdf_rejected") { _ = try LiveLingoCLI.fingerprintExports([bogusPdf]) }
            let missingHeading = try exportFile("synthetic-no-heading.md", Data("# 别的标题\n".utf8))
            try rejects("export_without_notes_heading_rejected") { _ = try LiveLingoCLI.fingerprintExports([missingHeading]) }
            let emptyCourse = root.appendingPathComponent("no-exports")
            try FileManager.default.createDirectory(at: emptyCourse, withIntermediateDirectories: true)
            try expect(try LiveLingoCLI.exportReadback(emptyCourse) == nil, "absent_exports_are_not_a_verification")
            try Data("{}\n".utf8).write(to: emptyCourse.appendingPathComponent("bilingual.jsonl"))
            try rejects("partial_export_rejected") { _ = try LiveLingoCLI.exportReadback(emptyCourse) }
            passed.append("export_content_fingerprints")
            stepName = "restart_fixtures"

            // Fixtures for the process-level reopen/restart driver. These are
            // synthetic files only: three captions without translations, one
            // bound isolation marker and one short silent recording.
            func makeCourse(_ name: String, captions: [TranscriptSegment], bind: Bool,
                            sessionID: UUID, paused: Bool, legacyMarker: Bool = false) throws -> URL {
                let directory = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(".cli-runtime/data", isDirectory: true), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(".cli-runtime/checkpoints", isDirectory: true), withIntermediateDirectories: true)
                try wav(at: directory)
                var snapshot = SessionSnapshot(sessionID: sessionID, segments: captions)
                snapshot.processing.paused = paused
                snapshot.processing.phase = paused ? .paused : .draining
                _ = try SessionStore(directory: directory).save(snapshot)
                let markerURL = directory.appendingPathComponent(".cli-runtime/run.json")
                if legacyMarker {
                    try Data("{\"runID\":\"\(UUID().uuidString)\",\"preferencesSuite\":\"com.jianhongli.LiveLingo.CLI.legacy\"}".utf8).write(to: markerURL)
                } else {
                    try LiveLingoCLI.writeMarker(try LiveLingoCLI.newMarker(directory: directory, runID: UUID(), source: .pending), directory: directory)
                    if bind { _ = try LiveLingoCLI.bindSession(directory: directory, source: .pending) }
                }
                return directory
            }
            let restartSession = UUID()
            let restartCaptions = (0..<3).map { index in
                TranscriptSegment(startTime: Double(index), endTime: Double(index) + 1,
                                  english: "Synthetic restart caption \(index + 1)", sessionID: restartSession)
            }
            try makeCourse("restart-course", captions: restartCaptions, bind: true,
                           sessionID: restartSession, paused: true)
            try makeCourse("unbound-course", captions: restartCaptions, bind: false,
                           sessionID: restartSession, paused: true)
            try makeCourse("legacy-course", captions: restartCaptions, bind: false,
                           sessionID: restartSession, paused: true, legacyMarker: true)
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("restart-course/.cli-runtime/run.json").path), "restart_fixture_present")
            passed.append("restart_fixtures")
            } catch let failure as Failure { throw failure
            } catch { throw Failure(name: stepName + ":" + String(describing: error)) }
            LiveLingoCLI.writeEvent(["event": "tests_passed", "count": passed.count, "cases": passed])
        } catch {
            _ = await LiveLingoCLI.cleanupOwnedRuntimes()
            if let failure = error as? Failure {
                LiveLingoCLI.writeEvent(["event": "tests_failed", "case": failure.name, "passed": passed], to: .standardError)
            } else { LiveLingoCLI.writeEvent(LiveLingoCLI.safeFailure(error), to: .standardError) }
            Darwin.exit(1)
        }
    }

    static let fakeWorker = #"""
import argparse, json, pathlib, sys
p = argparse.ArgumentParser()
p.add_argument('--model')
p.add_argument('--state-directory')
a = p.parse_args()
def emit(value):
    print(json.dumps(value), flush=True)
emit({'event': 'ready', 'version': 2})
for line in sys.stdin:
    command = json.loads(line)
    op = command['op']
    if op == 'generate':
        emit({'event': 'model_state', 'loaded': True})
        if command['input'] == 'failure':
            emit({'event': 'error', 'id': command['id'], 'recoverable': False, 'message': 'PRIVATE_SYNTHETIC_FAILURE'})
        elif command['input'] != 'hold':
            emit({'event': 'done', 'id': command['id'], 'wire': 'synthetic result', 'text': 'synthetic result'})
    else:
        if op == 'pause':
            state = pathlib.Path(a.state_directory)
            state.mkdir(parents=True, exist_ok=True)
            (state / 'synthetic-checkpoint.json').write_text(json.dumps({'saved': True}))
        emit({'event': 'paused' if op == 'pause' else op, 'controlID': command['controlID'], 'state': 'saved'})
        if op == 'shutdown':
            break
"""#
}
