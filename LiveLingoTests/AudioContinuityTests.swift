import AppKit
import AVFoundation
import XCTest
@testable import LiveLingo

private final class CaptureSleepEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func consume(_ event: SpeechPipeline.Event) {
        if case .failure(let message) = event { lock.withLock { messages.append(message) } }
    }
    var failures: [String] { lock.withLock { messages } }
}

private final class CapturingSleepNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [@Sendable (Notification) -> Void] = []
    var sleepHandlers: [@Sendable (Notification) -> Void] { lock.withLock { blocks } }
    override func addObserver(forName name: NSNotification.Name?, object obj: Any?,
                              queue: OperationQueue?, using block: @Sendable @escaping (Notification) -> Void) -> NSObjectProtocol {
        if name == NSWorkspace.willSleepNotification { lock.withLock { blocks.append(block) } }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
}

final class CaptureSleepTests: XCTestCase, @unchecked Sendable {
    private func beginCapture(center: NotificationCenter, mode: AudioInputMode? = .microphone,
                              existing: SpeechPipeline? = nil) async throws
        -> (pipeline: SpeechPipeline, events: CaptureSleepEvents, recording: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-Sleep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let events = CaptureSleepEvents()
        let pipeline = existing ?? SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio before a lifecycle event." },
            enableAudioAnalysis: false, captureSleepNotificationCenter: center)
        let recording = directory.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = try await pipeline.startSyntheticCapture(format: format, recordingURL: recording,
            sessionID: UUID(), inputMode: mode, eventHandler: events.consume)
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_200)!
        audio.frameLength = 3_200
        for i in 0..<3_200 { audio.floatChannelData![0][i] = Float(i % 100) / 1_000 }
        XCTAssertEqual(input.submit(audio), .accepted)
        await input.drain()
        return (pipeline, events, recording)
    }

    private func waitForSleepFailure(_ events: CaptureSleepEvents) async throws {
        for _ in 0..<200 where events.failures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(events.failures.count, 1)
        XCTAssertTrue(events.failures.first?.contains("休眠") == true)
    }

    func testOnlyDisplaySleepKeepsBothAudioInputsCapturing() async throws {
        for mode in [AudioInputMode.microphone, .systemAudio] {
            let center = NotificationCenter()
            let capture = try await beginCapture(center: center, mode: mode)
            center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(capture.pipeline.transcriptionState()?.isCapturing, true)
            XCTAssertTrue(capture.events.failures.isEmpty)
            await capture.pipeline.stop()
            XCTAssertEqual(try AVAudioFile(forReading: capture.recording).length, 3_200)
        }
    }

    func testSleepEndsPausedMicrophoneAndSystemAudioWithoutWakeRestart() async throws {
        for mode in [AudioInputMode.microphone, .systemAudio] {
            let center = NotificationCenter()
            let capture = try await beginCapture(center: center, mode: mode)
            capture.pipeline.pause()
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            try await waitForSleepFailure(capture.events)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(capture.pipeline.transcriptionState()?.isCapturing, false)
            XCTAssertEqual(capture.events.failures.count, 1)
            XCTAssertEqual(try AVAudioFile(forReading: capture.recording).length, 3_200)
            await capture.pipeline.stop()
        }
    }

    func testRepeatedSleepNotificationsFinalizeOnceAndLeaveOneDurableChunk() async throws {
        let center = NotificationCenter()
        let capture = try await beginCapture(center: center)
        for _ in 0..<3 { center.post(name: NSWorkspace.willSleepNotification, object: nil) }
        try await waitForSleepFailure(capture.events)
        await capture.pipeline.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(capture.events.failures.count, 1)
        XCTAssertEqual(capture.pipeline.transcriptionWork().count, 1)
        XCTAssertEqual(capture.pipeline.transcriptionWork().first?.endFrame, 3_200)
        XCTAssertEqual(try AVAudioFile(forReading: capture.recording).length, 3_200)
    }

    func testOldSessionSleepCallbackCannotStopReplacementSession() async throws {
        let center = CapturingSleepNotificationCenter()
        let first = try await beginCapture(center: center)
        let oldCallback = try XCTUnwrap(center.sleepHandlers.first)
        await first.pipeline.stop()
        let second = try await beginCapture(center: center, existing: first.pipeline)
        oldCallback(Notification(name: NSWorkspace.willSleepNotification))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(first.events.failures.isEmpty)
        XCTAssertTrue(second.events.failures.isEmpty)
        XCTAssertEqual(second.pipeline.transcriptionState()?.isCapturing, true)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitForSleepFailure(second.events)
        await second.pipeline.stop()
        XCTAssertEqual(try AVAudioFile(forReading: first.recording).length, 3_200)
        XCTAssertEqual(try AVAudioFile(forReading: second.recording).length, 3_200)
    }

    func testNonDeviceInputDoesNotSubscribeToCaptureSleepHandling() async throws {
        let center = CapturingSleepNotificationCenter()
        let capture = try await beginCapture(center: center, mode: nil)
        XCTAssertTrue(center.sleepHandlers.isEmpty)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(capture.pipeline.transcriptionState()?.isCapturing, true)
        XCTAssertTrue(capture.events.failures.isEmpty)
        await capture.pipeline.stop()
    }

    func testSleepFinalizesRecordedAudioBeforeReportingWhyCaptureStopped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-Sleep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let notificationCenter = NotificationCenter()
        let events = CaptureSleepEvents()
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "A synthetic sentence recorded before sleep." },
            enableAudioAnalysis: false, captureSleepNotificationCenter: notificationCenter)
        let recording = directory.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = try await pipeline.startSyntheticCapture(format: format, recordingURL: recording,
            sessionID: UUID(), inputMode: .microphone, eventHandler: events.consume)
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        audio.frameLength = 8_000
        for i in 0..<8_000 { audio.floatChannelData![0][i] = Float(i % 100) / 1_000 }
        XCTAssertEqual(input.submit(audio), .accepted)
        await input.drain()
        XCTAssertEqual(pipeline.transcriptionState()?.isCapturing, true)

        // Isolated notification center: no real sleep, device or permission.
        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<200 where events.failures.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(events.failures.count, 1, "System sleep must end capture with an explicit cause")
        XCTAssertTrue(events.failures.first?.contains("休眠") == true)
        XCTAssertEqual(pipeline.transcriptionState()?.isCapturing, false,
                       "Failure delivery must follow durable capture finalization")
        await pipeline.stop()
        let reader = try AVAudioFile(forReading: recording)
        XCTAssertEqual(reader.length, 8_000)
        let readback = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8_000)!
        try reader.read(into: readback)
        XCTAssertEqual(readback.frameLength, audio.frameLength)
        for i in 0..<8_000 { XCTAssertEqual(readback.floatChannelData![0][i], audio.floatChannelData![0][i]) }
        let work = pipeline.transcriptionWork()
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(work.first?.endFrame, 8_000)
    }
}

