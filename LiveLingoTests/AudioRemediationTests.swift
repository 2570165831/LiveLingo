import AVFoundation
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
    private func work(_ session: UUID, ordinal: Int, status: TranscriptionWorkRecord.Status = .pending) -> TranscriptionWorkRecord {
        var r = TranscriptionWorkRecord(id: UUID(), sessionID: session, ordinal: ordinal,
            audioFile: "chunk-\(ordinal).wav", startFrame: Int64(ordinal * 160_000),
            endFrame: Int64((ordinal + 1) * 160_000), sampleRate: 16_000,
            start: Double(ordinal * 10), end: Double((ordinal + 1) * 10), captureStart: nil, captureEnd: nil,
            modelKey: "primary", fallbackModelKey: nil, appleEvidence: "")
        r.status = status
        return r
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
}
