import AppKit
import Darwin
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
private final class PrivacyExitGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; entered = true }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class PrivacyExitRetryState {
    var calls = 0
    var failed = true
}

@MainActor
final class PrivacyExitTests: XCTestCase {
    private enum Failure: Error { case synthetic }

    private func makeModel() throws -> (AppModel, URL, AppModel.PrivacyExitConfiguration) {
        let evidence = TestFixtureDirectory.root.resolvingSymlinksInPath()
            .appendingPathComponent("privacy-followup/lifecycle")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let directory = evidence.appendingPathComponent("synthetic-exit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove(defaults) }
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in
                XCTFail("Synthetic exit tests must never start a model")
                throw Failure.synthetic
            })
        addTeardownBlock {
            let retired = evidence.appendingPathComponent("superseded", isDirectory: true)
            try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.moveItem(at: directory, to: retired.appendingPathComponent(directory.lastPathComponent))
            }
        }
        // XCTest runs these blocks in reverse order: settle the synthetic queue,
        // preserve its fixture, then remove this test's isolated preferences.
        addTeardownBlock { await queue.shutdownForTesting() }
        let model = AppModel(reviewQueue: queue, backgroundServices: false, scheduledNotes: false, defaults: defaults)
        var configuration = AppModel.PrivacyExitConfiguration()
        configuration.timeout = 0.05
        configuration.stopCapture = { _ in }
        configuration.pauseTranscription = {}
        configuration.pauseReview = {}
        configuration.retryTemporarySessions = {}
        configuration.discardTemporarySession = { _ in }
        model.configurePrivacyExitForTesting(configuration)
        model.beginLiveOnlyCourseForTesting(directory: directory)
        model.loadPresentationForTesting(phase: .recording, evidence: [
            .init(startTime: 0, endTime: 1, english: "SYNTHETIC_PRIVATE_CONTENT", chinese: "合成课堂内容")
        ], preview: "SYNTHETIC_PREVIEW")
        return (model, directory, configuration)
    }

    func testExitDeadlineCoversAllWaits() async throws {
        let stages = ["manual", "refresh", "import", "translation", "summary", "processing", "start",
                      "readiness", "power", "finalization", "capture", "transcription", "review", "park", "flush", "services"]
        for stage in stages {
            let (model, directory, initial) = try makeModel()
            var configuration = initial
            let gate = PrivacyExitGate()
            var deleted = false
            configuration.discardTemporarySession = { _ in deleted = true }
            switch stage {
            case "finalization": model.setPrivacyExitFinalizationForTesting(true)
            case "capture": configuration.stopCapture = { _ in await gate.wait() }
            case "transcription": configuration.pauseTranscription = { await gate.wait() }
            case "review": configuration.pauseReview = { await gate.wait() }
            case "park": configuration.park = { await gate.wait() }
            case "flush":
                configuration.flush = { await gate.wait() }
                configuration.park = { try await model.flushSavedCourseForTesting() }
            case "services": break
            default: model.setPrivacyExitTaskForTesting(Task { await gate.wait() }, stage: stage)
            }
            model.configurePrivacyExitForTesting(configuration)
            var reply: Bool?
            let exit = Task {
                reply = await model.prepareForApplicationExit(retireServices: {
                    if stage == "services" { await gate.wait() }
                })
            }
            try await Task.sleep(for: .milliseconds(150))
            let timedReply = reply
            let preservedBeforeRelease = !model.segments.isEmpty && model.temporarySessionForPrivacyExitTesting == directory
            model.setPrivacyExitFinalizationForTesting(false)
            gate.release()
            await exit.value
            XCTAssertEqual(timedReply, false, "Unbounded exit stage: \(stage)")
            XCTAssertTrue(preservedBeforeRelease, stage)
            XCTAssertFalse(deleted, "Late cleanup after timeout: \(stage)")
            XCTAssertFalse(model.segments.isEmpty, stage)
            XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory, stage)
        }
    }

    func testSlowSuccessfulNormalStopHasNoExitBudget() async throws {
        let (model, directory, initial) = try makeModel()
        try await model.beginSavedCourseForTesting(directory: directory)
        var configuration = initial
        let state = PrivacyExitRetryState()
        configuration.flush = {
            state.calls += 1
            if state.calls == 1 { try await Task.sleep(for: .milliseconds(15_100)) }
        }
        model.configurePrivacyExitForTesting(configuration)
        await model.stopSavedCourseForTesting()
        XCTAssertEqual(model.phase, .saved(directory))
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript-en.txt").path))
    }

    func testSlowSaveWithProgressCanFinishWithinOneExitAttempt() async throws {
        let (model, directory, initial) = try makeModel()
        try await model.beginSavedCourseForTesting(directory: directory)
        var configuration = initial
        configuration.flush = {
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(20))
                try SensitiveFileIO.atomicWrite(Data("synthetic save progress".utf8),
                    to: directory.appendingPathComponent("progress.txt"))
            }
        }
        model.configurePrivacyExitForTesting(configuration)
        let allowed = await model.prepareForApplicationExit()
        XCTAssertTrue(allowed)
        XCTAssertEqual(model.phase, .saved(directory))
        XCTAssertNil(model.archiveError)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("progress.txt"), encoding: .utf8),
                       "synthetic save progress")
    }

    func testPreexistingDetachedWriterRenewsOnlyWithActualStorageProgress() async throws {
        let (_, directory, _) = try makeModel()
        let binding = ExitDeadline.StorageProgress(), gate = PrivacyExitGate()
        let writer = Task.detached {
            await gate.wait()
            try ExitDeadline.$storageProgress.withValue(binding) {
                for index in 0..<6 {
                    Thread.sleep(forTimeInterval: 0.02)
                    try SensitiveFileIO.atomicWrite(Data("synthetic chunk \(index)".utf8),
                        to: directory.appendingPathComponent("background.txt"))
                }
            }
        }
        while !gate.entered { await Task.yield() }
        let deadline = ExitDeadline(inactivityTimeout: 0.05)
        binding.attach(deadline)
        gate.release()
        try await deadline.wait { try await writer.value }
        XCTAssertFalse(deadline.isExpired)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("background.txt"), encoding: .utf8),
                       "synthetic chunk 5")
    }

    func testCompletedSynchronousDiskCleanupDoesNotLeaveStaleRoot() async throws {
        let (model, directory, initial) = try makeModel()
        // Keep the queue journal outside the discarded course, as it is in
        // production. A queue shutdown must not recreate that course fixture.
        let course = directory.appendingPathComponent("temporary-course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: false)
        model.beginLiveOnlyCourseForTesting(directory: course)
        var configuration = initial
        configuration.discardTemporarySession = { root in
            try FileManager.default.removeItem(at: root)
            Thread.sleep(forTimeInterval: 0.08)
        }
        model.configurePrivacyExitForTesting(configuration)
        let first = await model.prepareForApplicationExit()
        XCTAssertFalse(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: course.path))
        XCTAssertNil(model.temporarySessionForPrivacyExitTesting)
        try await Task.sleep(for: .milliseconds(20))
        let second = await model.prepareForApplicationExit()
        XCTAssertTrue(second)
    }

    func testAppKitAllowsExplicitExitAfterHungCleanup() async throws {
        let delegate = AppLifecycleDelegate(), gate = PrivacyExitGate()
        delegate.terminationTimeoutForTesting = 0.05
        delegate.cleanupForTesting = { await gate.wait(); return true }
        delegate.confirmExitWithoutSavingForTesting = { true }
        var replies: [Bool] = []
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(replies, [true])
        gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(replies, [true])
    }

    func testLateCompletionCannotClearAfterTimeout() async throws {
        let (model, directory, initial) = try makeModel()
        var configuration = initial
        let gate = PrivacyExitGate()
        configuration.stopCapture = { _ in await gate.wait() }
        var deleted = false
        configuration.discardTemporarySession = { _ in deleted = true }
        model.configurePrivacyExitForTesting(configuration)
        let stop = Task { await model.stopSavedCourseForTesting() }
        let until = ContinuousClock.now.advanced(by: .seconds(1))
        while !gate.entered, ContinuousClock.now < until { await Task.yield() }
        XCTAssertTrue(gate.entered)
        let reply = await model.prepareForApplicationExit()
        XCTAssertFalse(reply)
        XCTAssertFalse(model.resetSessionForPrivacyExitTesting(), "A live old writer must block a new run")
        gate.release()
        await stop.value
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(deleted)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory)
    }

    func testStopCleanupFailurePreservesContentAndCanRetry() async throws {
        let (model, directory, initial) = try makeModel()
        var configuration = initial
        var calls = 0
        configuration.discardTemporarySession = { _ in
            calls += 1
            if calls == 1 { throw Failure.synthetic }
        }
        model.configurePrivacyExitForTesting(configuration)
        await model.stopSavedCourseForTesting()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.volatileEnglish, "SYNTHETIC_PREVIEW")
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory)
        XCTAssertTrue(model.isLiveOnly)
        await model.stopSavedCourseForTesting()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(model.segments.isEmpty)
        XCTAssertNil(model.temporarySessionForPrivacyExitTesting)
    }

    func testSynchronousCleanupRechecksDeadlineBeforeClearing() async throws {
        let (model, _, initial) = try makeModel()
        var configuration = initial
        configuration.discardTemporarySession = { _ in Thread.sleep(forTimeInterval: 0.08) }
        model.configurePrivacyExitForTesting(configuration)
        let allowed = await model.prepareForApplicationExit()
        XCTAssertFalse(allowed)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.volatileEnglish, "SYNTHETIC_PREVIEW")
        XCTAssertNotNil(model.archiveError)
    }

    func testNewRunRetriesJournalBeforeReset() throws {
        let (model, directory, initial) = try makeModel()
        var configuration = initial
        let state = PrivacyExitRetryState()
        configuration.retryTemporarySessions = {
            state.calls += 1
            if state.failed { throw Failure.synthetic }
        }
        model.configurePrivacyExitForTesting(configuration)
        XCTAssertFalse(model.resetSessionForPrivacyExitTesting())
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.volatileEnglish, "SYNTHETIC_PREVIEW")
        state.failed = false
        XCTAssertTrue(model.resetSessionForPrivacyExitTesting())
        XCTAssertEqual(state.calls, 2)
        XCTAssertNil(model.temporarySessionForPrivacyExitTesting)
        XCTAssertTrue(model.segments.isEmpty)
    }

    func testExitUsesSingleBudgetAcrossStages() async throws {
        let (model, directory, initial) = try makeModel()
        var configuration = initial
        configuration.timeout = 0.06
        configuration.stopCapture = { _ in try? await Task.sleep(for: .milliseconds(40)) }
        configuration.park = { try? await Task.sleep(for: .milliseconds(40)) }
        var deleted = false
        configuration.discardTemporarySession = { _ in deleted = true }
        model.configurePrivacyExitForTesting(configuration)
        let reply = await model.prepareForApplicationExit()
        XCTAssertFalse(reply)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(deleted)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory)
    }

    private func fullPipe() throws -> Pipe {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let bytes = [UInt8](repeating: 65, count: 4096)
        while true {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            if count > 0 { continue }
            if count < 0, errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw POSIXError(.EIO) }
            return pipe
        }
    }

    func testControlDeadlineStartsBeforeBlockedSend() async throws {
        let pipe = try fullPipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let runtime = MLXRuntime()
        let start = ContinuousClock.now
        do {
            try await runtime.controlForExitTesting(to: pipe.fileHandleForWriting, timeout: 0.05)
            XCTFail("A full pipe cannot deliver shutdown")
        } catch {}
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testPipeSendSharesAbsoluteExitDeadline() async throws {
        let pipe = try fullPipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let runtime = MLXRuntime(), deadline = ExitDeadline(seconds: 0.06)
        try await Task.sleep(for: .milliseconds(40))
        let start = ContinuousClock.now
        await ExitDeadline.$current.withValue(deadline) {
            do {
                try await runtime.controlForExitTesting(to: pipe.fileHandleForWriting, timeout: 0.4)
                XCTFail("The inherited exit budget must expire first")
            } catch {}
        }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(180))
    }

    func testAppKitRejectsTimedOutExit() async throws {
        let delegate = AppLifecycleDelegate(), gate = PrivacyExitGate()
        delegate.terminationTimeoutForTesting = 0.05
        var reply: Bool?
        delegate.cleanupForTesting = { await gate.wait(); return true }
        delegate.replyForTesting = { reply = $0 }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        try await Task.sleep(for: .milliseconds(150))
        let timedReply = reply
        gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(timedReply, false)
        XCTAssertEqual(reply, false, "A late completion cannot authorize termination")
    }
}
