import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import LiveLingo

private final class AudioTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.withLock { storage } }
    func update(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
}

private actor AudioTestGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

final class AudioRemediationTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-AudioRemediation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func format(_ rate: Double = 16_000, channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    }
    private func buffer(_ frames: Int, format: AVAudioFormat? = nil, value: Float = 0.05) -> AVAudioPCMBuffer {
        let f = format ?? self.format()
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(f.channelCount) {
            for frame in 0..<frames { b.floatChannelData![channel][frame] = value }
        }
        return b
    }
    private func audio(_ directory: URL, name: String = "input.wav", seconds: Double = 1) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let f = format()
        let file = try AVAudioFile(forWriting: url, settings: f.settings)
        try file.write(from: buffer(Int(seconds * f.sampleRate)))
        return url
    }
    private func waitUntil(_ test: @escaping @Sendable () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if test() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition was not reached", file: file, line: line)
    }
    private func work(_ session: UUID, ordinal: Int, status: TranscriptionWorkRecord.Status = .pending,
                      fallback: String? = nil) -> TranscriptionWorkRecord {
        var r = TranscriptionWorkRecord(id: UUID(), sessionID: session, ordinal: ordinal,
            audioFile: "chunk-\(ordinal).wav", startFrame: Int64(ordinal * 160_000),
            endFrame: Int64((ordinal + 1) * 160_000), sampleRate: 16_000,
            start: Double(ordinal * 10), end: Double((ordinal + 1) * 10), captureStart: nil, captureEnd: nil,
            modelKey: "primary", fallbackModelKey: fallback, appleEvidence: "")
        r.status = status
        return r
    }

    func testSealedInputFinishesAfterAllFramesAndOnlyOnce() async throws {
        let state = AudioTestBox((frames: 0, finishes: 0, framesAtFinish: 0))
        let input = try OwnedAudioCaptureBuffer(format: format(), queue: DispatchQueue(label: UUID().uuidString),
            consume: { pcm, _ in state.update { $0.frames += Int(pcm.frameLength) } }, failed: { _ in XCTFail("Unexpected input failure") },
            finish: { state.update { $0.finishes += 1; $0.framesAtFinish = $0.frames } })
        XCTAssertEqual(input.submit(buffer(8_000)), .accepted)
        await input.drain()
        XCTAssertEqual(state.value.finishes, 0)
        input.seal()
        await input.drain()
        input.seal()
        await input.drain()
        XCTAssertEqual(state.value.frames, 8_000)
        XCTAssertEqual(state.value.framesAtFinish, 8_000)
        XCTAssertEqual(state.value.finishes, 1)
    }

    func testTailFailureIsReportedOnceWithoutReprocessingInput() async throws {
        let state = AudioTestBox((frames: 0, finishes: 0, failures: 0))
        let input = try OwnedAudioCaptureBuffer(format: format(), queue: DispatchQueue(label: UUID().uuidString),
            consume: { pcm, _ in state.update { $0.frames += Int(pcm.frameLength) } },
            failed: { _ in state.update { $0.failures += 1 } },
            finish: { state.update { $0.finishes += 1 }; throw NSError(domain: "SyntheticTailFailure", code: 1) })
        XCTAssertEqual(input.submit(buffer(1_600)), .accepted)
        input.seal()
        await input.drain()
        await input.drain()
        XCTAssertEqual(state.value.frames, 1_600)
        XCTAssertEqual(state.value.finishes, 1)
        XCTAssertEqual(state.value.failures, 1)
        XCTAssertTrue(input.failureSnapshot?.reason.contains("尾部") == true)
    }

    func testFailedInputDoesNotFlushAdditionalConverterOutput() async throws {
        let finishes = AudioTestBox(0)
        let input = try OwnedAudioCaptureBuffer(format: format(), queue: DispatchQueue(label: UUID().uuidString),
            consume: { _, _ in throw NSError(domain: "SyntheticWriteFailure", code: 1) },
            failed: { _ in }, finish: { finishes.update { $0 += 1 } })
        XCTAssertEqual(input.submit(buffer(1_600)), .accepted)
        input.seal()
        await input.drain()
        XCTAssertNotNil(input.failureSnapshot)
        XCTAssertEqual(finishes.value, 0)
    }

    func testOwnedCapacityUsesActualInputFormat() throws {
        for f in [format(44_100), format(48_000, channels: 2), format(16_000)] {
            let ring = try OwnedAudioCaptureBuffer(format: f, queue: DispatchQueue(label: UUID().uuidString),
                                                  consume: { _, _ in }, failed: { _ in })
            XCTAssertEqual(ring.capacityFrames, Int(f.sampleRate * 2))
            XCTAssertEqual(ring.capacityBytes, Int(f.sampleRate * 2) * 4 * Int(f.channelCount))
        }
    }

    func testBorrowedBufferIsCopiedAndExactlyTwoSecondsCanQueue() async throws {
        let queue = DispatchQueue(label: UUID().uuidString)
        let blocked = DispatchSemaphore(value: 0)
        queue.async { blocked.wait() }
        let values = AudioTestBox<[Float]>([])
        let failures = AudioTestBox<[OwnedAudioCaptureBuffer.Failure]>([])
        let ring = try OwnedAudioCaptureBuffer(format: format(), queue: queue,
            consume: { b, _ in values.update { $0.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))) } },
            failed: { failure in failures.update { $0.append(failure) } })
        let borrowed = buffer(32_000, value: 0.125)
        XCTAssertEqual(ring.submit(borrowed, observedEnd: 2), .accepted)
        for i in 0..<32_000 { borrowed.floatChannelData![0][i] = 0.875 }
        XCTAssertEqual(ring.submit(buffer(1), observedEnd: 2.1), .overflow)
        XCTAssertEqual(ring.submit(buffer(16), observedEnd: 2.2), .closed)
        XCTAssertEqual(ring.pendingFrames, 32_000)
        blocked.signal()
        await ring.drain()
        XCTAssertEqual(values.value.count, 32_000)
        XCTAssertTrue(values.value.allSatisfy { $0 == 0.125 })
        XCTAssertEqual(failures.value.count, 1)
        XCTAssertEqual(ring.failureSnapshot?.rejectedFrames, 17)
        await ring.drain()
        XCTAssertEqual(failures.value.count, 1)
    }

    func testRingWrapPreservesOrderAndPauseDoesNotAdmitAudio() async throws {
        let values = AudioTestBox<[Float]>([])
        let ring = try OwnedAudioCaptureBuffer(format: format(), queue: DispatchQueue(label: UUID().uuidString),
            consume: { b, _ in values.update { $0.append(contentsOf: UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))) } },
            failed: { _ in XCTFail("unexpected ring failure") })
        ring.submit(buffer(25_000, value: 0.25)); await ring.drain()
        ring.setPaused(true)
        XCTAssertEqual(ring.submit(buffer(1)), .paused)
        ring.setPaused(false)
        ring.submit(buffer(16_000, value: 0.75)); await ring.drain()
        ring.seal()
        XCTAssertEqual(ring.submit(buffer(1)), .closed)
        XCTAssertEqual(values.value.count, 41_000)
        XCTAssertTrue(values.value.prefix(25_000).allSatisfy { $0 == 0.25 })
        XCTAssertTrue(values.value.suffix(16_000).allSatisfy { $0 == 0.75 })
    }

    func testConsumerFailureStopsOnceAndKeepsWrittenPrefix() async throws {
        let calls = AudioTestBox(0)
        let failures = AudioTestBox<[OwnedAudioCaptureBuffer.Failure]>([])
        let ring = try OwnedAudioCaptureBuffer(format: format(), queue: DispatchQueue(label: UUID().uuidString),
            consume: { _, _ in
                calls.update { $0 += 1 }
                if calls.value == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            }, failed: { f in failures.update { $0.append(f) } })
        ring.submit(buffer(10_000))
        await ring.drain()
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(failures.value.count, 1)
        XCTAssertEqual(failures.value.first?.processedFrames, 4096)
        XCTAssertEqual(ring.submit(buffer(1)), .closed)
    }

    func testTwoHourMetadataBacklogAndPersistentRetryBudget() throws {
        let root = try directory(), id = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        try journal.setPaused(true)
        for ordinal in 0..<720 { try journal.put(work(id, ordinal: ordinal)) }
        XCTAssertEqual(journal.processingState.backlogSeconds, 7_200)
        XCTAssertEqual(journal.processingState.pendingCount, 720)
        XCTAssertEqual(journal.processingState.prefetchedCount, 0)
        try journal.checkpoint()
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        XCTAssertTrue(reopened.isPaused)
        XCTAssertEqual(reopened.records.map(\.id), journal.records.map(\.id))
        XCTAssertEqual(reopened.processingState.backlogSeconds, 7_200)
    }

    func testAutomaticRetriesAreDebitedBeforeASRAcrossRestarts() throws {
        let root = try directory(), id = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        var record = work(id, ordinal: 0, status: .retryWaiting)
        try journal.put(record)
        let first = try XCTUnwrap(journal.claimNext())
        XCTAssertEqual(first.automaticRetryCount, 1)
        let restart1 = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        let second = try XCTUnwrap(restart1.claimNext())
        XCTAssertEqual(second.automaticRetryCount, 2)
        let restart2 = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        record = try XCTUnwrap(restart2.record(id: record.id))
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.automaticRetryCount, 2)
        XCTAssertNil(try restart2.claimNext())
        try restart2.retry(id: record.id)
        let manual = try XCTUnwrap(restart2.claimNext())
        XCTAssertEqual(manual.automaticRetryCount, 2)
        XCTAssertEqual(manual.manualRetryCount, 1)
    }

    func testTruncatedTailIsPreservedAndMiddleDamageStopsRecovery() throws {
        let root = try directory(), id = UUID()
        let j = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        try j.put(work(id, ordinal: 0))
        let url = j.directory.appendingPathComponent("work.jsonl")
        let good = try Data(contentsOf: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{unfinished".utf8)); try handle.close()
        let restored = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        XCTAssertTrue(restored.recoveredTruncatedTail)
        XCTAssertEqual(try Data(contentsOf: url), good)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: j.directory.path).filter { $0.hasPrefix("truncated-tail-") }.count, 1)
        let bad = Data("broken\n".utf8) + good
        try bad.write(to: url)
        XCTAssertThrowsError(try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id))
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testWrongSessionAndDuplicateRangeAreRejected() throws {
        let root = try directory(), id = UUID()
        let j = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        try j.put(work(id, ordinal: 0)); try j.checkpoint()
        XCTAssertThrowsError(try DurableTranscriptionJournal(sessionDirectory: root, sessionID: UUID()))
        let old = try XCTUnwrap(j.records.first)
        let conflict = TranscriptionWorkRecord(id: old.id, sessionID: id, ordinal: 0, audioFile: old.audioFile,
            startFrame: 16_000, endFrame: 176_000, sampleRate: 16_000, start: 1, end: 11,
            captureStart: nil, captureEnd: nil, modelKey: "primary", fallbackModelKey: nil, appleEvidence: "")
        XCTAssertThrowsError(try j.put(conflict))
        XCTAssertEqual(j.records.first, old)
    }

    func testUsablePrimarySurvivesFallbackFailureAndConflictBecomesCandidate() async throws {
        for fallbackFails in [true, false] {
            let root = try directory(), id = UUID(), chunkID = UUID()
            let wav = try audio(root, seconds: 10)
            let events = AudioTestBox<[SpeechPipeline.Event]>([])
            let q = DurableTranscriptionQueue { _, model, _ in
                if model == "primary" { return "Okay." }
                if fallbackFails { throw URLError(.timedOut) }
                return "A different proposed answer."
            }
            try await q.configure(directory: root, sessionID: id, persistent: true, identified: true,
                                  handler: { e in events.update { $0.append(e) } })
            q.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 10,
                           appleEvidence: "", recordingURL: nil, id: chunkID, sessionID: id), handler: { _ in })
            await q.finish()
            let finals = events.value.compactMap { e -> TranscriptionCommit? in if case .identifiedFinal(let c) = e { return c }; return nil }
            XCTAssertEqual(finals.count, 1)
            XCTAssertEqual(finals.first?.id, chunkID)
            XCTAssertEqual(finals.first?.text, "Okay.")
            XCTAssertEqual(q.records.first?.text, "Okay.")
            XCTAssertEqual(q.records.first?.candidateText != nil, !fallbackFails)
        }
    }

    func testSameRangeRepairKeepsIdentityAndExistingTextRequiresConfirmation() async throws {
        let root = try directory(), id = UUID(), chunk = UUID(), wav = try audio(root)
        let calls = AudioTestBox(0), events = AudioTestBox<[SpeechPipeline.Event]>([])
        let q = DurableTranscriptionQueue { _, _, _ in
            calls.update { $0 += 1 }
            return calls.value == 1 ? "" : "The recording contains a useful sentence."
        }
        try await q.configure(directory: root, sessionID: id, persistent: true, identified: true,
                              handler: { e in events.update { $0.append(e) } })
        q.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                       appleEvidence: "", recordingURL: nil, id: chunk, sessionID: id), handler: { _ in })
        await q.finish()
        let first = events.value.compactMap { e -> TranscriptionCommit? in if case .identifiedFinal(let c) = e { return c }; return nil }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.id, chunk)
        XCTAssertEqual(first.first?.isRepair, true)
        try q.retainExistingText(id: chunk, text: "User corrected this sentence.")
        try q.retry(id: chunk); await q.finish()
        XCTAssertEqual(q.records.first?.text, "User corrected this sentence.")
        XCTAssertEqual(q.records.first?.candidateOrigin, "sameRangeRevision")
        XCTAssertEqual(events.value.filter { if case .identifiedFinal = $0 { return true }; return false }.count, 1)
    }

    func testNewGenerationStartsWithoutWaitingForUncooperativeOldASR() async throws {
        let old = try directory(), newer = try directory(), firstID = UUID(), nextID = UUID()
        let gate = AudioTestGate(), entered = AudioTestBox(false)
        let events = AudioTestBox<[SpeechPipeline.Event]>([])
        let q = DurableTranscriptionQueue { url, _, _ in
            if url.lastPathComponent == "old.wav" { entered.update { $0 = true }; await gate.wait() }
            return "A complete sentence from the input."
        }
        try await q.configure(directory: old, sessionID: firstID, persistent: true, identified: true,
                              handler: { e in events.update { $0.append(e) } })
        let first = try audio(old, name: "old.wav")
        q.submit(.init(audioURL: first, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                       appleEvidence: "", recordingURL: nil, sessionID: firstID), handler: { _ in })
        try await waitUntil { entered.value }
        try await q.configure(directory: newer, sessionID: nextID, persistent: true, identified: true,
                              handler: { e in events.update { $0.append(e) } })
        let second = try audio(newer, name: "new.wav")
        q.submit(.init(audioURL: second, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                       appleEvidence: "", recordingURL: nil, sessionID: nextID), handler: { _ in })
        XCTAssertEqual(q.state?.sessionID, nextID)
        XCTAssertEqual(q.state?.pendingCount, 1)
        XCTAssertEqual(q.state?.activeCount, 0)
        await gate.release(); await q.finish()
        let commits = events.value.compactMap { e -> TranscriptionCommit? in if case .identifiedFinal(let c) = e { return c }; return nil }
        XCTAssertEqual(commits.map(\.sessionID), [nextID])
        let restored = try DurableTranscriptionJournal(sessionDirectory: old, sessionID: firstID)
        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(restored.processingState.pendingCount, 1)
    }

    func testPausedQueueRestoreWaitsForExplicitResume() async throws {
        let root = try directory(), id = UUID(), wav = try audio(root)
        let q = DurableTranscriptionQueue { _, _, _ in throw CancellationError() }
        try await q.configure(directory: root, sessionID: id, persistent: true, identified: true, handler: { _ in })
        try q.requestPause()
        q.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                       appleEvidence: "", recordingURL: nil, sessionID: id), handler: { _ in })
        let calls = AudioTestBox(0)
        let restored = DurableTranscriptionQueue { _, _, _ in calls.update { $0 += 1 }; return "Recovered after explicit resume." }
        try await restored.configure(directory: root, sessionID: id, persistent: true, identified: true, restoring: true, handler: { _ in })
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(restored.state?.isPaused, true)
        try restored.resume(); await restored.finish()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(restored.records.first?.id, q.records.first?.id)
    }

    func testStopCaptureDoesNotWaitForASRAndRepeatedStopHasOneFinalChunk() async throws {
        let root = try directory(), id = UUID(), gate = AudioTestGate()
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in await gate.wait(); return "Final stable sentence." }, enableAudioAnalysis: false)
        let wav = root.appendingPathComponent("recording.wav")
        let ring = try await pipeline.startSyntheticCapture(format: format(), recordingURL: wav, sessionID: id, eventHandler: { _ in })
        ring.submit(buffer(16_000)); await ring.drain()
        async let a: Void = pipeline.stopCapture()
        async let b: Void = pipeline.stopCapture()
        _ = await (a, b)
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 16_000)
        XCTAssertEqual(pipeline.transcriptionWork().count, 1)
        XCTAssertEqual(pipeline.transcriptionState()?.isCapturing, false)
        XCTAssertEqual(pipeline.transcriptionState()?.pendingCount, 1)
        await gate.release(); await pipeline.stop()
        XCTAssertEqual(pipeline.transcriptionWork().count, 1)
    }

    func testSavedCancelPreservesUnfinishedAudioButLiveOnlyCleansItsWork() async throws {
        for saved in [true, false] {
            let root = try directory(), id = UUID()
            let pipeline = SpeechPipeline(transcriber: { _, _, _ in try await Task.sleep(for: .seconds(30)); return "Unused sentence." }, enableAudioAnalysis: false)
            let recording = saved ? root.appendingPathComponent("recording.wav") : nil
            let ring = try await pipeline.startSyntheticCapture(format: format(), recordingURL: recording, sessionID: id, eventHandler: { _ in })
            let workDirectory = try XCTUnwrap(pipeline.syntheticWorkDirectory)
            ring.submit(buffer(16_000)); await ring.drain()
            await pipeline.cancel()
            XCTAssertEqual(FileManager.default.fileExists(atPath: workDirectory.path), saved)
            if let recording {
                XCTAssertEqual(try AVAudioFile(forReading: recording).length, 16_000)
                let queue = DurableTranscriptionQueue { _, _, _ in "Recovered saved audio." }
                try await queue.configure(directory: root, sessionID: id, persistent: true, identified: true, restoring: true, handler: { _ in })
                XCTAssertEqual(queue.state?.isPaused, true)
                try queue.resume(); await queue.finish()
                XCTAssertEqual(queue.records.first?.text, "Recovered saved audio.")
            }
        }
    }

    func testUnsealedChunkAfterCrashIsRecoveredWithoutChangingOriginalBytes() async throws {
        let root = try directory(), id = UUID(), chunkID = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        let raw = journal.directory.appendingPathComponent("unfinished.wav")
        let f = format()
        let writer = try AVAudioFile(forWriting: raw, settings: f.settings)
        try writer.write(from: buffer(32_000))
        try DurableTranscriptionJournal.stageCapture(CaptureChunkDescriptor(id: chunkID, sessionID: id,
            ordinal: 0, audioFile: raw.lastPathComponent, recordingFile: nil, startFrame: 16_000,
            sampleRate: 16_000, modelKey: "primary", fallbackModelKey: nil), directory: journal.directory)
        let before = try Data(contentsOf: raw)
        let expectedFrames = try WAVContextClip.readLayout(at: raw).frameCount
        let queue = DurableTranscriptionQueue { _, _, _ in "Recovered the open audio chunk." }
        try await queue.configure(directory: root, sessionID: id, persistent: true, identified: true, restoring: true, handler: { _ in })
        await queue.finish()
        XCTAssertEqual(queue.records.first?.id, chunkID)
        XCTAssertEqual(queue.records.first?.startFrame, 16_000)
        XCTAssertEqual(queue.records.first?.endFrame, 16_000 + Int64(expectedFrames))
        XCTAssertEqual(try Data(contentsOf: raw), before)
        XCTAssertEqual(queue.records.first?.status, .completed)
        withExtendedLifetime(writer) {}
    }

    func testOldFinishReturnsWhileNewGenerationASRRemainsBlocked() async throws {
        let oldRoot = try directory(), newRoot = try directory(), oldID = UUID(), newID = UUID()
        let oldGate = AudioTestGate(), newGate = AudioTestGate()
        let oldEntered = AudioTestBox(false), newEntered = AudioTestBox(false)
        let finishing = AudioTestBox(false), finished = AudioTestBox(false)
        let queue = DurableTranscriptionQueue { url, _, _ in
            if url.lastPathComponent == "old.wav" { oldEntered.update { $0 = true }; await oldGate.wait() }
            else { newEntered.update { $0 = true }; await newGate.wait() }
            return "One sentence from this session."
        }
        try await queue.configure(directory: oldRoot, sessionID: oldID, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: try audio(oldRoot, name: "old.wav"), modelKey: "primary", fallbackModelKey: nil,
                           start: 0, end: 1, appleEvidence: "", recordingURL: nil, sessionID: oldID), handler: { _ in })
        try await waitUntil { oldEntered.value }
        let finish = Task { finishing.update { $0 = true }; await queue.finish(sessionID: oldID); finished.update { $0 = true } }
        try await waitUntil { finishing.value }
        try await queue.configure(directory: newRoot, sessionID: newID, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: try audio(newRoot, name: "new.wav"), modelKey: "primary", fallbackModelKey: nil,
                           start: 0, end: 1, appleEvidence: "", recordingURL: nil, sessionID: newID), handler: { _ in })
        await oldGate.release()
        try await waitUntil { newEntered.value }
        try await waitUntil { finished.value }
        XCTAssertEqual(queue.state?.activeCount, 1)
        await newGate.release(); await queue.finish(sessionID: newID); await finish.value
    }

    func testTwoHourSlowASRBacklogKeepsOneActiveRequestAndNoPrefetch() async throws {
        let root = try directory(), id = UUID(), gate = AudioTestGate()
        let calls = AudioTestBox((active: 0, peak: 0, started: 0))
        let queue = DurableTranscriptionQueue { _, _, _ in
            calls.update { $0.active += 1; $0.started += 1; $0.peak = max($0.peak, $0.active) }
            await gate.wait()
            calls.update { $0.active -= 1 }
            return "The lecture sentence has finished."
        }
        try await queue.configure(directory: root, sessionID: id, persistent: true, identified: true, handler: { _ in })
        let source = try audio(root, seconds: 10)
        let journalRoot = try XCTUnwrap(queue.journalDirectory)
        for ordinal in 0..<720 {
            let path = journalRoot.appendingPathComponent("stress-\(ordinal).wav")
            try FileManager.default.copyItem(at: source, to: path)
            queue.submit(.init(audioURL: path, modelKey: "primary", fallbackModelKey: nil,
                start: Double(ordinal * 10), end: Double((ordinal + 1) * 10), appleEvidence: "", recordingURL: nil,
                sessionID: id), handler: { _ in })
        }
        try await waitUntil { calls.value.started == 1 }
        XCTAssertEqual(queue.state?.pendingCount, 720)
        XCTAssertEqual(queue.state?.backlogSeconds, 7_200)
        XCTAssertEqual(queue.state?.activeCount, 1)
        XCTAssertEqual(queue.state?.prefetchedCount, 0)
        try queue.requestPause()
        await gate.release(); await queue.finish()
        XCTAssertEqual(calls.value.peak, 1)
        let restored = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        XCTAssertEqual(restored.records.count, 720)
        XCTAssertEqual(restored.processingState.backlogSeconds, 7_200)
        XCTAssertTrue(restored.isPaused)
    }

    func testPipelineDiskFailureSealsReadablePrefixAndEmitsOneGapAndTerminal() async throws {
        let root = try directory(), id = UUID()
        let writes = AudioTestBox(0), events = AudioTestBox<[SpeechPipeline.Event]>([])
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Previously recorded sentence." },
            beforeAudioWrite: {
                writes.update { $0 += 1 }
                if writes.value == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            }, enableAudioAnalysis: false)
        let recording = root.appendingPathComponent("recording.wav")
        let ring = try await pipeline.startSyntheticCapture(format: format(), recordingURL: recording,
            sessionID: id, eventHandler: { event in events.update { $0.append(event) } })
        ring.submit(buffer(16_000)); await ring.drain()
        try await waitUntil { events.value.contains { if case .failure = $0 { return true }; return false } }
        await pipeline.stopCapture(); await pipeline.drainTranscription(sessionID: id)
        XCTAssertEqual(try AVAudioFile(forReading: recording).length, 4096)
        XCTAssertEqual(events.value.filter { if case .failure = $0 { return true }; return false }.count, 1)
        let gaps = events.value.compactMap { event -> CaptureGap? in if case .captureGap(let g) = event { return g }; return nil }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.lastWrittenFrame, 4096)
        XCTAssertEqual(gaps.first?.rejectedFrames, 16_000 - 4096)
        XCTAssertEqual(pipeline.transcriptionWork().first?.endFrame, 4096)
    }

    func testConflictingJournalReplayPreservesCorrectedBodyAndPersistsCandidate() async throws {
        let root = try directory(), id = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        var record = work(id, ordinal: 0, status: .completed)
        record.text = "The recognizer said the pressure increases."
        _ = try audio(journal.directory, name: record.audioFile, seconds: 10)
        try journal.put(record)
        let emitted = AudioTestBox<[TranscriptionCandidate]>([])
        let queue = DurableTranscriptionQueue { _, _, _ in
            XCTFail("Restoring completed text must not invoke ASR")
            return ""
        }
        try await queue.configure(directory: root, sessionID: id, persistent: true,
            identified: true, restoring: true, startPaused: true) { event in
                if case .transcriptionCandidate(let candidate) = event {
                    emitted.update { $0.append(candidate) }
                }
            }
        let original = "The user confirmed the pressure decreases."
        let candidate = try XCTUnwrap(record.text)
        try queue.preserveConflictingTranscript(id: record.id, sessionID: id,
            originalText: original, candidateText: candidate)
        XCTAssertEqual(queue.records.first?.text, original)
        XCTAssertEqual(queue.records.first?.candidateText, candidate)
        XCTAssertEqual(emitted.value.last?.originalText, original)
        XCTAssertEqual(emitted.value.last?.text, candidate)
        XCTAssertThrowsError(try queue.preserveConflictingTranscript(id: record.id, sessionID: id,
            originalText: original, candidateText: "Another unconfirmed replacement."))
        XCTAssertThrowsError(try queue.resolveCandidate(id: record.id, acceptedText: "Stale acceptance",
            expectedOriginal: candidate, expectedCandidate: candidate))
        XCTAssertThrowsError(try queue.resolveCandidate(id: record.id, acceptedText: nil,
            expectedOriginal: original, expectedCandidate: "Old candidate"))
        await queue.cancel()
        let reread = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        XCTAssertEqual(reread.records.first?.text, original)
        XCTAssertEqual(reread.records.first?.candidateText, candidate)
        try queue.resolveCandidate(id: record.id, acceptedText: nil,
            expectedOriginal: original, expectedCandidate: candidate)
        XCTAssertEqual(queue.records.first?.text, original)
        XCTAssertNil(queue.records.first?.candidateText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.directory.appendingPathComponent(record.audioFile).path))
    }

    func testCandidateAcknowledgementRecoversOnlyAnExactDurableConsent() async throws {
        for mode in ["accepted", "no-consent", "newer-candidate"] {
            let root = try directory(), session = UUID()
            let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
            var record = work(session, ordinal: 0, status: .completed)
            record.text = "The pressure increases."
            record.candidateText = "The pressure decreases."
            record.candidateOrigin = "sameRangeRevision"
            _ = try audio(journal.directory, name: record.audioFile, seconds: 10)
            try journal.put(record)
            let original = TranscriptSegment(id: record.id, startTime: 0, endTime: 10,
                english: record.text!, sessionID: session)
            let replacement = TranscriptSegment(id: record.id, startTime: 0, endTime: 10,
                english: "The pressure decreases steadily.", sessionID: session, inputRevision: 1)
            let store = SessionStore(directory: root)
            _ = try store.save(.init(sessionID: session, segments: [original]))
            _ = try store.append(.inputRevision(.init(fromRevision: 0, toRevision: 1,
                previousSegment: original, replacementSegment: replacement, reason: "Confirmed by test user",
                transcriptionCandidateText: mode == "no-consent" ? nil : record.candidateText)))
            if mode == "newer-candidate" {
                record.candidateText = "A different candidate now awaits confirmation."
                try journal.put(record)
            }
            let emitted = AudioTestBox<[String]>([])
            let queue = DurableTranscriptionQueue { _, _, _ in
                XCTFail("Restoring completed text cannot call the recognizer")
                return ""
            }
            try await queue.configure(directory: root, sessionID: session, persistent: true,
                identified: true, restoring: true, startPaused: true) { event in
                    if case .identifiedFinal(let value) = event { emitted.update { $0.append(value.text) } }
                }
            if mode == "accepted" {
                XCTAssertEqual(emitted.value, [replacement.english])
                XCTAssertEqual(queue.records.first?.text, replacement.english)
                XCTAssertNil(queue.records.first?.candidateText)
            } else {
                XCTAssertEqual(queue.records.first?.text, original.english)
                XCTAssertEqual(queue.records.first?.candidateText, record.candidateText)
            }
            await queue.cancel()
            let recovered = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
            XCTAssertEqual(recovered.records.first?.candidateText, mode == "accepted" ? nil : record.candidateText)
            XCTAssertEqual(try store.load()?.revisionHistory.first?.previousSegment.english, original.english)
        }
    }

    func testAutomaticASRReusesExactRequestsButKeepsContextSeparate() async throws {
        let root = try directory(), session = UUID(), chunk = UUID()
        let wav = try audio(root, name: "chunk.wav", seconds: 10)
        let recording = try audio(root, name: "recording.wav", seconds: 12)
        let calls = AudioTestBox<[String]>([]), events = AudioTestBox<[SpeechPipeline.Event]>([])
        let queue = DurableTranscriptionQueue { url, model, enhanced in
            let frames = try AVAudioFile(forReading: url).length
            calls.update { $0.append("\(model):\(enhanced):\(frames)") }
            return frames > 160_000 ? "A contextual candidate requires confirmation." : ""
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                  handler: { e in events.update { $0.append(e) } })
        queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 10,
                           appleEvidence: "", recordingURL: recording, id: chunk, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertEqual(calls.value.count, 4, "Only raw primary, enhanced primary/fallback, and a different context clip need inference")
        XCTAssertEqual(calls.value.filter { $0 == "primary:true:160000" }.count, 1)
        XCTAssertEqual(calls.value.filter { $0 == "fallback:true:160000" }.count, 1)
        let record = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.automaticRetryCount, 2)
        XCTAssertNil(record.text)
        XCTAssertEqual(record.candidateOrigin, "context")
        XCTAssertEqual(record.candidateText, "A contextual candidate requires confirmation.")
        XCTAssertFalse(events.value.contains { if case .identifiedFinal = $0 { return true }; return false })
    }

    func testAutomaticASRReuseKeepsDifferentModelsSeparate() async throws {
        let root = try directory(), session = UUID(), wav = try audio(root)
        let calls = AudioTestBox<[String]>([])
        let queue = DurableTranscriptionQueue { _, model, enhanced in
            calls.update { $0.append("\(model):\(enhanced)") }; return ""
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertEqual(calls.value, ["primary:false", "fallback:true", "primary:true"])
        XCTAssertEqual(queue.records.first?.automaticRetryCount, 2)
        XCTAssertEqual(queue.records.first?.status, .failed)
    }

    func testManualASRRetryStartsFreshAfterAutomaticExhaustion() async throws {
        let root = try directory(), session = UUID(), chunk = UUID(), wav = try audio(root)
        let calls = AudioTestBox(0), manual = AudioTestBox(false)
        let queue = DurableTranscriptionQueue { _, _, _ in
            calls.update { $0 += 1 }
            return manual.value ? "A fresh manual recognition result." : ""
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, id: chunk, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertEqual(calls.value, 2)
        manual.update { $0 = true }
        try queue.retry(id: chunk); await queue.finish()
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(queue.records.first?.text, "A fresh manual recognition result.")
        XCTAssertEqual(queue.records.first?.manualRetryCount, 1)
        XCTAssertEqual(queue.records.first?.automaticRetryCount, 2)
    }

    func testAutomaticASRReuseDoesNotCrossChunkIdentity() async throws {
        let root = try directory(), session = UUID()
        let calls = AudioTestBox(0)
        let queue = DurableTranscriptionQueue { _, _, _ in calls.update { $0 += 1 }; return "" }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                  startPaused: true, handler: { _ in })
        for ordinal in 0..<2 {
            let wav = try audio(root, name: "chunk-\(ordinal).wav")
            queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: nil,
                               start: Double(ordinal), end: Double(ordinal+1), appleEvidence: "", recordingURL: nil,
                               sessionID: session), handler: { _ in })
        }
        try queue.resume(); await queue.finish()
        XCTAssertEqual(calls.value, 4)
        XCTAssertEqual(queue.records.count, 2)
        XCTAssertTrue(queue.records.allSatisfy { $0.status == .failed && $0.automaticRetryCount == 2 })
    }

    func testAutomaticASRReuseDoesNotRetainTransientErrors() async throws {
        let root = try directory(), session = UUID(), wav = try audio(root)
        let calls = AudioTestBox(0)
        let queue = DurableTranscriptionQueue { _, _, _ in
            calls.update { $0 += 1 }
            if calls.value == 2 { throw URLError(.timedOut) }
            return calls.value == 3 ? "A successful retry after a transient failure." : ""
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(queue.records.first?.status, .completed)
        XCTAssertEqual(queue.records.first?.text, "A successful retry after a transient failure.")
    }

    func testChangedAudioCannotReuseAnEarlierRecognition() async throws {
        let root = try directory(), session = UUID(), wav = try audio(root)
        let calls = AudioTestBox(0)
        let queue = DurableTranscriptionQueue { url, _, _ in
            calls.update { $0 += 1 }
            if calls.value == 2 {
                let file = try AVAudioFile(forWriting: url, settings: self.format().settings)
                try file.write(from: self.buffer(16_000, value: 0.1))
            }
            return calls.value == 3 ? "The changed waveform needs a fresh result." : ""
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(queue.records.first?.text, "The changed waveform needs a fresh result.")
    }

    func testCancelledAutomaticASRReturnIsNotReused() async throws {
        let root = try directory(), session = UUID(), chunk = UUID()
        let old = try audio(root, name: "old.wav"), next = try audio(root, name: "new.wav")
        let gate = AudioTestGate(), entered = AudioTestBox(false), calls = AudioTestBox(0)
        let queue = DurableTranscriptionQueue { url, _, _ in
            if url.lastPathComponent == "new.wav" { return "The newly captured caption has priority." }
            calls.update { $0 += 1 }
            if calls.value == 2 { entered.update { $0 = true }; await gate.wait() }
            return calls.value == 3 ? "The old interval now has a valid result." : ""
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: old, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, id: chunk, sessionID: session), handler: { _ in })
        try await waitUntil { entered.value }
        queue.submit(.init(audioURL: next, modelKey: "primary", fallbackModelKey: nil, start: 1, end: 2,
                           appleEvidence: "", recordingURL: nil, sessionID: session), handler: { _ in })
        await gate.release(); await queue.finish()
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(queue.records.first { $0.id == chunk }?.text, "The old interval now has a valid result.")
        XCTAssertEqual(queue.records.first { $0.id == chunk }?.automaticRetryCount, 2)
        XCTAssertTrue(queue.records.allSatisfy { $0.status == .completed })
    }

    func testAutomaticASRReuseIsDiscardedWhenTheSessionChanges() async throws {
        let oldRoot = try directory(), newRoot = try directory(), oldSession = UUID(), newSession = UUID(), chunk = UUID()
        let gate = AudioTestGate(), entered = AudioTestBox(false), fallbackCalls = AudioTestBox(0)
        let events = AudioTestBox<[TranscriptionCommit]>([])
        let queue = DurableTranscriptionQueue { url, model, enhanced in
            if model == "primary" {
                if enhanced && url.path.hasPrefix(oldRoot.path + "/") {
                    entered.update { $0 = true }; await gate.wait()
                }
                return ""
            }
            fallbackCalls.update { $0 += 1 }
            return fallbackCalls.value == 1 ? "" : "A new session owns this result."
        }
        let handler: @Sendable (SpeechPipeline.Event) -> Void = { event in
            if case .identifiedFinal(let commit) = event { events.update { $0.append(commit) } }
        }
        try await queue.configure(directory: oldRoot, sessionID: oldSession, persistent: true, identified: true, handler: handler)
        queue.submit(.init(audioURL: try audio(oldRoot), modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, id: chunk, sessionID: oldSession), handler: handler)
        try await waitUntil { entered.value }
        try await queue.configure(directory: newRoot, sessionID: newSession, persistent: true, identified: true, handler: handler)
        queue.submit(.init(audioURL: try audio(newRoot), modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, id: chunk, sessionID: newSession), handler: handler)
        await gate.release(); await queue.finish()
        XCTAssertEqual(fallbackCalls.value, 2)
        XCTAssertEqual(events.value.count, 1)
        XCTAssertEqual(events.value.first?.sessionID, newSession)
        XCTAssertEqual(events.value.first?.text, "A new session owns this result.")
    }

    func testPauseDiscardsAutomaticASRReuseBeforeResuming() async throws {
        let root = try directory(), session = UUID(), wav = try audio(root)
        let fallbackCalls = AudioTestBox(0), paused = AudioTestBox(false)
        let holder = AudioTestBox<DurableTranscriptionQueue?>(nil)
        let queue = DurableTranscriptionQueue { _, model, _ in
            guard model == "fallback" else { return "" }
            fallbackCalls.update { $0 += 1 }
            return fallbackCalls.value == 1 ? "" : "A fresh result after resuming."
        }
        holder.update { $0 = queue }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true) { event in
            guard case .processing = event, !paused.value,
                  let owner = holder.value, owner.records.first?.status == .retryWaiting else { return }
            paused.update { $0 = true }
            do { try owner.requestPause() } catch { XCTFail("Pause failed: \(error)") }
        }
        queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, sessionID: session), handler: { _ in })
        try await waitUntil { paused.value }; await queue.finish()
        XCTAssertEqual(fallbackCalls.value, 1)
        XCTAssertEqual(queue.state?.isPaused, true)
        try queue.resume(); await queue.finish()
        XCTAssertEqual(fallbackCalls.value, 2)
        XCTAssertEqual(queue.records.first?.text, "A fresh result after resuming.")
        holder.update { $0 = nil }
    }

    func testOversizedASRResultsAreNotRetainedForRetry() async throws {
        let root = try directory(), session = UUID(), wav = try audio(root)
        let calls = AudioTestBox(0)
        let queue = DurableTranscriptionQueue { _, _, _ in
            calls.update { $0 += 1 }; return String(repeating: "?", count: 16_385)
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: nil, start: 0, end: 1,
                           appleEvidence: "", recordingURL: nil, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(queue.records.first?.status, .failed)
        XCTAssertNil(queue.records.first?.text)
    }

    func testOldCaptureCallbackCannotWriteIntoANewSession() async throws {
        let first = try directory(), second = try directory()
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "The retained recording." }, enableAudioAnalysis: false)
        let old = try await pipeline.startSyntheticCapture(format: format(), recordingURL: first.appendingPathComponent("recording.wav"),
            sessionID: UUID(), eventHandler: { _ in })
        old.submit(buffer(8_000)); await old.drain(); await pipeline.stopCapture()
        let new = try await pipeline.startSyntheticCapture(format: format(), recordingURL: second.appendingPathComponent("recording.wav"),
            sessionID: UUID(), eventHandler: { _ in })
        XCTAssertEqual(old.submit(buffer(16_000)), .closed)
        new.submit(buffer(4_000)); await new.drain(); await pipeline.stop()
        XCTAssertEqual(try AVAudioFile(forReading: first.appendingPathComponent("recording.wav")).length, 8_000)
        XCTAssertEqual(try AVAudioFile(forReading: second.appendingPathComponent("recording.wav")).length, 4_000)
    }

    // MARK: - Non-English speech and persisted failure reasons

    func testEnglishGateVerdictNamesTheRejectionWithoutChangingAcceptance() {
        XCTAssertEqual(EnglishTranscriptGate.verdict("是。我也想要。"), .hanDominant)
        XCTAssertEqual(EnglishTranscriptGate.verdict("Use 力"), .hanDominant)
        XCTAssertEqual(EnglishTranscriptGate.verdict("The symbol 力 means force in this textbook."), .accepted)
        XCTAssertEqual(EnglishTranscriptGate.verdict("Привет, мир"), .noLatin)
        XCTAssertEqual(EnglishTranscriptGate.verdict("……"), .noLatin)
        XCTAssertEqual(EnglishTranscriptGate.verdict("2 + 2 = 4"), .accepted)
        XCTAssertEqual(EnglishTranscriptGate.verdict("  "), .accepted)
        let loop = "We know we know we know we know we know we know the velocity."
        let runaway = (0..<45).map { "word\($0)" }.joined(separator: " ")
        let samples = ["", "  ", "Okay.", "123", "是。我也想要。", "这是中文", "Use 力", "Привет, мир", "……",
                       "The symbol 力 means force in this textbook.", "OK 那我们来看一下这个 equation",
                       "damaged \u{FFFD} text", loop, runaway]
        for text in samples {
            XCTAssertEqual(EnglishTranscriptGate.accepts(text), EnglishTranscriptGate.verdict(text) == .accepted, text)
            // A reason exists exactly when the shared caption gate drops the text.
            for duration in [2.0, 10.0] {
                XCTAssertEqual(TranscriptionWorkRecord.FailureReason.rejection(of: text, audioDuration: duration) == nil,
                               !SpeechPipeline.preferredTranscript(primary: nil, fallback: text, audioDuration: duration).isEmpty,
                               "\(text) @ \(duration)s")
            }
        }
        typealias Reason = TranscriptionWorkRecord.FailureReason
        XCTAssertEqual(Reason.rejection(of: " ", audioDuration: 10), .emptyOutput)
        XCTAssertEqual(Reason.rejection(of: "这是中文", audioDuration: 10), .englishGateHanDominant)
        XCTAssertEqual(Reason.rejection(of: "……", audioDuration: 10), .englishGateNoLatin)
        XCTAssertEqual(Reason.rejection(of: "damaged \u{FFFD} text", audioDuration: 10), .invalidText)
        XCTAssertEqual(Reason.rejection(of: loop, audioDuration: 10), .repeatedLoop)
        XCTAssertEqual(Reason.rejection(of: runaway, audioDuration: 2), .runawayText)
        XCTAssertNil(Reason.rejection(of: "Okay.", audioDuration: 10), "A short acknowledgement stays acceptable")
    }

    func testChineseSpeechBecomesTerminalOtherLanguageAfterOneEnhancedPass() async throws {
        let root = try directory(), session = UUID(), chunkID = UUID()
        let recording = try audio(root, name: "recording.wav", seconds: 12)
        let chunk = try audio(root, name: "zh.wav", seconds: 10)
        let calls = AudioTestBox<[String]>([]), manual = AudioTestBox(false)
        let events = AudioTestBox<[SpeechPipeline.Event]>([])
        let queue = DurableTranscriptionQueue { url, model, enhanced in
            let context = url.lastPathComponent.hasPrefix("LiveLingo-retry-")
            calls.update { $0.append("\(model):\(enhanced)" + (context ? ":context" : "")) }
            if model == "primary" { return manual.value ? "The lecturer switches back to English here." : "" }
            return "那我们来看一下这道题的答案"
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                  handler: { e in events.update { $0.append(e) } })
        queue.submit(.init(audioURL: chunk, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 10,
                           appleEvidence: "", recordingURL: recording, id: chunkID, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertEqual(calls.value, ["primary:false", "fallback:true", "primary:true"],
                       "Only the enhanced English pass is retried; no second retry and no neighbour context")
        let record = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(record.status, .otherLanguage)
        XCTAssertFalse(record.needsWork)
        XCTAssertEqual(record.automaticRetryCount, 1)
        XCTAssertEqual(record.failureReason, .englishGateHanDominant)
        XCTAssertNil(record.text)
        XCTAssertNil(record.candidateText)
        XCTAssertEqual(queue.state?.pendingCount, 0)
        XCTAssertEqual(queue.state?.unresolvedCount, 0)
        XCTAssertEqual(queue.state?.otherLanguageCount, 1)
        XCTAssertNotEqual(record.audioRetired, true)
        let journalDirectory = try XCTUnwrap(queue.journalDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalDirectory.appendingPathComponent(record.audioFile).path))
        XCTAssertFalse(events.value.contains {
            if case .identifiedFinal = $0 { return true }
            if case .transcriptionCandidate = $0 { return true }
            return false
        })
        // Only the first attempt warned; the terminal verdict is a count, not an error.
        XCTAssertEqual(events.value.filter { if case .transcriptionIssue = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events.value.filter { if case .nonEnglishSpeech(start: 0, end: 10) = $0 { return true }; return false }.count, 1)
        let issues = try String(contentsOf: root.appendingPathComponent("transcription-issues.jsonl"), encoding: .utf8)
        let rows = issues.split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.first?.contains("\"event\":\"transcription_missing\"") == true)
        XCTAssertTrue(rows.last?.contains("\"event\":\"transcription_non_english\"") == true)
        XCTAssertTrue(rows.allSatisfy { $0.contains("\"reason\":\"englishGateHanDominant\"") })
        XCTAssertFalse(issues.contains("那我们"), "Diagnostics carry the reason, never recognizer text")
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        XCTAssertEqual(reopened.record(id: chunkID)?.status, .otherLanguage)
        XCTAssertEqual(reopened.processingState.unresolvedCount, 0)
        XCTAssertNil(try reopened.claimNext())

        manual.update { $0 = true }
        try queue.retry(id: chunkID); await queue.finish()
        let retried = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(retried.status, .completed)
        XCTAssertEqual(retried.text, "The lecturer switches back to English here.")
        XCTAssertEqual(retried.manualRetryCount, 1)
        XCTAssertNil(retried.failure)
        XCTAssertNil(retried.failureReason)
        XCTAssertEqual(queue.state?.otherLanguageCount, 0)
    }

    func testHanFallbackLeavesAcceptedEnglishPathsUnchanged() async throws {
        // A usable primary caption wins over a Han fallback; the first enhanced
        // retry still recovers English that the raw pass missed.
        for enhancedRecovery in [false, true] {
            let root = try directory(), session = UUID(), chunkID = UUID()
            let wav = try audio(root, seconds: 10)
            let commits = AudioTestBox<[TranscriptionCommit]>([])
            let queue = DurableTranscriptionQueue { _, model, enhanced in
                guard model == "primary" else { return "这是中文讲话" }
                if enhancedRecovery { return enhanced ? "The enhanced pass recovers this sentence." : "" }
                return "Okay."
            }
            try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true) { e in
                if case .identifiedFinal(let commit) = e { commits.update { $0.append(commit) } }
            }
            queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 10,
                               appleEvidence: "", recordingURL: nil, id: chunkID, sessionID: session), handler: { _ in })
            await queue.finish()
            let expected = enhancedRecovery ? "The enhanced pass recovers this sentence." : "Okay."
            let record = try XCTUnwrap(queue.records.first)
            XCTAssertEqual(record.status, .completed)
            XCTAssertEqual(record.text, expected)
            XCTAssertEqual(record.automaticRetryCount, enhancedRecovery ? 1 : 0)
            XCTAssertNil(record.candidateText)
            XCTAssertNil(record.failureReason)
            XCTAssertEqual(commits.value.map(\.text), [expected])
            XCTAssertEqual(queue.state?.otherLanguageCount, 0)
        }
    }

    func testOtherFailuresKeepAutomaticRetriesAndPersistTheirReason() async throws {
        let cases: [(fallback: String?, context: String, reason: TranscriptionWorkRecord.FailureReason)] = [
            (nil, "", .error), (nil, "A neighbouring sentence from context.", .error),
            ("", "", .emptyOutput), ("……", "", .englishGateNoLatin)
        ]
        for (fallback, context, reason) in cases {
            let root = try directory(), session = UUID(), wav = try audio(root)
            let recording = try audio(root, name: "recording.wav", seconds: 4)
            let queue = DurableTranscriptionQueue { url, model, _ in
                if url.lastPathComponent.hasPrefix("LiveLingo-retry-") { return context }
                // A primary error is not hidden by a Han fallback, even when the
                // final retry finds a context candidate; it stays retryable.
                if model == "primary" { if fallback == nil { throw URLError(.timedOut) }; return "" }
                return fallback ?? "那我们来看一下这道题"
            }
            try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
            queue.submit(.init(audioURL: wav, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 1,
                               appleEvidence: "", recordingURL: recording, sessionID: session), handler: { _ in })
            await queue.finish()
            let record = try XCTUnwrap(queue.records.first)
            XCTAssertEqual(record.status, .failed)
            XCTAssertEqual(record.automaticRetryCount, DurableTranscriptionJournal.maximumAutomaticRetries)
            XCTAssertEqual(record.failureReason, reason)
            XCTAssertEqual(record.candidateText, context.isEmpty ? nil : context)
            XCTAssertEqual(queue.state?.unresolvedCount, 1)
            XCTAssertEqual(queue.state?.otherLanguageCount, 0)
        }
    }

    func testInterruptedAttemptPersistsItsReason() throws {
        let root = try directory(), id = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        var record = work(id, ordinal: 0, status: .active)
        record.attempt = .automaticRetry; record.automaticRetryCount = 1
        try journal.put(record)
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: id)
        XCTAssertEqual(reopened.record(id: record.id)?.status, .retryWaiting)
        XCTAssertEqual(reopened.record(id: record.id)?.failureReason, .interrupted)
    }

    func testOtherLanguageStaysReadableByOldBuildsAndOldJournalsStillDecode() throws {
        let root = try directory(), session = UUID()
        let journalDirectory = root.appendingPathComponent(DurableTranscriptionJournal.directoryName)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: false)
        // A journal exactly as 0.2.0 writes it opens without the new keys.
        var legacy = LegacyWorkRecord(id: UUID(), sessionID: session, ordinal: 0, audioFile: "chunk-0.wav",
            startFrame: 0, endFrame: 160_000, sampleRate: 16_000, start: 0, end: 10, captureStart: 1, captureEnd: 11,
            modelKey: "parakeet", fallbackModelKey: "1.7b", appleEvidence: "")
        legacy.status = .failed; legacy.attempt = .automaticRetry; legacy.automaticRetryCount = 2
        legacy.failure = "此处尚未得到可靠的英文转写，音频已保留。"
        try (legacyRow(LegacyMutation(version: 1, sessionID: session, sequence: 1, paused: false))
             + legacyRow(LegacyMutation(version: 1, sessionID: session, sequence: 2, record: legacy)))
            .write(to: journalDirectory.appendingPathComponent("work.jsonl"))
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        var record = try XCTUnwrap(journal.record(id: legacy.id))
        XCTAssertEqual(record.status, .failed)
        XCTAssertNil(record.failureReason)
        XCTAssertEqual(record.automaticRetryCount, 2)
        XCTAssertEqual(record.captureEnd, 11)
        XCTAssertEqual(record.failure, legacy.failure)
        XCTAssertEqual(journal.processingState.unresolvedCount, 1)

        // The new status is persisted as `failed` plus optional keys and round-trips.
        record.status = .otherLanguage
        record.failureReason = .englishGateHanDominant
        try journal.put(record); try journal.checkpoint()
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        XCTAssertEqual(reopened.record(id: record.id), record)
        XCTAssertEqual(reopened.processingState.unresolvedCount, 0)
        XCTAssertEqual(reopened.processingState.otherLanguageCount, 1)
        // 0.2.0 still decodes every row and the snapshot, and sees a manually retryable failure.
        let rows = try Data(contentsOf: journalDirectory.appendingPathComponent("work.jsonl")).split(separator: 0x0a)
        let mutations = try rows.map {
            try JSONDecoder().decode(LegacyMutation.self, from: JSONDecoder().decode(LegacyEnvelope.self, from: Data($0)).payload)
        }
        XCTAssertEqual(mutations.count, 3)
        XCTAssertEqual(mutations.last?.record?.status, .failed)
        let snapshot = try JSONDecoder().decode(LegacyEnvelope.self,
            from: Data(contentsOf: journalDirectory.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(try JSONDecoder().decode(LegacyState.self, from: snapshot.payload).records.map(\.status), [.failed])

        // Field-level round-trip with every optional present.
        var full = TranscriptionWorkRecord(id: UUID(), sessionID: session, ordinal: 3, audioFile: "chunk-3.wav",
            startFrame: 480_000, endFrame: 640_000, sampleRate: 16_000, start: 30, end: 40, captureStart: 31, captureEnd: 41,
            modelKey: "parakeet", fallbackModelKey: "1.7b", appleEvidence: "evidence", recordingFile: "recording.wav",
            audioRetired: false)
        full.status = .otherLanguage; full.attempt = .manual; full.automaticRetryCount = 1; full.manualRetryCount = 2
        full.text = "Earlier text."; full.candidateText = "A candidate."; full.candidateOrigin = "context"
        full.failure = "此处为非英语讲话（未转写），音频已保留，可手动重试。"; full.failureReason = .englishGateHanDominant
        let encoded = try JSONEncoder().encode(full)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionWorkRecord.self, from: encoded), full)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "failed")
        XCTAssertEqual(object["extendedStatus"] as? String, "otherLanguage")
        XCTAssertEqual(object["failureReason"] as? String, "englishGateHanDominant")
        XCTAssertEqual(try JSONDecoder().decode(LegacyWorkRecord.self, from: encoded).status, .failed)
        // Values from a newer build degrade instead of failing the journal.
        object["extendedStatus"] = "someLaterStatus"; object["failureReason"] = "someLaterReason"
        let tolerant = try JSONDecoder().decode(TranscriptionWorkRecord.self,
                                                from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(tolerant.status, .failed)
        XCTAssertNil(tolerant.failureReason)
        // Without new fields the bytes equal 0.2.0's synthesized encoding.
        let sorted = JSONEncoder(); sorted.outputFormatting = [.sortedKeys]
        for status: TranscriptionWorkRecord.Status in [.pending, .active, .retryWaiting, .manualPending, .completed, .silent, .failed] {
            var plain = full; plain.status = status; plain.failureReason = nil
            let bytes = try sorted.encode(plain)
            XCTAssertEqual(try sorted.encode(JSONDecoder().decode(LegacyWorkRecord.self, from: bytes)), bytes)
            XCTAssertEqual(try JSONDecoder().decode(TranscriptionWorkRecord.self, from: bytes), plain)
        }
    }

    func testInterruptedManualRetryOfNonEnglishSpeechKeepsItsVerdict() async throws {
        let root = try directory(), session = UUID(), chunkID = UUID()
        let recording = try audio(root, name: "recording.wav", seconds: 24)
        let chunk = try audio(root, name: "zh.wav", seconds: 10)
        let blocking = AudioTestBox(false), started = AudioTestBox(0)
        let queue = DurableTranscriptionQueue { url, model, _ in
            if url.lastPathComponent == "next.wav" { return model == "primary" ? "The next caption wins." : "" }
            if model == "primary", blocking.value {
                started.update { $0 += 1 }
                try await Task.sleep(for: .seconds(30))
            }
            return model == "primary" ? "" : "那我们来看一下这道题的答案"
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true, handler: { _ in })
        queue.submit(.init(audioURL: chunk, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 10,
                           appleEvidence: "", recordingURL: recording, id: chunkID, sessionID: session), handler: { _ in })
        await queue.finish()
        let verdict = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(verdict.status, .otherLanguage)
        blocking.update { $0 = true }
        func startManualRetry(_ attempt: Int) async throws {
            try queue.retry(id: chunkID)
            for _ in 0..<100 where started.value < attempt { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertEqual(started.value, attempt)
        }
        func assertVerdictStands(_ label: String) throws {
            let record = try XCTUnwrap(queue.records.first(where: { $0.id == chunkID }), label)
            XCTAssertEqual(record.status, .otherLanguage, label)
            XCTAssertEqual(record.failureReason, .englishGateHanDominant, label)
            XCTAssertEqual(record.failure, verdict.failure, label)
            XCTAssertEqual(queue.state?.unresolvedCount, 0, label)
            XCTAssertEqual(queue.state?.otherLanguageCount, 1, label)
        }
        // New captions preempt the optional repair.
        try await startManualRetry(1)
        queue.submit(.init(audioURL: try audio(root, name: "next.wav", seconds: 10), modelKey: "primary",
                           fallbackModelKey: "fallback", start: 10, end: 20, appleEvidence: "", recordingURL: recording,
                           sessionID: session), handler: { _ in })
        await queue.finish()
        try assertVerdictStands("preempted")
        XCTAssertEqual(queue.records.last?.status, .completed)
        // Parking saved processing (pause, confirming a candidate, opening another course).
        try await startManualRetry(2)
        try await queue.pause()
        try assertVerdictStands("paused")
        XCTAssertEqual(queue.records.first?.manualRetryCount, 2)
    }

    func testRelaunchAfterInterruptedRetriesKeepsVerdictsAndMarksOthersInterrupted() throws {
        let root = try directory(), session = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        var nonEnglish = work(session, ordinal: 0, status: .otherLanguage, fallback: "fallback")
        nonEnglish.attempt = .automaticRetry; nonEnglish.automaticRetryCount = 1
        nonEnglish.failure = "此处为非英语讲话（未转写），音频已保留，可手动重试。"
        nonEnglish.failureReason = .englishGateHanDominant
        var failed = work(session, ordinal: 1, status: .failed, fallback: "fallback")
        failed.attempt = .automaticRetry; failed.automaticRetryCount = 2
        failed.failure = "此处尚未得到可靠的英文转写，音频已保留。"; failed.failureReason = .emptyOutput
        var waiting = work(session, ordinal: 2, status: .retryWaiting, fallback: "fallback")
        waiting.failure = failed.failure; waiting.failureReason = .englishGateHanDominant
        // Without a fallback model the primary's own Han verdict never means `.otherLanguage`.
        var primaryOnly = work(session, ordinal: 3, status: .failed)
        primaryOnly.attempt = .automaticRetry; primaryOnly.automaticRetryCount = 2
        primaryOnly.failure = failed.failure; primaryOnly.failureReason = .englishGateHanDominant
        for record in [nonEnglish, failed, waiting, primaryOnly] { try journal.put(record) }
        func retryAndClaimAll() throws {
            for record in [nonEnglish, failed, primaryOnly] { try journal.retry(id: record.id) }
            for _ in 0..<4 { XCTAssertNotNil(try journal.claimNext()) }
        }
        try retryAndClaimAll()
        XCTAssertEqual(journal.records.map(\.attempt), [.manual, .manual, .automaticRetry, .manual])
        // Parking requeues in place.
        try journal.requeueActive()
        XCTAssertEqual(journal.records.map(\.status), [.otherLanguage, .failed, .retryWaiting, .failed])
        XCTAssertEqual(journal.records.map(\.failureReason), [.englishGateHanDominant, .interrupted, .interrupted, .interrupted])
        XCTAssertEqual(journal.records.first?.failure, nonEnglish.failure)
        XCTAssertEqual(journal.processingState.unresolvedCount, 3)
        XCTAssertEqual(journal.processingState.otherLanguageCount, 1)
        // Quitting mid-attempt is recovered when the journal is reopened.
        try retryAndClaimAll()
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        XCTAssertEqual(reopened.records.map(\.status), [.otherLanguage, .failed, .failed, .failed])
        XCTAssertEqual(reopened.records.map(\.failureReason), [.englishGateHanDominant, .interrupted, .interrupted, .interrupted])
        XCTAssertEqual(reopened.records.first?.failure, nonEnglish.failure)
        XCTAssertEqual(reopened.processingState.unresolvedCount, 3)
        XCTAssertEqual(reopened.processingState.otherLanguageCount, 1)
    }

    func testNonEnglishChunkWithPendingCandidateIsCountedOnce() async throws {
        for accept in [false, true] {
            let root = try directory(), session = UUID(), chunkID = UUID()
            let recording = try audio(root, name: "recording.wav", seconds: 12)
            let chunk = try audio(root, name: "zh.wav", seconds: 10)
            let manual = AudioTestBox(false), events = AudioTestBox<[SpeechPipeline.Event]>([])
            // As in a 0.2.0 course: every automatic attempt fails, and the last one borrows a context candidate.
            let queue = DurableTranscriptionQueue { url, model, _ in
                if url.lastPathComponent.hasPrefix("LiveLingo-retry-") { return "A neighbouring sentence from context." }
                return model == "primary" || !manual.value ? "" : "那我们来看一下这道题的答案"
            }
            try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                      handler: { e in events.update { $0.append(e) } })
            queue.submit(.init(audioURL: chunk, modelKey: "primary", fallbackModelKey: "fallback", start: 0, end: 10,
                               appleEvidence: "", recordingURL: recording, id: chunkID, sessionID: session), handler: { _ in })
            await queue.finish()
            XCTAssertEqual(queue.records.first?.status, .failed)
            XCTAssertEqual(queue.records.first?.candidateOrigin, "context")
            manual.update { $0 = true }
            try queue.retry(id: chunkID); await queue.finish()
            let record = try XCTUnwrap(queue.records.first)
            XCTAssertEqual(record.status, .otherLanguage)
            XCTAssertEqual(record.candidateText, "A neighbouring sentence from context.", "A visible candidate is never dropped silently")
            XCTAssertEqual(queue.state?.unresolvedCount, 1)
            XCTAssertEqual(queue.state?.otherLanguageCount, 0)
            XCTAssertFalse(events.value.contains { if case .nonEnglishSpeech = $0 { return true }; return false },
                           "The candidate notice stays until the candidate is resolved")
            try queue.resolveCandidate(id: chunkID, acceptedText: accept ? "The accepted sentence." : nil)
            let resolved = try XCTUnwrap(queue.records.first)
            XCTAssertNil(resolved.candidateText)
            XCTAssertEqual(resolved.status, accept ? .completed : .otherLanguage)
            XCTAssertEqual(resolved.failureReason, accept ? nil : .englishGateHanDominant)
            XCTAssertEqual(resolved.failure == nil, accept)
            XCTAssertEqual(queue.state?.unresolvedCount, 0)
            XCTAssertEqual(queue.state?.otherLanguageCount, accept ? 0 : 1)
        }
    }

    func testRestoredConsentCompletesTheChunkAndClearsItsReason() async throws {
        let root = try directory(), session = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        var record = work(session, ordinal: 0, status: .failed)
        record.attempt = .automaticRetry; record.automaticRetryCount = 2
        record.failure = "此处尚未得到可靠的英文转写，音频已保留。"; record.failureReason = .emptyOutput
        record.text = "An earlier partial sentence."
        record.candidateText = "A neighbouring sentence from context."; record.candidateOrigin = "context"
        _ = try audio(journal.directory, name: record.audioFile, seconds: 10)
        try journal.put(record)
        let original = TranscriptSegment(id: record.id, startTime: 0, endTime: 10, english: record.text!, sessionID: session)
        let replacement = TranscriptSegment(id: record.id, startTime: 0, endTime: 10,
            english: "The confirmed sentence.", sessionID: session, inputRevision: 1)
        let store = SessionStore(directory: root)
        _ = try store.save(.init(sessionID: session, segments: [original]))
        _ = try store.append(.inputRevision(.init(fromRevision: 0, toRevision: 1, previousSegment: original,
            replacementSegment: replacement, reason: "Confirmed by test user",
            transcriptionCandidateText: record.candidateText)))
        let queue = DurableTranscriptionQueue { _, _, _ in
            XCTFail("Restoring a confirmed candidate cannot call the recognizer")
            return ""
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true,
                                  identified: true, restoring: true, startPaused: true, handler: { _ in })
        let restored = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.text, replacement.english)
        XCTAssertNil(restored.failure)
        XCTAssertNil(restored.failureReason)
        await queue.cancel()
    }

    @MainActor
    func testNonEnglishVerdictClearsOnlyThatRangesWarning() throws {
        let root = try directory()
        let reviews = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false) { _, _, _, _, _ in
            throw CancellationError()
        }
        let suite = "LiveLingo-Test-\(UUID())"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        addTeardownBlock {
            await reviews.shutdownForTesting()
            try preferenceCleanup.remove()
        }
        let model = AppModel(reviewQueue: reviews, backgroundServices: false, defaults: defaults)
        model.receiveTranscriptionNoticeForTesting(.transcriptionIssue(start: 750, end: 760,
            message: "此处尚未得到可靠的英文转写，音频已保留。"))
        XCTAssertEqual(model.sessionNotice, "12:30–12:40 · 此处尚未得到可靠的英文转写，音频已保留。")
        model.receiveTranscriptionNoticeForTesting(.nonEnglishSpeech(start: 740, end: 750))
        XCTAssertNotNil(model.sessionNotice, "Another range's warning stays")
        model.receiveTranscriptionNoticeForTesting(.nonEnglishSpeech(start: 750, end: 760))
        XCTAssertNil(model.sessionNotice)
    }
}

