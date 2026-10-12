import AVFoundation
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class AlarmLifecycleTests: XCTestCase {
    private final class FailureSwitch: @unchecked Sendable {
        let lock = NSLock()
        private var enabled = false
        func enable() { lock.withLock { enabled = true } }
        func check() throws { if lock.withLock({ enabled }) { throw CocoaError(.fileWriteUnknown) } }
    }
    private struct Fixture {
        let root: URL
        let defaults: TestUserDefaults
        let cleanup: TestPreferenceCleanup
        let pipeline: SpeechPipeline
        let queue: LearningReviewQueue
        let model: AppModel
    }
    private func fixture(failure: FailureSwitch? = nil) throws -> Fixture {
        let root = TestFixtureDirectory.root.appendingPathComponent("Alarm-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic public test voice." },
            beforeChunkOpen: { try failure?.check() }, enableAudioAnalysis: false,
            enableMicrophoneWatchdog: false, enableCaptureHealthWatchdog: false)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("review.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        let model = AppModel(reviewQueue: queue, pipeline: pipeline, backgroundServices: false, defaults: defaults)
        addTeardownBlock { @MainActor in
            await model.retireAlarmTasksForTesting()
            await pipeline.stopCapture(continueTranscribing: false)
            try await TestTaskLifetime.stop(model, queue: queue)
            try cleanup.remove(defaults)
            // Synthetic PCM and snapshots stay in this run's DerivedData.
        }
        return Fixture(root: root, defaults: defaults, cleanup: cleanup, pipeline: pipeline, queue: queue, model: model)
    }
    private func trigger(_ model: AppModel, now: Double = 100) {
        for (index, end) in [3.0, 4.5, 6].enumerated() {
            model.receiveAlarmSoundForTesting(.init(start: end - 3, end: end, score: 0.8), now: now + Double(index) * 1.5)
        }
    }
    private func pcm(_ value: Float, frames: UInt32 = 1600) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: MediaFileImport.storageFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: value, count: Int(frames))
        return buffer
    }
    private func push(_ input: OwnedAudioCaptureBuffer, value: Float, end: TimeInterval) -> OwnedAudioCaptureBuffer.Submission {
        let buffer = pcm(value)
        return input.copy(buffer.audioBufferList, frames: Int(buffer.frameLength), observedEnd: end)
    }
    func testBothPreferencesDefaultOnAndExplicitOffPersists() throws {
        let f = try fixture()
        XCTAssertTrue(f.model.alarmDetectionEnabled)
        XCTAssertTrue(f.model.alarmAutomaticSaveEnabled)
        f.model.alarmDetectionEnabled = false
        f.model.alarmAutomaticSaveEnabled = false
        XCTAssertEqual(f.defaults.object(forKey: AppModel.alarmDetectionDefaultsKey) as? Bool, false)
        XCTAssertEqual(f.defaults.object(forKey: AppModel.alarmAutomaticSaveDefaultsKey) as? Bool, false)
        let model = AppModel(reviewQueue: f.queue, pipeline: f.pipeline, backgroundServices: false, defaults: f.defaults)
        XCTAssertFalse(model.alarmDetectionEnabled)
        XCTAssertFalse(model.alarmAutomaticSaveEnabled)
    }
    func testSystemAudioImportAndDisabledDetectionCannotPresentOrSplit() throws {
        for scenario in 0..<3 {
            let f = try fixture()
            f.model.loadPresentationForTesting(phase: .recording, evidence: [])
            f.model.configureAlarmForTesting(input: scenario == 0 ? .systemAudio : .microphone, importing: scenario == 1)
            if scenario == 2 { f.model.alarmDetectionEnabled = false }
            trigger(f.model)
            XCTAssertNil(f.model.alarmBanner)
            f.model.alarmCountdownTickForTesting(now: 200)
            XCTAssertNil(f.model.alarmRolloverTaskForTesting)
        }
    }
    func testCancelDuringCountdownKeepsSameRecordingAndAudioWriter() async throws {
        let f = try fixture()
        let directory = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: directory)
        XCTAssertEqual(push(input, value: 0.1, end: 1), .accepted)
        trigger(f.model)
        XCTAssertEqual(f.model.alarmBanner?.secondsRemaining, 30)
        f.model.dismissAlarmReminder()
        f.model.alarmCountdownTickForTesting(now: 200)
        XCTAssertNil(f.model.alarmRolloverTaskForTesting)
        XCTAssertTrue(f.model.isRecording)
        XCTAssertEqual(f.model.currentCourseDirectory, directory)
        XCTAssertEqual(push(input, value: 0.2, end: 1.1), .accepted)
        await f.pipeline.stopCapture(continueTranscribing: false)
        XCTAssertEqual(try AVAudioFile(forReading: directory.appendingPathComponent("recording.wav")).length, 3200)
    }
    func testPausedImportAndLiveOnlyCannotAutoSplitAtDeadline() async throws {
        for scenario in 0..<3 {
            let f = try fixture()
            _ = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: f.root.appendingPathComponent("first"))
            trigger(f.model)
            if scenario == 0 { f.model.pause() }
            if scenario == 1 { f.model.configureAlarmForTesting(input: .microphone, importing: true) }
            if scenario == 2 { f.model.configureAlarmForTesting(input: .microphone, storage: .liveOnly) }
            f.model.alarmCountdownTickForTesting(now: 133)
            XCTAssertNil(f.model.alarmRolloverTaskForTesting)
            XCTAssertNotNil(f.model.alarmBanner)
            XCTAssertNil(f.model.alarmBanner?.secondsRemaining)
        }
    }
    func testLiveOnlyAndManualSaveDisabledOnlyRemind() throws {
        for liveOnly in [true, false] {
            let f = try fixture()
            f.model.loadPresentationForTesting(phase: .recording, evidence: [])
            f.model.configureAlarmForTesting(input: .microphone, storage: liveOnly ? .liveOnly : .saveSession)
            if !liveOnly { f.model.alarmAutomaticSaveEnabled = false }
            trigger(f.model)
            XCTAssertNotNil(f.model.alarmBanner)
            XCTAssertEqual(f.model.alarmBanner?.liveOnly, liveOnly)
            XCTAssertNil(f.model.alarmBanner?.secondsRemaining)
            f.model.alarmCountdownTickForTesting(now: 200)
            XCTAssertNil(f.model.alarmRolloverTaskForTesting)
        }
    }
    func testCountdownSwitchesToSameParentAndPCMRemainsContinuous() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        let identity = input.identity
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 132.99)
        XCTAssertNil(f.model.alarmRolloverTaskForTesting)
        f.model.alarmCountdownTickForTesting(now: 133)
        let split = try XCTUnwrap(f.model.alarmRolloverTaskForTesting)
        try await TestTaskLifetime.value(split)
        XCTAssertTrue(f.model.isRecording)
        let second = try XCTUnwrap(f.model.currentCourseDirectory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.deletingLastPathComponent(), first.deletingLastPathComponent())
        XCTAssertTrue(second.lastPathComponent.hasSuffix(AlarmPolicy.postAlarmFolderSuffix))
        XCTAssertTrue(f.model.alarmBanner?.saved == true)
        XCTAssertEqual(input.identity, identity)
        XCTAssertEqual(push(input, value: 0.25, end: 1.1), .accepted)
        await f.pipeline.stopCapture(continueTranscribing: false)
        let a = try AVAudioFile(forReading: first.appendingPathComponent("recording.wav"))
        let b = try AVAudioFile(forReading: second.appendingPathComponent("recording.wav"))
        XCTAssertEqual(a.length, 1600)
        XCTAssertEqual(b.length, 1600)
        let sa = try XCTUnwrap(SessionStore(directory: first).load())
        let sb = try XCTUnwrap(SessionStore(directory: second).load())
        XCTAssertNotEqual(sa.sessionID, sb.sessionID)
        XCTAssertEqual(sa.audioFiles.first?.frameCount, 1600)
        XCTAssertEqual(sa.audioFiles.first?.isFinalized, true)
        XCTAssertNil(sa.targetLocale)
        XCTAssertNil(sb.targetLocale)
        XCTAssertNotNil(sb.captureStart)
        XCTAssertEqual(sb.transcriptionJournalPath, DurableTranscriptionJournal.directoryName + "/work.jsonl")
        XCTAssertEqual(f.model.outputLanguage, .simplifiedChinese)
        let samples = AVAudioPCMBuffer(pcmFormat: a.processingFormat, frameCapacity: 1600)!
        try a.read(into: samples)
        XCTAssertEqual(samples.floatChannelData![0][0], 0.125, accuracy: 0.0001)
        try b.read(into: samples)
        XCTAssertEqual(samples.floatChannelData![0][1599], 0.25, accuracy: 0.0001)
        let submittedFrames: Int64 = 3200
        let missingFrames = submittedFrames - a.length - b.length
        let frameGapMilliseconds = Double(missingFrames) / a.processingFormat.sampleRate * 1000
        let previousCaptureEnd = try XCTUnwrap(sa.audioRanges.last?.captureEnd)
        let nextCaptureStart = try XCTUnwrap(f.pipeline.transcriptionWork().last?.captureStart)
        let observedGapMilliseconds = (nextCaptureStart - previousCaptureEnd) * 1000
        XCTAssertEqual(missingFrames, 0)
        XCTAssertEqual(observedGapMilliseconds, 0, accuracy: 0.001)
        print("ALARM_ROLLOVER submitted_frames=\(submittedFrames) measured_gap_frames=\(missingFrames) frame_gap_ms=\(frameGapMilliseconds) observed_gap_ms=\(observedGapMilliseconds) sample_rate=\(a.processingFormat.sampleRate) first_frames=\(a.length) second_frames=\(b.length) barrier_ms=\(f.model.alarmSwitchMilliseconds ?? -1) synthetic_pcm=true")
    }
    func testPreparationFailureKeepsFirstAudioAndContinuesRecording() async throws {
        let fail = FailureSwitch()
        let f = try fixture(failure: fail)
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        fail.enable()
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        XCTAssertTrue(f.model.isRecording)
        XCTAssertEqual(f.model.currentCourseDirectory, first)
        XCTAssertNotNil(f.model.alarmBanner?.failure)
        XCTAssertEqual(push(input, value: 0.25, end: 1.1), .accepted)
        await f.pipeline.stopCapture(continueTranscribing: false)
        XCTAssertEqual(try AVAudioFile(forReading: first.appendingPathComponent("recording.wav")).length, 3200)
        XCTAssertNotNil(try SessionStore(directory: first).load())
    }
    func testLateOldQueueProcessingCannotBorrowNewCourseAudioRanges() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        var replayed = false
        f.model.configurePrivacyExitForTesting(.init(flush: {
            if f.pipeline.transcriptionState()?.sessionID != f.model.captureHealthSessionIDForTesting {
                replayed = true
                f.model.replayParkedAlarmProcessingForTesting()
                f.model.configurePrivacyExitForTesting(.init())
                try await f.model.flushSavedCourseForTesting()
            }
        }))
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        f.model.configurePrivacyExitForTesting(.init())
        XCTAssertTrue(replayed)
        XCTAssertTrue(f.model.isRecording)
        let old = try XCTUnwrap(SessionStore(directory: first).load())
        XCTAssertEqual(old.audioRanges.count, 1)
        XCTAssertEqual(old.audioRanges.first?.frameCount, 1600)
        XCTAssertEqual(old.audioFiles.first?.isFinalized, true)
        XCTAssertNotEqual(old.sessionID, f.model.captureHealthSessionIDForTesting)
    }

    func testPostBoundarySaveFailurePreservesFirstTranscriptAndBothRecordingTrees() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        let caption = TranscriptSegment(startTime: 0, endTime: 0.1,
            english: "Synthetic first section remains intact.", chinese: "第一节合成内容完整保留。",
            sessionID: f.model.captureHealthSessionIDForTesting)
        f.model.receiveIdentifiedCaptionForTesting(caption)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        f.model.configurePrivacyExitForTesting(.init(flush: {
            if f.pipeline.transcriptionState()?.sessionID != f.model.captureHealthSessionIDForTesting {
                throw CocoaError(.fileWriteUnknown)
            }
        }))
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        f.model.configurePrivacyExitForTesting(.init())
        try await f.model.flushSavedCourseForTesting()
        XCTAssertFalse(f.model.isRecording)
        XCTAssertNil(f.model.alarmBanner)
        XCTAssertEqual(try AVAudioFile(forReading: first.appendingPathComponent("recording.wav")).length, 1600)
        XCTAssertEqual(try SessionStore(directory: first).load()?.segments.map(\.english), [caption.english])
        let siblings = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(AlarmPolicy.postAlarmFolderSuffix) }
        XCTAssertEqual(siblings.count, 1)
        let second = try XCTUnwrap(siblings.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("recording.wav").path))
        XCTAssertNotNil(try SessionStore(directory: second).load())
        XCTAssertNotEqual(try SessionStore(directory: first).load()?.sessionID,
                          try SessionStore(directory: second).load()?.sessionID)
        XCTAssertNotNil(f.model.archiveNotice)
    }

    func testStopWithdrawsBannerAndCountdownImmediately() async throws {
        let f = try fixture()
        _ = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: f.root.appendingPathComponent("first"))
        trigger(f.model)
        f.model.stop()
        XCTAssertNil(f.model.alarmBanner)
        f.model.alarmCountdownTickForTesting(now: 133)
        XCTAssertNil(f.model.alarmRolloverTaskForTesting)
        await f.model.stopSavedCourseForTesting()
    }
}
