import AVFoundation
import XCTest
@testable import LiveLingo

/// B 线（对标 Coursedude 的本地文件摄取）：把本地音频/视频喂进与实时采集
/// 相同的分块→转写路径，不联网、不改动源文件。
final class MediaImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - helpers

    private func makeWav(seconds: Double, sampleRate: Double = 48_000,
                         channels: AVAudioChannelCount = 2) throws -> URL {
        let url = directory.appendingPathComponent("input-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        if frames > 0 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            if let data = buffer.floatChannelData {
                for frame in 0..<Int(frames) {
                    let value = Float(sin(Double(frame) * 2 * .pi * 440 / sampleRate)) * 0.3
                    for channel in 0..<Int(channels) { data[channel][frame] = value }
                }
            }
            try file.write(from: buffer)
        }
        if #available(macOS 15, *) { file.close() }
        return url
    }

    private func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    // MARK: - 解码

    func testDecodingResamplesStereo48kIntoThePipelineFormat() async throws {
        let wav = try makeWav(seconds: 3, sampleRate: 48_000, channels: 2)
        let sizeBefore = try fileSize(wav)
        let box = ImportRecorder()
        let total = try await MediaFileImport.decode(wav, onProgress: { box.record(progress: $0) }) { buffer in
            box.record(format: buffer.format, frames: buffer.frameLength)
        }

        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(Double(total), 3 * 16_000, accuracy: 1_600, "应统一到 16 kHz")
        XCTAssertEqual(box.sampleRates, [16_000])
        XCTAssertEqual(box.channelCounts, [1])
        XCTAssertTrue(box.formatsAreFloat32, "统一使用 float32 便于写入会话文件")
        XCTAssertEqual(box.framesFromBuffers, total)
        XCTAssertEqual(box.progress.last ?? 0, 1.0, accuracy: 0.05)
        XCTAssertEqual(try fileSize(wav), sizeBefore, "导入不得改动源文件")
    }

    func testDecodingAnM4AContainerWorks() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("需要 macOS 15+ 的导出 API") }
        let wav = try makeWav(seconds: 2)
        let m4a = directory.appendingPathComponent("input.m4a")
        let asset = AVURLAsset(url: wav)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw XCTSkip("本机没有可用的 M4A 导出预设")
        }
        try await session.export(to: m4a, as: .m4a)

        let box = ImportRecorder()
        let total = try await MediaFileImport.decode(m4a) { buffer in
            box.record(format: buffer.format, frames: buffer.frameLength)
        }
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(Double(total), 2 * 16_000, accuracy: 3_200)
        XCTAssertEqual(box.sampleRates, [16_000])
    }

    /// 实测 MKV/WebM 打不开；用户看到的必须是能照做的说明，而不是 "Cannot Open"。
    func testUnsupportedContainerGetsAnActionableMessage() {
        let raw = NSError(domain: "AVFoundationErrorDomain", code: -11_828,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot Open"])
        let hint = MediaFileImport.readableFailureHint(for: raw)
        XCTAssertTrue(hint.contains("封装格式"), hint)
        XCTAssertTrue(hint.contains("MP4"), hint)
        XCTAssertFalse(hint.contains("Cannot Open"), "不要把系统原文丢给用户")
        // 其它错误保持原样，不吞掉信息
        let other = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "磁盘读取失败"])
        XCTAssertEqual(MediaFileImport.readableFailureHint(for: other), "磁盘读取失败")
    }

    func testImportErrorsAreSpecific() async throws {
        let missing = directory.appendingPathComponent("nope.wav")
        await assertImportThrows(missing, expected: "找不到要导入的文件。")

        let text = directory.appendingPathComponent("notes.txt")
        try "这 不 是 音 频".write(to: text, atomically: true, encoding: .utf8)
        await assertImportThrows(text, expected: nil, mustMention: "不是音频或视频文件")

        let empty = try makeWav(seconds: 0)
        await assertImportThrows(empty, expected: nil)
    }

    private func assertImportThrows(_ url: URL, expected: String?, mustMention: String? = nil) async {
        do {
            _ = try await MediaFileImport.decode(url) { _ in }
            XCTFail("应该抛出导入错误：\(url.lastPathComponent)")
        } catch let error as MediaFileImport.ImportError {
            if let expected {
                XCTAssertEqual(error.errorDescription, expected)
            } else {
                XCTAssertNotNil(error.errorDescription, "错误必须有可读的中文说明")
                if let mustMention {
                    XCTAssertTrue(error.errorDescription?.contains(mustMention) == true,
                                  "错误说明应点明原因，实际：\(error.errorDescription ?? "无")")
                }
            }
        } catch {
            XCTFail("抛出了非导入错误：\(error)")
        }
    }

    // MARK: - 端到端：文件 → 分块 → 转写事件 → 会话录音

    /// 导入被取消（用户点「停止导入」或应用退出）时，已经写入的音频与已产出的字幕要保留，
    /// 之后的正常收尾必须还能跑（不能因为取消而崩或写坏文件）。
    func testCancellingAnImportKeepsWhatWasAlreadyWritten() async throws {
        executionTimeAllowance = 30
        let wav = try makeWav(seconds: 60, sampleRate: 48_000, channels: 2)
        let recording = directory.appendingPathComponent("recording.wav")
        let collector = ImportEventCollector()
        let gate = ImportTranscriberGate()
        let pipeline = SpeechPipeline(transcriber: { url, _, _ in
            await gate.holdFirstFile(url)
            return "The lecturer explains the energy of the system."
        })
        let task = Task {
            try await pipeline.importMediaFile(wav, recordingURL: recording,
                eventHandler: { collector.append($0) }, onProgress: nil)
        }
        let queuedFile = await gate.waitForFirstFile()
        XCTAssertTrue(pipeline.hasRecordedAudio, "音频已经写入，不能因字幕尚未返回而丢弃")
        task.cancel()
        do { try await task.value } catch is CancellationError {} catch {
            XCTFail("取消不应抛出其它错误：\(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: queuedFile.path), "排队的转写仍需要分块")
        await gate.release()
        await pipeline.stop()
        let reader = try AVAudioFile(forReading: recording)
        XCTAssertGreaterThan(reader.length, 0)
        XCTAssertLessThan(Double(reader.length), 60 * 16_000)
        XCTAssertEqual(reader.processingFormat.sampleRate, 16_000)
        let spans = collector.events.compactMap { event -> (TimeInterval, TimeInterval)? in
            if case let .final(_, start, end, _) = event { return (start, end) }
            return nil
        }.sorted { $0.0 < $1.0 }
        XCTAssertFalse(spans.isEmpty)
        XCTAssertEqual(spans.first?.0 ?? -1, 0, accuracy: 0.05)
        XCTAssertEqual(spans.last?.1 ?? -1, Double(reader.length) / 16_000, accuracy: 0.1)
        for pair in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1.0 - pair.0.1, 0.1, "停止时剩余转写不可出现空洞")
        }
        for event in collector.events {
            if case let .transcriptionIssue(_, _, message) = event { XCTFail(message) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedFile.path), "收尾完成后清理分块")
    }

    func testImportWriteFailureStopsDecodingAndPreservesPartialAudio() async throws {
        let wav = try makeWav(seconds: 3)
        let before = try Data(contentsOf: wav)
        let recording = directory.appendingPathComponent("partial.wav")
        let collector = ImportEventCollector()
        let failure = ImportWriteFailure()
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Recorded material." },
                                      beforeAudioWrite: { try failure.beforeWrite() })
        do {
            try await pipeline.importMediaFile(wav, recordingURL: recording,
                eventHandler: { collector.append($0) })
            XCTFail("写盘失败必须终止解码")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("音频写入失败"))
        }
        XCTAssertTrue(pipeline.hasRecordedAudio)
        XCTAssertEqual(failure.count, 2, "不得继续向失效文件空写")
        await pipeline.stop()
        let audio = try AVAudioFile(forReading: recording)
        XCTAssertGreaterThan(audio.length, 0)
        XCTAssertLessThan(Double(audio.length), 3 * 16_000)
        XCTAssertEqual(try Data(contentsOf: wav), before)
        for event in collector.events {
            if case .failure = event { XCTFail("导入失败应通过解码错误统一收尾，不启动另一条失败任务") }
        }
    }

    func testPipelineImportProducesCaptionsAndWritesTheSessionRecording() async throws {
        let wav = try makeWav(seconds: 25, sampleRate: 48_000, channels: 2)
        let recording = directory.appendingPathComponent("recording.wav")
        let collector = ImportEventCollector()
        let progressBox = ImportRecorder()
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Imported lecture sentence." })

        try await pipeline.importMediaFile(
            wav,
            recordingURL: recording,
            eventHandler: { collector.append($0) },
            onProgress: { progressBox.record(progress: $0) }
        )
        await pipeline.stop()

        let reader = try AVAudioFile(forReading: recording)
        XCTAssertEqual(reader.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(reader.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(reader.length), 25 * 16_000, accuracy: 3_200, "会话录音应按导入格式完整落盘")

        let captions = collector.events.compactMap { event -> String? in
            if case let .final(text, _, _, _) = event { return text }
            return nil
        }
        XCTAssertFalse(captions.isEmpty, "25 秒素材应当至少产出一个分块并完成转写")
        XCTAssertTrue(captions.allSatisfy { $0 == "Imported lecture sentence." })
        XCTAssertEqual(progressBox.progress.last ?? 0, 1.0, accuracy: 0.05)
    }
}