private struct MultilingualASRCall: Sendable {
    let model: String
    let enhanced: Bool
    let mode: ASRLanguageMode
    let requestID: String
    var stage: String { requestID.components(separatedBy: "_").dropFirst(4).first ?? "" }
    var legacySignature: String { "\(model):\(enhanced)" }
    var legacyRequestSignature: String { "\(legacySignature):\(stage)" }
}

extension AudioRemediationTests {
    private func detectedSource(_ text: String = "蓝色小车停在门边。", language: String = "zh") -> ASRTranscription {
        ASRTranscription(text: text, languageMode: .auto, language: language, decode: .detected,
            detectedLabel: SpokenLanguage.find(language)?.qwenLabel, languageProbability: 0.99,
            englishProbability: 0.001, generatedTokens: 12, policy: 1)
    }

    private func asrCall(_ model: String, _ enhanced: Bool, _ mode: ASRLanguageMode) -> MultilingualASRCall {
        .init(model: model, enhanced: enhanced, mode: mode, requestID: ASRRequestContext.requestID ?? "")
    }

    private func sortedBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func commitEventBytes(_ events: [SpeechPipeline.Event]) throws -> Data {
        // Processing notifications reflect scheduling, not committed captions.
        // Keep every caption event and every field, including in-memory language
        // (the journal encoder deliberately omits an English language code).
        let commits = events.compactMap { event -> [String: Any]? in
            switch event {
            case .identifiedFinal(let commit):
                return ["kind": "identifiedFinal", "id": commit.id.uuidString,
                    "sessionID": commit.sessionID.uuidString, "text": commit.text,
                    "start": commit.start, "end": commit.end, "startFrame": commit.startFrame,
                    "endFrame": commit.endFrame, "sampleRate": commit.sampleRate, "isRepair": commit.isRepair,
                    "language": commit.language as Any? ?? NSNull(),
                    "hints": commit.hints.map { ["kind": $0.kind.rawValue, "value": $0.value] }]
            case .final(let text, let start, let end, let hints, let language):
                return ["kind": "final", "text": text, "start": start, "end": end,
                    "language": language as Any? ?? NSNull(),
                    "hints": hints.map { ["kind": $0.kind.rawValue, "value": $0.value] }]
            default: return nil
            }
        }
        return try JSONSerialization.data(withJSONObject: commits, options: [.sortedKeys])
    }

