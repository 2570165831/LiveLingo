import AppKit
import Foundation
import XCTest
import Darwin
@testable import LiveLingo

@MainActor
final class DataSafetyAppTests: XCTestCase {
    private final class CloudOpenProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var ready: Bool
        private let blocked: Bool
        private let latePlaceholder: Bool
        private var loads = 0
        private var events: [String] = []
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let requestFinished = DispatchSemaphore(value: 0)
        init(ready: Bool = false, blocked: Bool = true, latePlaceholder: Bool = false) {
            self.ready = ready; self.blocked = blocked; self.latePlaceholder = latePlaceholder
        }
        func pending(_ root: URL) -> [URL] { lock.withLock { ready ? [] : [root.appendingPathComponent(SessionStore.snapshotFileName)] } }
        func request(_ url: URL) {
            XCTAssertFalse(SessionStore.isHoldingProcessLock)
            XCTAssertFalse(SensitiveFileIO.materializationBlocked)
            XCTAssertNotEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            lock.withLock { events.append("download") }
            reached.signal()
            if blocked { _ = release.wait(timeout: .now() + 5) }
            lock.withLock { ready = true }
            requestFinished.signal()
        }
        func beforeLoad() throws {
            try lock.withLock {
                XCTAssertTrue(ready, "The provider must finish before entering the store")
                loads += 1; events.append("load")
                if latePlaceholder && loads == 1 {
                    ready = false
                    throw SessionStoreError.storageDeferred("合成云端文件尚未下载")
                }
            }
        }
        var order: [String] { lock.withLock { events } }
        func environment(timeout: TimeInterval = 3) -> SessionCloudOpenPreparation.Environment {
            .init(pendingItems: { self.pending($0) }, requestDownload: { self.request($0) }, pollInterval: 0.005, timeout: timeout)
        }
    }

    private func cloudFixture(_ root: URL, defaults: TestUserDefaults) throws -> (AppModel, LearningReviewQueue, URL, SessionSnapshot) {
        let (model, queue) = fixture(root, defaults: defaults)
        let course = root.appendingPathComponent("cloud-course", isDirectory: true)
        let id = UUID()
        let segment = TranscriptSegment(startTime: 0, endTime: 2, english: "Synthetic cloud course.", chinese: "合成云端课程。", sessionID: id)
        let snapshot = try SessionStore(directory: course).save(SessionSnapshot(sessionID: id, segments: [segment]))
        return (model, queue, course, snapshot)
    }

    func testCloudStorageDeferredCodesAndVisibleReasonsRemainReadableAndPrivate() {
        let error = SessionStoreError.storageDeferred("SYNTHETIC_PRIVATE_DETAIL")
        let code = LearningFailureCode.code(for: error)
        XCTAssertEqual(code, "session_storageDeferred")
        XCTAssertEqual(ReviewFailure.safeCode(code), code)
        let label = LearningFailureCode.label(for: code)
        XCTAssertTrue(label.contains("云端")); XCTAssertTrue(label.contains("尚未下载到本机"))
        XCTAssertFalse(label.contains("SYNTHETIC_PRIVATE_DETAIL"))
        for stage in [ReviewFailureStage.directory, .input] {
            let failure = ReviewFailure.classify(error, defaultStage: stage)
            XCTAssertEqual(failure.code, code)
            XCTAssertTrue(failure.description.contains("复查已延后"))
            XCTAssertFalse(failure.description.contains("失败"))
            XCTAssertTrue(ReviewRetryPolicy.isRetryable(failure))
        }
        XCTAssertEqual(LearningFailureCode.code(for: SessionStoreError.storageDeferred("其他操作仍在修复课程文件")), "session_storageBusy")
        XCTAssertTrue(LearningFailureCode.label(for: LearningFailureCode.code(for: SessionCloudOpenError.timedOut)).contains("超时"))
        XCTAssertEqual(LearningFailureCode.label(for: LearningFailureCode.code(for: CancellationError())), "操作已取消")
        XCTAssertFalse(label.contains("打开课程时"))
    }

    func testSlowLocalOpenNeverShowsCloudBannerOrUsesCloudTimeout() async throws {
        let root = try DataSafetyFixtures.make("slow-local-open"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())", cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (model, queue, course, snapshot) = try cloudFixture(root, defaults: defaults)
        let settings = SessionCloudOpenPreparation.Environment(pendingItems: { _ in
            Thread.sleep(forTimeInterval: 0.08); return []
        }, requestDownload: { _ in XCTFail("Local reads must never request a download") }, timeout: 0.01)
        let work = Task {
            try await SessionCloudOpenPreparation.$environment.withValue(settings) {
                try await SessionCloudOpenPreparation.$beforeLoad.withValue({ Thread.sleep(forTimeInterval: 0.08) }) {
                    try await model.openSavedSession(course, allowAutomaticProcessing: false)
                }
            }
        }
        while !model.archiveLoading { try await Task.sleep(for: .milliseconds(1)) }
        while model.archiveLoading {
            XCTAssertNil(model.archiveCloudDownloadStatus)
            try await Task.sleep(for: .milliseconds(2))
        }
        try await work.value
        XCTAssertEqual(model.segments, snapshot.segments)
        XCTAssertNil(model.archiveCloudDownloadStatus)
        await queue.shutdownForTesting()
    }

    func testLocalOpenBypassesTwoOccupiedCloudWorkers() async throws {
        let root = try DataSafetyFixtures.make("cloud-workers-local"); defer { DataSafetyFixtures.preserve(root) }
        let course = root.appendingPathComponent("course", isDirectory: true)
        let store = SessionStore(directory: course)
        let snapshot = try store.save(SessionSnapshot())
        let probes = [CloudOpenProbe(), CloudOpenProbe()]
        let tasks = probes.map { probe in Task {
            try await SessionCloudOpenPreparation.$environment.withValue(probe.environment()) {
                try await SessionCloudOpenPreparation.load(store) { _ in }
            }
        } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while probes.contains(where: { $0.order.isEmpty }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(probes.allSatisfy { $0.order == ["download"] })
        defer { probes.forEach { $0.release.signal() } }
        let local = SessionCloudOpenPreparation.Environment(pendingItems: { _ in [] }, requestDownload: { _ in XCTFail("Local download") }, timeout: 0.01)
        let result = try await SessionCloudOpenPreparation.$environment.withValue(local) {
            try await SessionCloudOpenPreparation.$beforeLoad.withValue({ Thread.sleep(forTimeInterval: 0.04) }) {
                try await SessionCloudOpenPreparation.load(store) { _ in XCTFail("Local progress") }
            }
        }
        XCTAssertEqual(result.snapshot, snapshot)
        XCTAssertTrue(probes.allSatisfy { $0.order == ["download"] })
        probes.forEach { $0.release.signal() }
        for work in tasks { _ = try await work.value }
    }

    func testPlaceholderProbeErrorsKeepTheStoreErrorCategories() async throws {
        let root = try DataSafetyFixtures.make("cloud-probe-errors"); defer { DataSafetyFixtures.preserve(root) }
        do {
            _ = try await SessionCloudOpenPreparation.load(SessionStore(directory: root.appendingPathComponent("missing"))) { _ in XCTFail("Missing course progress") }
            XCTFail("Missing directory")
        } catch SessionStoreError.missingSnapshot { }
        let settings = SessionCloudOpenPreparation.Environment(pendingItems: { _ in
            throw SensitiveFileIO.Failure.system(operation: "synthetic probe", code: EIO)
        }, requestDownload: { _ in XCTFail("Probe error download") })
        do {
            _ = try await SessionCloudOpenPreparation.$environment.withValue(settings) {
                try await SessionCloudOpenPreparation.load(SessionStore(directory: root)) { _ in XCTFail("Probe error progress") }
            }
            XCTFail("Probe I/O error")
        } catch SessionStoreError.io(let operation, let code) {
            XCTAssertEqual(operation, "synthetic probe"); XCTAssertEqual(code, EIO)
        }
    }

    func testUserCloudOpenCoordinatesWhenPrimaryDownloadIsUnsupported() async throws {
        let root = try DataSafetyFixtures.make("cloud-coordination"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root.appendingPathComponent("course", isDirectory: true))
        let snapshot = try store.save(SessionSnapshot())
        let probe = CloudOpenProbe(blocked: false)
        var settings = probe.environment()
        settings.requestDownload = { _ in throw SessionCloudOpenError.requestUnavailable }
        settings.coordinateDownload = { url, cancelled in
            XCTAssertFalse(cancelled()); probe.request(url)
        }
        let result = try await SessionCloudOpenPreparation.$environment.withValue(settings) {
            try await SessionCloudOpenPreparation.$beforeLoad.withValue({ try probe.beforeLoad() }) {
                try await SessionCloudOpenPreparation.load(store) { _ in }
            }
        }
        XCTAssertEqual(probe.order, ["download", "load"])
        XCTAssertEqual(result.snapshot, snapshot)
    }

    func testCoordinatedCloudReadHasTheSameBoundedWait() async throws {
        let root = try DataSafetyFixtures.make("cloud-coordination-timeout"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root.appendingPathComponent("course", isDirectory: true))
        _ = try store.save(SessionSnapshot())
        let probe = CloudOpenProbe()
        var settings = probe.environment(timeout: 0.05)
        settings.requestDownload = { _ in throw SessionCloudOpenError.requestUnavailable }
        settings.coordinateDownload = { url, cancelled in probe.request(url); XCTAssertTrue(cancelled()) }
        do {
            _ = try await SessionCloudOpenPreparation.$environment.withValue(settings) {
                try await SessionCloudOpenPreparation.load(store) { _ in }
            }
            XCTFail("Coordination must time out")
        } catch SessionCloudOpenError.timedOut { }
        probe.release.signal()
        XCTAssertEqual(probe.requestFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(probe.order, ["download"])
    }

    func testUserCloudOpenDownloadsOutsideLocksThenOpensAndShowsWaitingState() async throws {
        let root = try DataSafetyFixtures.make("user-cloud-open"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())", cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (model, queue, course, snapshot) = try cloudFixture(root, defaults: defaults)
        let probe = CloudOpenProbe()
        let work = Task {
            try await SessionCloudOpenPreparation.$environment.withValue(probe.environment()) {
                try await SessionCloudOpenPreparation.$beforeLoad.withValue({ try probe.beforeLoad() }) {
                    try await model.openSavedSession(course, allowAutomaticProcessing: false)
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.archiveCloudDownloadStatus?.contains("等待 1 个文件") != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.archiveLoading)
        XCTAssertTrue(model.archiveCloudDownloadStatus?.contains("云端") == true)
        XCTAssertNil(model.savedSessionDirectory, "The course is not installed while the download waits")
        probe.release.signal()
        try await work.value
        XCTAssertEqual(probe.order, ["download", "load"])
        XCTAssertEqual(model.segments, snapshot.segments)
        XCTAssertEqual(model.savedSessionDirectory, course)
        XCTAssertFalse(model.archiveLoading); XCTAssertNil(model.archiveCloudDownloadStatus)
        await queue.shutdownForTesting()
    }

    func testUserCloudOpenRetriesIfPlaceholderAppearsAfterTheInitialProbe() async throws {
        let root = try DataSafetyFixtures.make("user-cloud-open-retry"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())", cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (model, queue, course, _) = try cloudFixture(root, defaults: defaults)
        let probe = CloudOpenProbe(ready: true, blocked: false, latePlaceholder: true)
        try await SessionCloudOpenPreparation.$environment.withValue(probe.environment()) {
            try await SessionCloudOpenPreparation.$beforeLoad.withValue({ try probe.beforeLoad() }) {
                try await model.openSavedSession(course, allowAutomaticProcessing: false)
            }
        }
        XCTAssertEqual(probe.order, ["load", "download", "load"])
        XCTAssertEqual(model.savedSessionDirectory, course)
        await queue.shutdownForTesting()
    }

    func testUserCloudOpenCancellationStopsWaitingWithoutInstallingTheCourse() async throws {
        let root = try DataSafetyFixtures.make("user-cloud-cancel"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())", cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (model, queue, course, _) = try cloudFixture(root, defaults: defaults)
        let probe = CloudOpenProbe()
        let work = Task {
            try await SessionCloudOpenPreparation.$environment.withValue(probe.environment()) {
                try await model.openSavedSession(course, allowAutomaticProcessing: false)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while probe.order.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        model.cancelCloudCourseOpen()
        do { try await work.value; XCTFail("Cancelled opening must not succeed") }
        catch is CancellationError { }
        probe.release.signal()
        XCTAssertEqual(probe.requestFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(model.savedSessionDirectory); XCTAssertFalse(model.archiveLoading)
        XCTAssertNil(model.archiveCloudDownloadStatus)
        XCTAssertEqual(probe.order, ["download"])
        await queue.shutdownForTesting()
    }

    func testUserCloudOpenTimeoutReturnsEvenWhileProviderCallIsStillBlocked() async throws {
        let root = try DataSafetyFixtures.make("user-cloud-timeout"); defer { DataSafetyFixtures.preserve(root) }
        let suite = "LiveLingo-Test-\(UUID())", cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        defer { do { try cleanup.remove(defaults) } catch { XCTFail("\(error)") } }
        let (model, queue, course, _) = try cloudFixture(root, defaults: defaults)
        let probe = CloudOpenProbe()
        let start = ContinuousClock.now
        do {
            try await SessionCloudOpenPreparation.$environment.withValue(probe.environment(timeout: 0.05)) {
                try await model.openSavedSession(course, allowAutomaticProcessing: false)
            }
            XCTFail("The blocked provider must time out")
        } catch SessionCloudOpenError.timedOut { }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        probe.release.signal()
        XCTAssertEqual(probe.requestFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(probe.order, ["download"])
        XCTAssertNil(model.savedSessionDirectory); XCTAssertFalse(model.archiveLoading)
        await queue.shutdownForTesting()
    }
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
