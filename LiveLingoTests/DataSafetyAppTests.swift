import AppKit
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class DataSafetyAppTests: XCTestCase {
    private actor CallCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
    @MainActor private final class NoteGate {
        var entered = false
        private var waiting: CheckedContinuation<String, Never>?
        func wait() async -> String {
            entered = true
            return await withCheckedContinuation { waiting = $0 }
        }
        func finish(_ text: String) { waiting?.resume(returning: text); waiting = nil }
    }
    private func fixture(_ root: URL, defaults: UserDefaults, pipeline: SpeechPipeline? = nil,
                         notes: LearningGenerationDependencies? = nil,
                         translation: CaptionTranslationDependencies? = nil) -> (AppModel, LearningReviewQueue) {
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        let model = AppModel(reviewQueue: queue,
            pipeline: pipeline ?? SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio." }, enableAudioAnalysis: false),
            translation: translation, notes: notes, backgroundServices: false, defaults: defaults)
        return (model, queue)
    }

    func testAPP01NormalQuitWaitsForArchiveAcknowledgement() async throws {
        let root = try DataSafetyFixtures.make("APP01"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        var translation = CaptionTranslationDependencies.unavailable
        translation.translate = { _, _, _, _, _ in "合成尾段。" }
        let (model, queue) = fixture(root, defaults: defaults, translation: translation)
        let course = root.appendingPathComponent("course")
        try await model.beginSavedCourseForTesting(directory: course)
        let caption = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic final caption.", chinese: "合成尾段。",
            sessionID: model.captureHealthSessionIDForTesting)
        model.receiveIdentifiedCaptionForTesting(caption)
        let delegate = AppLifecycleDelegate()
        var prepared = false
        var replied: Bool?
        delegate.prepareToTerminate = {
            do { try await model.flushSavedCourseForTesting(); prepared = true; return true }
            catch { return false }
        }
        delegate.terminationReply = { replied = $0 }
        let response = delegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(response, .terminateLater)
        if response == .terminateLater {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while replied == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(replied, true)
            XCTAssertTrue(prepared)
            XCTAssertEqual(try SessionStore(directory: course).load()?.segments, [caption])
        }
        await queue.shutdownForTesting()
    }

    func testAPP02ConvertedLiveCourseHasDurableRecoveryIndexBeforeStop() async throws {
        let root = try DataSafetyFixtures.make("APP02"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio." }, enableAudioAnalysis: false)
        let (model, queue) = fixture(root, defaults: defaults, pipeline: pipeline)
        let staging = root.appendingPathComponent(SessionWorkspace.temporaryPrefix + UUID().uuidString)
        let output = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await model.beginLiveCourseForTesting(directory: staging, outputRoot: output)
        await model.convertCurrentSessionToRecording(in: output)
        XCTAssertFalse(model.isLiveOnly)
        XCTAssertNotNil(try SessionStore(directory: staging).load(), "conversion must await its first archive")
        XCTAssertNotNil(defaults.data(forKey: "LiveLingo.pendingRecordingRecovery"), "a fresh process must discover the converted recording")
        await pipeline.stopCapture(continueTranscribing: false)
        await queue.shutdownForTesting()
    }

    func testAPP03StoppedSaveFailureCanBeRetriedDirectly() async throws {
        let root = try DataSafetyFixtures.make("APP03"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (model, queue) = fixture(root, defaults: defaults)
        let course = root.appendingPathComponent("course")
        try await model.beginSavedCourseForTesting(directory: course)
        let blocked = course.appendingPathComponent("bilingual.srt")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        await model.stopSavedCourseForTesting()
        guard case .failed = model.phase else { XCTFail("fixture must fail its export"); return }
        try FileManager.default.moveItem(at: blocked, to: root.appendingPathComponent("failed-output-slot"))
        model.retrySavedSessionWrite()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.archiveLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.phase, .saved(course))
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.appendingPathComponent("manifest.json").path))
        await queue.shutdownForTesting()
    }

    func testAPP04CourseLocationLabelIgnoresNextRecordingPreference() async throws {
        let root = try DataSafetyFixtures.make("APP04"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (model, queue) = fixture(root, defaults: defaults)
        let course = root.appendingPathComponent("actual-course")
        try await model.beginSavedCourseForTesting(directory: course)
        model.outputDirectory = root.appendingPathComponent("next-recording")
        XCTAssertEqual(model.courseSaveDirectoryLabel, "actual-course")
        await queue.shutdownForTesting()
    }

    func testF05SavedFinalNoteOwnsSummarySlotAndBlocksManualAdmission() async throws {
        let root = try DataSafetyFixtures.make("F05"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let gate = NoteGate()
        let (model, queue) = fixture(root, defaults: defaults, notes: .init(generate: { _, _, _, _, _ in await gate.wait() }))
        var snapshot = SessionSnapshot()
        snapshot.segments = [TranscriptSegment(startTime: 0, endTime: 4,
            english: "The synthetic container expands.", chinese: "合成容器会膨胀。", sessionID: snapshot.sessionID)]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: root).save(snapshot)
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        model.resumeSavedProcessing()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.entered)
        XCTAssertNotNil(model.savedProcessingTaskForTesting)
        XCTAssertNotNil(model.summaryTaskForTesting)
        let manualCalls = CallCounter()
        model.setTypedTranslationRequestForTesting { _, _, _ in await manualCalls.increment(); return "合成译文。" }
        model.manualTranslationInput = "The synthetic container expands."
        model.translateTypedText()
        try await Task.sleep(for: .milliseconds(150))
        let callsWhileNoteHeld = await manualCalls.value
        XCTAssertEqual(callsWhileNoteHeld, 0)
        let note = LearningNote(topic: "合成容器", points: [.init(kind: "核心要点", text: "合成容器会膨胀。",
            sources: [.init(index: 0, quote: "The synthetic container expands.")])], sourceVersion: 2)
        gate.finish(String(decoding: try JSONEncoder().encode(note), as: UTF8.self))
        await model.savedProcessingTaskForTesting?.value
        while model.isManualTranslating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await queue.shutdownForTesting()
    }
}