    private func runSourceFixture(_ queue: DurableTranscriptionQueue, record: TranscriptionWorkRecord,
                                  identified: Bool = true, evidence: String? = nil) async throws -> (TranscriptionWorkRecord, [SpeechPipeline.Event]) {
        let root = try directory(), events = AudioTestBox<[SpeechPipeline.Event]>([])
        let wav = try audio(root, name: record.audioFile, seconds: record.duration)
        try await queue.configure(directory: root, sessionID: record.sessionID, persistent: true, identified: identified,
                                  handler: { event in events.update { $0.append(event) } })
        queue.submit(.init(audioURL: wav, modelKey: record.modelKey, fallbackModelKey: record.fallbackModelKey,
            start: record.start, end: record.end, appleEvidence: evidence ?? record.appleEvidence, recordingURL: nil,
            id: record.id, sessionID: record.sessionID), handler: { _ in })
        await queue.finish()
        return (try XCTUnwrap(queue.records.first), events.value)
    }

    private func assertOldBuildReads(_ queue: DurableTranscriptionQueue,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try XCTUnwrap(queue.journalDirectory, file: file, line: line)
        let rows = try Data(contentsOf: root.appendingPathComponent("work.jsonl")).split(separator: 0x0a)
        let oldRows = try rows.map {
            let envelope = try JSONDecoder().decode(LegacyEnvelope.self, from: Data($0))
            return try JSONDecoder().decode(LegacyMutation.self, from: envelope.payload)
        }
        let snapshot = try JSONDecoder().decode(LegacyEnvelope.self, from: Data(contentsOf: root.appendingPathComponent("snapshot.json")))
        let oldState = try JSONDecoder().decode(LegacyState.self, from: snapshot.payload)
        XCTAssertEqual(oldRows.compactMap(\.record).last?.text, queue.records.last?.text, file: file, line: line)
        XCTAssertEqual(oldState.records.map(\.text), queue.records.map(\.text), file: file, line: line)
        XCTAssertEqual(oldState.records.map(\.candidateText), queue.records.map(\.candidateText), file: file, line: line)
    }

