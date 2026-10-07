import AVFoundation
import Darwin
import Foundation

/// Additional offline regressions; the existing CLI tests remain unchanged.
@main @MainActor
struct CLITargetReviewTests {
    struct Failure: Error { let check: String }
    static func expect(_ value: Bool, _ check: String) throws {
        if !value { throw Failure(check: check) }
    }
    static func rejectsExport(_ directory: URL) throws {
        do { try LiveLingoCLI.verifySaved(directory, emit: false) }
        catch LiveLingoCLI.CLIError.inconsistentExport { return }
        throw Failure(check: "must_report_inconsistent_export")
    }

    static func fixture(_ root: URL, name: String, target: OutputLanguage = .simplifiedChinese,
                        body: String = "Air is clear.", snapshot: Bool = false,
                        recordedTarget: String? = nil) throws -> (URL, TranscriptSegment) {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.floatChannelData![0].initialize(repeating: 0, count: 160)
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("recording.wav"), settings: format.settings)
        try file.write(from: buffer)
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Air is clear.", chinese: body)
        // Stamp a new course before writing derived exports. Creating a
        // non-default snapshot after a legacy export would correctly hit the
        // store's immutable-target guard rather than exercise verification.
        if snapshot {
            try SessionStore(directory: directory).save(SessionSnapshot(segments: [segment], targetLocale: recordedTarget))
        }
        try SessionExporter.export(segments: [segment], sessionDirectory: directory,
            createdAt: Date(timeIntervalSince1970: 0), target: target)
        return (directory, segment)
    }

    static func files(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    static func retentionChecks() throws {
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Air is clear.", chinese: "Clear air.")
        let snapshot = SessionSnapshot(segments: [segment], targetLocale: "en")
        let facts = LiveLingoCLI.fingerprint(from: [segment], batches: [])
        var bound = LiveLingoCLI.CLIRunSession(sessionID: snapshot.sessionID.uuidString, inputRevision: 0,
            segmentIDs: facts.ids, captionDigest: facts.captions, completedIDs: facts.completed,
            completedDigest: facts.completedDigest, batchIDs: facts.batchIDs, batchDigest: facts.batchDigest,
            latestEvidenceIDs: [], audioFrames: 160, audioSampleRate: 16_000, journalIncompleteTailBytes: 0,
            boundAt: "1970-01-01T00:00:00Z", targetLocale: "en")
        var observed = LiveLingoCLI.CLIObservedSession(sessionID: snapshot.sessionID, snapshot: snapshot,
            notes: "", processingPaused: true, captureActive: false, transcription: nil, candidates: 0,
            reviewHasWork: false, reviewRunning: false, reviewFailure: nil, summarizedCount: 0,
            translatedCount: 1, pendingWorkers: 0, archiveErrorPresent: false, journalIncompleteTailBytes: 0,
            exportPaths: [], audioFrames: 160, audioSampleRate: 16_000)
        try LiveLingoCLI.verifyRetention(bound: bound, observed: observed)
        for changed in [Optional<String>.none, "fr", "zh-Hans"] {
            observed.snapshot.targetLocale = changed
            do { try LiveLingoCLI.verifyRetention(bound: bound, observed: observed) }
            catch LiveLingoCLI.CLIError.sessionIdentityMismatch { continue }
            throw Failure(check: "retention_rejects_changed_target")
        }
        bound.targetLocale = nil
        observed.snapshot.targetLocale = "zh-Hans"
        try LiveLingoCLI.verifyRetention(bound: bound, observed: observed)
    }

    static func forwardingChecks(_ root: URL) async throws {
        let output = root.appendingPathComponent("never-created")
        let args = ["--system-audio", "1", "--output", output.path, "--target", "en",
                    "--high-quality", "--export-notes", "--run-review"]
        guard case .generate(let command) = try LiveLingoCLI.parseForTesting(args,
            releasedTargets: [.simplifiedChinese, .english]) else { throw Failure(check: "parsed_generation") }
        var calls = 0
        try await LiveLingoCLI.executeGeneration(command, file: nil, seconds: 1, directory: output,
            runner: { file, seconds, directory, highQuality, paced, exportNotes, runReview, target, _ in
                calls += 1
                try expect(file == nil && seconds == 1 && directory == output, "forwarded_input")
                try expect(highQuality && paced && exportNotes && runReview, "forwarded_options")
                try expect(target == .english && target == command.target, "cli_run_receives_parsed_target")
            }, report: { _, _ in })
        try expect(calls == 1 && !FileManager.default.fileExists(atPath: output.path), "dispatch_without_io")
        do { _ = try LiveLingoCLI.parse(args) }
        catch LiveLingoCLI.CLIError.invalidArguments { return }
        throw Failure(check: "production_release_gate_remains_frozen")
    }

    static func main() async {
        do {
            try expect(CommandLine.arguments.count == 2, "supply_new_evidence_directory")
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
            let work = (ProcessInfo.processInfo.environment["LIVELINGO_CLI_TEST_OUTPUT_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work", isDirectory: true)).standardizedFileURL
            try expect(root.path.hasPrefix(work.path + "/") && root.resolvingSymlinksInPath() == root,
                "evidence_under_source_work")
            try expect(mkdir(root.path, 0o700) == 0, "new_evidence_directory_only")
            var passed: [String] = []

            let (valid, segment) = try fixture(root, name: "valid-default")
            try SessionStore(directory: valid).save(SessionSnapshot(segments: [segment]))
            let before = try files(valid)
            try expect(try LiveLingoCLI.verifySaved(valid, emit: false) == 1, "nil_snapshot_target_is_hans")
            try expect(try files(valid) == before, "snapshot_verification_is_read_only")
            passed.append("readable_default_snapshot_is_authoritative_and_read_only")

            let (mismatch, english) = try fixture(root, name: "nil-vs-english", target: .english)
            try SessionStore(directory: mismatch).save(SessionSnapshot(segments: [english]))
            let mismatchBefore = try files(mismatch)
            try rejectsExport(mismatch)
            try expect(try files(mismatch) == mismatchBefore, "rejection_is_read_only")
            let (stamped, _) = try fixture(root, name: "english-vs-french", target: .french,
                snapshot: true, recordedTarget: "en")
            try rejectsExport(stamped)
            passed.append("snapshot_and_manifest_target_mismatches_rejected")

            for kind in ["corrupt", "future-schema", "tail"] {
                let (directory, caption) = try fixture(root, name: kind)
                try SessionStore(directory: directory).save(SessionSnapshot(segments: [caption]))
                let snapshotURL = directory.appendingPathComponent(SessionStore.snapshotFileName)
                if kind == "tail" {
                    try Data(#"{"unfinished":"#.utf8).write(to: directory.appendingPathComponent(SessionStore.journalFileName))
                } else if kind == "future-schema" {
                    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as! [String: Any]
                    object["schemaVersion"] = 999
                    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: snapshotURL)
                } else { try Data("damaged snapshot".utf8).write(to: snapshotURL) }
                let original = try files(directory)
                try rejectsExport(directory)
                try expect(try files(directory) == original, "unreadable_snapshot_is_not_repaired")
            }
            passed.append("snapshot_errors_map_to_inconsistent_export")

            for (index, body) in ["Air is clear.", "Clear air."].enumerated() {
                let (directory, _) = try fixture(root, name: "fixture-english-\(index)", target: .english, body: body)
                let srt = Data("1\n00:00:00,000 --> 00:00:01,000\nAir is clear.\n\(body)\n".utf8)
                try srt
                    .write(to: directory.appendingPathComponent("bilingual.srt"))
                try expect(try LiveLingoCLI.verifySaved(directory, emit: false) == 1, "explicit_fixture_two_line_layout")
                let (recorded, _) = try fixture(root, name: "recorded-english-\(index)", target: .english,
                    body: body, snapshot: true, recordedTarget: "en")
                try srt.write(to: recorded.appendingPathComponent("bilingual.srt"))
                try rejectsExport(recorded)
            }
            passed.append("fixture_two_line_english_is_verifier_only")

            try retentionChecks()
            passed.append("retention_checks_effective_target")
            try await forwardingChecks(root)
            passed.append("parsed_nondefault_target_reaches_cli_run_dispatch")
            LiveLingoCLI.writeEvent(["event": "target_review_tests_passed", "checks": passed,
                                    "passed": passed.count, "failed": 0])
        } catch {
            LiveLingoCLI.writeEvent(["event": "target_review_tests_failed",
                "check": (error as? Failure)?.check ?? "unexpected_error"], to: .standardError)
            exit(1)
        }
    }
}
