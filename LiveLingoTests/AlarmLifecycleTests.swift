import AVFoundation
import Combine
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class AlarmLifecycleTests: XCTestCase {
    private final class DiskWorkProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func enter() { lock.withLock { calls += 1 } }
    }
    @MainActor private final class Gate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Alarm lifecycle checkpoint was not reached"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private final class FailureSwitch: @unchecked Sendable {
        let lock = NSLock()
        private var enabled = false
        func enable() { lock.withLock { enabled = true } }
        func check() throws { if lock.withLock({ enabled }) { throw CocoaError(.fileWriteUnknown) } }
    }
    private final class WriterPreparationGate: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var armed = false
        private var reached = false
        var entered: Bool { lock.withLock { reached } }
        func arm() { lock.withLock { armed = true } }
        func holdIfArmed() {
            guard lock.withLock({ if armed { reached = true; return true }; return false }) else { return }
            _ = ready.wait(timeout: .now() + 5)
        }
        func release() { ready.signal() }
    }
    private final class SyntheticMicrophone: NSObject, MicrophoneCaptureEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var starts = 0
        var notificationObject: AnyObject { self }
        let outputFormat = MediaFileImport.storageFormat
        var isRunning: Bool { lock.withLock { running } }
        var startCount: Int { lock.withLock { starts } }
        func installTap(format: AVAudioFormat, input: OwnedAudioCaptureBuffer) throws {}
        func removeTap() {}
        func prepare() {}
        func start() throws { lock.withLock { running = true; starts += 1 } }
        func pause() { lock.withLock { running = false } }
        func stop() { lock.withLock { running = false } }
    }
    private struct Fixture {
        let root: URL
        let defaults: TestUserDefaults
        let cleanup: TestPreferenceCleanup
        let pipeline: SpeechPipeline
        let queue: LearningReviewQueue
        let model: AppModel
    }
    private func fixture(failure: FailureSwitch? = nil, writerPreparation: WriterPreparationGate? = nil,
                         translation: CaptionTranslationDependencies = .unavailable,
                         chineseRecognition: ChineseRecognitionDependencies = .unavailable) throws -> Fixture {
        let root = TestFixtureDirectory.root.appendingPathComponent("Alarm-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic public test voice." },
            beforeChunkOpen: { try failure?.check(); writerPreparation?.holdIfArmed() }, enableAudioAnalysis: false,
            enableMicrophoneWatchdog: false, enableCaptureHealthWatchdog: false)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("review.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        let model = AppModel(reviewQueue: queue, pipeline: pipeline, translation: translation, notes: .unavailable, chineseRecognition: chineseRecognition,
                             backgroundServices: false, defaults: defaults, recoveryDirectory: root)
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
        for end in [3.0, 4.5, 6, 7.5, 9] {
            model.receiveAlarmSoundForTesting(.init(start: end - 3, end: end, score: 0.8), now: now + end - 6)
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
    func testAlarmRolloverHandsQueuedChineseRequestToSavedCourse() async throws {
        var calls = 0
        let f = try fixture(chineseRecognition: .init { _, _ in
            calls += 1
            return .init(text: "警报前课程的中文原文。", languageMode: .chinese, language: "zh", decode: .forced,
                         generatedTokens: 12, policy: 1)
        })
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        let samples = pcm(0.125, frames: 48_000)
        XCTAssertEqual(input.copy(samples.audioBufferList, frames: 48_000, observedEnd: 3), .accepted)
        await input.drain()
        f.model.receiveCaptionForTesting("A synthetic caption before alarm.", start: 0, end: 3)
        let caption = try XCTUnwrap(f.model.segments.first)
        f.model.recognizeCaptionAsChinese(caption.id)
        XCTAssertEqual(f.model.chineseRecognitionState.statuses[caption.id], .waitingForRealtime)
        XCTAssertEqual(calls, 0)
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        await f.model.waitForAlarmArchivesForTesting()
        let saved = try XCTUnwrap(f.model.alarmArchivedModelsForTesting.first)
        XCTAssertEqual(saved.chineseRecognitionState.statuses[caption.id], .pending)
        XCTAssertEqual(try SessionStore(directory: first).load()?.pendingChineseRecognition?.first?.id, caption.id)
        XCTAssertNil(f.model.chineseRecognitionState.statuses[caption.id])
        XCTAssertTrue(f.model.isRecording)
        // Manual work remains parked while the next live course owns realtime.
        // The old saved course retains an executable/cancellable request.
        await f.model.stopSavedCourseForTesting()
        try await eventually { calls == 1 }
        await saved.chineseRecognitionTaskForTesting(caption.id)?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try SessionStore(directory: first).load()?.segments.first?.english, "警报前课程的中文原文。")
        XCTAssertNil(try SessionStore(directory: first).load()?.pendingChineseRecognition)
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
        FloatingSubtitlePreferences(store: f.defaults).showsOnRecordStart = true
        let subtitles = FloatingSubtitleWindowController(defaults: f.defaults)
        let panel = subtitles.prepareWindow(model: f.model)
        panel.alphaValue = 0
        defer { subtitles.shutdown() }
        let observer = FloatingSubtitleRecordStartObserver(model: f.model, windowController: subtitles, defaults: f.defaults)
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
        withExtendedLifetime(observer) {
            XCTAssertFalse(subtitles.isVisible, "An alarm split cannot reopen deliberately hidden subtitles")
            XCTAssertFalse(panel.isVisible)
        }
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
        XCTAssertTrue(try postAlarmDirectories(f.root).isEmpty,
                      "A writer preparation failure must not leave an empty post-alarm course")
    }
    func testPauseAfterRolloverPreparationRestoresTranscriptionAndTranslationOnResume() async throws {
        var translations = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { _, _, _, _, _ in
            translations += 1
            return "恢复后的合成译文。"
        }
        let f = try fixture(translation: dependencies)
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        let microphone = SyntheticMicrophone()
        f.pipeline.bindSyntheticMicrophoneEngine(microphone)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        var checkpointReached = false
        f.model.alarmPreparationParkedForTesting = {
            checkpointReached = true
            XCTAssertTrue(f.model.savedProcessingIsPaused)
            XCTAssertEqual(f.pipeline.transcriptionState()?.isPaused, true)
            f.model.pause()
        }
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        f.model.alarmPreparationParkedForTesting = nil
        XCTAssertTrue(checkpointReached)
        XCTAssertTrue(f.model.isPaused)
        XCTAssertFalse(f.model.savedProcessingIsPaused)
        XCTAssertEqual(f.pipeline.transcriptionState()?.isPaused, false)
        XCTAssertEqual(f.model.currentCourseDirectory, first)
        XCTAssertNil(f.model.alarmBanner?.failure, "A user pause is not a segmentation failure")
        f.model.resume()
        XCTAssertTrue(f.model.isRecording)
        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertEqual(push(input, value: 0.25, end: 1.1), .accepted)
        let segment = TranscriptSegment(startTime: 0, endTime: 0.2, english: "Synthetic caption after resume.",
            sessionID: f.model.captureHealthSessionIDForTesting)
        f.model.receiveIdentifiedCaptionForTesting(segment)
        if let translation = f.model.translationTaskForTesting { try await TestTaskLifetime.value(translation) }
        XCTAssertEqual(translations, 1)
        XCTAssertEqual(f.model.segments.first(where: { $0.id == segment.id })?.chinese, "恢复后的合成译文。")
        await f.pipeline.stopCapture(continueTranscribing: false)
        XCTAssertEqual(try AVAudioFile(forReading: first.appendingPathComponent("recording.wav")).length, 3200)
    }

    func testOpeningPreAlarmCourseJoinsBackgroundOwnerBeforeBindingForegroundArchive() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        await f.model.waitForAlarmArchivesForTesting()
        let archived = try XCTUnwrap(f.model.alarmArchivedModelsForTesting.first)
        XCTAssertEqual(archived.currentCourseDirectory, first)
        await f.model.stopSavedCourseForTesting()
        // A path alias must resolve to the same owner, not another journal.
        let alias = f.root.appendingPathComponent("first-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        try await f.model.openSavedSession(alias, allowAutomaticProcessing: false)
        XCTAssertTrue(f.model.alarmArchivedModelsForTesting.isEmpty)
        XCTAssertTrue(archived.savedProcessingIsPaused)
        XCTAssertNil(archived.savedProcessingTaskForTesting)
        XCTAssertNil(archived.translationTaskForTesting)
        XCTAssertNil(archived.summaryTaskForTesting)
        XCTAssertEqual(SessionDirectoryLocation.canonical(try XCTUnwrap(f.model.currentCourseDirectory)),
                       SessionDirectoryLocation.canonical(first))
        XCTAssertNil(f.model.archiveError)
        try await f.model.flushSavedCourseForTesting()
        let saved = try XCTUnwrap(SessionStore(directory: first).load())
        XCTAssertEqual(saved.sessionID, f.model.captureHealthSessionIDForTesting)
        XCTAssertEqual(saved.audioFiles.first?.frameCount, 1600)
        XCTAssertEqual(saved.audioFiles.first?.isFinalized, true)
        await archived.retireAlarmTasksForTesting()
    }

    func testBackgroundParkingFailureDoesNotOpenASecondWriter() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        await f.model.waitForAlarmArchivesForTesting()
        let archived = try XCTUnwrap(f.model.alarmArchivedModelsForTesting.first)
        await f.model.stopSavedCourseForTesting()
        let second = f.model.currentCourseDirectory
        archived.configurePrivacyExitForTesting(.init(park: { throw CocoaError(.fileWriteUnknown) }))
        defer { archived.configurePrivacyExitForTesting(.init()) }
        do {
            try await f.model.openSavedSession(first, allowAutomaticProcessing: false)
            XCTFail("Failed ownership handoff must not bind a second archive writer")
        } catch { XCTAssertTrue(error is CocoaError) }
        XCTAssertEqual(f.model.currentCourseDirectory, second)
        XCTAssertTrue(f.model.alarmArchivedModelsForTesting.contains(where: { $0 === archived }))
    }
    func testCommittedRolloverKeepsRecordingAndBlocksAllSessionSwitchEntrypoints() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        f.model.loadPresentationForTesting(phase: .recording, evidence: [])
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        let other = f.root.appendingPathComponent("other")
        let otherID = UUID()
        try SessionStore(directory: other).save(SessionSnapshot(sessionID: otherID))
        let originalID = f.model.captureHealthSessionIDForTesting
        let originalOutput = f.model.outputDirectory
        var checkpoint = false
        defer { f.model.alarmBeforeBindingForTesting = nil }
        f.model.alarmBeforeBindingForTesting = {
            checkpoint = true
            XCTAssertTrue(f.model.isRecording)
            XCTAssertTrue(f.model.hasActiveSession)
            XCTAssertTrue(f.model.phase.isBusy, "Preclone's phase gate must still see live capture")
            XCTAssertTrue(f.model.canToggleRecording, "Stop must remain available")
            XCTAssertEqual(f.model.stopRecordingTitle, "结束并保存")
            XCTAssertFalse(f.model.canPauseRecording)
            XCTAssertFalse(f.model.canStart)
            XCTAssertFalse(f.model.canOpenLesson)
            XCTAssertFalse(f.model.canImportMedia)
            // Never invoke an admitted start in a red fixture: that could prepare
            // a real model. A rejected start exercises the production entry guard.
            if !f.model.canStart { f.model.start() }
            if !f.model.canOpenLesson { try await f.model.openSavedSession(other, allowAutomaticProcessing: false) }
            await f.model.recoverRecording(.init(id: otherID, directory: other, outputRoot: f.root))
            f.model.useOutputDirectory(other)
            let chosen = await f.model.chooseOutputDirectory()
            XCTAssertNil(chosen)
            f.model.pause()
            XCTAssertTrue(f.model.isRecording)
            XCTAssertEqual(f.model.captureHealthSessionIDForTesting, originalID)
            XCTAssertEqual(f.model.outputDirectory, originalOutput)
        }
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        XCTAssertTrue(checkpoint)
        XCTAssertTrue(f.model.isRecording)
        XCTAssertNotEqual(f.model.captureHealthSessionIDForTesting, originalID)
        XCTAssertEqual(push(input, value: 0.25, end: 1.1), .accepted)
    }

    func testConvertedLiveCourseSavesBothAlarmSectionsToSelectedLocation() async throws {
        let f = try fixture()
        let staging = try SessionWorkspace.makeTemporarySessionDirectory()
        let selected = f.root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: staging, storage: .liveOnly)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        await f.model.convertCurrentSessionToRecording(in: selected)
        XCTAssertNil(f.model.archiveError)
        XCTAssertFalse(f.model.isLiveOnly)
        let oldID = f.model.captureHealthSessionIDForTesting
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        XCTAssertTrue(f.model.isRecording)
        let next = try XCTUnwrap(f.model.currentCourseDirectory)
        XCTAssertEqual(next.deletingLastPathComponent(), selected)
        XCTAssertEqual(push(input, value: 0.25, end: 1.1), .accepted)
        await f.model.stopSavedCourseForTesting()
        XCTAssertEqual(f.model.savedSessionDirectory, next)
        let courses = try FileManager.default.contentsOfDirectory(at: selected, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("LiveLingo ") }
        XCTAssertEqual(courses.count, 2)
        let snapshots = try courses.map { try XCTUnwrap(SessionStore(directory: $0).load()) }
        XCTAssertTrue(snapshots.contains(where: { $0.sessionID == oldID }))
        XCTAssertTrue(snapshots.allSatisfy { $0.audioFiles.first?.isFinalized == true })
        let audioFrames = try courses.map { try AVAudioFile(forReading: $0.appendingPathComponent("recording.wav")).length }
        XCTAssertEqual(audioFrames.sorted(), [1600, 1600])
        XCTAssertTrue(try SessionWorkspace.recordingRecoveries(in: f.root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let preserved = try FileManager.default.contentsOfDirectory(at: staging.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("." + staging.lastPathComponent + ".migrated-") }
        XCTAssertEqual(preserved.count, 1, "Converted source must be recoverably retained")
    }

    func testExitDuringCommittedRolloverBindsAndFinalizesNewCourseWithinSameLease() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        let gate = Gate()
        defer { gate.release(); f.model.alarmBeforeBindingForTesting = nil }
        f.model.alarmBeforeBindingForTesting = { await gate.wait() }
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        let rollover = try XCTUnwrap(f.model.alarmRolloverTaskForTesting)
        try await eventually { gate.entered }
        XCTAssertEqual(push(input, value: 0.25, end: 1.1), .accepted)
        await input.drain()
        let deadline = ExitDeadline(seconds: 5)
        let exit = Task { @MainActor in await f.model.prepareForApplicationExit(deadline: deadline) }
        try await eventually { f.model.isTerminating && deadline.hasPendingOperations }
        gate.release()
        try await TestTaskLifetime.value(rollover)
        let exited = await exit.value
        XCTAssertTrue(exited)
        XCTAssertFalse(deadline.isExpired)
        XCTAssertFalse(f.pipeline.alarmCaptureIsActive)
        let next = try XCTUnwrap(f.model.currentCourseDirectory)
        XCTAssertNotEqual(next, first)
        XCTAssertEqual(f.model.phase, .saved(next))
        XCTAssertEqual(try SessionStore(directory: first).load()?.audioFiles.first?.isFinalized, true)
        XCTAssertEqual(try SessionStore(directory: next).load()?.audioFiles.first?.isFinalized, true)
        XCTAssertEqual(try AVAudioFile(forReading: first.appendingPathComponent("recording.wav")).length, 1600)
        XCTAssertEqual(try AVAudioFile(forReading: next.appendingPathComponent("recording.wav")).length, 1600)
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

    private func postAlarmDirectories(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(AlarmPolicy.postAlarmFolderSuffix) }
    }

    func testAlarmSegmentationNeverStartsPrecloneDiskWorkWhileCaptureContinues() async throws {
        let f = try fixture()
        let disk = DiskWorkProbe()
        var scheduled = 0
        var worker: (@Sendable () -> Bool)?
        var complete: (@MainActor @Sendable (Bool) -> Void)?
        let controller = ModelPrecloneController(phases: f.model.$phase.eraseToAnyPublisher(),
            scheduler: { delay, priority, work, completion in
                XCTAssertEqual(delay, .seconds(15))
                XCTAssertEqual(priority, .background)
                scheduled += 1; worker = work; complete = completion
                return .init(cancel: {})
            }, work: { _ in disk.enter(); return false })
        defer { withExtendedLifetime(controller) {} }
        XCTAssertEqual(scheduled, 1, "Idle schedules an initial grace period")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: f.root.appendingPathComponent("first"))
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        var splitPhases: [AppPhase] = []
        let observation = f.model.$phase.sink { phase in
            if f.model.alarmRolloverIsActive {
                splitPhases.append(phase)
                XCTAssertTrue(ModelPrecloneController.blocksPreclone(phase), "Capture is active during alarm split: \(phase)")
            }
        }
        defer { observation.cancel() }
        f.model.alarmPreparationReadyForTesting = { _ in
            XCTAssertTrue(f.model.alarmRolloverIsActive)
            XCTAssertTrue(f.pipeline.alarmCaptureIsActive)
            guard let worker, let complete else { XCTFail("Missing injected preclone job"); return }
            XCTAssertTrue(worker(), "An idle grace period expiring during split must defer before disk work")
            complete(true)
            XCTAssertEqual(disk.count, 0)
            XCTAssertEqual(scheduled, 1, "A deferred job cannot reschedule during segmentation")
        }
        f.model.alarmBeforeBindingForTesting = {
            XCTAssertTrue(f.model.alarmRolloverIsActive)
            XCTAssertTrue(f.pipeline.alarmCaptureIsActive)
            XCTAssertEqual(scheduled, 1)
            XCTAssertEqual(disk.count, 0)
        }
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        XCTAssertTrue(splitPhases.contains(.preparing))
        XCTAssertTrue(splitPhases.contains(.recording))
        XCTAssertTrue(f.pipeline.alarmCaptureIsActive)
        XCTAssertTrue(f.model.isRecording)
        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(disk.count, 0)
        await f.model.stopSavedCourseForTesting()
        XCTAssertEqual(scheduled, 2, "Disk work may schedule again only after recording stops")
        XCTAssertFalse(try XCTUnwrap(worker)())
        try XCTUnwrap(complete)(false)
        XCTAssertEqual(disk.count, 1, "The injected worker must actually be usable after capture")
    }

    func testContinuousAlarmAfterSplitKeepsSavedBannerUntilCooldownEnds() async throws {
        let f = try fixture()
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: f.root.appendingPathComponent("first"))
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        let start = ProcessInfo.processInfo.systemUptime
        trigger(f.model, now: start)
        let originalDeadline = f.model.alarmCooldownDeadlineForTesting
        f.model.alarmCountdownTickForTesting(now: start + 33)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        let second = f.model.currentCourseDirectory
        let deadline = f.model.alarmCooldownDeadlineForTesting
        XCTAssertGreaterThanOrEqual(deadline, originalDeadline, "Segmentation must not reset the reminder cooldown")
        XCTAssertEqual(f.model.alarmBanner?.saved, true)
        // Audio timestamps restart for the new writer. Keep the same alarm
        // sounding, including the old 9–12s regression and the cooldown edge.
        for end in stride(from: 3.0, through: 177.0, by: 1.5) {
            f.model.receiveAlarmSoundForTesting(.init(start: end - 3, end: end, score: 0.9), now: start + end)
            XCTAssertEqual(f.model.alarmBanner?.saved, true, "new audio end=\(end)")
            XCTAssertNil(f.model.alarmRolloverTaskForTesting)
        }
        f.model.receiveAlarmSoundForTesting(.init(start: 175.5, end: 178.5, score: 0.9), now: deadline - 0.001)
        XCTAssertEqual(f.model.alarmBanner?.saved, true)
        // After cooldown a fresh independent run can remind, but never split
        // the already post-alarm course or replace its recording directory.
        for end in [180.0, 183, 186] {
            f.model.receiveAlarmSoundForTesting(.init(start: end - 3, end: end, score: 0.9), now: deadline + end - 180)
        }
        XCTAssertEqual(f.model.alarmBanner?.saved, false)
        XCTAssertNil(f.model.alarmBanner?.secondsRemaining)
        f.model.alarmCountdownTickForTesting(now: deadline + 100)
        XCTAssertNil(f.model.alarmRolloverTaskForTesting)
        XCTAssertEqual(f.model.currentCourseDirectory, second)
        XCTAssertEqual(try postAlarmDirectories(f.root).count, 1)
    }

    func testAcknowledgingSavedBannerStillSuppressesContinuousAlarmDuringCooldown() async throws {
        let f = try fixture()
        _ = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: f.root.appendingPathComponent("first"))
        let start = ProcessInfo.processInfo.systemUptime
        trigger(f.model, now: start)
        f.model.alarmCountdownTickForTesting(now: start + 33)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        XCTAssertEqual(f.model.alarmBanner?.saved, true)
        f.model.dismissAlarmReminder()
        XCTAssertNil(f.model.alarmBanner)
        let deadline = f.model.alarmCooldownDeadlineForTesting
        for end in stride(from: 3.0, through: 174.0, by: 1.5) {
            f.model.receiveAlarmSoundForTesting(.init(start: end - 3, end: end, score: 0.9), now: deadline - 180 + end)
            XCTAssertNil(f.model.alarmBanner)
        }
        XCTAssertNil(f.model.alarmRolloverTaskForTesting)
    }

    func testPostAlarmCourseOnlyRemindsAndFreshRecordingCanSplitAgain() async throws {
        let f = try fixture()
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: f.root.appendingPathComponent("first"))
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        let second = f.model.currentCourseDirectory
        f.model.dismissAlarmReminder()
        trigger(f.model, now: ProcessInfo.processInfo.systemUptime + AlarmPolicy.cooldownSeconds + 10)
        XCTAssertNotNil(f.model.alarmBanner)
        XCTAssertNil(f.model.alarmBanner?.secondsRemaining)
        f.model.alarmCountdownTickForTesting(now: ProcessInfo.processInfo.systemUptime + 500)
        XCTAssertNil(f.model.alarmRolloverTaskForTesting)
        XCTAssertEqual(f.model.currentCourseDirectory, second)
        XCTAssertEqual(try postAlarmDirectories(f.root).count, 1)
        await f.model.stopSavedCourseForTesting()
        _ = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: f.root.appendingPathComponent("fresh"))
        trigger(f.model)
        XCTAssertEqual(f.model.alarmBanner?.secondsRemaining, 30)
    }

    func testPauseStopAndQuitDuringPreparedSplitLeaveNoEmptyCourse() async throws {
        for action in 0..<3 {
            let f = try fixture()
            let first = f.root.appendingPathComponent("first")
            let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
            XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
            await input.drain()
            let gate = Gate()
            var prepared: URL?
            f.model.alarmPreparationReadyForTesting = { directory in prepared = directory; await gate.wait() }
            defer { gate.release(); f.model.alarmPreparationReadyForTesting = nil }
            trigger(f.model)
            f.model.alarmCountdownTickForTesting(now: 133)
            let rollover = try XCTUnwrap(f.model.alarmRolloverTaskForTesting)
            try await eventually { gate.entered }
            let next = try XCTUnwrap(prepared)
            XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
            var exit: Task<Bool, Never>?
            if action == 0 { f.model.pause() }
            else if action == 1 { f.model.stop() }
            else {
                exit = Task { @MainActor in await f.model.prepareForApplicationExit(deadline: ExitDeadline(seconds: 5)) }
                try await eventually { f.model.isTerminating }
            }
            gate.release()
            try await TestTaskLifetime.value(rollover)
            if let exit { let result = await exit.value; XCTAssertTrue(result) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: next.path))
            XCTAssertEqual(f.model.currentCourseDirectory, first)
            XCTAssertNil(f.model.alarmBanner?.failure)
            if action == 0 { XCTAssertTrue(f.model.isPaused) }
            else { XCTAssertNil(f.model.alarmBanner) }
            await f.pipeline.stopCapture(continueTranscribing: false)
            XCTAssertEqual(try AVAudioFile(forReading: first.appendingPathComponent("recording.wav")).length, 1600)
        }
    }

    func testAbortedSplitPreservesUnexpectedFileAndNeighbourCourse() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        _ = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        let neighbour = f.root.appendingPathComponent("neighbour" + AlarmPolicy.postAlarmFolderSuffix)
        let neighbourID = UUID()
        try SessionStore(directory: neighbour).save(SessionSnapshot(sessionID: neighbourID))
        var next: URL?
        f.model.alarmPreparationReadyForTesting = { directory in
            next = directory
            try? Data("keep".utf8).write(to: directory.appendingPathComponent("keep.txt"))
            f.model.pause()
        }
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        f.model.alarmPreparationReadyForTesting = nil
        let prepared = try XCTUnwrap(next)
        XCTAssertEqual(try Data(contentsOf: prepared.appendingPathComponent("keep.txt")), Data("keep".utf8))
        XCTAssertEqual(try SessionStore(directory: neighbour).load()?.sessionID, neighbourID)
        XCTAssertNotNil(f.model.archiveNotice)
    }

    func testStopWhileWriterPreparationIsBlockedCancelsBeforeAudioBoundary() async throws {
        let gate = WriterPreparationGate()
        defer { gate.release() }
        let f = try fixture(writerPreparation: gate)
        let first = f.root.appendingPathComponent("first")
        let input = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        XCTAssertEqual(push(input, value: 0.125, end: 1), .accepted)
        await input.drain()
        gate.arm()
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        let rollover = try XCTUnwrap(f.model.alarmRolloverTaskForTesting)
        try await eventually { gate.entered }
        f.model.stop()
        gate.release()
        try await TestTaskLifetime.value(rollover)
        XCTAssertEqual(f.model.phase, .saved(first))
        XCTAssertEqual(f.model.currentCourseDirectory, first)
        XCTAssertNil(f.model.alarmBanner)
        XCTAssertTrue(try postAlarmDirectories(f.root).isEmpty)
        XCTAssertEqual(try AVAudioFile(forReading: first.appendingPathComponent("recording.wav")).length, 1600)
    }

    func testFileAddedAfterPreparationCleanupValidationIsNeverRemoved() async throws {
        let f = try fixture()
        let first = f.root.appendingPathComponent("first")
        _ = try await f.model.beginAlarmMicrophoneCourseForTesting(directory: first)
        var next: URL?
        f.model.alarmPreparationReadyForTesting = { directory in next = directory; f.model.pause() }
        f.model.alarmBeforeEmptyCleanupForTesting = { directory in
            try? Data("Late user file must remain".utf8).write(to: directory.appendingPathComponent("late-keep.txt"))
        }
        defer { f.model.alarmPreparationReadyForTesting = nil; f.model.alarmBeforeEmptyCleanupForTesting = nil }
        trigger(f.model)
        f.model.alarmCountdownTickForTesting(now: 133)
        try await TestTaskLifetime.value(try XCTUnwrap(f.model.alarmRolloverTaskForTesting))
        let prepared = try XCTUnwrap(next)
        XCTAssertEqual(try Data(contentsOf: prepared.appendingPathComponent("late-keep.txt")),
                       Data("Late user file must remain".utf8))
        XCTAssertEqual(f.model.currentCourseDirectory, first)
        XCTAssertTrue(f.model.isPaused)
        XCTAssertNotNil(f.model.archiveNotice)
    }
}