    private func assertEnglishBytes(primary: String, autoResult: ASRTranscription? = nil,
                                    expectedModes: [ASRLanguageMode], expectedStages: [String],
                                    identified: Bool = true, evidence: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let root = try directory(), session = UUID()
        let record = work(session, ordinal: 0, fallback: "fallback")
        let wav = try audio(root, seconds: record.duration)
        let secondary = "The blue cart stops beside the metal gate."
        let calls = AudioTestBox<[MultilingualASRCall]>([]), legacyCalls = AudioTestBox<[MultilingualASRCall]>([])
        let modern: DurableTranscriptionQueue.Transcriber = { _, model, enhanced, mode in
            calls.update { $0.append(self.asrCall(model, enhanced, mode)) }
            if model == "primary" { return ASRTranscription(text: primary) }
            if mode == .auto { return autoResult ?? ASRTranscription(text: secondary, languageMode: .auto) }
            return ASRTranscription(text: secondary)
        }
        let legacy: DurableTranscriptionQueue.LegacyTranscriber = { _, model, enhanced in
            legacyCalls.update { $0.append(self.asrCall(model, enhanced, .english)) }
            return model == "primary" ? primary : secondary
        }
        // The reference executes the frozen pre-step-5 recognition function,
        // not the new function with its language information removed.
        let oldOutcome = try await Step5LegacyRecognition.recognize(record, audioURL: wav, recordingURL: nil,
            formulaContext: "", attempts: Step5LegacyAttemptCache(), transcriber: legacy)
        let outcome = try await DurableTranscriptionQueue.recognize(record, audioURL: wav, recordingURL: nil,
            formulaContext: "", attempts: TranscriptionAttemptCache(), transcriber: modern)
        XCTAssertTrue(try sortedBytes(outcome) == sortedBytes(oldOutcome), "Outcome bytes changed", file: file, line: line)
        XCTAssertNil(outcome.language, file: file, line: line)
        let frozenCalls = legacyCalls.value.map(\.legacyRequestSignature)
        XCTAssertEqual(calls.value.filter { $0.stage != "fallbackEn" }.map(\.legacyRequestSignature),
                       frozenCalls, "Requests differ from frozen recognition", file: file, line: line)
        calls.update { $0.removeAll() }; legacyCalls.update { $0.removeAll() }
        let newQueue = DurableTranscriptionQueue(transcriber: modern)
        let adaptedQueue = DurableTranscriptionQueue(transcriber: legacy)
        let (newRecord, newEvents) = try await runSourceFixture(newQueue, record: record, identified: identified, evidence: evidence)
        let (adaptedRecord, adaptedEvents) = try await runSourceFixture(adaptedQueue, record: record, identified: identified, evidence: evidence)
        // This checks the legacy adapter; frozen recognition above is the
        // independent reference for outcomes and actual request sequences.
        XCTAssertTrue(try sortedBytes(newRecord) == sortedBytes(adaptedRecord), "Legacy adapter journal bytes changed", file: file, line: line)
        XCTAssertTrue(try commitEventBytes(newEvents) == commitEventBytes(adaptedEvents), "Legacy adapter caption events changed", file: file, line: line)
        XCTAssertEqual(newRecord.text, oldOutcome.text, file: file, line: line)
        XCTAssertEqual(newRecord.candidateText, oldOutcome.candidate, file: file, line: line)
        let hints = AuxiliaryTranslationHintExtractor.extract(from: evidence, primary: oldOutcome.text)
        var commits = 0
        for event in newEvents {
            switch event {
            case .identifiedFinal(let commit):
                commits += 1; XCTAssertTrue(identified, file: file, line: line)
                XCTAssertNil(commit.language, file: file, line: line)
                XCTAssertEqual(commit.hints, hints, file: file, line: line)
            case .final(_, _, _, let actualHints, let language):
                commits += 1; XCTAssertFalse(identified, file: file, line: line)
                XCTAssertNil(language, file: file, line: line)
                XCTAssertEqual(actualHints, hints, file: file, line: line)
            default: break
            }
        }
        XCTAssertEqual(commits, 1, file: file, line: line)
        XCTAssertEqual(calls.value.map(\.mode), expectedModes, file: file, line: line)
        XCTAssertEqual(calls.value.map(\.stage), expectedStages, file: file, line: line)
        XCTAssertEqual(calls.value.filter { $0.stage != "fallbackEn" }.map(\.legacyRequestSignature),
                       frozenCalls, file: file, line: line)
        XCTAssertEqual(legacyCalls.value.map(\.legacyRequestSignature), frozenCalls, file: file, line: line)
        XCTAssertEqual(Set(calls.value.map(\.requestID)).count, calls.value.count, file: file, line: line)
        XCTAssertTrue(calls.value.allSatisfy { !$0.requestID.isEmpty && $0.requestID.count <= 128 && $0.stage.count <= 21 },
                      file: file, line: line)
    }

