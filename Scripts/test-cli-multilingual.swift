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

    static func newEvidenceDirectory(_ supplied: String?) throws -> URL {
        let manager = FileManager.default
        let sourceRoot = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard manager.fileExists(atPath: sourceRoot.appendingPathComponent("Scripts/test-cli-multilingual.swift").path),
              manager.fileExists(atPath: sourceRoot.appendingPathComponent("LiveLingo/Sources/SessionExporter.swift").path)
        else { throw Failure(name: "run_from_source_root") }
        let work = sourceRoot.appendingPathComponent("work", isDirectory: true).standardizedFileURL
        let directory = supplied.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? work.appendingPathComponent("cli-multilingual-" + UUID().uuidString, isDirectory: true)
        guard work.resolvingSymlinksInPath().path == work.path,
              directory.path.hasPrefix(work.path + "/"),
              directory.resolvingSymlinksInPath().path == directory.path
        else { throw Failure(name: "evidence_must_be_under_source_work") }
        try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure(name: "requires_new_evidence_directory") }
        return directory
    }

    static func fixtureDirectory(_ root: URL, name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.floatChannelData![0].initialize(repeating: 0, count: 160)
        do {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("recording.wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        return directory
    }

    static func fixture(_ root: URL, name: String, segments: [TranscriptSegment]) throws -> URL {
        let directory = try fixtureDirectory(root, name: name)
        try SessionExporter.export(segments: segments, sessionDirectory: directory, createdAt: Date(timeIntervalSince1970: 0))
        return directory
    }

    /// Old expected bytes must never be produced by the current exporter.
    static func frozenFixture(_ root: URL, name: String, files: [String: String]) throws -> URL {
        let directory = try fixtureDirectory(root, name: name)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
        }
        return directory
    }

    static func fileBytes(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    struct BinaryResult {
        let status: Int32
        let output: Data
        let errors: Data
        let events: [[String: Any]]
        var savedReceipt: [String: Any]? { events.first { $0["event"] as? String == "saved_verified" } }
    }

    static func runCLI(_ executable: URL, directory: URL) throws -> BinaryResult {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = ["--verify-saved", directory.path]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Keep captured output in memory. A failure report must not print it.
        let receiptBytes = output.fileHandleForReading.readDataToEndOfFile()
        let errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let events = try String(decoding: receiptBytes, as: UTF8.self).split(separator: "\n").map { line in
            guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { throw Failure(name: "binary_event_must_be_json") }
            return event
        }
        return BinaryResult(status: process.terminationStatus, output: receiptBytes, errors: errorBytes, events: events)
    }

    static func expectNoCaptionLog(_ result: BinaryResult, segments: [TranscriptSegment]) throws {
        let logged = String(decoding: result.output + result.errors, as: UTF8.self)
        for segment in segments {
            for text in [segment.english, segment.chinese, segment.translationError ?? ""] where !text.isEmpty {
                try expect(!logged.contains(text), "binary_verify_does_not_log_caption_text")
            }
        }
    }

    static func expectFrozenEvent(_ event: [String: Any], _ expected: String, root: URL, name: String) throws {
        let file = root.appendingPathComponent(name + ".ndjson")
        try Data().write(to: file, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: file)
        LiveLingoCLI.writeEvent(event, to: handle)
        try handle.close()
        try expect(try Data(contentsOf: file) == Data((expected + "\n").utf8), name)
    }

    @MainActor static func main() async {
        var passed: [String] = []
        do {
            guard (2...3).contains(CommandLine.arguments.count) else { throw Failure(name: "requires_cli_executable_and_optional_evidence_directory") }
            let cli = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
            let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            guard cli.lastPathComponent == "livelingo-cli", FileManager.default.isExecutableFile(atPath: cli.path),
                  cli.deletingLastPathComponent() == testExecutable.deletingLastPathComponent()
            else { throw Failure(name: "requires_cli_from_same_build_directory") }
            let suppliedRoot = CommandLine.arguments.count == 3 ? CommandLine.arguments[2]
                : ProcessInfo.processInfo.environment["LIVELINGO_CLI_MULTILINGUAL_WORK"]
            let root = try newEvidenceDirectory(suppliedRoot)
            let segments = [
                TranscriptSegment(startTime: 0, endTime: 1, english: "Air is clear.", chinese: "空气清澈。"),
                TranscriptSegment(startTime: 1, endTime: 2, english: "這個實驗需要兩個容器。", chinese: "这个实验需要两个容器。", sourceLanguage: "zh"),
                TranscriptSegment(startTime: 2, endTime: 3, english: "El agua fluye.", chinese: "水会流动。", sourceLanguage: "es"),
                TranscriptSegment(startTime: 3, endTime: 4, english: "水會流㗎。", chinese: "水会流动。", sourceLanguage: "yue")
            ]
            let mixed = try fixture(root, name: "mixed", segments: segments)
            let before = try fileBytes(mixed)
            try expect(try LiveLingoCLI.verifySaved(mixed, emit: false) == 4, "mixed_verify")
            try expect(try fileBytes(mixed) == before, "mixed_verify_is_read_only")
            try expect(Set(before.keys) == ["recording.wav", "manifest.json", "bilingual.jsonl", "bilingual.srt",
                "transcript-en.txt", "transcript-zh-Hans.txt"], "mixed_adds_no_files")
            try expect(before["transcript-en.txt"] == Data("Air is clear.\n這個實驗需要兩個容器。\nEl agua fluye.\n水會流㗎。\n".utf8), "source_text_has_no_labels")
            try expect(before["transcript-zh-Hans.txt"] == Data("空气清澈。\n这个实验需要两个容器。\n水会流动。\n水会流动。\n".utf8), "target_text_uses_simplified_chinese")
            try expect(before["bilingual.srt"] == Data("1\n00:00:00,000 --> 00:00:01,000\nAir is clear.\n空气清澈。\n\n2\n00:00:01,000 --> 00:00:02,000\n这个实验需要两个容器。\n\n3\n00:00:02,000 --> 00:00:03,000\nEl agua fluye.\n水会流动。\n\n4\n00:00:03,000 --> 00:00:04,000\n水會流㗎。\n水会流动。\n".utf8), "mixed_srt_is_frozen")
            let mixedManifest = try JSONSerialization.jsonObject(with: before["manifest.json"]!) as! [String: Any]
            try expect(mixedManifest["sourceLanguages"] as? [String] == ["es", "yue", "zh"], "mixed_manifest_languages_are_frozen")
            passed.append("mixed_read_only_verify")

            let mixedResult = try runCLI(cli, directory: mixed)
            try expect(mixedResult.status == 0, "binary_mixed_verify_exit")
            try expect(mixedResult.savedReceipt?["segments"] as? Int == 4,
                "binary_mixed_verify_receipt")
            try expectNoCaptionLog(mixedResult, segments: segments)
            try expect(try fileBytes(mixed) == before, "binary_verify_is_read_only")
            passed.append("actual_cli_binary_mixed_verify")

            let preferred = TranscriptSegment(startTime: 0, endTime: 1, english: "這個實驗需要兩個容器。",
                chinese: "这个实验需要三个容器。", sourceLanguage: "zh")
            let fallback = TranscriptSegment(startTime: 1, endTime: 2, english: "這個實驗需要兩個容器。", sourceLanguage: "zh")
            let passThrough = try fixture(root, name: "pass-through", segments: [preferred, fallback])
            try expect(try LiveLingoCLI.verifySaved(passThrough, emit: false) == 2, "pass_through_verify")
            let passThroughBytes = try fileBytes(passThrough)
            try expect(passThroughBytes["transcript-en.txt"] == Data("這個實驗需要兩個容器。\n這個實驗需要兩個容器。\n".utf8), "pass_through_keeps_original_source")
            try expect(passThroughBytes["transcript-zh-Hans.txt"] == Data("这个实验需要三个容器。\n这个实验需要两个容器。\n".utf8), "pass_through_prefers_usable_target_then_normalizes_source")
            try expect(passThroughBytes["bilingual.srt"] == Data("1\n00:00:00,000 --> 00:00:01,000\n这个实验需要三个容器。\n\n2\n00:00:01,000 --> 00:00:02,000\n这个实验需要两个容器。\n".utf8), "pass_through_srt_is_single_target_line")
            passed.append("pass_through_target_priority_and_fallback")

            var structuredForeignFailure = TranscriptSegment(startTime: 1, endTime: 2, english: "La presión cambia.", sourceLanguage: "es")
            structuredForeignFailure.failTranslation("PRIVATE_STRUCTURED_DIAGNOSTIC")
            let foreignFailures = [TranscriptSegment(startTime: 0, endTime: 1, english: "El agua fluye.",
                chinese: "[翻译失败：PRIVATE_MARKER_DIAGNOSTIC]", sourceLanguage: "es"), structuredForeignFailure]
            let foreign = try fixture(root, name: "foreign-failure", segments: foreignFailures)
            let foreignBefore = try fileBytes(foreign)
            try expect(foreignBefore["transcript-zh-Hans.txt"] == Data("（本段翻译未完成，可对照原文）\n（本段翻译未完成，可对照原文）\n".utf8), "foreign_failures_have_neutral_placeholder")
            try expect(foreignBefore["bilingual.srt"] == Data("1\n00:00:00,000 --> 00:00:01,000\nEl agua fluye.\n（本段翻译未完成，可对照原文）\n\n2\n00:00:01,000 --> 00:00:02,000\nLa presión cambia.\n（本段翻译未完成，可对照原文）\n".utf8), "foreign_failure_srt_is_frozen")
            try expect(try LiveLingoCLI.verifySaved(foreign, emit: false) == 2, "foreign_failures_are_valid_exports")
            let foreignResult = try runCLI(cli, directory: foreign)
            try expect(foreignResult.status == 0 && foreignResult.savedReceipt?["missingTranslations"] as? Int == 2,
                "binary_foreign_failure_verify")
            try expectNoCaptionLog(foreignResult, segments: foreignFailures)
            try expect(try fileBytes(foreign) == foreignBefore, "foreign_failure_diagnostics_are_preserved")
            passed.append("spanish_failure_placeholder_and_private_diagnostics")

            var structuredEnglishFailure = TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
                startTime: 3, endTime: 4, english: "Mass stays constant.")
            structuredEnglishFailure.failTranslation("PRIVATE_STRUCTURED_DIAGNOSTIC")
            let englishSegments = [
                TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
                    startTime: 0, endTime: 1, english: "Air is clear.", chinese: "空气清澈。"),
                TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                    startTime: 1, endTime: 2, english: "Heat rises."),
                TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
                    startTime: 2, endTime: 3, english: "Pressure changes.", chinese: "[翻译失败：PRIVATE_MARKER_DIAGNOSTIC]"),
                structuredEnglishFailure
            ]
            let english = try fixture(root, name: "english", segments: englishSegments)
            let empty = try fixture(root, name: "empty", segments: [])
            try expect(try LiveLingoCLI.verifySaved(english, emit: false) == 4, "english_verify")
            try expect(try LiveLingoCLI.verifySaved(empty, emit: false) == 0, "empty_verify")
            let englishBytes = try fileBytes(english)
            try expect(englishBytes["manifest.json"] == Data(#"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":4,"sourceLocale":"en-US","targetLocale":"zh-Hans"}"#.utf8), "english_manifest_is_frozen_without_language_field")
            try expect(englishBytes["transcript-en.txt"] == Data("Air is clear.\nHeat rises.\nPressure changes.\nMass stays constant.\n".utf8), "english_source_is_frozen")
            try expect(englishBytes["transcript-zh-Hans.txt"] == Data("空气清澈。\n（本段暂无译文）\n（本段翻译未完成，可对照英文）\n（本段暂无译文）\n".utf8), "english_target_placeholders_are_frozen")
            try expect(englishBytes["bilingual.srt"] == Data("1\n00:00:00,000 --> 00:00:01,000\nAir is clear.\n空气清澈。\n\n2\n00:00:01,000 --> 00:00:02,000\nHeat rises.\n（本段暂无译文）\n\n3\n00:00:02,000 --> 00:00:03,000\nPressure changes.\n（本段翻译未完成，可对照英文）\n\n4\n00:00:03,000 --> 00:00:04,000\nMass stays constant.\n（本段暂无译文）\n".utf8), "english_srt_is_frozen")
            let englishJSONL = [
                #"{"chinese":"空气清澈。","endTime":1,"english":"Air is clear.","id":"00000000-0000-0000-0000-000000000101","inputRevision":0,"startTime":0,"translationState":"completed"}"#,
                #"{"chinese":"","endTime":2,"english":"Heat rises.","id":"00000000-0000-0000-0000-000000000102","inputRevision":0,"startTime":1,"translationState":"pending"}"#,
                #"{"chinese":"[翻译失败：PRIVATE_MARKER_DIAGNOSTIC]","endTime":3,"english":"Pressure changes.","id":"00000000-0000-0000-0000-000000000103","inputRevision":0,"startTime":2,"translationError":"PRIVATE_MARKER_DIAGNOSTIC","translationState":"failed"}"#,
                #"{"chinese":"","endTime":4,"english":"Mass stays constant.","id":"00000000-0000-0000-0000-000000000104","inputRevision":0,"startTime":3,"translationError":"PRIVATE_STRUCTURED_DIAGNOSTIC","translationState":"failed"}"#
            ].joined(separator: "\n") + "\n"
            try expect(englishBytes["bilingual.jsonl"] == Data(englishJSONL.utf8), "english_jsonl_is_frozen")
            let englishResult = try runCLI(cli, directory: english)
            try expect(englishResult.status == 0 && englishResult.savedReceipt?["segments"] as? Int == 4,
                "binary_english_verify")
            try expectNoCaptionLog(englishResult, segments: englishSegments)
            try expect(try fileBytes(english) == englishBytes, "english_verify_is_read_only")
            let emptyBytes = try fileBytes(empty)
            for name in ["transcript-en.txt", "transcript-zh-Hans.txt", "bilingual.jsonl", "bilingual.srt"] {
                try expect(emptyBytes[name] == Data("\n".utf8), "empty_export_bytes_are_frozen")
            }
            passed.append("frozen_english_and_empty_exports")

            let legacyJSON = #"{"id":"00000000-0000-0000-0000-000000000078","startTime":0,"endTime":1,"english":"這個實驗需要兩個容器。","chinese":"這個實驗需要兩個容器。"}"#
            let legacyFailedJSON = #"{"id":"00000000-0000-0000-0000-000000000079","startTime":1,"endTime":2,"english":"Air is clear.","chinese":"[翻译失败：PRIVATE_LEGACY_DIAGNOSTIC]"}"#
            let legacy = try JSONDecoder().decode(TranscriptSegment.self, from: Data(legacyJSON.utf8))
            let legacyFailure = try JSONDecoder().decode(TranscriptSegment.self, from: Data(legacyFailedJSON.utf8))
            try expect(legacy.sourceLanguage == "zh" && !legacy.hasExplicitSourceLanguage, "legacy_chinese_is_inferred_without_marker")
            let legacySRT = "1\n00:00:00,000 --> 00:00:01,000\n這個實驗需要兩個容器。\n這個實驗需要兩個容器。\n\n2\n00:00:01,000 --> 00:00:02,000\nAir is clear.\n（本段翻译未完成，可对照英文）\n"
            let legacyDirectory = try frozenFixture(root, name: "legacy", files: [
                "manifest.json": #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":2,"sourceLocale":"en-US","targetLocale":"zh-Hans"}"#,
                "bilingual.jsonl": legacyJSON + "\n" + legacyFailedJSON + "\n",
                "transcript-en.txt": "這個實驗需要兩個容器。\nAir is clear.\n",
                "transcript-zh-Hans.txt": "這個實驗需要兩個容器。\n（本段翻译未完成，可对照英文）\n",
                "bilingual.srt": legacySRT
            ])
            let legacyBefore = try fileBytes(legacyDirectory)
            try expect(try LiveLingoCLI.verifySaved(legacyDirectory, emit: false) == 2, "frozen_legacy_double_line_verify")
            let legacyResult = try runCLI(cli, directory: legacyDirectory)
            try expect(legacyResult.status == 0 && legacyResult.savedReceipt?["segments"] as? Int == 2,
                "binary_frozen_legacy_verify")
            try expectNoCaptionLog(legacyResult, segments: [legacy, legacyFailure])
            try expect(try fileBytes(legacyDirectory) == legacyBefore, "legacy_diagnostics_and_exports_are_preserved")
            try Data("1\n00:00:00,000 --> 00:00:01,000\n這個實驗需要兩個容器。\n\n2\n00:00:01,000 --> 00:00:02,000\nAir is clear.\n（本段翻译未完成，可对照英文）\n".utf8)
                .write(to: legacyDirectory.appendingPathComponent("bilingual.srt"))
            try rejects("legacy_requires_old_double_line_srt") { try LiveLingoCLI.verifySaved(legacyDirectory, emit: false) }
            try Data(legacySRT.utf8).write(to: legacyDirectory.appendingPathComponent("bilingual.srt"))
            passed.append("frozen_legacy_traditional_chinese_and_double_line_srt")

            let inferredDirectory = try fixture(root, name: "inferred-new-export", segments: [legacy])
            let inferredBytes = try fileBytes(inferredDirectory)
            let inferredManifest = try JSONSerialization.jsonObject(with: inferredBytes["manifest.json"]!) as! [String: Any]
            try expect(inferredManifest["sourceLanguages"] as? [String] == ["zh"], "new_inferred_export_has_manifest_language")
            try expect(inferredBytes["bilingual.jsonl"].map { !String(decoding: $0, as: UTF8.self).contains("sourceLanguage") } == true,
                "inferred_jsonl_keeps_absent_marker")
            try expect(inferredBytes["bilingual.srt"] == Data("1\n00:00:00,000 --> 00:00:01,000\n這個實驗需要兩個容器。\n".utf8), "new_inferred_export_uses_single_usable_target_line")
            try expect(try LiveLingoCLI.verifySaved(inferredDirectory, emit: false) == 1, "new_inferred_export_uses_shared_rendering")
            passed.append("unmarked_inferred_new_export_with_manifest_language")

            let manifestURL = mixed.appendingPathComponent("manifest.json")
            for languages in [["es", "zh"], ["zh", "yue", "es"], ["es", "es", "yue", "zh"], [String]()] {
                var corrupted = mixedManifest
                corrupted["sourceLanguages"] = languages
                try JSONSerialization.data(withJSONObject: corrupted, options: [.sortedKeys]).write(to: manifestURL)
                try rejects("manifest_language_mismatch") { try LiveLingoCLI.verifySaved(mixed, emit: false) }
            }
            var missingLanguages = mixedManifest
            missingLanguages.removeValue(forKey: "sourceLanguages")
            try JSONSerialization.data(withJSONObject: missingLanguages, options: [.sortedKeys]).write(to: manifestURL)
            try rejects("explicit_languages_cannot_downgrade_to_legacy") { try LiveLingoCLI.verifySaved(mixed, emit: false) }
            let missingLanguagesResult = try runCLI(cli, directory: mixed)
            try expect(missingLanguagesResult.status != 0 && missingLanguagesResult.savedReceipt == nil,
                "binary_missing_manifest_languages_rejected")
            try expectNoCaptionLog(missingLanguagesResult, segments: segments)
            try before["manifest.json"]!.write(to: manifestURL)
            passed.append("manifest_language_integrity")

            let markedLegacyRows = [
                ("en", #"{"id":"00000000-0000-0000-0000-000000000082","startTime":0,"endTime":1,"english":"這個實驗需要兩個容器。","chinese":"這個實驗需要兩個容器。","sourceLanguage":"en"}"#),
                ("unknown", #"{"id":"00000000-0000-0000-0000-000000000083","startTime":0,"endTime":1,"english":"這個實驗需要兩個容器。","chinese":"這個實驗需要兩個容器。","sourceLanguage":"xx"}"#)
            ]
            for (name, json) in markedLegacyRows {
                let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
                try expect(decoded.sourceLanguage == nil && !decoded.hasExplicitSourceLanguage,
                    "stored_marker_must_be_checked_before_normalization")
                let marked = try frozenFixture(root, name: "legacy-marker-" + name, files: [
                    "manifest.json": #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":1,"sourceLocale":"en-US","targetLocale":"zh-Hans"}"#,
                    "bilingual.jsonl": json + "\n",
                    "transcript-en.txt": "這個實驗需要兩個容器。\n",
                    "transcript-zh-Hans.txt": "這個實驗需要兩個容器。\n",
                    "bilingual.srt": "1\n00:00:00,000 --> 00:00:01,000\n這個實驗需要兩個容器。\n這個實驗需要兩個容器。\n"
                ])
                let markedBefore = try fileBytes(marked)
                try rejects("stored_en_or_unknown_marker_requires_manifest_languages") {
                    try LiveLingoCLI.verifySaved(marked, emit: false)
                }
                let result = try runCLI(cli, directory: marked)
                try expect(result.status != 0 && result.savedReceipt == nil,
                    "binary_stored_marker_without_manifest_languages_rejected")
                try expectNoCaptionLog(result, segments: [decoded])
                try expect(try fileBytes(marked) == markedBefore, "rejected_stored_marker_verify_is_read_only")
            }
            let nullJSON = #"{"id":"00000000-0000-0000-0000-000000000084","startTime":0,"endTime":1,"english":"這個實驗需要兩個容器。","chinese":"這個實驗需要兩個容器。","sourceLanguage":null}"#
            let nullMarker = try frozenFixture(root, name: "legacy-marker-null", files: [
                "manifest.json": #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":1,"sourceLocale":"en-US","targetLocale":"zh-Hans"}"#,
                "bilingual.jsonl": nullJSON + "\n",
                "transcript-en.txt": "這個實驗需要兩個容器。\n",
                "transcript-zh-Hans.txt": "這個實驗需要兩個容器。\n",
                "bilingual.srt": "1\n00:00:00,000 --> 00:00:01,000\n這個實驗需要兩個容器。\n這個實驗需要兩個容器。\n"
            ])
            let nullBefore = try fileBytes(nullMarker)
            let nullSegment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(nullJSON.utf8))
            try expect(nullSegment.sourceLanguage == "zh" && !nullSegment.hasExplicitSourceLanguage,
                "null_marker_keeps_legacy_inference")
            try expect(try LiveLingoCLI.verifySaved(nullMarker, emit: false) == 1, "null_stored_marker_is_legacy_compatible")
            try expect(try fileBytes(nullMarker) == nullBefore, "null_marker_verify_is_read_only")
            passed.append("stored_en_unknown_and_null_language_markers")

            for invalidLocale in ["../zh-Hans", "zh-Hans/../../outside", "", "zh_Hans"] {
                var corrupted = mixedManifest
                corrupted["targetLocale"] = invalidLocale
                try JSONSerialization.data(withJSONObject: corrupted, options: [.sortedKeys]).write(to: manifestURL)
                try rejects("unsafe_manifest_target_locale_rejected") { try LiveLingoCLI.verifySaved(mixed, emit: false) }
            }
            try before["manifest.json"]!.write(to: manifestURL)
            passed.append("manifest_target_locale_path_boundary")

            try expect(SessionExporter.targetTranscriptFileName(for: "zh-Hant") == "transcript-zh-Hant.txt"
                && SessionExporter.targetSummaryFileName(for: "zh-Hant") == "summary-zh-Hant.md"
                && SessionExporter.targetTranscriptFileName(for: "en") == "transcript-target-en.txt",
                "saved_target_filenames_are_frozen")
            let otherTargetJSON = #"{"id":"00000000-0000-0000-0000-000000000080","startTime":0,"endTime":1,"english":"Air is clear.","chinese":"空氣清澈。"}"#
            let otherTarget = try frozenFixture(root, name: "saved-traditional-target", files: [
                "manifest.json": #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":1,"sourceLocale":"en-US","targetLocale":"zh-Hant"}"#,
                "bilingual.jsonl": otherTargetJSON + "\n",
                "transcript-en.txt": "Air is clear.\n",
                "transcript-zh-Hant.txt": "空氣清澈。\n",
                "bilingual.srt": "1\n00:00:00,000 --> 00:00:01,000\nAir is clear.\n空氣清澈。\n",
                "summary-zh-Hant.md": "# 摘要\n空氣清澈。\n"
            ])
            let otherTargetBefore = try fileBytes(otherTarget)
            try expect(try LiveLingoCLI.verifySaved(otherTarget, emit: false) == 1, "saved_target_can_differ_from_current")
            let otherTargetResult = try runCLI(cli, directory: otherTarget)
            try expect(otherTargetResult.status == 0, "binary_saved_target_verify")
            let targetFiles = (otherTargetResult.savedReceipt?["files"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            try expect(Set(targetFiles) == ["manifest.json", "bilingual.jsonl", "bilingual.srt", "recording.wav",
                "transcript-en.txt", "transcript-zh-Hant.txt", "summary-zh-Hant.md"], "receipt_uses_saved_target_filenames")
            let otherTargetSegment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(otherTargetJSON.utf8))
            try expectNoCaptionLog(otherTargetResult, segments: [otherTargetSegment])
            try expect(try fileBytes(otherTarget) == otherTargetBefore, "saved_other_target_verify_is_read_only")

            let englishTarget = try frozenFixture(root, name: "saved-english-target", files: [
                "manifest.json": #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":1,"sourceLocale":"en-US","targetLocale":"en"}"#,
                "bilingual.jsonl": #"{"id":"00000000-0000-0000-0000-000000000081","startTime":0,"endTime":1,"english":"Air is clear.","chinese":"Clear air."}"# + "\n",
                "transcript-en.txt": "Air is clear.\n",
                "transcript-target-en.txt": "Clear air.\n",
                "bilingual.srt": "1\n00:00:00,000 --> 00:00:01,000\nAir is clear.\nClear air.\n",
                "summary-en.md": "# Summary\nClear air.\n"
            ])
            let englishTargetBefore = try fileBytes(englishTarget)
            try expect(try LiveLingoCLI.verifySaved(englishTarget, emit: false) == 1, "saved_english_target_keeps_distinct_source_file")
            try expect(try fileBytes(englishTarget) == englishTargetBefore, "saved_english_target_verify_is_read_only")
            passed.append("saved_target_locale_selects_transcript_and_summary")

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
            try expect(safeVerified["event"] as? String == "progress", "callback_cannot_emit_run_verified")
            for key in keys { try expect(type(of: verified[key]!) == Int.self && safeVerified[key] as? Int == verified[key] as? Int, "verified_counts_are_integers") }
            let englishVerified = LiveLingoCLI.verifiedRunEvent(segments: [segments[0]], otherLanguageTranscription: 0, languageProbes: 0)
            try expect(keys.allSatisfy { englishVerified[$0] as? Int == 0 }, "english_counts_are_zero")
            try expectFrozenEvent(englishVerified,
                #"{"chineseCaptions":0,"event":"run_verified","languageProbes":0,"otherLanguageCaptions":0,"otherLanguageTranscription":0,"pendingTranscription":0,"segments":1,"unresolvedTranscription":0}"#,
                root: root, name: "english_verified_event_is_frozen")
            try expectFrozenEvent(LiveLingoCLI.safeEvent("state", fields: ["segments": 1, "translated": 1,
                "summarized": 0, "otherLanguageTranscription": 0, "message": "PRIVATE_EVENT_TEXT"], elapsed: 1.25),
                #"{"elapsedSeconds":1.25,"event":"state","otherLanguageTranscription":0,"segments":1,"summarized":0,"translated":1}"#,
                root: root, name: "english_state_event_is_frozen")
            try expectFrozenEvent(LiveLingoCLI.safeEvent("finished", fields: [:], elapsed: 0),
                #"{"elapsedSeconds":0,"event":"processing_finished"}"#,
                root: root, name: "english_finished_event_is_frozen")
            try expectFrozenEvent(LiveLingoCLI.safeEvent("run_verified", fields: englishVerified, elapsed: 0),
                #"{"chineseCaptions":0,"elapsedSeconds":0,"event":"progress","languageProbes":0,"otherLanguageCaptions":0,"otherLanguageTranscription":0,"pendingTranscription":0,"segments":1,"unresolvedTranscription":0}"#,
                root: root, name: "english_callback_cannot_spoof_verification")
            passed.append("verified_caption_counts")
            passed.append("frozen_english_events_and_verifier_identity")

            try Data("broken\n".utf8).write(to: mixed.appendingPathComponent("bilingual.srt"))
            try rejects("corrupt_srt_rejected") { try LiveLingoCLI.verifySaved(mixed, emit: false) }
            passed.append("corrupt_srt_rejected")
            passed += try targetChecks(root)
            LiveLingoCLI.writeEvent(["event": "multilingual_cli_tests_passed", "tests": passed.count, "checks": passed])
        } catch {
            LiveLingoCLI.writeEvent(["event": "multilingual_cli_tests_failed",
                "check": (error as? Failure)?.name ?? "operation_failed", "checksCompleted": passed,
                "failure": LiveLingoCLI.safeFailure(error)])
            exit(1)
        }
    }
    static func targetChecks(_ root: URL) throws -> [String] {
        var passed: [String] = []
        let base = ["--replay", "synthetic.wav", "--output", "synthetic-output"]
        let implicit = try LiveLingoCLI.parse(base)
        let explicit = try LiveLingoCLI.parse(base + ["--target", "zh-Hans"])
        try expect(implicit == explicit, "target_default_matches_explicit_hans")
        for arguments in [
            base + ["--target", "en"], base + ["--target", "fr"],
            base + ["--target", "zh-Hant-TW"], base + ["--target", "unknown"],
            base + ["--target", "zh-Hans", "--target", "zh-Hans"],
            ["--verify-saved", "synthetic", "--target", "zh-Hans"],
            ["--open-saved", "synthetic", "--target", "zh-Hans"],
            ["--resume-saved", "synthetic", "--target", "zh-Hans"],
            ["--translate-text", "synthetic", "--target", "zh-Hans"]
        ] {
            do { _ = try LiveLingoCLI.parse(arguments) }
            catch LiveLingoCLI.CLIError.invalidArguments { continue }
            throw Failure(name: "target_option_must_be_validated_before_io")
        }
        passed.append("validated_generation_target_and_mode_boundaries")

        let course = try fixtureDirectory(root, name: "single-line-english-target")
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Air is clear.", chinese: "Air is clear.")
        try SessionExporter.export(segments: [segment], sessionDirectory: course,
            summary: "Clear air.", createdAt: Date(timeIntervalSince1970: 0), target: .english)
        let before = try fileBytes(course)
        try expect(before["transcript-target-en.txt"] == Data("Air is clear.\n".utf8), "english_target_has_distinct_filename")
        try expect(before["bilingual.srt"] == Data("1\n00:00:00,000 --> 00:00:01,000\nAir is clear.\n".utf8), "english_target_single_line_srt")
        try expect(try LiveLingoCLI.verifySaved(course, emit: false) == 1, "english_target_is_not_legacy_hans")
        try expect(try fileBytes(course) == before, "english_target_verify_is_read_only")
        passed.append("single_line_english_target_verify")

        let traditional = try frozenFixture(root, name: "annotated-traditional-target", files: [
            "manifest.json": #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":1,"sourceLocale":"en-US","targetLocale":"zh-Hant","sourceLanguages":["zh"]}"#,
            "bilingual.jsonl": #"{"id":"00000000-0000-0000-0000-000000000080","startTime":0,"endTime":1,"english":"這個實驗需要兩個容器。","chinese":"這個實驗需要兩個容器。","sourceLanguage":"zh"}"# + "\n",
            "transcript-en.txt": "這個實驗需要兩個容器。\n",
            "transcript-zh-Hant.txt": "這個實驗需要兩個容器。\n",
            "bilingual.srt": "1\n00:00:00,000 --> 00:00:01,000\n這個實驗需要兩個容器。\n"
        ])
        let traditionalBefore = try fileBytes(traditional)
        try expect(try LiveLingoCLI.verifySaved(traditional, emit: false) == 1, "annotated_traditional_keeps_single_line_srt")
        try expect(try fileBytes(traditional) == traditionalBefore, "annotated_traditional_verify_is_read_only")
        passed.append("annotated_traditional_target_keeps_original_rendering")

        let manifest = course.appendingPathComponent("manifest.json")
        for locale in ["xx", "zh-Hant-TW"] {
            var object = try JSONSerialization.jsonObject(with: before["manifest.json"]!) as! [String: Any]
            object["targetLocale"] = locale
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifest)
            try rejects("unknown_or_unavailable_saved_renderer_rejected") {
                try LiveLingoCLI.verifySaved(course, emit: false)
            }
        }
        try before["manifest.json"]!.write(to: manifest)
        passed.append("unknown_saved_target_and_unavailable_converter_rejected")

        let oldMarker = #"{"audioFrames":0,"audioSampleRate":0,"batchDigest":"synthetic","batchIDs":[],"boundAt":"synthetic","captionDigest":"synthetic","completedDigest":"synthetic","completedIDs":[],"inputRevision":0,"journalIncompleteTailBytes":0,"latestEvidenceIDs":[],"segmentIDs":[],"sessionID":"synthetic"}"#
        var bound = try JSONDecoder().decode(LiveLingoCLI.CLIRunSession.self, from: Data(oldMarker.utf8))
        try expect(bound.targetLocale == nil, "old_marker_defaults_to_hans")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try expect(try encoder.encode(bound) == Data(oldMarker.utf8), "nil_marker_target_preserves_bytes")
        bound.targetLocale = "en"
        try expect(try JSONDecoder().decode(LiveLingoCLI.CLIRunSession.self, from: encoder.encode(bound)).targetLocale == "en", "marker_target_round_trip")
        passed.append("optional_cli_target_marker_compatibility")
        return passed
    }

}
