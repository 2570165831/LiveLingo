import AppKit
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class DataSafetyAppTests: XCTestCase {
    func testN03AppConversionPreservesAnUnreadableRecoveryIndex() async throws {
        let root = try DataSafetyFixtures.make("N03-app")
        defer { DataSafetyFixtures.preserve(root) }
        let index = root.appendingPathComponent("pending-recordings.json")
        let bytes = Data(#"{"version":99,"recordings":[],"futureState":"SYNTHETIC_RETAIN"}"#.utf8)
        try bytes.write(to: index)
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio." }, enableAudioAnalysis: false)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"), observeSleep: false,
            diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        let model = AppModel(reviewQueue: queue, pipeline: pipeline, backgroundServices: false,
            defaults: defaults, recoveryDirectory: root)
        let staging = root.appendingPathComponent(SessionWorkspace.temporaryPrefix + UUID().uuidString)
        try await model.beginLiveCourseForTesting(directory: staging, outputRoot: root)
        await model.convertCurrentSessionToRecording(in: root)
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        XCTAssertNotNil(model.archiveError)
        await pipeline.stopCapture(continueTranscribing: false)
        await queue.shutdownForTesting()
    }
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
    private func fixture(_ root: URL, defaults: TestUserDefaults, pipeline: SpeechPipeline? = nil,
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
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
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
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
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

    /// Issue #13: a live course started before midnight and stopped after it
    /// keeps its start in the course data and in the promoted folder name.
    func testAPP02bConvertedLiveCourseKeepsItsCaptureStart() async throws {
        let root = try DataSafetyFixtures.make("APP02b"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio." }, enableAudioAnalysis: false)
        let (model, queue) = fixture(root, defaults: defaults, pipeline: pipeline)
        // Promotion only accepts a staging folder directly under the host's temporary root.
        let staging = try SessionWorkspace.temporaryRoot()
            .appendingPathComponent(SessionWorkspace.temporaryPrefix + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let start = try XCTUnwrap(SessionCaptureStart(date: Date(timeIntervalSince1970: 1_791_474_600),
                                                      utcOffsetSeconds: 8 * 3_600))
        try await model.beginLiveCourseForTesting(directory: staging, outputRoot: output, captureStart: start)
        await model.convertCurrentSessionToRecording(in: output)
        XCTAssertEqual(try SessionStore(directory: staging).load()?.captureStart, start)
        await model.stopSavedCourseForTesting()
        let promoted = output.appendingPathComponent("LiveLingo 2026-10-08 23.50.00")
        XCTAssertEqual(try SessionStore(directory: promoted).load()?.captureStart, start)
        await queue.shutdownForTesting()
    }

    /// Converts a live course to a recording in `root/selected` and leaves its
    /// recovery record behind, as an interrupted process would.
    private func interruptedConvertedRecording(_ root: URL, defaults: TestUserDefaults) async throws
        -> (SessionWorkspace.RecordingRecovery, URL) {
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio." }, enableAudioAnalysis: false)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue-first-launch.json"), observeSleep: false,
            diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        let model = AppModel(reviewQueue: queue, pipeline: pipeline, backgroundServices: false,
            defaults: defaults, recoveryDirectory: root)
        let staging = root.appendingPathComponent(SessionWorkspace.temporaryPrefix + UUID().uuidString)
        let output = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await model.beginLiveCourseForTesting(directory: staging, outputRoot: output)
        await model.convertCurrentSessionToRecording(in: output)
        XCTAssertNil(model.archiveError)
        await pipeline.stopCapture(continueTranscribing: false)
        await queue.shutdownForTesting()
        return (try XCTUnwrap(SessionWorkspace.recordingRecoveries(in: root).first), output)
    }

    private func relaunchedModel(_ root: URL, defaults: TestUserDefaults) -> (AppModel, LearningReviewQueue) {
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue-relaunch.json"), observeSleep: false,
            diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        let model = AppModel(reviewQueue: queue,
            pipeline: SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio." }, enableAudioAnalysis: false),
            backgroundServices: false, defaults: defaults, recoveryDirectory: root)
        return (model, queue)
    }

    private func samePath(_ lhs: URL?, _ rhs: URL) -> Bool {
        lhs?.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The open-panel grant ends with its process: a relaunched recovery must
    /// reach the selected folder through its bookmark, even after a move.
    func testRecoveryAfterRelaunchResolvesTheSelectedFolderBookmark() async throws {
        let root = try DataSafetyFixtures.make("recovery-relaunch"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (record, output) = try await interruptedConvertedRecording(root, defaults: defaults)
        XCTAssertNotNil(record.outputRootBookmark, "conversion must persist a grant for the selected folder")
        let moved = root.appendingPathComponent("selected-moved", isDirectory: true)
        try FileManager.default.moveItem(at: output, to: moved)
        let (model, queue) = relaunchedModel(root, defaults: defaults)
        XCTAssertEqual(model.recoverableRecordings.map(\.id), [record.id])
        await model.recoverRecording(record)
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(samePath(model.outputDirectory, moved), "\(String(describing: model.outputDirectory))")
        await queue.shutdownForTesting()
    }

    func testRecoveryWithUnavailableSelectedFolderAsksForItAgain() async throws {
        let root = try DataSafetyFixtures.make("recovery-folder-gone"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (record, output) = try await interruptedConvertedRecording(root, defaults: defaults)
        try FileManager.default.removeItem(at: output)
        let (model, queue) = relaunchedModel(root, defaults: defaults)
        await model.recoverRecording(record)
        XCTAssertNil(model.archiveError)
        XCTAssertNil(model.outputDirectory, "an unreachable folder must not be reused silently")
        XCTAssertTrue(model.archiveNotice?.contains("保存位置") == true, "\(String(describing: model.archiveNotice))")
        XCTAssertEqual(model.recoverableRecordings.map(\.id), [record.id], "the recording stays recoverable")
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        model.useOutputDirectory(replacement)
        XCTAssertEqual(model.outputDirectory, replacement)
        let stored = try XCTUnwrap(SessionWorkspace.recordingRecoveries(in: root).first { $0.id == record.id })
        XCTAssertEqual(stored.outputRoot, replacement, "a later relaunch must use the newly selected folder")
        XCTAssertNotNil(stored.outputRootBookmark)
        await queue.shutdownForTesting()
    }

    func testLegacyRecoveryRecordWithoutBookmarkKeepsThePlainFolder() async throws {
        let root = try DataSafetyFixtures.make("recovery-legacy"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (record, output) = try await interruptedConvertedRecording(root, defaults: defaults)
        var legacy = record
        legacy.outputRootBookmark = nil
        try SessionWorkspace.saveRecordingRecoveries([legacy], in: root, expected: [record])
        let (model, queue) = relaunchedModel(root, defaults: defaults)
        XCTAssertEqual(model.recoverableRecordings, [legacy])
        await model.recoverRecording(legacy)
        XCTAssertNil(model.archiveError)
        XCTAssertEqual(model.outputDirectory, output)
        XCTAssertTrue(model.archiveNotice?.contains("旧版") == true, "\(String(describing: model.archiveNotice))")
        await queue.shutdownForTesting()
    }

    /// The legacy and unreachable notices ask the user to re-choose the save
    /// folder; picking the same folder again must still store a fresh grant.
    func testRechoosingTheSameFolderForALegacyRecoveryStoresAGrant() async throws {
        let root = try DataSafetyFixtures.make("recovery-legacy-rechoose"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (record, output) = try await interruptedConvertedRecording(root, defaults: defaults)
        var legacy = record
        legacy.outputRootBookmark = nil
        try SessionWorkspace.saveRecordingRecoveries([legacy], in: root, expected: [record])
        let (model, queue) = relaunchedModel(root, defaults: defaults)
        await model.recoverRecording(legacy)
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(model.archiveNotice?.contains("保存位置") == true, "\(String(describing: model.archiveNotice))")
        model.useOutputDirectory(output)
        try assertStoredGrant(for: record.id, resolvesTo: output, in: root)
        await queue.shutdownForTesting()
    }

    func testRechoosingTheSameFolderAfterItsGrantFailedStoresAFreshGrant() async throws {
        let root = try DataSafetyFixtures.make("recovery-dead-grant-rechoose"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (record, output) = try await interruptedConvertedRecording(root, defaults: defaults)
        var dead = record
        dead.outputRootBookmark = Data("not a bookmark".utf8)
        try SessionWorkspace.saveRecordingRecoveries([dead], in: root, expected: [record])
        let (model, queue) = relaunchedModel(root, defaults: defaults)
        await model.recoverRecording(dead)
        XCTAssertNil(model.archiveError)
        XCTAssertNil(model.outputDirectory, "a grant that did not resolve must not be reused silently")
        XCTAssertTrue(model.archiveNotice?.contains("保存位置") == true, "\(String(describing: model.archiveNotice))")
        model.useOutputDirectory(output)
        XCTAssertEqual(model.outputDirectory, output)
        try assertStoredGrant(for: record.id, resolvesTo: output, in: root)
        await queue.shutdownForTesting()
    }

    private func assertStoredGrant(for id: UUID, resolvesTo folder: URL, in root: URL,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let stored = try XCTUnwrap(SessionWorkspace.recordingRecoveries(in: root).first { $0.id == id }, file: file, line: line)
        XCTAssertEqual(stored.outputRoot, folder, file: file, line: line)
        let bookmark = try XCTUnwrap(stored.outputRootBookmark, "re-choosing the folder must store a grant",
                                     file: file, line: line)
        let access = try SessionWorkspace.ScopedFolderAccess(bookmark: bookmark)
        defer { access.stop() }
        XCTAssertTrue(samePath(access.url, folder), "\(access.url)", file: file, line: line)
    }

    func testRecoveryOpensThePromotedCourseThroughItsBookmark() async throws {
        let root = try DataSafetyFixtures.make("recovery-promoted"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let output = root.appendingPathComponent("selected", isDirectory: true)
        let course = output.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        let snapshot = SessionSnapshot()
        _ = try SessionStore(directory: course).save(snapshot)
        let record = SessionWorkspace.RecordingRecovery(id: snapshot.sessionID, directory: course, outputRoot: output)
            .withOutputRoot(output).promoted(to: course)
        try SessionWorkspace.saveRecordingRecoveries([record], in: root)
        let moved = output.appendingPathComponent("course-renamed", isDirectory: true)
        try FileManager.default.moveItem(at: course, to: moved)
        let (model, queue) = relaunchedModel(root, defaults: defaults)
        await model.recoverRecording(record)
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(samePath(model.savedSessionDirectory, moved), "\(String(describing: model.savedSessionDirectory))")
        await queue.shutdownForTesting()
    }

    func testAPP03StoppedSaveFailureCanBeRetriedDirectly() async throws {
        let root = try DataSafetyFixtures.make("APP03"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
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
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
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
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
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