    func testMultilingualAcceptedPrimaryMatchesLegacyEnglishBytes() async throws {
        try await assertEnglishBytes(primary: "The small cart rolls across the empty lab.",
                                     expectedModes: [.english], expectedStages: ["primary"])
    }

    func testMultilingualEnglishCommitsKeepLanguageNilAndNonemptyHints() async throws {
        let text = "The small cart rolls across the empty lab.", evidence = "NMR 5 mL"
        XCTAssertFalse(AuxiliaryTranslationHintExtractor.extract(from: evidence, primary: text).isEmpty)
        for identified in [true, false] {
            try await assertEnglishBytes(primary: text, expectedModes: [.english], expectedStages: ["primary"],
                                         identified: identified, evidence: evidence)
        }
    }

    func testMultilingualFormulaReviewMatchesLegacyEnglishBytes() async throws {
        let text = "The partial derivative points along the slope."
        XCTAssertTrue(FormulaASRReview.needsReview(text))
        XCTAssertNil(ASRQualityGate.fallbackReason(for: text, audioDuration: 10))
        try await assertEnglishBytes(primary: text, expectedModes: [.english, .english], expectedStages: ["primary", "fallback"])
    }

    func testMultilingualShortUsablePrimaryMatchesLegacyEnglishBytes() async throws {
        XCTAssertEqual(ASRQualityGate.fallbackReason(for: "Okay.", audioDuration: 10), .implausiblyShort)
        try await assertEnglishBytes(primary: "Okay.", expectedModes: [.english, .english], expectedStages: ["primary", "fallback"])
    }

