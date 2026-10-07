import AVFoundation
import Foundation
import XCTest
@testable import LiveLingo

private final class DataSafetyAudioBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    @discardableResult
    func update<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&stored) } }
}

private actor DataSafetyPreviewGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { opened = true; waiter?.resume(); waiter = nil }
}

private final class DataSafetyMicrophone: NSObject, MicrophoneCaptureEngine, @unchecked Sendable {
    enum Gate { case none, format, tap }
    private let lock = NSLock()
    private let gate: Gate
    private let releaseGate = DispatchSemaphore(value: 0)
    private var gated = false
    private var entered = false
    private var timedOut = false
    private var running = false
    private var input: OwnedAudioCaptureBuffer?
    init(gate: Gate) { self.gate = gate }
    var notificationObject: AnyObject { self }
    var outputFormat: AVAudioFormat {
        block(at: .format)
        return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }
    var isRunning: Bool { lock.withLock { running } }
    var hasTap: Bool { lock.withLock { input != nil } }
    var gateEntered: Bool { lock.withLock { entered } }
    var gateTimedOut: Bool { lock.withLock { timedOut } }
    private func block(at point: Gate) {
        let shouldWait = lock.withLock { () -> Bool in
            guard point == gate, !gated else { return false }
            gated = true; entered = true
            return true
        }
        if shouldWait, releaseGate.wait(timeout: .now() + 5) != .success {
            lock.withLock { timedOut = true }
        }
    }
    func release() { releaseGate.signal() }
    func installTap(format: AVAudioFormat, input: OwnedAudioCaptureBuffer) throws {
        lock.withLock { self.input = input }
        block(at: .tap)
    }
    func removeTap() { lock.withLock { input = nil } }
    func prepare() {}
    func start() throws { lock.withLock { running = true } }
    func pause() { lock.withLock { running = false } }
    func stop() { lock.withLock { running = false } }
    func submit(_ buffer: AVAudioPCMBuffer) -> OwnedAudioCaptureBuffer.Submission? {
        lock.withLock { input }?.submit(buffer)
    }
    func drain() async { await lock.withLock { input }?.drain() }
}

