import AVFoundation
import Darwin
import Foundation

/// Compiled with the production CLI and LIVELINGO_CLI_LIFECYCLE_TESTS to replace
/// only its entry point. No model, HTTP service, AppModel or real course is used.
@main struct CLIMultilingualTests {
    struct Failure: Error { let name: String }

    static func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure(name: name) }
    }

    static func rejects(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch LiveLingoCLI.CLIError.inconsistentExport { return }
        throw Failure(name: name)
    }

    static func fixture(_ root: URL, name: String, segments: [TranscriptSegment]) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.floatChannelData![0].initialize(repeating: 0, count: 160)
        do {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("recording.wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        try SessionExporter.export(segments: segments, sessionDirectory: directory, createdAt: Date(timeIntervalSince1970: 0))
        return directory
    }

    static func fileBytes(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CLI-Multilingual-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed: [String] = []
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure(name: "requires_cli_executable") }
            let segments = [
                TranscriptSegment(startTime: 0, endTime: 1, english: "Air is clear.", chinese: "空气清澈。"),
                TranscriptSegment(startTime: 1, endTime: 2, english: "冰很冷。", chinese: "冰很冷。", sourceLanguage: "zh"),
                TranscriptSegment(startTime: 2, endTime: 3, english: "El agua fluye.", chinese: "水会流动。", sourceLanguage: "es"),
                TranscriptSegment(startTime: 3, endTime: 4, english: "水會流㗎。", chinese: "水会流动。", sourceLanguage: "yue")
            ]
            let mixed = try fixture(root, name: "mixed", segments: segments)
            let before = try fileBytes(mixed)
            try expect(try LiveLingoCLI.verifySaved(mixed, emit: false) == 4, "mixed_verify")
            try expect(try fileBytes(mixed) == before, "mixed_verify_is_read_only")
            try expect(Set(before.keys) == ["recording.wav", "manifest.json", "bilingual.jsonl", "bilingual.srt",
                "transcript-en.txt", "transcript-zh-Hans.txt"], "mixed_adds_no_files")
            try expect(before["transcript-en.txt"] == Data("Air is clear.\n冰很冷。\nEl agua fluye.\n水會流㗎。\n".utf8), "source_text_has_no_labels")
            passed.append("mixed_read_only_verify")

            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            process.arguments = ["--verify-saved", mixed.path]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let receiptBytes = output.fileHandleForReading.readDataToEndOfFile()
            let errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try expect(process.terminationStatus == 0, "binary_mixed_verify_exit")
            let receipts = try String(decoding: receiptBytes, as: UTF8.self).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            let receipt = receipts.compactMap { $0 }.first { $0["event"] as? String == "saved_verified" }
            try expect(receipt?["event"] as? String == "saved_verified" && receipt?["segments"] as? Int == 4,
                "binary_mixed_verify_receipt")
            for segment in segments {
                try expect(!String(decoding: receiptBytes + errorBytes, as: UTF8.self).contains(segment.english),
                    "binary_verify_does_not_log_caption_text")
            }
            try expect(try fileBytes(mixed) == before, "binary_verify_is_read_only")
            passed.append("actual_cli_binary_mixed_verify")

            let english = try fixture(root, name: "english", segments: [segments[0]])
            let empty = try fixture(root, name: "empty", segments: [])
            try expect(try LiveLingoCLI.verifySaved(english, emit: false) == 1, "english_verify")
            try expect(try LiveLingoCLI.verifySaved(empty, emit: false) == 0, "empty_verify")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: english.appendingPathComponent("manifest.json"))) as? [String: Any]
            try expect(manifest?["sourceLanguages"] == nil, "english_manifest_has_no_new_field")
            passed.append("english_and_empty_compatibility")

            let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000078","startTime":0,"endTime":1,"english":"冰很冷。","chinese":"冰很冷。"}"#
            let legacy = try JSONDecoder().decode(TranscriptSegment.self, from: Data(legacyJSON.utf8))
            let legacyDirectory = try fixture(root, name: "legacy", segments: [legacy])
            try expect(try LiveLingoCLI.verifySaved(legacyDirectory, emit: false) == 1, "inferred_chinese_verify")
            // Legacy manifests omit the new optional key. Absence remains valid.
            let legacyManifestURL = legacyDirectory.appendingPathComponent("manifest.json")
            var legacyManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyManifestURL)) as! [String: Any]
            legacyManifest.removeValue(forKey: "sourceLanguages")
            try JSONSerialization.data(withJSONObject: legacyManifest, options: [.sortedKeys]).write(to: legacyManifestURL)
            try expect(try LiveLingoCLI.verifySaved(legacyDirectory, emit: false) == 1, "optional_manifest_key")
            passed.append("legacy_chinese_and_optional_manifest")

            let manifestURL = mixed.appendingPathComponent("manifest.json")
            var corrupted = try JSONSerialization.jsonObject(with: before["manifest.json"]!) as! [String: Any]
            corrupted["sourceLanguages"] = ["es", "zh"]
            try JSONSerialization.data(withJSONObject: corrupted, options: [.sortedKeys]).write(to: manifestURL)
            try rejects("manifest_language_mismatch") { try LiveLingoCLI.verifySaved(mixed, emit: false) }
            try before["manifest.json"]!.write(to: manifestURL)
            passed.append("manifest_language_integrity")

            let keys = ["chineseCaptions", "otherLanguageCaptions", "languageProbes"]
            let invalidCounts: [Any] = ["private text", true, 3.0, -1, NSNumber(value: true),
                NSNumber(value: 3.0), NSNull(), ["text": "private"]]
            for key in keys {
                let accepted = LiveLingoCLI.safeEvent("state", fields: [key: 3], elapsed: 0)
                try expect(accepted[key] as? Int == 3, "integer_count_allowed")
                for invalid in invalidCounts {
                    let safe = LiveLingoCLI.safeEvent("state", fields: [key: invalid], elapsed: 0)
                    try expect(safe[key] == nil, "noninteger_or_negative_count_rejected")
                }
            }
            passed.append("strict_integer_event_allowlist")

            let verified = LiveLingoCLI.verifiedRunEvent(segments: segments, otherLanguageTranscription: 2, languageProbes: 3)
            try expect(verified["event"] as? String == "run_verified", "verified_event_identity")
            try expect(verified["chineseCaptions"] as? Int == 1 && verified["otherLanguageCaptions"] as? Int == 2
                && verified["languageProbes"] as? Int == 3, "verified_language_counts")
            let safeVerified = LiveLingoCLI.safeEvent("run_verified", fields: verified, elapsed: 0)
            try expect(safeVerified["event"] as? String == "run_verified", "verified_event_allowed")
            for key in keys { try expect(type(of: verified[key]!) == Int.self && safeVerified[key] as? Int == verified[key] as? Int, "verified_counts_are_integers") }
            let englishVerified = LiveLingoCLI.verifiedRunEvent(segments: [segments[0]], otherLanguageTranscription: 0, languageProbes: 0)
            try expect(keys.allSatisfy { englishVerified[$0] as? Int == 0 }, "english_counts_are_zero")
            passed.append("verified_caption_counts")

            try Data("broken\n".utf8).write(to: mixed.appendingPathComponent("bilingual.srt"))
            try rejects("corrupt_srt_rejected") { try LiveLingoCLI.verifySaved(mixed, emit: false) }
            passed.append("corrupt_srt_rejected")
            LiveLingoCLI.writeEvent(["event": "multilingual_cli_tests_passed", "tests": passed.count, "checks": passed])
        } catch {
            LiveLingoCLI.writeEvent(["event": "multilingual_cli_tests_failed",
                "check": (error as? Failure)?.name ?? "operation_failed", "checksCompleted": passed,
                "failure": LiveLingoCLI.safeFailure(error)])
            exit(1)
        }
    }
}