    func testMultilingualAcceptedChineseCommitsLanguageWithoutHints() async throws {
        let source = detectedSource(), evidence = "NMR 5 mL"
        XCTAssertFalse(AuxiliaryTranslationHintExtractor.extract(from: evidence, primary: source.text).isEmpty)
        for identified in [true, false] {
            let calls = AudioTestBox<[MultilingualASRCall]>([])
            let queue = DurableTranscriptionQueue { _, model, enhanced, mode in
                calls.update { $0.append(self.asrCall(model, enhanced, mode)) }
                return model == "primary" ? ASRTranscription(text: "") : source
            }
            let input = work(UUID(), ordinal: 0, fallback: "fallback")
            let (record, events) = try await runSourceFixture(queue, record: input, identified: identified, evidence: evidence)
            XCTAssertEqual(calls.value.map(\.mode), [.english, .auto])
            XCTAssertEqual(calls.value.filter { $0.model == "fallback" }.count, 1)
            XCTAssertEqual(record.status, .completed)
            XCTAssertEqual(record.text, source.text)
            XCTAssertEqual(record.textLanguage, "zh")
            XCTAssertNil(record.failure)
            XCTAssertNil(record.failureReason)
            XCTAssertEqual(record.automaticRetryCount, 0)
            var commits = 0
            for event in events {
                switch event {
                case .identifiedFinal(let commit):
                    commits += 1; XCTAssertEqual(commit.language, "zh"); XCTAssertEqual(commit.text, source.text)
                    XCTAssertTrue(commit.hints.isEmpty)
                case .final(let text, _, _, let hints, let language):
                    commits += 1; XCTAssertEqual(language, "zh"); XCTAssertEqual(text, source.text); XCTAssertTrue(hints.isEmpty)
                default: break
                }
            }
            XCTAssertEqual(commits, 1)
            try assertOldBuildReads(queue)
        }
    }