/// Two recording-continuity faults are covered here:
/// 1. context retry could not read a recording that was still being written,
/// 2. a microphone switch stopped capture because the new hardware format was
///    pushed into the tap and file of the old one.
final class AudioContinuityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - 录音仍在写入时的上下文提取

    func testContextExtractionWorksWhileTheRecordingIsStillOpen() throws {
        let url = directory.appendingPathComponent("recording.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 6, startingAt: 0)

        let sizeBefore = try Self.fileSize(url)
        let headerBefore = try Self.prefixBytes(url, count: 8_192)

        // The reason the old code failed: a writer that is still open leaves the
        // data chunk length at zero, so AVAudioFile reports an empty recording.
        let liveLength = try AVAudioFile(forReading: url).length
        XCTAssertEqual(liveLength, 0, "仍在写入的 WAV 在 AVAudioFile 中应当读不到长度")

        // The window is [start - 0.75, end + 0.75].
        let clip = try WAVContextClip.extract(from: url, start: 2, end: 4)
        XCTAssertEqual(try Self.duration(of: clip), 3.5, accuracy: 0.02)

        // The window starts 0.75 s before the requested start and the samples
        // carry their own time stamp, so this also proves the data offset.
        let firstSamples = try Self.firstFrames(of: clip, count: 4)
        XCTAssertEqual(Double(firstSamples[0]), 1.25, accuracy: 0.01)

        XCTAssertEqual(try Self.fileSize(url), sizeBefore, "提取上下文不得改写原录音")
        XCTAssertEqual(try Self.prefixBytes(url, count: 8_192), headerBefore, "原录音头不得被改写")
    }

    func testLayoutReadsARealHeaderWithAZeroLengthDataChunk() throws {
        let url = directory.appendingPathComponent("live-layout.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 6, startingAt: 0)

        let layout = try WAVContextClip.readLayout(at: url)
        XCTAssertEqual(layout.sampleRate, 48_000)
        XCTAssertEqual(layout.channelCount, 1)
        XCTAssertEqual(layout.bitsPerSample, 32)
        XCTAssertEqual(layout.blockAlign, 4)
        XCTAssertGreaterThan(layout.dataOffset, 44)
        XCTAssertGreaterThan(layout.dataByteCount, 0)
        XCTAssertEqual(layout.frameCount, layout.dataByteCount / layout.blockAlign)
    }

    func testChunkWalkHandlesPaddingAndAnUnupdatedDataLength() throws {
        let url = directory.appendingPathComponent("handmade.wav")
        let frames = 4_800
        var bytes = Data()
        func appendU32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func appendU16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(contentsOf: Array("RIFF".utf8))
        appendU32(0) // stale length, as while recording
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("JUNK".utf8))
        appendU32(3)
        bytes.append(contentsOf: [1, 2, 3, 0]) // odd size plus pad byte
        bytes.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)
        appendU16(3); appendU16(1); appendU32(48_000); appendU32(48_000 * 4); appendU16(4); appendU16(32)
        bytes.append(contentsOf: Array("data".utf8))
        appendU32(0) // writer has not updated this yet
        bytes.append(Data(repeating: 0x11, count: frames * 4))
        try bytes.write(to: url)

        let layout = try WAVContextClip.readLayout(at: url)
        XCTAssertEqual(layout.dataOffset, 56)
        XCTAssertEqual(layout.dataByteCount, frames * 4)
        XCTAssertEqual(layout.frameCount, frames)

        let clip = try WAVContextClip.extract(from: url, start: 0, end: 0.05)
        XCTAssertEqual(try Self.duration(of: clip), 0.1, accuracy: 0.001)
    }

    func testAppendedAudioIsVisibleInALaterSnapshot() throws {
        let url = directory.appendingPathComponent("growing.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 3, startingAt: 0)

        let first = try WAVContextClip.extract(from: url, start: 0, end: 1)
        XCTAssertEqual(try Self.duration(of: first), 1.75, accuracy: 0.02)

        try Self.writeRamp(to: writer, format: format, seconds: 3, startingAt: 3)
        let second = try WAVContextClip.extract(from: url, start: 4, end: 5)
        // The writer may still hold the newest bytes in memory, so the length is
        // only bounded here; the sample values prove which audio was read.
        XCTAssertGreaterThanOrEqual(try Self.duration(of: second), 1.0)
        XCTAssertLessThanOrEqual(try Self.duration(of: second), 2.52)
        let samples = try Self.firstFrames(of: second, count: 4)
        XCTAssertEqual(Double(samples[0]), 3.25, accuracy: 0.02)
    }

    func testPartialTrailingFrameIsDroppedInsteadOfCorruptingTheClip() throws {
        let url = directory.appendingPathComponent("truncated.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 6, startingAt: 0)
        if #available(macOS 15, *) { writer.close() }

        let handle = try FileHandle(forWritingTo: url)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 3)
        try handle.close()

        let clip = try WAVContextClip.extract(from: url, start: 5, end: 6)
        // 6 s minus three bytes leaves 143 999 3/4 frames; the clip must keep
        // only complete frames instead of failing or emitting a broken file.
        XCTAssertEqual(try Self.duration(of: clip), 1.7499, accuracy: 0.001)
    }

    func testUnwrittenRangeAndUnreadableFilesGetDistinctDiagnostics() throws {
        let url = directory.appendingPathComponent("short.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 1, startingAt: 0)

        XCTAssertThrowsEqual(
            try WAVContextClip.extract(from: url, start: 30, end: 31),
            WAVContextClip.ClipError.rangeNotWrittenYet
        )

        let missing = directory.appendingPathComponent("missing.wav")
        XCTAssertThrowsEqual(
            try WAVContextClip.extract(from: missing, start: 0, end: 1),
            WAVContextClip.ClipError.fileMissing
        )

        let notWave = directory.appendingPathComponent("notes.txt")
        try Data(repeating: 0x41, count: 512).write(to: notWave)
        XCTAssertThrowsEqual(
            try WAVContextClip.extract(from: notWave, start: 0, end: 1),
            WAVContextClip.ClipError.notWaveFile
        )
    }

    func testExtractedClipIsBoundedAndReadableByStandardReaders() throws {
        let url = directory.appendingPathComponent("bounded.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 30, startingAt: 0)

        let clip = try WAVContextClip.extract(from: url, start: 0, end: 20,
                                              maximumSeconds: 1, maximumBytes: 1 << 20)
        XCTAssertLessThanOrEqual(try Self.duration(of: clip), 1.0001)
        let reader = try AVAudioFile(forReading: clip)
        XCTAssertEqual(reader.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(reader.processingFormat.channelCount, 1)
    }

    // MARK: - 设备切换与格式变化

    func testRecoveryPlanCoversSampleRateChannelAndDeviceRemoval() {
        let storage = Self.floatFormat(48_000, channels: 1)
        let builtIn = Self.floatFormat(44_100, channels: 1)
        let stereo = Self.floatFormat(48_000, channels: 2)

        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: builtIn, storageFormat: storage),
            .convert
        )
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: stereo, storageFormat: storage),
            .convert
        )
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: storage, storageFormat: storage),
            .direct
        )
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: nil, storageFormat: storage),
            .unavailable
        )
        let removed = AVAudioFormat(standardFormatWithSampleRate: 0, channels: 0)
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: removed, storageFormat: storage),
            .unavailable
        )
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: builtIn, storageFormat: nil),
            .direct
        )
    }

    func testBridgeSurvivesRepeatedHardwareFormatChanges() throws {
        let session = Self.floatFormat(48_000, channels: 1)
        let airPods = Self.floatFormat(48_000, channels: 1)
        let builtIn = Self.floatFormat(44_100, channels: 1)

        var bridge = CaptureFormatBridge(inputFormat: airPods, storageFormat: session)
        XCTAssertFalse(bridge.needsConversion)
        XCTAssertTrue(bridge.isUsable)

        XCTAssertTrue(bridge.update(inputFormat: builtIn))
        XCTAssertTrue(bridge.needsConversion)
        // A sample-rate converter may prime its filter on the first buffer, so
        // the frames are counted across several callbacks.
        var convertedFrames = 0
        for _ in 0..<4 {
            let converted = try bridge.convert(Self.ramp(format: builtIn, seconds: 0.1, startingAt: 7))
            XCTAssertEqual(converted.format.sampleRate, 48_000)
            XCTAssertEqual(converted.format.channelCount, 1)
            convertedFrames += Int(converted.frameLength)
        }
        // A sample-rate converter keeps a fixed few milliseconds of samples in
        // its filter; measured shortfall is 264 frames over these four buffers,
        // so the allowance is one priming latency rather than a drift budget.
        XCTAssertEqual(Double(convertedFrames), 4 * 4_800, accuracy: 800)

        for _ in 0..<5 {
            XCTAssertTrue(bridge.update(inputFormat: airPods))
            XCTAssertFalse(bridge.needsConversion)
            let direct = try bridge.convert(Self.ramp(format: airPods, seconds: 0.05, startingAt: 1))
            XCTAssertEqual(direct.frameLength, 2_400)
            XCTAssertTrue(bridge.update(inputFormat: builtIn))
            XCTAssertTrue(bridge.needsConversion)
            _ = try bridge.convert(Self.ramp(format: builtIn, seconds: 0.05, startingAt: 1))
        }
    }

    func testBridgeDownmixesStereoHardwareIntoTheMonoSessionFile() throws {
        let session = Self.floatFormat(48_000, channels: 1)
        let stereo = Self.floatFormat(44_100, channels: 2)
        let bridge = CaptureFormatBridge(inputFormat: stereo, storageFormat: session)
        XCTAssertTrue(bridge.isUsable)

        var frames = 0
        for _ in 0..<3 {
            let output = try bridge.convert(Self.ramp(format: stereo, seconds: 0.2, startingAt: 0))
            XCTAssertEqual(output.format.channelCount, 1)
            XCTAssertEqual(output.format.sampleRate, 48_000)
            frames += Int(output.frameLength)
        }
        XCTAssertEqual(Double(frames), 3 * 9_600, accuracy: 1_600)
    }

    func testSessionFileStaysWritableAcrossAFormatChange() throws {
        let url = directory.appendingPathComponent("session.wav")
        let session = Self.floatFormat(48_000, channels: 1)
        let file = try Self.writer(at: url, format: session)

        // First device: 48 kHz.
        try file.write(from: Self.ramp(format: session, seconds: 1, startingAt: 0))
        // The user switches to a 44.1 kHz device.
        let bridge = CaptureFormatBridge(inputFormat: Self.floatFormat(44_100, channels: 1),
                                         storageFormat: session)
        try file.write(from: try bridge.convert(Self.ramp(format: Self.floatFormat(44_100, channels: 1),
                                                          seconds: 1, startingAt: 1)))
        if #available(macOS 15, *) { file.close() }

        // The recording stays a single readable 48 kHz file instead of a
        // half-48-kHz, half-44.1-kHz stream.
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.processingFormat.sampleRate, 48_000)
        // One second at 48 kHz plus one converted second at 44.1 kHz, minus the
        // converter's fixed priming latency instead of a rising drift.
        XCTAssertEqual(Double(reader.length), 96_000, accuracy: 800)
    }

    // MARK: - helpers

    private static func floatFormat(_ rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    }

    private static func writer(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: format.settings,
                        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Samples carry their own time stamp, which makes an offset mistake visible.
    private static func ramp(format: AVAudioFormat, seconds: Double, startingAt offset: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount((format.sampleRate * seconds).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        guard let data = buffer.floatChannelData else { return buffer }
        for frame in 0..<Int(frames) {
            let value = Float(offset + Double(frame) / format.sampleRate)
            for channel in 0..<channels {
                data[format.isInterleaved ? 0 : channel][format.isInterleaved ? frame * channels + channel : frame] = value
            }
        }
        return buffer
    }

    private static func writeRamp(to file: AVAudioFile, format: AVAudioFormat,
                                  seconds: Double, startingAt offset: Double) throws {
        try file.write(from: ramp(format: format, seconds: seconds, startingAt: offset))
    }

    private static func duration(of url: URL) throws -> Double {
        let reader = try AVAudioFile(forReading: url)
        return Double(reader.length) / reader.processingFormat.sampleRate
    }

    private static func firstFrames(of url: URL, count: Int) throws -> [Float] {
        let reader = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                      frameCapacity: AVAudioFrameCount(max(count, 1)))!
        try reader.read(into: buffer, frameCount: AVAudioFrameCount(max(count, 1)))
        guard let data = buffer.floatChannelData else { return [] }
        return (0..<Int(buffer.frameLength)).map { data[0][$0] }
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? -1
    }

    private static func prefixBytes(_ url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return (try handle.read(upToCount: count)) ?? Data()
    }

    private func XCTAssertThrowsEqual(_ expression: @autoclosure () throws -> URL,
                                      _ expected: WAVContextClip.ClipError,
                                      file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try expression()
            XCTFail("预期抛出 \(expected)", file: file, line: line)
        } catch let error as WAVContextClip.ClipError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("抛出了未预期的错误：\(error)", file: file, line: line)
        }
    }

    // MARK: - 静音闸门（DigitalSilenceGate）

    /// 判静音会**直接跳过转写**（见 SpeechPipeline 的调用点），所以判错的代价是丢真实语音。
    /// 这里钉住它的边界：只有"整段都是 0 且有限"才算静音；NaN、极小非零信号、
    /// 任意声道的信号、以及它无法分析的格式，都必须判**不静音**。
    func testSilenceGateOnlyReportsSilenceWhenItCanProveIt() throws {
        let allZero = try writeFloatWav(name: "silent.wav", perChannel: [[Float](repeating: 0, count: 4_096)])
        XCTAssertTrue(try DigitalSilenceGate.isSilent(allZero), "全 0 应判静音")

        var tiny = [Float](repeating: 0, count: 4_096)
        tiny[512] = 1e-4
        let tinyURL = try writeFloatWav(name: "tiny.wav", perChannel: [tiny])
        XCTAssertFalse(try DigitalSilenceGate.isSilent(tinyURL), "1e-4 的信号不该被当成静音")

        let belowThreshold = try writeFloatWav(name: "below.wav",
                                               perChannel: [[Float](repeating: 1e-6, count: 4_096)])
        XCTAssertTrue(try DigitalSilenceGate.isSilent(belowThreshold), "远低于阈值的底噪仍算静音")

        var withNaN = [Float](repeating: 0, count: 4_096)
        withNaN[100] = .nan
        let nanURL = try writeFloatWav(name: "nan.wav", perChannel: [withNaN])
        XCTAssertFalse(try DigitalSilenceGate.isSilent(nanURL), "NaN 与任何数比较都是 false，必须靠 isFinite 拦住")

        let stereo = try writeFloatWav(name: "stereo.wav", perChannel: [
            [Float](repeating: 0, count: 4_096),
            {
                var channel = [Float](repeating: 0, count: 4_096)
                channel[10] = 0.5
                return channel
            }(),
        ])
        XCTAssertFalse(try DigitalSilenceGate.isSilent(stereo), "任一频道有信号就不算静音")
    }

    /// 16 位 PCM（应用之外常见的录音格式）也要能正确判断：AVAudioFile 会把它读成 float32，
    /// 所以闸门应当照常分析，而不是因为"不是 float32 文件"就一律放行。
    func testSilenceGateAlsoHandlesSixteenBitRecordings() throws {
        let silent = try writeInt16Wav(name: "int16-silent.wav", amplitude: 0)
        XCTAssertTrue(try DigitalSilenceGate.isSilent(silent), "全 0 的 16 位录音应判静音")

        let loud = try writeInt16Wav(name: "int16-loud.wav", amplitude: 8_000)
        XCTAssertFalse(try DigitalSilenceGate.isSilent(loud), "有信号的 16 位录音不该判静音")
    }

    @discardableResult
    private func writeFloatWav(name: String, perChannel: [[Float]]) throws -> URL {
        let channels = AVAudioChannelCount(perChannel.count)
        let frames = AVAudioFrameCount(perChannel[0].count)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let url = directory.appendingPathComponent(name)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for (channel, values) in perChannel.enumerated() {
            for (index, value) in values.enumerated() {
                buffer.floatChannelData![channel][index] = value
            }
        }
        try file.write(from: buffer)
        if #available(macOS 15, *) { file.close() }
        return url
    }

    @discardableResult
    private func writeInt16Wav(name: String, amplitude: Int16 = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(4_096)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        if let data = buffer.int16ChannelData {
            for index in 0..<Int(frames) {
                data[0][index] = amplitude == 0 ? 0 : (index % 256 == 0 ? amplitude : 0)
            }
        }
        try file.write(from: buffer)
        if #available(macOS 15, *) { file.close() }
        return url
    }
}