/// 线程安全的观测盒：解码回调在导入任务上执行，测试在主线程读。
private final class ImportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sampleRates: Set<Double> = []
    private var _channelCounts: Set<AVAudioChannelCount> = []
    private var _allFloat32 = true
    private var _frames: AVAudioFramePosition = 0
    private var _progress: [Double] = []

    func record(format: AVAudioFormat, frames: AVAudioFrameCount) {
        lock.withLock {
            _sampleRates.insert(format.sampleRate)
            _channelCounts.insert(format.channelCount)
            _allFloat32 = _allFloat32 && format.commonFormat == .pcmFormatFloat32
            _frames += AVAudioFramePosition(frames)
        }
    }

    func record(progress: Double) { lock.withLock { _progress.append(progress) } }

    var sampleRates: Set<Double> { lock.withLock { _sampleRates } }
    var channelCounts: Set<AVAudioChannelCount> { lock.withLock { _channelCounts } }
    var formatsAreFloat32: Bool { lock.withLock { _allFloat32 } }
    var framesFromBuffers: AVAudioFramePosition { lock.withLock { _frames } }
    var progress: [Double] { lock.withLock { _progress } }
}

private final class ImportEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SpeechPipeline.Event] = []
    func append(_ event: SpeechPipeline.Event) { lock.withLock { values.append(event) } }
    var events: [SpeechPipeline.Event] { lock.withLock { values } }
}


private actor ImportTranscriberGate {
    private var firstFile: URL?
    private var entered: CheckedContinuation<URL, Never>?
    private var releaseFirst: CheckedContinuation<Void, Never>?
    func holdFirstFile(_ url: URL) async {
        guard firstFile == nil else { return }
        firstFile = url
        await withCheckedContinuation { continuation in
            releaseFirst = continuation
            entered?.resume(returning: url)
            entered = nil
        }
    }
    func waitForFirstFile() async -> URL {
        if let firstFile { return firstFile }
        return await withCheckedContinuation { entered = $0 }
    }
    func release() { releaseFirst?.resume(); releaseFirst = nil }
}


private final class ImportWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    var count: Int { lock.withLock { writes } }
    func beforeWrite() throws {
        try lock.withLock {
            writes += 1
            if writes == 2 { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
        }
    }
}