    func testMultilingualAcceptedChineseClearsPrimaryError() async throws {
        let root = try directory(), record = work(UUID(), ordinal: 0, fallback: "fallback"), source = detectedSource()
        let transcriber: DurableTranscriptionQueue.Transcriber = { _, model, _, mode in
            if model == "primary" { throw URLError(.timedOut) }
            XCTAssertEqual(mode, .auto); return source
        }
        let outcome = try await DurableTranscriptionQueue.recognize(record, audioURL: audio(root, seconds: 10), recordingURL: nil,
            formulaContext: "", attempts: TranscriptionAttemptCache(), transcriber: transcriber)
        XCTAssertNil(outcome.failureReason)
        XCTAssertEqual(outcome.language, "zh")
        let (completed, _) = try await runSourceFixture(DurableTranscriptionQueue(transcriber: transcriber), record: record)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.textLanguage, "zh")
        XCTAssertNil(completed.failure)
        XCTAssertNil(completed.failureReason)
    }

    func testMultilingualCantoneseIsAcceptedAsSourceLanguage() async throws {
        let source = detectedSource("架蓝色车停喺门口。", language: "yue"), calls = AudioTestBox<[ASRLanguageMode]>([])
        let queue = DurableTranscriptionQueue { _, model, _, mode in
            calls.update { $0.append(mode) }
            return model == "primary" ? ASRTranscription(text: "") : source
        }
        let (record, events) = try await runSourceFixture(queue, record: work(UUID(), ordinal: 0, fallback: "fallback"))
        XCTAssertEqual(calls.value, [.english, .auto])
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.textLanguage, "yue")
        XCTAssertEqual(events.compactMap { if case .identifiedFinal(let c) = $0 { return c.language }; return nil }, ["yue"])
        XCTAssertFalse(try XCTUnwrap(SpokenLanguage.find("yue")).avoidsTranslation)
        try assertOldBuildReads(queue)
    }

    func testMultilingualRejectedChineseMatchesLegacyEnglishBytes() async throws {
        let rejected = detectedSource("The lab door is open.")
        XCTAssertFalse(SourceLanguagePolicy.accepts(rejected, audioDuration: 10))
        try await assertEnglishBytes(primary: "", autoResult: rejected,
            expectedModes: [.english, .auto, .english], expectedStages: ["primary", "fallback", "fallbackEn"])
    }

    func testMultilingualForcedResultMatchesLegacyEnglishBytes() async throws {
        try await assertEnglishBytes(primary: "", expectedModes: [.english, .auto], expectedStages: ["primary", "fallback"])
    }

    func testMultilingualForcedAutoCacheMatchesLegacyAcrossAutomaticRetry() async throws {
        let root = try directory(), wav = try audio(root, seconds: 10)
        var record = work(UUID(), ordinal: 0, fallback: "fallback")
        let rejected = "这段保留音频。"
        XCTAssertTrue(SpeechPipeline.preferredTranscript(primary: nil, fallback: rejected, audioDuration: 10).isEmpty)
        XCTAssertEqual(ASRQualityGate.fallbackReason(for: "Okay.", audioDuration: 10), .implausiblyShort)
        let forced = ASRTranscription(text: rejected, languageMode: .auto, detectedLabel: "English",
            languageProbability: 0.95, englishProbability: 0.95, generatedTokens: 48, policy: 1)
        let calls = AudioTestBox<[MultilingualASRCall]>([]), legacyCalls = AudioTestBox<[MultilingualASRCall]>([])
        let cache = TranscriptionAttemptCache(), legacyCache = Step5LegacyAttemptCache()
        let modern: DurableTranscriptionQueue.Transcriber = { _, model, enhanced, mode in
            calls.update { $0.append(self.asrCall(model, enhanced, mode)) }
            if model == "primary" { return ASRTranscription(text: enhanced ? "Okay." : "") }
            guard mode == .auto else {
                XCTFail("Automatic retry must reuse the equivalent forced English result")
                throw URLError(.timedOut)
            }
            return forced
        }
        let legacy: DurableTranscriptionQueue.LegacyTranscriber = { _, model, enhanced in
            legacyCalls.update { $0.append(self.asrCall(model, enhanced, .english)) }
            return model == "primary" ? (enhanced ? "Okay." : "") : rejected
        }
        for attempt in [TranscriptionWorkRecord.Attempt.initial, .automaticRetry] {
            record.attempt = attempt; record.automaticRetryCount = attempt == .initial ? 0 : 1
            let oldOutcome = try await Step5LegacyRecognition.recognize(record, audioURL: wav, recordingURL: nil,
                formulaContext: "", attempts: legacyCache, transcriber: legacy)
            let outcome = try await DurableTranscriptionQueue.recognize(record, audioURL: wav, recordingURL: nil,
                formulaContext: "", attempts: cache, transcriber: modern)
            XCTAssertEqual(try sortedBytes(outcome), try sortedBytes(oldOutcome))
            XCTAssertEqual(calls.value.map(\.legacyRequestSignature), legacyCalls.value.map(\.legacyRequestSignature))
            let fingerprint = try TranscriptionAttemptCache.fingerprint(wav)
            let englishKey = TranscriptionAttemptCache.Key(id: record.id, model: "fallback", enhanced: true,
                                                           mode: .english, audio: fingerprint)
            let autoKey = TranscriptionAttemptCache.Key(id: record.id, model: "fallback", enhanced: true,
                                                        mode: .auto, audio: fingerprint)
            XCTAssertEqual(cache.result(for: englishKey), ASRTranscription(text: rejected),
                           "The reused reply must match every English reply field")
            XCTAssertEqual(cache.result(for: autoKey), forced)
        }
        XCTAssertEqual(calls.value.map(\.stage), ["primary", "fallback", "primary"])
        XCTAssertEqual(calls.value.map(\.mode), [.english, .auto, .english])
    }

    func testMultilingualRetryCacheSeparatesModesAndKeepsContextEnglish() async throws {
        let root = try directory(), session = UUID(), events = AudioTestBox<[SpeechPipeline.Event]>([])
        let wav = try audio(root, seconds: 10), recording = try audio(root, name: "recording.wav", seconds: 12)
        let calls = AudioTestBox<[MultilingualASRCall]>([]), rejected = detectedSource("The gate stays closed.")
        let queue = DurableTranscriptionQueue { url, model, enhanced, mode in
            calls.update { $0.append(self.asrCall(model, enhanced, mode)) }
            if mode == .auto { return rejected }
            if try AVAudioFile(forReading: url).length > 160_000 { return ASRTranscription(text: "A nearby sentence needs confirmation.") }
            return ASRTranscription(text: "")
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                  handler: { e in events.update { $0.append(e) } })
        // The same model and enhanced waveform occur in both modes. Omitting
        // the mode from the cache key would suppress fallbackEn or reuse it as auto.
        queue.submit(.init(audioURL: wav, modelKey: "1.7b", fallbackModelKey: "1.7b", start: 0, end: 10,
            appleEvidence: "", recordingURL: recording, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertEqual(calls.value.map(\.stage), ["primary", "fallback", "fallbackEn", "context"])
        XCTAssertEqual(calls.value.map(\.mode), [.english, .auto, .english, .english])
        XCTAssertEqual(calls.value.filter { $0.mode == .auto }.count, 1)
        let record = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(record.automaticRetryCount, 2)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.candidateOrigin, "context")
        XCTAssertNil(record.candidateLanguage)
        let diagnostics = try String(contentsOf: root.appendingPathComponent("transcription-issues.jsonl"), encoding: .utf8)
        XCTAssertFalse(diagnostics.contains(record.candidateText!))
        let rows = try diagnostics.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertTrue(rows.contains {
            ($0["candidateBytes"] as? Int) == record.candidateText!.utf8.count
                && ($0["candidateSHA256"] as? String)?.count == 64
        })
        XCTAssertFalse(diagnostics.contains(rejected.text))
        XCTAssertEqual(Set(calls.value.map(\.requestID)).count, calls.value.count)
        XCTAssertTrue(calls.value.allSatisfy { $0.requestID.count <= 128 && $0.stage.count <= 21 })
        try assertOldBuildReads(queue)
    }

    func testMultilingualRejectedDetectionKeepsUnswitchedOtherLanguage() async throws {
        let calls = AudioTestBox<[MultilingualASRCall]>([]), rejected = detectedSource("The gate stays closed.")
        let queue = DurableTranscriptionQueue { _, model, enhanced, mode in
            calls.update { $0.append(self.asrCall(model, enhanced, mode)) }
            if model == "primary" { return ASRTranscription(text: "") }
            return mode == .auto ? rejected : ASRTranscription(text: "这段保留音频。")
        }
        let (record, _) = try await runSourceFixture(queue, record: work(UUID(), ordinal: 0, fallback: "fallback"))
        XCTAssertEqual(record.status, .otherLanguage)
        XCTAssertEqual(record.failureReason, .englishGateHanDominant)
        XCTAssertEqual(record.automaticRetryCount, 1)
        XCTAssertEqual(calls.value.map(\.stage), ["primary", "fallback", "fallbackEn", "primary"])
        XCTAssertEqual(calls.value.filter { $0.mode == .auto }.count, 1)
        XCTAssertNil(record.textLanguage)
        try assertOldBuildReads(queue)
    }

    func testMultilingualManualRetryProducesChineseCandidateKeepsEnglishBody() async throws {
        let root = try directory(), session = UUID(), chunk = UUID(), manual = AudioTestBox(false)
        let events = AudioTestBox<[SpeechPipeline.Event]>([]), calls = AudioTestBox<[MultilingualASRCall]>([])
        let source = detectedSource(), english = "The cart rolls past the quiet bench."
        let queue = DurableTranscriptionQueue { _, model, enhanced, mode in
            calls.update { $0.append(self.asrCall(model, enhanced, mode)) }
            if model == "primary" { return ASRTranscription(text: manual.value ? "" : english) }
            return source
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                  handler: { e in events.update { $0.append(e) } })
        queue.submit(.init(audioURL: try audio(root, seconds: 10), modelKey: "primary", fallbackModelKey: "fallback",
            start: 0, end: 10, appleEvidence: "", recordingURL: nil, id: chunk, sessionID: session), handler: { _ in })
        await queue.finish()
        manual.update { $0 = true }; try queue.retry(id: chunk); await queue.finish()
        let record = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(calls.value.map(\.mode), [.english, .english, .auto])
        XCTAssertEqual(record.text, english)
        XCTAssertNil(record.textLanguage)
        XCTAssertEqual(record.candidateText, source.text)
        XCTAssertEqual(record.candidateLanguage, "zh")
        XCTAssertEqual(record.candidateOrigin, "sameRangeRevision")
        XCTAssertEqual(record.manualRetryCount, 1)
        XCTAssertEqual(events.value.filter { if case .identifiedFinal = $0 { return true }; return false }.count, 1)
        let candidate = try XCTUnwrap(events.value.compactMap { if case .transcriptionCandidate(let c) = $0 { return c }; return nil }.last)
        XCTAssertEqual(candidate.language, "zh")
        XCTAssertEqual(candidate.originalText, english)
        try assertOldBuildReads(queue)
    }

    func testMultilingualManualRetryWithOnlyLanguageChangeProducesCandidate() async throws {
        let root = try directory(), session = UUID(), chunk = UUID(), manual = AudioTestBox(false)
        let events = AudioTestBox<[SpeechPipeline.Event]>([])
        let queue = DurableTranscriptionQueue { _, model, _, mode in
            if model == "primary" { return ASRTranscription(text: "") }
            XCTAssertEqual(mode, .auto)
            return self.detectedSource(language: manual.value ? "yue" : "zh")
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                  handler: { e in events.update { $0.append(e) } })
        queue.submit(.init(audioURL: try audio(root, seconds: 10), modelKey: "primary", fallbackModelKey: "fallback",
            start: 0, end: 10, appleEvidence: "", recordingURL: nil, id: chunk, sessionID: session), handler: { _ in })
        await queue.finish()
        manual.update { $0 = true }; try queue.retry(id: chunk); await queue.finish()
        let record = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(record.text, record.candidateText)
        XCTAssertEqual(record.textLanguage, "zh")
        XCTAssertEqual(record.candidateLanguage, "yue")
        XCTAssertEqual(record.candidateOrigin, "sameRangeRevision")
        XCTAssertEqual(events.value.filter { if case .identifiedFinal = $0 { return true }; return false }.count, 1,
                       "A language-only candidate must not be committed over the existing body")
        XCTAssertEqual(events.value.compactMap { if case .transcriptionCandidate(let c) = $0 { return c.language }; return nil }, ["yue"])
        try assertOldBuildReads(queue)
    }

    func testMultilingualEnglishAlternateCandidateClearsPreviousChineseLanguage() async throws {
        let root = try directory(), session = UUID(), chunk = UUID(), attempt = AudioTestBox(0)
        let events = AudioTestBox<[TranscriptionCandidate]>([]), source = detectedSource()
        let original = "The partial derivative points along the slope."
        let alternate = "The blue cart stops beside the metal gate."
        XCTAssertTrue(FormulaASRReview.needsReview(original))
        let queue = DurableTranscriptionQueue { _, model, _, mode in
            if model == "primary" { return ASRTranscription(text: attempt.value == 1 ? "" : original) }
            if attempt.value == 1 { XCTAssertEqual(mode, .auto); return source }
            XCTAssertEqual(mode, .english)
            return ASRTranscription(text: attempt.value == 0 ? original : alternate)
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true) {
            if case .transcriptionCandidate(let candidate) = $0 { events.update { $0.append(candidate) } }
        }
        queue.submit(.init(audioURL: try audio(root, seconds: 10), modelKey: "primary", fallbackModelKey: "fallback",
            start: 0, end: 10, appleEvidence: "", recordingURL: nil, id: chunk, sessionID: session), handler: { _ in })
        await queue.finish()
        XCTAssertNil(queue.records.first?.candidateText)
        attempt.update { $0 = 1 }; try queue.retry(id: chunk); await queue.finish()
        XCTAssertEqual(queue.records.first?.candidateLanguage, "zh")
        XCTAssertEqual(events.value.last?.language, "zh")
        attempt.update { $0 = 2 }; try queue.retry(id: chunk); await queue.finish()
        let record = try XCTUnwrap(queue.records.first), candidate = try XCTUnwrap(events.value.last)
        XCTAssertEqual(record.text, original)
        XCTAssertNil(record.textLanguage)
        XCTAssertEqual(record.candidateText, alternate)
        XCTAssertEqual(record.candidateOrigin, "alternateModel")
        XCTAssertNil(record.candidateLanguage)
        XCTAssertEqual(candidate.text, alternate)
        XCTAssertEqual(candidate.origin, "alternateModel")
        XCTAssertNil(candidate.language)
        try queue.resolveCandidate(id: chunk, acceptedText: alternate)
        XCTAssertEqual(queue.records.first?.text, alternate)
        XCTAssertNil(queue.records.first?.textLanguage)
        await queue.finish(); try assertOldBuildReads(queue)
    }

    func testMultilingualManualRetryRequestsFreshAutoAfterExhaustion() async throws {
        let manual = AudioTestBox(false), calls = AudioTestBox<[ASRLanguageMode]>([]), source = detectedSource()
        let queue = DurableTranscriptionQueue { _, model, _, mode in
            calls.update { $0.append(mode) }
            if model == "primary" { return ASRTranscription(text: "") }
            return manual.value ? source : ASRTranscription(text: "", languageMode: .auto)
        }
        let input = work(UUID(), ordinal: 0, fallback: "fallback")
        _ = try await runSourceFixture(queue, record: input)
        XCTAssertEqual(queue.records.first?.status, .failed)
        XCTAssertEqual(calls.value.filter { $0 == .auto }.count, 1)
        manual.update { $0 = true }; try queue.retry(id: input.id); await queue.finish()
        XCTAssertEqual(queue.records.first?.status, .completed)
        XCTAssertEqual(queue.records.first?.textLanguage, "zh")
        XCTAssertEqual(calls.value.filter { $0 == .auto }.count, 2)
    }

    func testMultilingualCancellationPropagatesThroughEveryStage() async throws {
        for stage in ["primary", "fallback", "fallbackEn", "context"] {
            let root = try directory(), wav = try audio(root, seconds: 10)
            let recording = try audio(root, name: "recording.wav", seconds: 12)
            var record = work(UUID(), ordinal: 0, fallback: "fallback")
            record.attempt = .automaticRetry; record.automaticRetryCount = 2
            let calls = AudioTestBox<[String]>([])
            do {
                _ = try await DurableTranscriptionQueue.recognize(record, audioURL: wav, recordingURL: recording,
                    formulaContext: "", attempts: TranscriptionAttemptCache()) { _, model, enhanced, mode in
                        let call = self.asrCall(model, enhanced, mode); calls.update { $0.append(call.stage) }
                        if call.stage == stage { throw CancellationError() }
                        if mode == .auto, stage == "fallbackEn" { return self.detectedSource("The gate stays closed.") }
                        return ASRTranscription(text: "", languageMode: mode)
                    }
                XCTFail("Cancellation must escape the \(stage) stage")
            } catch is CancellationError {} catch { XCTFail("Unexpected error type in \(stage)") }
            let expected: [String]
            switch stage {
            case "primary": expected = ["primary"]
            case "fallback": expected = ["primary", "fallback"]
            case "fallbackEn": expected = ["primary", "fallback", "fallbackEn"]
            default: expected = ["primary", "fallback", "context"]
            }
            XCTAssertEqual(calls.value, expected, "No later stage may run after cancellation")
        }
    }

    func testMultilingualCancelledAutoReplyIsNotCached() async throws {
        let root = try directory(), wav = try audio(root, seconds: 10), record = work(UUID(), ordinal: 0, fallback: "fallback")
        let cache = TranscriptionAttemptCache(), gate = AudioTestGate(), entered = AudioTestBox(false), autoCalls = AudioTestBox(0)
        let source = detectedSource()
        let transcriber: DurableTranscriptionQueue.Transcriber = { _, model, _, _ in
            if model == "primary" { return ASRTranscription(text: "") }
            autoCalls.update { $0 += 1 }
            if autoCalls.value == 1 { entered.update { $0 = true }; await gate.wait() }
            return source
        }
        let task = Task {
            try await DurableTranscriptionQueue.recognize(record, audioURL: wav, recordingURL: nil,
                formulaContext: "", attempts: cache, transcriber: transcriber)
        }
        try await waitUntil { entered.value }
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("A cancelled caller cannot accept the response") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
        let outcome = try await DurableTranscriptionQueue.recognize(record, audioURL: wav, recordingURL: nil,
            formulaContext: "", attempts: cache, transcriber: transcriber)
        XCTAssertEqual(autoCalls.value, 2)
        XCTAssertEqual(outcome.language, "zh")
    }

    func testMultilingualCancelledEnglishFallbackReplyIsNotCached() async throws {
        let root = try directory(), wav = try audio(root, seconds: 10), record = work(UUID(), ordinal: 0, fallback: "fallback")
        let cache = TranscriptionAttemptCache(), gate = AudioTestGate(), entered = AudioTestBox(false)
        let englishCalls = AudioTestBox(0), calls = AudioTestBox<[MultilingualASRCall]>([])
        let rejected = detectedSource("The gate stays closed."), english = "The blue cart stops beside the metal gate."
        let transcriber: DurableTranscriptionQueue.Transcriber = { _, model, enhanced, mode in
            calls.update { $0.append(self.asrCall(model, enhanced, mode)) }
            if model == "primary" { return ASRTranscription(text: "") }
            if mode == .auto { return rejected }
            englishCalls.update { $0 += 1 }
            if englishCalls.value == 1 { entered.update { $0 = true }; await gate.wait() }
            return ASRTranscription(text: english)
        }
        let task = Task {
            try await DurableTranscriptionQueue.recognize(record, audioURL: wav, recordingURL: nil,
                formulaContext: "", attempts: cache, transcriber: transcriber)
        }
        try await waitUntil { entered.value }
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("A cancelled fallbackEn reply must be discarded") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
        let fingerprint = try TranscriptionAttemptCache.fingerprint(wav)
        XCTAssertNil(cache.result(for: .init(id: record.id, model: "fallback", enhanced: true, mode: .english, audio: fingerprint)))
        let outcome = try await DurableTranscriptionQueue.recognize(record, audioURL: wav, recordingURL: nil,
            formulaContext: "", attempts: cache, transcriber: transcriber)
        XCTAssertEqual(englishCalls.value, 2)
        XCTAssertEqual(calls.value.map(\.stage), ["primary", "fallback", "fallbackEn", "primary", "fallbackEn"])
        XCTAssertEqual(outcome.text, english)
        XCTAssertNil(outcome.language)
    }

    private func assertChineseFormulaContext(priorEnglish: Bool) async throws {
        let root = try directory(), session = UUID(), calls = AudioTestBox<[String]>([])
        let source = detectedSource("这段中文说明 partial 的计算方法。")
        XCTAssertTrue(SourceLanguagePolicy.accepts(source, audioDuration: 10))
        let queue = DurableTranscriptionQueue { url, model, _, mode in
            calls.update { $0.append("\(url.lastPathComponent):\(model):\(mode.rawValue)") }
            if url.lastPathComponent == "han.wav" { return model == "primary" ? ASRTranscription(text: "") : source }
            if url.lastPathComponent == "seed.wav" { return ASRTranscription(text: "The derivative points along the slope in this example.") }
            return ASRTranscription(text: "The factorial notation fits this small example.")
        }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                  startPaused: true, handler: { _ in })
        let names = (priorEnglish ? ["seed.wav"] : []) + ["han.wav", "tail.wav"]
        for (ordinal, name) in names.enumerated() {
            queue.submit(.init(audioURL: try audio(root, name: name, seconds: 10), modelKey: "primary", fallbackModelKey: "fallback",
                start: Double(ordinal * 10), end: Double((ordinal + 1) * 10), appleEvidence: "", recordingURL: nil,
                sessionID: session), handler: { _ in })
        }
        try queue.resume(); await queue.finish()
        XCTAssertEqual(queue.records.map(\.status), Array(repeating: .completed, count: names.count))
        XCTAssertEqual(calls.value.filter { $0 == "tail.wav:fallback:english" }.count, priorEnglish ? 1 : 0)
        XCTAssertEqual(calls.value.filter { $0.hasSuffix(":auto") }, ["han.wav:fallback:auto"])
    }

    func testMultilingualChineseCannotEstablishFormulaContext() async throws {
        try await assertChineseFormulaContext(priorEnglish: false)
    }

    func testMultilingualChineseKeepsPreviousEnglishFormulaContext() async throws {
        try await assertChineseFormulaContext(priorEnglish: true)
    }

    func testMultilingualCandidateResolutionCarriesAndClearsLanguages() async throws {
        for accept in [true, false] {
            let root = try directory(), session = UUID()
            let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
            var record = work(session, ordinal: 0, status: .completed, fallback: "fallback")
            record.text = "The gate stays closed."; record.candidateText = detectedSource().text
            record.candidateLanguage = "zh"; record.candidateOrigin = "sameRangeRevision"
            try journal.put(record)
            let queue = DurableTranscriptionQueue { _, _, _, _ in XCTFail("No recognition during resolution"); return ASRTranscription(text: "") }
            try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                                      restoring: true, startPaused: true, handler: { _ in })
            try queue.resolveCandidate(id: record.id, acceptedText: accept ? record.candidateText : nil)
            let resolved = try XCTUnwrap(queue.records.first)
            XCTAssertEqual(resolved.textLanguage, accept ? "zh" : nil)
            XCTAssertEqual(resolved.text, accept ? record.candidateText : record.text)
            XCTAssertNil(resolved.candidateText)
            XCTAssertNil(resolved.candidateLanguage)
            await queue.finish(); try assertOldBuildReads(queue)
        }
    }

    func testMultilingualRestoredConflictsPreserveBodyAndCandidateLanguages() async throws {
        let source = detectedSource()
        for languageOnly in [false, true] {
            for accept in [false, true] {
                let root = try directory(), session = UUID()
                let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
                var record = work(session, ordinal: 0, status: .completed, fallback: "fallback")
                record.text = source.text; record.textLanguage = source.language
                _ = try audio(journal.directory, name: record.audioFile, seconds: 10)
                try journal.put(record)
                let original = TranscriptSegment(id: record.id, startTime: 0, endTime: 10,
                    english: languageOnly ? source.text : "The archive keeps the confirmed sentence.",
                    sessionID: session, sourceLanguage: languageOnly ? "yue" : nil)
                let store = SessionStore(directory: root)
                _ = try store.save(.init(sessionID: session, segments: [original]))
                let replayed = AudioTestBox<[TranscriptionCommit]>([]), candidates = AudioTestBox<[TranscriptionCandidate]>([])
                let queue = DurableTranscriptionQueue { _, _, _, _ in
                    XCTFail("Restoring conflicts cannot invoke ASR"); return ASRTranscription(text: "")
                }
                try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
                    restoring: true, startPaused: true) {
                        if case .identifiedFinal(let commit) = $0 { replayed.update { $0.append(commit) } }
                        if case .transcriptionCandidate(let candidate) = $0 { candidates.update { $0.append(candidate) } }
                    }
                let replay = try XCTUnwrap(replayed.value.last)
                let archived = try XCTUnwrap(store.load()?.segments.first)
                try queue.preserveConflictingTranscript(id: replay.id, sessionID: session,
                    originalText: archived.english, originalLanguage: archived.sourceLanguage,
                    candidateText: replay.text, candidateLanguage: replay.language)
                XCTAssertEqual(queue.records.first?.text, archived.english)
                XCTAssertEqual(queue.records.first?.textLanguage, archived.sourceLanguage)
                XCTAssertEqual(queue.records.first?.candidateText, source.text)
                XCTAssertEqual(queue.records.first?.candidateLanguage, "zh")
                XCTAssertEqual(candidates.value.last?.language, "zh")
                XCTAssertThrowsError(try queue.preserveConflictingTranscript(id: replay.id, sessionID: session,
                    originalText: archived.english, originalLanguage: archived.sourceLanguage,
                    candidateText: replay.text, candidateLanguage: "ja"), "A differently labelled pending candidate stays intact")
                await queue.finish()

                let restored = DurableTranscriptionQueue { _, _, _, _ in
                    XCTFail("A second restore cannot invoke ASR"); return ASRTranscription(text: "")
                }
                replayed.update { $0.removeAll() }; candidates.update { $0.removeAll() }
                try await restored.configure(directory: root, sessionID: session, persistent: true, identified: true,
                    restoring: true, startPaused: true) {
                        if case .identifiedFinal(let commit) = $0 { replayed.update { $0.append(commit) } }
                        if case .transcriptionCandidate(let candidate) = $0 { candidates.update { $0.append(candidate) } }
                    }
                XCTAssertEqual(replayed.value.last?.text, archived.english)
                XCTAssertEqual(replayed.value.last?.language, archived.sourceLanguage)
                XCTAssertEqual(candidates.value.last?.text, source.text)
                XCTAssertEqual(candidates.value.last?.language, "zh")
                try restored.resolveCandidate(id: record.id, acceptedText: accept ? source.text : nil)
                XCTAssertEqual(restored.records.first?.text, accept ? source.text : archived.english)
                XCTAssertEqual(restored.records.first?.textLanguage, accept ? "zh" : archived.sourceLanguage)
                XCTAssertNil(restored.records.first?.candidateLanguage)
                await restored.finish(); try assertOldBuildReads(restored)
            }
        }
    }

    func testMultilingualRestoredCandidateConsentKeepsCaptionLanguage() async throws {
        let root = try directory(), session = UUID(), events = AudioTestBox<[TranscriptionCommit]>([])
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        let evidence = "NMR 5 mL"
        var record = TranscriptionWorkRecord(id: UUID(), sessionID: session, ordinal: 0, audioFile: "chunk-0.wav",
            startFrame: 0, endFrame: 160_000, sampleRate: 16_000, start: 0, end: 10, captureStart: nil, captureEnd: nil,
            modelKey: "primary", fallbackModelKey: "fallback", appleEvidence: evidence)
        record.status = .completed
        record.text = "The cart stops by the gate."; record.candidateText = detectedSource().text
        record.candidateLanguage = "zh"; record.candidateOrigin = "sameRangeRevision"
        XCTAssertFalse(AuxiliaryTranslationHintExtractor.extract(from: evidence, primary: record.candidateText!).isEmpty)
        try journal.put(record)
        let original = TranscriptSegment(id: record.id, startTime: 0, endTime: 10, english: record.text!, sessionID: session)
        let replacement = TranscriptSegment(id: record.id, startTime: 0, endTime: 10, english: record.candidateText!,
            sessionID: session, inputRevision: 1, sourceLanguage: "zh")
        let store = SessionStore(directory: root)
        _ = try store.save(.init(sessionID: session, segments: [original]))
        _ = try store.append(.inputRevision(.init(fromRevision: 0, toRevision: 1, previousSegment: original,
            replacementSegment: replacement, reason: "Synthetic confirmation", transcriptionCandidateText: record.candidateText)))
        let queue = DurableTranscriptionQueue { _, _, _, _ in XCTFail("Restoration cannot run ASR"); return ASRTranscription(text: "") }
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
            restoring: true, startPaused: true) { if case .identifiedFinal(let c) = $0 { events.update { $0.append(c) } } }
        XCTAssertEqual(queue.records.first?.textLanguage, "zh")
        XCTAssertNil(queue.records.first?.candidateLanguage)
        XCTAssertEqual(events.value.map(\.language), ["zh"])
        XCTAssertTrue(events.value.allSatisfy { $0.hints.isEmpty })
        await queue.finish(); try assertOldBuildReads(queue)
    }

    func testMultilingualSpeechPipelinePassesAutoModeAndLanguage() async throws {
        let root = try directory(), session = UUID(), calls = AudioTestBox<[ASRLanguageMode]>([])
        let events = AudioTestBox<[SpeechPipeline.Event]>([]), source = detectedSource()
        let pipeline = SpeechPipeline(transcriber: { _, _, _, mode in
            calls.update { $0.append(mode) }
            return mode == .auto ? source : ASRTranscription(text: "")
        }, enableAudioAnalysis: false)
        let input = try await pipeline.startSyntheticCapture(format: format(), recordingURL: root.appendingPathComponent("recording.wav"),
            sessionID: session, eventHandler: { e in events.update { $0.append(e) } })
        input.submit(buffer(16_000)); await input.drain()
        await pipeline.stopCapture(); await pipeline.drainTranscription(sessionID: session)
        XCTAssertEqual(calls.value, [.english, .auto])
        XCTAssertEqual(pipeline.transcriptionWork().first?.textLanguage, "zh")
        XCTAssertEqual(events.value.compactMap { if case .identifiedFinal(let c) = $0 { return c.language }; return nil }, ["zh"])
    }
}

