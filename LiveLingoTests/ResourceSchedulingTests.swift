import Foundation
import XCTest
@testable import LiveLingo

private actor ASRTransportFixture {
    var requests: [String: ASRRequestState] = [:]
    var receipts: [String: ASRRequestState] = [:]
    var waits: [String: CheckedContinuation<ASRHTTPResult, Error>] = [:]
    var headers: [String: String] = [:]
    var failRequests = false
    var invalidHealth = false
    var reportedPID: Int32 = 1234
    var posts = 0
    var unloadingModels: [String] = []
    var suspendHealth = false
    var healthWaits: [CheckedContinuation<Void, Never>] = []

    func send(_ request: URLRequest) async throws -> ASRHTTPResult {
        if request.url?.lastPathComponent == "health" {
            if suspendHealth { await withCheckedContinuation { healthWaits.append($0) } }
            if invalidHealth { return .init(data: Data("{}".utf8), status: 200) }
            struct Health: Encodable {
                let ok = true
                let pid: Int32
                let `protocol` = 1
                let loaded_models = ["0.6b"]
                let unloading_models: [String]
                let requests: [String: ASRRequestState]
                let completed_requests: [String: ASRRequestState]
            }
            return .init(data: try JSONEncoder().encode(Health(pid: reportedPID, unloading_models: unloadingModels,
                                                                requests: requests,
                                                               completed_requests: receipts)), status: 200)
        }
        posts += 1
        let id = request.value(forHTTPHeaderField: "X-LiveLingo-Request-ID") ?? "missing"
        headers[id] = request.value(forHTTPHeaderField: "X-LiveLingo-Token")
        requests[id] = .init(model: "0.6b", state: "running")
        if failRequests { throw URLError(.networkConnectionLost) }
        guard waits[id] == nil else { throw URLError(.badServerResponse) }
        return try await withCheckedThrowingContinuation { waits[id] = $0 }
    }

    func finish(_ id: String) throws {
        requests.removeValue(forKey: id)
        receipts[id] = .init(model: "0.6b", state: "finished")
        let body = try JSONSerialization.data(withJSONObject: ["request_id": id, "model": "0.6b", "text": "A complete sentence."])
        waits.removeValue(forKey: id)?.resume(returning: .init(data: body, status: 200))
    }
    func clearRemoteWithoutReceipt(_ id: String) { requests.removeValue(forKey: id) }
    func recordReceipt(_ id: String, model: String = "0.6b") {
        requests.removeValue(forKey: id)
        receipts[id] = .init(model: model, state: "finished")
    }
    func setFailRequests(_ value: Bool) { failRequests = value }
    func setInvalidHealth(_ value: Bool) { invalidHealth = value }
    func setPID(_ value: Int32) { reportedPID = value }
    func setUnloading(_ models: [String]) { unloadingModels = models }
    func holdHealth() { suspendHealth = true }
    func releaseHealth() {
        suspendHealth = false
        let pending = healthWaits
        healthWaits = []
        pending.forEach { $0.resume() }
    }
    func sendMismatchedResponse(_ id: String) throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "request_id": id, "model": "wrong-model", "text": "Unrelated result."])
        waits.removeValue(forKey: id)?.resume(returning: .init(data: body, status: 200))
    }
    func releaseAll() {
        releaseHealth()
        let pending = waits
        waits = [:]
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class ResourceSchedulingTests: XCTestCase {
    func testASRModelDirectoryIdentityIgnoresOnlyPathSpelling() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ASRDirectoryIdentity-\(UUID())", isDirectory: true)
        let models = root.appendingPathComponent("Models", isDirectory: true)
        let other = root.appendingPathComponent("Models-other", isDirectory: true)
        try manager.createDirectory(at: models, withIntermediateDirectories: true)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        addTeardownBlock { try? manager.trashItem(at: root, resultingItemURL: nil) }
        let link = root.appendingPathComponent("linked-models")
        try manager.createSymbolicLink(at: link, withDestinationURL: models)
        let wrongLink = root.appendingPathComponent("other-link")
        try manager.createSymbolicLink(at: wrongLink, withDestinationURL: other)
        let regularFile = root.appendingPathComponent("not-a-directory")
        try Data("synthetic".utf8).write(to: regularFile)

        XCTAssertTrue(ASRRuntime.modelDirectoryMatches(models.path, expected: models))
        XCTAssertTrue(ASRRuntime.modelDirectoryMatches(models.path + "/", expected: models))
        XCTAssertTrue(ASRRuntime.modelDirectoryMatches(link.path, expected: models))
        XCTAssertTrue(ASRRuntime.modelDirectoryMatches(models.path, expected: link))
        XCTAssertTrue(ASRRuntime.modelDirectoryMatches(root.path + "/Models/../Models", expected: models))
        XCTAssertFalse(ASRRuntime.modelDirectoryMatches(other.path, expected: models))
        XCTAssertFalse(ASRRuntime.modelDirectoryMatches(wrongLink.path, expected: models))
        XCTAssertFalse(ASRRuntime.modelDirectoryMatches("Models", expected: models))
        XCTAssertFalse(ASRRuntime.modelDirectoryMatches(root.path + "/missing", expected: models))
        XCTAssertFalse(ASRRuntime.modelDirectoryMatches(regularFile.path, expected: regularFile))
    }

    private let endpoint = ASRRuntime.Endpoint(baseURL: URL(string: "http://127.0.0.1:19191")!,
                                               token: "synthetic-test-token", processIdentifier: 1234)
    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ASRResource-\(UUID()).wav")
        try Data([0, 0, 0, 0]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { XCTFail("ASR fixture did not reach the expected state"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func coordinator(_ fixture: ASRTransportFixture) -> ASRRequestCoordinator {
        ASRRequestCoordinator(confirmationTimeout: 0, transport: { try await fixture.send($0) }, observeExit: { _ in false })
    }

    func testCancelledCallerKeepsInferenceOwnedUntilResponseArrives() async throws {
        let fixture = ASRTransportFixture(), audio = try file()
        let coordinator = coordinator(fixture)
        addTeardownBlock { await fixture.releaseAll() }
        var completed = false
        let task = Task { () -> Result<String, Error> in
            defer { completed = true }
            do { return .success(try await coordinator.transcribe(endpoint: endpoint, audioURL: audio,
                modelKey: "0.6b", requestID: "owned-cancel")) }
            catch { return .failure(error) }
        }
        try await waitUntil { await fixture.posts == 1 }
        task.cancel()
        try await waitUntil { completed }
        XCTAssertTrue(completed, "停止等待不能阻塞下一场采集；推理资源仍须保留归属")
        let active = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertEqual(active.activeCount, 1)
        XCTAssertEqual(active.requests["owned-cancel"]?.model, "0.6b")
        let receivedToken = await fixture.headers["owned-cancel"]
        XCTAssertEqual(receivedToken, "synthetic-test-token")
        try await fixture.finish("owned-cancel")
        if case .failure(let error) = await task.value { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("Cancelled caller must not receive late text") }
        try await waitUntil { await coordinator.resourceState(endpoint: self.endpoint).activeCount == 0 }
        let released = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertEqual(released.activeCount, 0)
        XCTAssertTrue(released.ownershipConfirmed)
    }

    func testAbsentRequestAfterLostResponseDoesNotProveCompletion() async throws {
        let fixture = ASRTransportFixture(), audio = try file()
        let coordinator = coordinator(fixture)
        await fixture.setFailRequests(true)
        do {
            _ = try await coordinator.transcribe(endpoint: endpoint, audioURL: audio, modelKey: "0.6b", requestID: "lost")
            XCTFail("Expected transport failure")
        } catch {}
        await fixture.clearRemoteWithoutReceipt("lost")
        let unknown = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertEqual(unknown.unresolvedRequests, ["lost"])
        XCTAssertFalse(unknown.ownershipConfirmed)
        do {
            _ = try await coordinator.transcribe(endpoint: endpoint, audioURL: audio, modelKey: "0.6b", requestID: "second")
            XCTFail("Unconfirmed old inference must keep its capacity")
        } catch {}
        let postCount = await fixture.posts
        XCTAssertEqual(postCount, 1)
        await fixture.recordReceipt("lost", model: "wrong-model")
        let mismatchedReceipt = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertFalse(mismatchedReceipt.ownershipConfirmed)
        await fixture.recordReceipt("lost")
        let released = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertTrue(released.unresolvedRequests.isEmpty)
        XCTAssertTrue(released.ownershipConfirmed)
    }

    func testMalformedHealthAndWrongProcessAreUnavailable() async throws {
        let fixture = ASRTransportFixture()
        let coordinator = coordinator(fixture)
        await fixture.setInvalidHealth(true)
        let malformed = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertEqual(malformed.status, .unavailable)
        XCTAssertFalse(malformed.ownershipConfirmed)
        await fixture.setInvalidHealth(false)
        await fixture.setPID(9999)
        let otherProcess = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertEqual(otherProcess.status, .unavailable)
    }

    func testThreeInFlightSubmissionsBoundLocalCapacityAfterCancellation() async throws {
        let fixture = ASRTransportFixture(), audio = try file()
        let coordinator = coordinator(fixture)
        addTeardownBlock { await fixture.releaseAll() }
        let tasks = (0..<3).map { i in Task {
            try await coordinator.transcribe(endpoint: endpoint, audioURL: audio,
                modelKey: "0.6b", requestID: "slot-\(i)")
        } }
        try await waitUntil { await fixture.posts == 3 }
        tasks.forEach { $0.cancel() }
        do {
            _ = try await coordinator.transcribe(endpoint: endpoint, audioURL: audio, modelKey: "0.6b", requestID: "overflow")
            XCTFail("A fourth request must wait outside the service")
        } catch {}
        let postCount = await fixture.posts
        XCTAssertEqual(postCount, 3)
        for i in 0..<3 { try await fixture.finish("slot-\(i)") }
        for task in tasks { _ = await task.result }
        let finalState = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertEqual(finalState.activeCount, 0)
    }

    func testRequestIDsRejectUnsafeAndOversizedValues() {
        for value in ["", "a b", "line\nbreak", "中文", String(repeating: "x", count: 129)] {
            XCTAssertFalse(ASRRequestCoordinator.validRequestID(value))
        }
        XCTAssertTrue(ASRRequestCoordinator.validRequestID("course_chunk-0123"))
    }

    func testDuplicateAdmissionIsRecheckedAfterHealthSuspendsActor() async throws {
        let fixture = ASRTransportFixture(), audio = try file()
        let coordinator = coordinator(fixture)
        addTeardownBlock { await fixture.releaseAll() }
        await fixture.setFailRequests(true)
        do {
            _ = try await coordinator.transcribe(endpoint: endpoint, audioURL: audio,
                modelKey: "0.6b", requestID: "previous")
            XCTFail("Expected the first response to be lost")
        } catch {}
        await fixture.recordReceipt("previous")
        await fixture.setFailRequests(false)
        await fixture.holdHealth()
        let tasks = (0..<2).map { _ in Task {
            try await coordinator.transcribe(endpoint: endpoint, audioURL: audio,
                modelKey: "0.6b", requestID: "shared-id")
        } }
        try await waitUntil { await fixture.healthWaits.count == 2 }
        await fixture.releaseHealth()
        try await waitUntil { await fixture.posts >= 2 }
        for _ in 0..<10 { await Task.yield() }
        try await fixture.finish("shared-id")
        var successes = 0
        for task in tasks {
            if case .success = await task.result { successes += 1 }
        }
        XCTAssertEqual(successes, 1)
        let posts = await fixture.posts
        XCTAssertEqual(posts, 2, "Only the previous request and one new attempt may reach transport")
    }

    func testMismatchedResponseKeepsLeaseUntilMatchingReceipt() async throws {
        let fixture = ASRTransportFixture(), audio = try file()
        let coordinator = coordinator(fixture)
        addTeardownBlock { await fixture.releaseAll() }
        let task = Task {
            try await coordinator.transcribe(endpoint: endpoint, audioURL: audio,
                modelKey: "0.6b", requestID: "mismatch")
        }
        try await waitUntil { await fixture.posts == 1 }
        try await fixture.sendMismatchedResponse("mismatch")
        if case .success = await task.result { XCTFail("A foreign model result must be rejected") }
        let pending = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertEqual(pending.unresolvedRequests, ["mismatch"])
        XCTAssertEqual(pending.activeCount, 1)
        await fixture.recordReceipt("mismatch")
        let completed = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertTrue(completed.ownershipConfirmed)
        XCTAssertEqual(completed.activeCount, 0)
    }

    func testExitConfirmationIsLimitedToExactOwnedEndpoint() async throws {
        let fixture = ASRTransportFixture(), audio = try file()
        let coordinator = coordinator(fixture)
        await fixture.setFailRequests(true)
        await fixture.setInvalidHealth(true)
        let first = ASRRuntime.Endpoint(baseURL: endpoint.baseURL, token: endpoint.token,
                                       runtimeID: UUID(), processIdentifier: 1234)
        let second = ASRRuntime.Endpoint(baseURL: endpoint.baseURL, token: endpoint.token,
                                        runtimeID: UUID(), processIdentifier: 1235)
        for (service, id) in [(first, "old"), (second, "new")] {
            do {
                _ = try await coordinator.transcribe(endpoint: service, audioURL: audio,
                    modelKey: "0.6b", requestID: id)
                XCTFail("Expected transport failure")
            } catch {}
        }
        await coordinator.confirmServiceExited(endpoint)
        let stillOwned = await coordinator.resourceState(endpoint: first)
        XCTAssertEqual(stillOwned.unresolvedRequests, ["old"])
        await coordinator.confirmServiceExited(first)
        let old = await coordinator.resourceState(endpoint: first)
        let new = await coordinator.resourceState(endpoint: second)
        XCTAssertTrue(old.unresolvedRequests.isEmpty)
        XCTAssertEqual(new.unresolvedRequests, ["new"])
    }

    func testRuntimeDoesNotClaimUnrecognizedProcessHasExited() async {
        let runtime = ASRRuntime()
        let unknown = ASRRuntime.Endpoint(baseURL: endpoint.baseURL, token: endpoint.token,
                                         runtimeID: UUID(), processIdentifier: 1234)
        let result = await runtime.hasExited(unknown)
        XCTAssertNil(result, "No process was launched or observed by this isolated runtime")
        let snapshot = await runtime.resourceState()
        XCTAssertEqual(snapshot.status, .stopped)
    }

    func testUnloadingModelsKeepReleaseUnconfirmed() async {
        let fixture = ASRTransportFixture()
        let coordinator = coordinator(fixture)
        await fixture.setUnloading(["0.6b"])
        let retiring = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertEqual(retiring.unloadingModels, ["0.6b"])
        XCTAssertFalse(retiring.ownershipConfirmed)
        await fixture.setUnloading([])
        let released = await coordinator.resourceState(endpoint: endpoint)
        XCTAssertTrue(released.ownershipConfirmed)
    }

    private func context() -> ResourceSchedulingPolicy.Context {
        .init(now: 1000, memoryNormal: true, captionBacklog: false, captionPending: false,
              recording: true, allowConcurrent: false, summaryRunning: false, paused: false,
              lastSummaryStarted: 800, continuingSummary: false, lowPower: true,
              resources: .init(asr: .init(status: .ready, observedAt: 1000), languageWorkers: [:], observedAt: 1000))
    }

    func testOrdinaryCaptionsAndLowPowerDoNotCancelActiveSummary() {
        var state = context()
        state.summaryRunning = true
        state.captionPending = true
        let decision = ResourceSchedulingPolicy.decide(.summary, in: state)
        XCTAssertTrue(decision.allowed)
        XCTAssertFalse(decision.interrupt)
        state.captionBacklog = true
        XCTAssertTrue(ResourceSchedulingPolicy.decide(.summary, in: state).interrupt)
        state.captionBacklog = false
        state.memoryNormal = false
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.summary, in: state).reason, .memoryPressure)
    }

    func testCadenceAndOwnershipGateWithoutChangingModelBudget() {
        var state = context()
        XCTAssertTrue(ResourceSchedulingPolicy.decide(.summary, in: state).allowed)
        state.lastSummaryStarted = 900
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.summary, in: state).reason, .interval)
        state.continuingSummary = true
        XCTAssertTrue(ResourceSchedulingPolicy.decide(.summary, in: state).allowed)
        state.resources = nil
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .releaseUnconfirmed)
        state.resources = .init(asr: .init(status: .ready), languageWorkers: ["4b": .init(
            workerID: UUID(), processIdentifier: 100, modelLoaded: true, outstandingRequests: 0,
            pendingControls: 1, retiring: false)], observedAt: 1000)
        XCTAssertFalse(ResourceSchedulingPolicy.decide(.review, in: state).allowed)
        state = context()
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.repair, in: state).reason, .recordingPriority)
    }

    func testActiveModelRequestsRespectSerialAndConcurrentProfiles() {
        var state = context()
        state.resources?.asr.requests = ["live": .init(model: "parakeet", state: "running")]
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.summary, in: state).reason, .modelBusy)
        state.allowConcurrent = true
        XCTAssertTrue(ResourceSchedulingPolicy.decide(.summary, in: state).allowed)
        state.allowConcurrent = false
        state.resources?.asr.requests = [:]
        state.resources?.languageWorkers = ["4b": .init(workerID: UUID(), processIdentifier: 123,
            modelLoaded: true, outstandingRequests: 1, pendingControls: 0, retiring: false)]
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .modelBusy)
        state.allowConcurrent = true
        XCTAssertTrue(ResourceSchedulingPolicy.decide(.review, in: state).allowed)
    }

    func testFreshWrapperDoesNotRefreshAnOldASRSample() {
        var state = context()
        state.resources?.asr.observedAt = 970
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.summary, in: state).reason, .releaseUnconfirmed)
        state.resources?.asr.observedAt = 1000
        XCTAssertTrue(ResourceSchedulingPolicy.decide(.summary, in: state).allowed)
    }

    func testSerialReviewDoesNotPauseItsOwnRequestOrDeliveryAcknowledgement() {
        var state = context()
        state.recording = false
        state.continuingRequestID = "review-current"
        let worker = MLXRuntime.ResourceState(workerID: UUID(), processIdentifier: 123,
            modelLoaded: true, outstandingRequests: 1, pendingControls: 0, retiring: false,
            requestIDs: ["review-current"])
        state.resources?.languageWorkers = ["9b": worker]
        XCTAssertTrue(ResourceSchedulingPolicy.decide(.review, in: state).allowed)
        // The real resource snapshot continues to report the occupied lease.
        XCTAssertTrue(state.resources?.hasActiveRequests == true)
        state.resources?.languageWorkers = ["9b": .init(workerID: worker.workerID,
            processIdentifier: 123, modelLoaded: true, outstandingRequests: 1,
            pendingControls: 1, retiring: false, requestIDs: ["review-current"],
            acknowledgingRequestIDs: ["review-current"])]
        XCTAssertTrue(ResourceSchedulingPolicy.decide(.review, in: state).allowed)
        XCTAssertTrue(state.resources?.hasUnconfirmedRelease == true)
        state.continuingRequestID = nil
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .releaseUnconfirmed)
    }

    func testReviewContinuationCannotHideOtherRequestsOrUnconfirmedExit() {
        var state = context()
        state.recording = false
        state.continuingRequestID = "review-current"
        state.resources?.languageWorkers = ["9b": .init(workerID: UUID(), processIdentifier: 123,
            modelLoaded: true, outstandingRequests: 2, pendingControls: 0, retiring: false,
            requestIDs: ["review-current", "translation-other"])]
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .modelBusy)
        state.resources?.languageWorkers = ["9b": .init(workerID: UUID(), processIdentifier: 123,
            modelLoaded: true, outstandingRequests: 1, pendingControls: 1, retiring: false,
            requestIDs: ["review-current"])]
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .releaseUnconfirmed)
        state.resources?.languageWorkers = ["9b": .init(workerID: UUID(), processIdentifier: 123,
            modelLoaded: true, outstandingRequests: 1, pendingControls: 0, retiring: true,
            requestIDs: ["review-current"])]
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .releaseUnconfirmed)
        state.resources?.languageWorkers = ["9b": .init(workerID: UUID(), processIdentifier: 123,
            modelLoaded: true, outstandingRequests: 1, pendingControls: 0, retiring: false,
            requestIDs: ["review-current"])]
        state.memoryNormal = false
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .memoryPressure)
        state.memoryNormal = true
        state.captionBacklog = true
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .captionBacklog)
        state.captionBacklog = false
        state.continuingRequestID = "old-request"
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.review, in: state).reason, .modelBusy)
        state.continuingRequestID = "review-current"
        XCTAssertEqual(ResourceSchedulingPolicy.decide(.summary, in: state).reason, .modelBusy)
    }
}
