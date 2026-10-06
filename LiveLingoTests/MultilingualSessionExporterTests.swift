import AVFoundation
import Foundation
import XCTest
@testable import LiveLingo

final class MultilingualSessionExporterTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MultilingualExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testEnglishExportsMatchFrozenStep6Bytes() throws {
        let root = try directory()
        let segments = [
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                startTime: 0, endTime: 1.25, english: "Ice is cold.", chinese: "冰很冷。"),
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                startTime: 1.25, endTime: 2.5, english: "Water flows.", inputRevision: 2),
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                startTime: 2.5, endTime: 4, english: "Heat moves.", chinese: "[翻译失败：synthetic-failure]")
        ]
        try SessionExporter.export(segments: segments, sessionDirectory: root, summary: "\n# Lesson\n",
            createdAt: Date(timeIntervalSince1970: 0))
        // Exporter untouched since b614a3c; checked against these frozen literals
        // before adding multilingual rendering. Never derive expected bytes from it.
        let expected: [String: String] = [
            "transcript-en.txt": "Ice is cold.\nWater flows.\nHeat moves.\n",
            "transcript-zh-Hans.txt": "冰很冷。\n（本段暂无译文）\n（本段翻译未完成，可对照英文）\n",
            "summary-zh-Hans.md": "# Lesson\n",
            "manifest.json": #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":3,"sourceLocale":"en-US","targetLocale":"zh-Hans"}"#,
            "bilingual.jsonl": #"""
            {"chinese":"冰很冷。","endTime":1.25,"english":"Ice is cold.","id":"00000000-0000-0000-0000-000000000011","inputRevision":0,"startTime":0,"translationState":"completed"}
            {"chinese":"","endTime":2.5,"english":"Water flows.","id":"00000000-0000-0000-0000-000000000012","inputRevision":2,"startTime":1.25,"translationState":"pending"}
            {"chinese":"[翻译失败：synthetic-failure]","endTime":4,"english":"Heat moves.","id":"00000000-0000-0000-0000-000000000013","inputRevision":0,"startTime":2.5,"translationError":"synthetic-failure","translationState":"failed"}
            """# + "\n",
            "bilingual.srt": """
            1
            00:00:00,000 --> 00:00:01,250
            Ice is cold.
            冰很冷。

            2
            00:00:01,250 --> 00:00:02,500
            Water flows.
            （本段暂无译文）

            3
            00:00:02,500 --> 00:00:04,000
            Heat moves.
            （本段翻译未完成，可对照英文）
            """ + "\n"
        ]
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(expected.keys))
        for (name, bytes) in expected {
            XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent(name)) == Data(bytes.utf8), name)
        }
    }

    func testEmptyEnglishExportMatchesFrozenStep6Bytes() throws {
        let root = try directory()
        try SessionExporter.export(segments: [], sessionDirectory: root, summary: " \n ",
            createdAt: Date(timeIntervalSince1970: 0))
        let names = ["transcript-en.txt", "transcript-zh-Hans.txt", "bilingual.jsonl", "bilingual.srt"]
        for name in names {
            XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent(name)) == Data("\n".utf8), name)
        }
        let manifest = #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":0,"sourceLocale":"en-US","targetLocale":"zh-Hans"}"#
        XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent("manifest.json")) == Data(manifest.utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(names + ["manifest.json"]))
    }

    func testMixedExportsKeepOriginalTextAndSeparateLanguageCodes() throws {
        let root = try directory()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, english: "Air is clear.", chinese: "空气清澈。"),
            TranscriptSegment(startTime: 1, endTime: 2, english: "冰很冷。", chinese: "冰很冷。", sourceLanguage: "zh"),
            TranscriptSegment(startTime: 2, endTime: 3, english: "El agua fluye.", chinese: "水会流动。", sourceLanguage: "es"),
            TranscriptSegment(startTime: 3, endTime: 4, english: "水會流㗎。", chinese: "水会流动。", sourceLanguage: "yue")
        ]
        try SessionExporter.export(segments: segments, sessionDirectory: root)
        let expectedSource = "Air is clear.\n冰很冷。\nEl agua fluye.\n水會流㗎。\n"
        let expectedTarget = "空气清澈。\n冰很冷。\n水会流动。\n水会流动。\n"
        XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent("transcript-en.txt")) == Data(expectedSource.utf8))
        XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent("transcript-zh-Hans.txt")) == Data(expectedTarget.utf8))
        let expectedSRT = """
        1
        00:00:00,000 --> 00:00:01,000
        Air is clear.
        空气清澈。

        2
        00:00:01,000 --> 00:00:02,000
        冰很冷。

        3
        00:00:02,000 --> 00:00:03,000
        El agua fluye.
        水会流动。

        4
        00:00:03,000 --> 00:00:04,000
        水會流㗎。
        水会流动。
        """ + "\n"
        XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent("bilingual.srt")) == Data(expectedSRT.utf8))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["sourceLanguages"] as? [String], ["es", "yue", "zh"])
        XCTAssertEqual(manifest?["targetLocale"] as? String, CaptionTranslationTarget.current.rawValue)
        let jsonl = try String(contentsOf: root.appendingPathComponent("bilingual.jsonl"), encoding: .utf8)
        let rows = try jsonl.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertNil(rows[0]["sourceLanguage"])
        XCTAssertEqual(rows.dropFirst().compactMap { $0["sourceLanguage"] as? String }, ["zh", "es", "yue"])
        XCTAssertTrue(rows.compactMap { $0["english"] as? String } == segments.map(\.english))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
            ["transcript-en.txt", "transcript-zh-Hans.txt", "bilingual.jsonl", "bilingual.srt", "manifest.json"])
    }

    func testChineseRenderingUsesOriginalOnceAndOtherLanguagesKeepBothLines() {
        let zh = TranscriptSegment(startTime: 0, endTime: 1, english: "冰很冷。", sourceLanguage: "zh")
        XCTAssertTrue(SessionExporter.sourceLine(zh) == "冰很冷。")
        XCTAssertTrue(SessionExporter.targetLine(zh) == "冰很冷。")
        XCTAssertTrue(SessionExporter.srtCue(zh, index: 0) == "1\n00:00:00,000 --> 00:00:01,000\n冰很冷。")
        let es = TranscriptSegment(startTime: 1, endTime: 2, english: "El agua fluye.", sourceLanguage: "es")
        XCTAssertTrue(SessionExporter.srtCue(es, index: 1)
            == "2\n00:00:01,000 --> 00:00:02,000\nEl agua fluye.\n（本段暂无译文）")
        XCTAssertEqual(SessionExporter.targetTranscriptFileName, "transcript-" + CaptionTranslationTarget.current.rawValue + ".txt")
        XCTAssertEqual(SessionExporter.targetSummaryFileName, "summary-" + CaptionTranslationTarget.current.rawValue + ".md")
    }

    func testLegacyChineseInferenceRetainsJournalProvenanceAndSingleLineExport() throws {
        let root = try directory()
        let raw = #"{"id":"00000000-0000-0000-0000-000000000078","startTime":0,"endTime":1,"english":"冰很冷。","chinese":"冰很冷。"}"#
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(raw.utf8))
        try SessionExporter.export(segments: [segment], sessionDirectory: root)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("bilingual.srt"), encoding: .utf8)
            == "1\n00:00:00,000 --> 00:00:01,000\n冰很冷。\n")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["sourceLanguages"] as? [String], ["zh"])
        let jsonl = try Data(contentsOf: root.appendingPathComponent("bilingual.jsonl"))
        let encoded = try JSONSerialization.jsonObject(with: jsonl) as? [String: Any]
        XCTAssertNil(encoded?["sourceLanguage"], "Step 4 preserves an inferred marker's absence for legacy revision replay")
    }

    @MainActor func testProbeCountIncludesSubmittedAutoRequestsAndExcludesPreflightFailures() async throws {
        let root = try directory(), audio = root.appendingPathComponent("synthetic.wav")
        try Data([1, 2, 3]).write(to: audio)
        let endpoint = ASRRuntime.Endpoint(baseURL: URL(string: "http://127.0.0.1:1")!, token: "synthetic")
        let coordinator = ASRRequestCoordinator(transport: { request in
            let id = request.value(forHTTPHeaderField: "X-LiveLingo-Request-ID")!
            if id == "rejected" { return ASRHTTPResult(data: Data("{}".utf8), status: 400) }
            var payload: [String: Any] = ["request_id": id, "model": "1.7b", "text": "Ice is cold."]
            if request.url?.query?.contains("language=auto") == true {
                payload.merge(["language_mode": "auto", "language": "en", "decode": "forced",
                    "detected_label": NSNull(), "language_probability": NSNull(), "english_probability": NSNull(),
                    "generated_tokens": 1, "truncated": false, "policy": 1]) { _, new in new }
            }
            return ASRHTTPResult(data: try JSONSerialization.data(withJSONObject: payload), status: 200)
        }, observeExit: { _ in false })
        for (index, language) in [ASRLanguageMode.english, .auto, .auto, .english].enumerated() {
            _ = try await coordinator.transcribe(endpoint: endpoint, audioURL: audio, modelKey: "1.7b",
                language: language, requestID: "synthetic-\(index)")
        }
        var count = await coordinator.languageProbeCount
        XCTAssertEqual(count, 2)
        for id in ["invalid?id", "rejected"] {
            do {
                _ = try await coordinator.transcribe(endpoint: endpoint, audioURL: audio, modelKey: "1.7b",
                    language: .auto, requestID: id)
                XCTFail("Expected rejected synthetic request")
            } catch is QwenRuntimeError {}
        }
        count = await coordinator.languageProbeCount
        XCTAssertEqual(count, 3)
    }

    @MainActor func testCachedAutomaticRetryDoesNotAddLanguageProbes() async throws {
        let root = try directory(), audio = root.appendingPathComponent("synthetic.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = 160_000
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 160_000)
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        let endpoint = ASRRuntime.Endpoint(baseURL: URL(string: "http://127.0.0.1:1")!, token: "synthetic")
        let coordinator = ASRRequestCoordinator(transport: { request in
            let id = request.value(forHTTPHeaderField: "X-LiveLingo-Request-ID")!
            let model = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "model" }!.value!
            var payload: [String: Any] = ["request_id": id, "model": model, "text": model == "primary" ? "" : "冰很冷。"]
            if request.url?.query?.contains("language=auto") == true {
                payload.merge(["language_mode": "auto", "language": "en", "decode": "forced",
                    "detected_label": NSNull(), "language_probability": NSNull(), "english_probability": NSNull(),
                    "generated_tokens": 1, "truncated": false, "policy": 1]) { _, new in new }
            }
            return ASRHTTPResult(data: try JSONSerialization.data(withJSONObject: payload), status: 200)
        }, observeExit: { _ in false })
        let transcriber: DurableTranscriptionQueue.Transcriber = { url, model, enhance, mode in
            try await coordinator.transcribe(endpoint: endpoint, audioURL: url, modelKey: model,
                enhanceSpeech: enhance, language: mode, requestID: ASRRequestContext.requestID)
        }
        var record = TranscriptionWorkRecord(id: UUID(), sessionID: UUID(), ordinal: 0, audioFile: "synthetic.wav",
            startFrame: 0, endFrame: 160_000, sampleRate: 16_000, start: 0, end: 10,
            captureStart: nil, captureEnd: nil, modelKey: "primary", fallbackModelKey: "fallback", appleEvidence: "")
        let attempts = TranscriptionAttemptCache()
        _ = try await DurableTranscriptionQueue.recognize(record, audioURL: audio, recordingURL: nil,
            formulaContext: "", attempts: attempts, transcriber: transcriber)
        let firstCount = await coordinator.languageProbeCount
        XCTAssertEqual(firstCount, 1)
        record.attempt = .automaticRetry
        record.automaticRetryCount = 1
        _ = try await DurableTranscriptionQueue.recognize(record, audioURL: audio, recordingURL: nil,
            formulaContext: "", attempts: attempts, transcriber: transcriber)
        let retryCount = await coordinator.languageProbeCount
        XCTAssertEqual(retryCount, firstCount)
    }
}