final class DataSafetyAudioTests: XCTestCase, @unchecked Sendable {
    private func directory(_ label: String) throws -> URL {
        let root = try DataSafetyFixtures.make(label)
        addTeardownBlock { DataSafetyFixtures.preserve(root) }
        return root
    }
    private func format() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }
    private func pcm(_ frames: Int, value: Float = 0.125) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format(), frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames { buffer.floatChannelData![0][frame] = value }
        return buffer
    }
    private func wave(_ url: URL, frames: Int, value: Float = 0.125) throws {
        let writer = try AVAudioFile(forWriting: url, settings: format().settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        if frames > 0 { try writer.write(from: pcm(frames, value: value)) }
    }
    private func work(_ session: UUID, ordinal: Int = 0, frames: Int64 = 1_600,
                      recording: String? = nil) -> TranscriptionWorkRecord {
        let first = Int64(ordinal) * frames
        return TranscriptionWorkRecord(id: UUID(), sessionID: session, ordinal: ordinal,
            audioFile: "synthetic-\(ordinal).wav", startFrame: first, endFrame: first + frames,
            sampleRate: 16_000, start: Double(first) / 16_000, end: Double(first + frames) / 16_000,
            captureStart: nil, captureEnd: nil, modelKey: "synthetic-no-model",
            fallbackModelKey: nil, appleEvidence: "", recordingFile: recording)
    }
    private func pipeline(beforeChunkOpen: (@Sendable () throws -> Void)? = nil,
                          beforeChunkWrite: (@Sendable () throws -> Void)? = nil,
                          microphone: @escaping @Sendable () -> any MicrophoneCaptureEngine = {
                              DataSafetyMicrophone(gate: .none)
                          }) -> SpeechPipeline {
        SpeechPipeline(transcriber: { _, _, _ in "A complete synthetic sentence." },
            beforeChunkOpen: beforeChunkOpen, beforeChunkWrite: beforeChunkWrite,
            enableAudioAnalysis: false, captureSleepNotificationCenter: NotificationCenter(),
            microphoneEngineFactory: microphone, microphoneNotifications: NotificationCenter(),
            enableMicrophoneWatchdog: false, enableCaptureHealthWatchdog: false)
    }
    private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw NSError(domain: "SyntheticGateNotReached", code: 1)
    }

    // A1: every accepted frame must be queued or explicitly counted as unwritten.
    func testRotationOpenFailureAccountsForPersistentAndLiveOnlyTail() async throws {
        for persistent in [true, false] {
            let root = try directory(persistent ? "rotation-persistent" : "rotation-live")
            let opens = DataSafetyAudioBox(0)
            let p = pipeline(beforeChunkOpen: {
                let count = opens.update { $0 += 1; return $0 }
                if count == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            })
            let recording = persistent ? root.appendingPathComponent("recording.wav") : nil
            let input = try await p.startSyntheticCapture(format: format(), recordingURL: recording,
                sessionID: UUID(), syntheticDirectory: root.appendingPathComponent("live"), eventHandler: { _ in })
            for _ in 0..<99 {
                XCTAssertEqual(input.submit(pcm(1_600)), .accepted)
                await input.drain()
            }
            XCTAssertEqual(input.submit(pcm(32_000)), .accepted)
            await input.drain()
            await p.stopCapture(continueTranscribing: false)
            try await p.pauseTranscription()
            let records = p.transcriptionWork()
            let journal = try DurableTranscriptionJournal(
                sessionDirectory: try XCTUnwrap(p.syntheticWorkDirectory).deletingLastPathComponent(),
                sessionID: try XCTUnwrap(p.transcriptionState()).sessionID)
            XCTAssertNotNil(input.failureSnapshot)
            XCTAssertEqual(journal.gaps.count, 1)
            let covered = records.reduce(Int64(0)) { $0 + $1.endFrame - $1.startFrame }
            let rejected = journal.gaps.reduce(Int64(0)) { $0 + ($1.rejectedFrames ?? 0) }
            XCTAssertEqual(covered + rejected, 190_400)
            XCTAssertGreaterThan(rejected, 0)
            if let recording {
                XCTAssertEqual(Int64(try WAVContextClip.readLayout(at: recording).frameCount), covered)
            }
        }
    }

    // A2: a real partial write through an injected FileHandle must survive finalization.
    func testShortJournalAppendCannotBeExtendedByFinalizer() throws {
        let root = try directory("short-append"), session = UUID()
        let armed = DataSafetyAudioBox(false)
        let partial = DataSafetyAudioBox(Data())
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session,
            writeLog: { handle, bytes in
                if armed.update({ let wasArmed = $0; $0 = false; return wasArmed }) {
                    let prefix = Data(bytes.prefix(32))
                    try handle.write(contentsOf: prefix)
                    partial.update { $0 = prefix }
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try handle.write(contentsOf: bytes)
            })
        try journal.setCapturing(true)
        let original = work(session)
        try journal.put(original)
        let log = journal.directory.appendingPathComponent("work.jsonl")
        let before = try Data(contentsOf: log)
        armed.update { $0 = true }
        XCTAssertThrowsError(try journal.put(work(session, ordinal: 1)))
        XCTAssertEqual(try Data(contentsOf: log), before + partial.value)
        XCTAssertEqual(partial.value.count, 32)
        try? journal.setCapturing(false)
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        XCTAssertEqual(reopened.records, [original])
        XCTAssertFalse(reopened.processingState.isCapturing)
        let evidence = try FileManager.default.contentsOfDirectory(at: journal.directory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("truncated-tail-") }
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(evidence.first)), partial.value)
    }

    // A3: bytes already in the main WAV must re-enter durable work after a chunk write fails.
    func testMainRecordingTailRecoversAfterSecondWriterFailure() async throws {
        let root = try directory("second-writer"), session = UUID()
        let writes = DataSafetyAudioBox(0)
        let p = pipeline(beforeChunkWrite: {
            let count = writes.update { $0 += 1; return $0 }
            if count == 2 { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let recording = root.appendingPathComponent("recording.wav")
        let input = try await p.startSyntheticCapture(format: format(), recordingURL: recording,
            sessionID: session, eventHandler: { _ in })
        XCTAssertEqual(input.submit(pcm(1_600)), .accepted)
        await input.drain()
        XCTAssertEqual(input.submit(pcm(4_096)), .accepted)
        await input.drain()
        await p.stopCapture(continueTranscribing: false)
        try await p.pauseTranscription()
        let frames = Int64(try WAVContextClip.readLayout(at: recording).frameCount)
        XCTAssertEqual(frames, 5_696)
        let q = DurableTranscriptionQueue { _, _, _ in "Recovered synthetic tail." }
        try await q.configure(directory: root, sessionID: session, persistent: true, identified: true,
                              restoring: true, startPaused: true, handler: { _ in })
        XCTAssertEqual(q.records.map(\.endFrame).max(), frames)
        let ordered = q.records.sorted { $0.startFrame < $1.startFrame }
        XCTAssertEqual(ordered.first?.startFrame, 0)
        for pair in zip(ordered, ordered.dropFirst()) { XCTAssertEqual(pair.0.endFrame, pair.1.startFrame) }
        await q.cancel()
    }

    // A4: one invalid WAV retains its marker without blocking valid work.
    func testShortCaptureDoesNotBlockHealthyCaptureRecovery() async throws {
        let root = try directory("isolated-short-wave"), session = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        var saved = work(session, ordinal: 2)
        saved.status = .completed; saved.text = "Previously saved synthetic sentence."
        try journal.put(saved)
        let badID = UUID(), goodID = UUID()
        let bad = journal.directory.appendingPathComponent("bad.wav")
        let badBytes = Data("RIFF".utf8)
        try badBytes.write(to: bad)
        try wave(journal.directory.appendingPathComponent("good.wav"), frames: 1_600)
        for (id, ordinal, name) in [(badID, 0, "bad.wav"), (goodID, 1, "good.wav")] {
            try DurableTranscriptionJournal.stageCapture(CaptureChunkDescriptor(id: id, sessionID: session,
                ordinal: ordinal, audioFile: name, recordingFile: nil, startFrame: Int64(ordinal * 1_600),
                sampleRate: 16_000, modelKey: "synthetic-no-model", fallbackModelKey: nil), directory: journal.directory)
        }
        let q = DurableTranscriptionQueue { _, _, _ in "Synthetic sentence." }
        try await q.configure(directory: root, sessionID: session, persistent: true, identified: true,
                              restoring: true, startPaused: true, handler: { _ in })
        XCTAssertTrue(q.records.contains { $0.id == saved.id && $0.text == saved.text })
        XCTAssertTrue(q.records.contains { $0.id == goodID && $0.endFrame - $0.startFrame == 1_600 })
        XCTAssertEqual(try Data(contentsOf: bad), badBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            journal.directory.appendingPathComponent("capture-" + badID.uuidString + ".json").path))
        await q.cancel()
    }

    private func assertRetiredChunkRebuilt(frames: Int, value: Float) async throws {
        let root = try directory("retired-\(frames)"), session = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        let recording = root.appendingPathComponent("recording.wav")
        try wave(recording, frames: 1_600)
        var record = work(session, recording: recording.lastPathComponent)
        record.audioRetired = true
        let stale = journal.directory.appendingPathComponent(record.audioFile)
        try wave(stale, frames: frames, value: value)
        let staleBytes = try Data(contentsOf: stale)
        try journal.put(record)
        let observed = DataSafetyAudioBox((frames: Int64(0), sample: Float(0), calls: 0))
        let q = DurableTranscriptionQueue { url, _, _ in
            let audio = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1)!
            try audio.read(into: buffer, frameCount: 1)
            observed.update { $0 = (audio.length, buffer.floatChannelData![0][0], $0.calls + 1) }
            return "A complete synthetic sentence."
        }
        try await q.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
        await q.finish()
        XCTAssertEqual(observed.value.calls, 1)
        XCTAssertEqual(observed.value.frames, 1_600)
        XCTAssertEqual(observed.value.sample, 0.125, accuracy: 0.00001)
        XCTAssertEqual(q.records.first?.status, .completed)
        let kept = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(kept.contains { (try? Data(contentsOf: $0)) == staleBytes })
        await q.cancel()
    }

    // A5: absence of samples cannot prove silence or completeness.
    func testRetiredShortChunkIsRebuiltBeforeTranscription() async throws {
        try await assertRetiredChunkRebuilt(frames: 200, value: 0.75)
    }
    func testRetiredEmptyChunkIsNotAcceptedAsSilence() async throws {
        try await assertRetiredChunkRebuilt(frames: 0, value: 0.75)
    }
    func testRetiredSameLengthDifferentPCMIsRebuilt() async throws {
        try await assertRetiredChunkRebuilt(frames: 1_600, value: 0.75)
    }

    // A6: a damaged acceleration cache must not defeat an intact log.
    func testCorruptSnapshotFallsBackToCompleteJournal() throws {
        let root = try directory("corrupt-cache"), session = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        let original = work(session)
        try journal.put(original); try journal.checkpoint()
        let snapshot = journal.directory.appendingPathComponent("snapshot.json")
        try FileManager.default.moveItem(at: snapshot, to: root.appendingPathComponent("known-good-snapshot.json"))
        let badBytes = Data("synthetic invalid cache".utf8)
        try badBytes.write(to: snapshot)
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        XCTAssertEqual(reopened.records, [original])
        let kept = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(kept.contains { (try? Data(contentsOf: $0)) == badBytes })
    }
    func testWrongSessionSnapshotIsStillRejected() throws {
        let root = try directory("wrong-cache-session"), session = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        try journal.put(work(session)); try journal.checkpoint()
        let bytes = try Data(contentsOf: journal.directory.appendingPathComponent("snapshot.json"))
        XCTAssertThrowsError(try DurableTranscriptionJournal(sessionDirectory: root, sessionID: UUID()))
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("snapshot.json")), bytes)
    }

    // A7: directory and log identity must be checked before recreating or appending.
    func testMovedJournalDirectoryCannotForkAtRecreatedPath() throws {
        let root = try directory("moved-journal"), session = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        try journal.put(work(session))
        let before = try Data(contentsOf: journal.directory.appendingPathComponent("work.jsonl"))
        let moved = root.appendingPathComponent("preserved-journal")
        try FileManager.default.moveItem(at: journal.directory, to: moved)
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try journal.put(work(session, ordinal: 1)))
        XCTAssertThrowsError(try journal.checkpoint())
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.directory.appendingPathComponent("work.jsonl").path))
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("work.jsonl")), before)
    }
    func testReplacedJournalLogIsNotExtended() throws {
        let root = try directory("replaced-log"), session = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        try journal.put(work(session))
        let log = journal.directory.appendingPathComponent("work.jsonl")
        let before = try Data(contentsOf: log)
        try FileManager.default.moveItem(at: log, to: root.appendingPathComponent("preserved-work.jsonl"))
        try Data().write(to: log)
        XCTAssertThrowsError(try journal.setCapturing(true))
        XCTAssertEqual(try Data(contentsOf: log), Data())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("preserved-work.jsonl")), before)
    }

    // A8: ingress rejects and already accepted but unwritten frames are disjoint.
    func testOverflowThenWriteFailureKeepsAllRejectedFramesAndReason() async throws {
        let queue = DispatchQueue(label: "DataSafetyAudio.BlockedConsumer")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        let notifications = DataSafetyAudioBox(0)
        let ring = try OwnedAudioCaptureBuffer(format: format(), queue: queue,
            consume: { _, _ in throw CocoaError(.fileWriteOutOfSpace) },
            failed: { _ in notifications.update { $0 += 1 } })
        XCTAssertEqual(ring.submit(pcm(32_000), observedEnd: 2), .accepted)
        XCTAssertEqual(ring.submit(pcm(4_000), observedEnd: 2.25), .overflow)
        XCTAssertEqual(ring.submit(pcm(500), observedEnd: 2.3), .closed)
        XCTAssertEqual(ring.failureSnapshot?.rejectedFrames, 4_500)
        release.signal()
        await ring.drain()
        await ring.drain()
        XCTAssertEqual(ring.failureSnapshot?.rejectedFrames, 36_500)
        XCTAssertTrue(ring.failureSnapshot?.reason.contains("两秒") == true)
        XCTAssertEqual(ring.failureSnapshot?.processedFrames, 0)
        XCTAssertEqual(ring.pendingFrames, 0)
        XCTAssertEqual(notifications.value, 1)
    }

    // C02: a stale live writer must fail without appending a duplicate sequence.
    func testTwoJournalWritersCannotAppendDuplicateSequence() throws {
        let root = try directory("journal-two-writers"), session = UUID()
        let first = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        let second = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        try first.setCapturing(true)
        let log = first.directory.appendingPathComponent("work.jsonl")
        let good = try Data(contentsOf: log)
        XCTAssertThrowsError(try second.setPaused(true))
        XCTAssertEqual(try Data(contentsOf: log), good)
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        XCTAssertFalse(reopened.processingState.isCapturing)
        XCTAssertFalse(reopened.isPaused)
    }

    private func assertStopDuringStartup(_ gate: DataSafetyMicrophone.Gate) async throws {
        let root = try directory("stop-startup"), mic = DataSafetyMicrophone(gate: gate)
        let p = pipeline(microphone: { mic })
        defer { mic.release(); mic.stop(); mic.removeTap() }
        let starting = Task.detached {
            do {
                try await p.start(inputMode: .microphone, recordingURL: root.appendingPathComponent("recording.wav"),
                                  sessionID: UUID(), eventHandler: { _ in })
                return true
            } catch { return false }
        }
        try await eventually { mic.gateEntered }
        await p.stopCapture(continueTranscribing: false)
        mic.release()
        let started = await starting.value
        await p.stopCapture(continueTranscribing: false)
        XCTAssertFalse(started)
        XCTAssertFalse(mic.gateTimedOut)
        XCTAssertFalse(mic.isRunning)
        XCTAssertFalse(mic.hasTap)
        XCTAssertFalse(p.transcriptionState()?.isCapturing ?? false)
    }
    // F01: stop must invalidate startup before either blocking device operation.
    func testStopDuringInitialFormatReadCannotReviveCapture() async throws {
        try await assertStopDuringStartup(.format)
    }
    func testStopDuringInitialTapInstallCannotReviveCapture() async throws {
        try await assertStopDuringStartup(.tap)
    }

    // F02: overlapping initial starts are refused before changing session ownership.
    func testOverlappingInitialStartsCannotMixSessions() async throws {
        let rootA = try directory("overlap-a"), rootB = try directory("overlap-b")
        let micA = DataSafetyMicrophone(gate: .format), micB = DataSafetyMicrophone(gate: .none)
        let calls = DataSafetyAudioBox(0)
        let p = pipeline(microphone: { calls.update { $0 += 1; return $0 == 1 ? micA : micB } })
        defer { micA.release(); micA.stop(); micA.removeTap(); micB.stop(); micB.removeTap() }
        let first = Task.detached {
            try await p.start(inputMode: .microphone, recordingURL: rootA.appendingPathComponent("recording.wav"),
                              sessionID: UUID(), eventHandler: { _ in })
        }
        try await eventually { micA.gateEntered }
        var secondRejected = false
        do {
            try await p.start(inputMode: .microphone, recordingURL: rootB.appendingPathComponent("recording.wav"),
                              sessionID: UUID(), eventHandler: { _ in })
        } catch { secondRejected = true }
        micA.release()
        try await first.value
        XCTAssertTrue(secondRejected)
        XCTAssertNil(micB.submit(pcm(1_600, value: 0.75)))
        XCTAssertEqual(micA.submit(pcm(1_600)), .accepted)
        await micA.drain()
        await p.stopCapture(continueTranscribing: false)
        let audio = try AVAudioFile(forReading: rootA.appendingPathComponent("recording.wav"))
        XCTAssertEqual(audio.length, 1_600)
        let sample = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1)!
        try audio.read(into: sample, frameCount: 1)
        XCTAssertEqual(sample.floatChannelData![0][0], 0.125, accuracy: 0.00001)
        XCTAssertFalse(micA.isRunning); XCTAssertFalse(micA.hasTap)
        XCTAssertFalse(micB.isRunning); XCTAssertFalse(micB.hasTap)
        try await p.pauseTranscription()
    }

    // C05: exercise the production task publication seam without Apple Speech.
    func testPreviewPreparedAfterStopCannotPublishUnownedTasks() async throws {
        guard #available(macOS 27, *) else { throw XCTSkip("Modern preview lifecycle requires macOS 27") }
        let root = try directory("late-preview"), p = pipeline()
        _ = try await p.startSyntheticCapture(format: format(), recordingURL: root.appendingPathComponent("recording.wav"),
                                            sessionID: UUID(), eventHandler: { _ in })
        let entered = DataSafetyAudioBox(false), gate = DataSafetyPreviewGate()
        let result = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(30)) }
        let analysis = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(30)) }
        let preparing = Task {
            await p.startSyntheticPreview(prepare: { entered.update { $0 = true }; await gate.wait() },
                                          result: result, analysis: analysis)
        }
        try await eventually { entered.value }
        await p.stopCapture(continueTranscribing: false)
        await gate.release()
        await preparing.value
        XCTAssertTrue(result.isCancelled)
        XCTAssertTrue(analysis.isCancelled)
        result.cancel(); analysis.cancel()
        await result.value; await analysis.value
        try await p.pauseTranscription()
    }
}
