import AVFoundation
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class AlarmLifecycleTests: XCTestCase {
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
    private func fixture(failure: FailureSwitch? = nil, translation: CaptionTranslationDependencies = .unavailable) throws -> Fixture {
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
        let model = AppModel(reviewQueue: queue, pipeline: pipeline, translation: translation, notes: .unavailable,
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
}