/// The journal record exactly as LiveLingo 0.2.0 declares it (synthesized coding),
/// used to check that new journals still open after a downgrade.
private struct LegacyWorkRecord: Codable, Equatable {
    enum Status: String, Codable { case pending, active, retryWaiting, manualPending, completed, silent, failed }
    enum Attempt: String, Codable { case initial, automaticRetry, manual }
    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    let audioFile: String
    let startFrame: Int64
    let endFrame: Int64
    let sampleRate: Double
    let start: TimeInterval
    let end: TimeInterval
    let captureStart: TimeInterval?
    let captureEnd: TimeInterval?
    let modelKey: String
    let fallbackModelKey: String?
    let appleEvidence: String
    var recordingFile: String? = nil
    var audioRetired: Bool? = nil
    var status: Status = .pending
    var attempt: Attempt = .initial
    var automaticRetryCount = 0
    var manualRetryCount = 0
    var text: String?
    var candidateText: String?
    var candidateOrigin: String?
    var failure: String?
}

private struct LegacyMutation: Codable {
    let version: Int
    let sessionID: UUID
    let sequence: Int
    var record: LegacyWorkRecord?
    var paused: Bool?
    var capturing: Bool?
}

private struct LegacyState: Decodable {
    let version: Int
    let sessionID: UUID
    let sequence: Int
    let records: [LegacyWorkRecord]
}

private struct LegacyEnvelope: Codable {
    let payload: Data
    let sha256: String
}

/// One checksummed journal line in the 0.2.0 format.
private func legacyRow<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(value)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    var row = try JSONEncoder().encode(LegacyEnvelope(payload: payload, sha256: digest))
    row.append(0x0a)
    return row
}

/// Frozen recognition and cache from ea844fc, before step 5. Only type names,
/// access for the test, and Encodable on its outcome differ from that source.
private enum Step5LegacyRecognition {
    struct Outcome: Encodable, Sendable {
        var text = ""
        var silent = false
        var candidate: String?
        var origin: String?
        /// Why the exact range has no accepted English; identifiers only.
        var failureReason: TranscriptionWorkRecord.FailureReason?
        var otherLanguage = false
    }
    static func recognize(_ record: TranscriptionWorkRecord, audioURL: URL, recordingURL: URL?,
                                  formulaContext: String, attempts: Step5LegacyAttemptCache,
                                  transcriber: DurableTranscriptionQueue.LegacyTranscriber) async throws -> Outcome {
        try Task.checkCancellation()
        if try DigitalSilenceGate.isSilent(audioURL) { return Outcome(silent: true) }
        let attemptNonce = UUID()
        func recognizeStage(_ url: URL, model: String, enhance: Bool, stage: String) async throws -> String {
            try Task.checkCancellation()
            // Only enhanced exact-range requests recur during automatic repair.
            // Raw first-pass speech and final neighbour clips need no caching.
            let reusable = enhance && stage != "context" && record.attempt != .manual
            let fingerprint = reusable ? try? Step5LegacyAttemptCache.fingerprint(url) : nil
            let key = fingerprint.map { Step5LegacyAttemptCache.Key(id: record.id, model: model,
                                                                       enhanced: enhance, audio: $0) }
            if let key, let text = attempts.text(for: key) {
                try Task.checkCancellation()
                return text
            }
            let id = ASRRequestContext.identifier(sessionID: record.sessionID, chunkID: record.id,
                automatic: record.automaticRetryCount, manual: record.manualRetryCount,
                stage: stage, nonce: attemptNonce)
            let text = try await ASRRequestContext.$requestID.withValue(id) {
                try await transcriber(url, model, enhance)
            }
            try Task.checkCancellation()
            if let key, text.utf8.count <= Step5LegacyAttemptCache.maximumTextBytes,
               (try? Step5LegacyAttemptCache.fingerprint(url)) == key.audio {
                attempts.store(text, for: key)
            }
            return text
        }
        var primary = ""
        var primaryError: Error?
        do { primary = try await recognizeStage(audioURL, model: record.modelKey,
            enhance: record.attempt != .initial, stage: "primary") }
        catch is CancellationError { throw CancellationError() }
        catch { primaryError = error }
        try Task.checkCancellation()
        let usable = SpeechPipeline.preferredTranscript(primary: primary, fallback: "", audioDuration: record.duration)
        let formula = FormulaASRReview.needsReview(primary, context: formulaContext)
        let needsFallback = primaryError != nil || formula || !EnglishTranscriptGate.accepts(primary)
            || ASRQualityGate.fallbackReason(for: primary, audioDuration: record.duration) != nil
        var output = Outcome(text: usable)
        if usable.isEmpty {
            output.failureReason = primaryError == nil
                ? .rejection(of: primary, audioDuration: record.duration) : .error
        }
        var fallbackVerdict: EnglishTranscriptGate.Verdict?
        if needsFallback, let model = record.fallbackModelKey {
            do {
                let secondary = try await recognizeStage(audioURL, model: model, enhance: true, stage: "fallback")
                try Task.checkCancellation()
                let alternate = SpeechPipeline.preferredTranscript(primary: nil, fallback: secondary, audioDuration: record.duration)
                fallbackVerdict = EnglishTranscriptGate.verdict(secondary)
                if output.text.isEmpty {
                    output.text = alternate
                    // A primary error stays the reason: it, not the language, blocks `.otherLanguage`.
                    if primaryError == nil { output.failureReason = .rejection(of: secondary, audioDuration: record.duration) }
                }
                else if !alternate.isEmpty, alternate != output.text {
                    output.candidate = alternate; output.origin = "alternateModel"
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A fallback exception must never erase usable primary speech.
                if output.text.isEmpty { primaryError = error; output.failureReason = .error }
            }
        }
        if !output.text.isEmpty { return output }
        // No English was accepted, the enhanced English pass has run (it can still
        // recover speech the raw pass missed), and the multilingual fallback heard
        // Han-dominant speech. Stop: later automatic attempts reuse these results
        // and neighbour context would only borrow adjacent sentences.
        if primaryError == nil, record.attempt != .initial, fallbackVerdict == .hanDominant {
            output.otherLanguage = true
            return output
        }
        // The second automatic attempt may consult neighbours after retrying
        // the EXACT original chunk. Its result is always an explicit candidate.
        if record.attempt != .initial,
           record.automaticRetryCount >= DurableTranscriptionJournal.maximumAutomaticRetries,
           let recordingURL {
            let clip = try RecordingDiagnostics.contextAudio(recordingURL: recordingURL, start: record.start, end: record.end)
            defer { try? FileManager.default.removeItem(at: clip) }
            let text = try await recognizeStage(clip, model: record.fallbackModelKey ?? record.modelKey,
                                                enhance: true, stage: "context")
            try Task.checkCancellation()
            let candidate = SpeechPipeline.preferredTranscript(primary: nil, fallback: text, audioDuration: record.duration + 1.5)
            if !candidate.isEmpty { output.candidate = candidate; output.origin = "context" }
        }
        if output.candidate == nil, let primaryError { throw primaryError }
        return output
    }
}

private final class Step5LegacyAttemptCache: @unchecked Sendable {
    struct Key: Hashable {
        let id: UUID
        let model: String
        let enhanced: Bool
        let audio: Data
    }
    static let maximumTextBytes = 16 * 1024
    private let lock = NSLock()
    private var entries: [Key: String] = [:]
    private var order: [Key] = []

    func text(for key: Key) -> String? { lock.withLock { entries[key] } }
    func store(_ text: String, for key: Key) {
        guard text.utf8.count <= Self.maximumTextBytes else { return }
        lock.withLock {
            if entries[key] == nil {
                if order.count == 64 { entries.removeValue(forKey: order.removeFirst()) }
                order.append(key)
            }
            entries[key] = text
        }
    }
    func remove(id: UUID) {
        lock.withLock {
            for key in order where key.id == id { entries.removeValue(forKey: key) }
            order.removeAll { $0.id == id }
        }
    }
    static func fingerprint(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let limit = 64 * 1024 * 1024
        guard values.isRegularFile == true, let size = values.fileSize, size <= limit else {
            throw CocoaError(.fileReadTooLarge)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), count = 0
        while let data = try file.read(upToCount: 64 * 1024), !data.isEmpty {
            count += data.count
            guard count <= limit else { throw CocoaError(.fileReadTooLarge) }
            digest.update(data: data)
        }
        return Data(digest.finalize())
    }
}
