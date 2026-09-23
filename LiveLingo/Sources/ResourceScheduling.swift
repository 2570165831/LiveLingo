import Foundation
import OSLog

struct ASRRequestState: Codable, Equatable, Sendable {
    let model: String
    let state: String
}

struct ASRResourceSnapshot: Equatable, Sendable {
    enum Status: String, Sendable { case stopped, starting, ready, retiring, unavailable }
    var status: Status
    var runtimeID: UUID?
    var processIdentifier: Int32?
    var loadedModels: [String] = []
    var unloadingModels: [String] = []
    var requests: [String: ASRRequestState] = [:]
    var unresolvedRequests: Set<String> = []
    var observedAt = ProcessInfo.processInfo.systemUptime
    var diagnostic: String?

    var activeCount: Int { requests.values.filter { $0.state != "finished" }.count }
    var ownershipConfirmed: Bool {
        (status == .ready || status == .stopped) && unresolvedRequests.isEmpty && unloadingModels.isEmpty
    }
    func withStatus(_ status: Status) -> Self {
        var value = self
        value.status = status
        return value
    }
}

struct ASRHTTPResult: Sendable {
    let data: Data
    let status: Int
}

enum ASRRequestContext {
    @TaskLocal static var requestID: String?

    static func identifier(sessionID: UUID, chunkID: UUID, automatic: Int, manual: Int,
                           stage: String, nonce: UUID) -> String {
        let session = sessionID.uuidString.replacingOccurrences(of: "-", with: "")
        let chunk = chunkID.uuidString.replacingOccurrences(of: "-", with: "")
        let attempt = nonce.uuidString.replacingOccurrences(of: "-", with: "")
        return "s\(session)_c\(chunk)_a\(automatic)_m\(manual)_\(stage)_\(attempt)"
    }
}

/// Cancellation detaches the UI caller; only the independent request monitor
/// may release the inference lease. Each admitted request owns one delivery.
private final class ASRCallerDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?

    func resolve(_ result: Result<String, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(with: result)
    }

    func wait() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let completed = lock.withLock { () -> Result<String, Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }
    }
}

/// A caller can stop caring about a result while its inference still owns
/// memory. Keep the independent HTTP operation alive to receive completion.
/// Transport failure needs a matching receipt or owned-process exit.
actor ASRRequestCoordinator {
    static let shared = ASRRequestCoordinator()
    typealias Transport = @Sendable (URLRequest) async throws -> ASRHTTPResult
    typealias ExitObservation = @Sendable (ASRRuntime.Endpoint) async -> Bool?

    private struct Key: Hashable, Sendable {
        let endpoint: ASRRuntime.Endpoint
        let id: String
    }
    private struct Lease: Sendable {
        let model: String
        var cancelled = false
        var unknown = false
    }
    private struct Health: Decodable {
        let ok: Bool
        let pid: Int32
        let `protocol`: Int
        let loaded_models: [String]
        let unloading_models: [String]?
        let requests: [String: ASRRequestState]
        let completed_requests: [String: ASRRequestState]?
    }

    private let transport: Transport
    private let observeExit: ExitObservation
    private let confirmationTimeout: TimeInterval
    private var leases: [Key: Lease] = [:]
    private static let log = Logger(subsystem: "com.jianhongli.LiveLingo", category: "ASROwnership")

    init(confirmationTimeout: TimeInterval = 5,
         transport: @escaping Transport = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let http = response as? HTTPURLResponse else { throw QwenRuntimeError.invalidResponse }
             return ASRHTTPResult(data: data, status: http.statusCode)
         },
         observeExit: @escaping ExitObservation = { await ASRRuntime.shared.hasExited($0) }) {
        self.transport = transport
        self.observeExit = observeExit
        self.confirmationTimeout = confirmationTimeout
    }

    static func validRequestID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    func transcribe(endpoint: ASRRuntime.Endpoint, audioURL: URL, modelKey: String,
                    enhanceSpeech: Bool = false, requestID suppliedID: String? = nil) async throws -> String {
        try Task.checkCancellation()
        let requestID = suppliedID ?? UUID().uuidString
        guard Self.validRequestID(requestID) else { throw QwenRuntimeError.requestFailed("转写请求编号无效") }
        let key = Key(endpoint: endpoint, id: requestID)
        if leases.contains(where: { $0.key.endpoint == endpoint && $0.value.unknown }) {
            _ = await resourceState(endpoint: endpoint)
            guard !leases.contains(where: { $0.key.endpoint == endpoint && $0.value.unknown }) else {
                throw QwenRuntimeError.requestFailed("上一转写请求的退出尚未确认；片段已保留，等待服务恢复。")
            }
        }
        // Health polling suspends this actor. Another caller may have acquired
        // this ID or filled the slots while we were waiting for the receipt.
        try Task.checkCancellation()
        guard leases[key] == nil else { throw QwenRuntimeError.requestFailed("转写请求仍在处理，不能重复提交") }
        guard leases.keys.filter({ $0.endpoint == endpoint }).count < 3 else {
            throw QwenRuntimeError.requestFailed("本机转写队列已满，片段等待重试。")
        }
        var components = URLComponents(url: endpoint.baseURL.appending(path: "transcribe"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "model", value: modelKey),
                                 URLQueryItem(name: "enhance", value: enhanceSpeech ? "speech" : "off")]
        guard let url = components?.url else { throw QwenRuntimeError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-LiveLingo-Request-ID")
        Self.authorize(&request, endpoint)
        request.httpBody = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        try Task.checkCancellation()
        leases[key] = Lease(model: modelKey)
        let transport = self.transport
        let started = ProcessInfo.processInfo.systemUptime
        Self.log.notice("asr event=acquired id=\(requestID, privacy: .public) model=\(modelKey, privacy: .public)")
        let delivery = ASRCallerDelivery()
        let submittedRequest = request
        Task {
            let outcome: Result<ASRHTTPResult, Error>
            do { outcome = .success(try await transport(submittedRequest)) }
            catch { outcome = .failure(error) }
            do { delivery.resolve(.success(try await finish(outcome, key: key, started: started))) }
            catch { delivery.resolve(.failure(error)) }
        }
        return try await withTaskCancellationHandler {
            try await delivery.wait()
        } onCancel: {
            delivery.resolve(.failure(CancellationError()))
            Task { await self.markCallerCancelled(key) }
        }
    }

    private func finish(_ outcome: Result<ASRHTTPResult, Error>, key: Key,
                        started: TimeInterval) async throws -> String {
        let requestID = key.id
        guard let modelKey = leases[key]?.model else { throw CancellationError() }
        switch outcome {
        case .success(let response):
            let payload = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
            let matched = payload?["request_id"] as? String == requestID
                && payload?["model"] as? String == modelKey
            let rejectedBeforeAdmission = [400, 401, 403, 404, 413, 503].contains(response.status)
            if matched || rejectedBeforeAdmission {
                leases.removeValue(forKey: key)
                Self.log.notice("asr event=released id=\(requestID, privacy: .public) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            } else {
                leases[key]?.unknown = true
                let confirmation = Task { await self.confirmCompletion(key) }
                _ = await confirmation.value
            }
            try Task.checkCancellation()
            guard leases[key] == nil else {
                throw QwenRuntimeError.requestFailed("转写响应未能确认所属请求，已保留处理记录。")
            }
            guard response.status == 200 else {
                throw QwenRuntimeError.requestFailed(payload?["error"] as? String ?? "本机转写请求失败")
            }
            guard matched, let text = payload?["text"] as? String else { throw QwenRuntimeError.invalidResponse }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure(let error):
            leases[key]?.unknown = true
            let confirmation = Task { await self.confirmCompletion(key) }
            _ = await confirmation.value
            if Task.isCancelled { throw CancellationError() }
            throw QwenASRClient.transportError(error)
        }
    }

    private func markCallerCancelled(_ key: Key) {
        guard leases[key] != nil else { return }
        leases[key]?.cancelled = true
        Self.log.notice("asr event=caller_cancelled_waiting_for_exit id=\(key.id, privacy: .public)")
    }

    private func confirmCompletion(_ key: Key) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + confirmationTimeout
        repeat {
            if await observeExit(key.endpoint) == true {
                confirmServiceExited(key.endpoint)
                return true
            }
            _ = await resourceState(endpoint: key.endpoint)
            if leases[key] == nil { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            await Self.pause(0.1)
        } while true
        return false
    }

    func resourceState(endpoint: ASRRuntime.Endpoint) async -> ASRResourceSnapshot {
        let observedAt = ProcessInfo.processInfo.systemUptime
        var request = URLRequest(url: endpoint.baseURL.appending(path: "health"))
        request.timeoutInterval = 2
        Self.authorize(&request, endpoint)
        do {
            let response = try await transport(request)
            guard response.status == 200 else { throw QwenRuntimeError.serviceUnavailable }
            let health = try JSONDecoder().decode(Health.self, from: response.data)
            guard health.ok, health.protocol == 1,
                  endpoint.processIdentifier.map({ $0 == health.pid }) ?? true,
                  health.requests.allSatisfy({ Self.validRequestID($0.key)
                      && ["waiting", "running", "finished"].contains($0.value.state) }),
                  (health.completed_requests ?? [:]).allSatisfy({ Self.validRequestID($0.key) && $0.value.state == "finished" }) else {
                throw QwenRuntimeError.invalidResponse
            }
            let completed = health.completed_requests ?? [:]
            for (key, lease) in leases where key.endpoint == endpoint && lease.unknown {
                let receipt = completed[key.id] ?? health.requests[key.id]
                if receipt?.model == lease.model && receipt?.state == "finished" { leases.removeValue(forKey: key) }
            }
            var requests = health.requests
            for (key, lease) in leases where key.endpoint == endpoint && requests[key.id] == nil {
                requests[key.id] = ASRRequestState(model: lease.model,
                    state: lease.unknown ? "unconfirmed" : lease.cancelled ? "cancelling" : "submitted")
            }
            return ASRResourceSnapshot(status: .ready, runtimeID: endpoint.runtimeID,
                processIdentifier: health.pid, loadedModels: health.loaded_models.sorted(),
                unloadingModels: (health.unloading_models ?? []).sorted(), requests: requests,
                unresolvedRequests: Set(leases.filter { $0.key.endpoint == endpoint && $0.value.unknown }.map { $0.key.id }),
                observedAt: observedAt)
        } catch {
            let owned = leases.filter { $0.key.endpoint == endpoint }
            return ASRResourceSnapshot(status: .unavailable, runtimeID: endpoint.runtimeID,
                processIdentifier: endpoint.processIdentifier,
                requests: Dictionary(uniqueKeysWithValues: owned.map {
                    ($0.key.id, ASRRequestState(model: $0.value.model, state: "unconfirmed"))
                }), unresolvedRequests: Set(owned.keys.map(\.id)), observedAt: observedAt,
                diagnostic: "转写资源状态读取失败，当前占用尚未确认。")
        }
    }

    func confirmServiceExited(_ endpoint: ASRRuntime.Endpoint) {
        guard endpoint.runtimeID != nil, let pid = endpoint.processIdentifier, pid > 0 else { return }
        leases = leases.filter { $0.key.endpoint != endpoint }
    }

    private static func authorize(_ request: inout URLRequest, _ endpoint: ASRRuntime.Endpoint) {
        if !endpoint.token.isEmpty { request.setValue(endpoint.token, forHTTPHeaderField: "X-LiveLingo-Token") }
    }

    private static func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}

struct RuntimeResourceSnapshot: Sendable {
    var asr: ASRResourceSnapshot
    var languageWorkers: [String: MLXRuntime.ResourceState]
    var observedAt = ProcessInfo.processInfo.systemUptime
    var hasUnconfirmedRelease: Bool {
        !asr.ownershipConfirmed || languageWorkers.values.contains { $0.retiring || $0.pendingControls > 0 }
    }
    var hasActiveRequests: Bool {
        asr.activeCount > 0 || languageWorkers.values.contains { $0.outstandingRequests > 0 }
    }
}

enum ResourceSchedulingPolicy {
    enum Work: Sendable, Equatable { case summary, review, repair }
    enum Reason: String, Sendable {
        case available, finishSummary, memoryPressure, captionBacklog, releaseUnconfirmed
        case userPaused, recordingPriority, captionSlot, modelBusy, interval
        var description: String {
            switch self {
            case .available: return "资源可用"
            case .finishSummary: return "继续完成当前摘要"
            case .memoryPressure: return "内存紧张，保留进度等待"
            case .captionBacklog: return "字幕积压，优先追上课堂"
            case .releaseUnconfirmed: return "等待上一个模型请求退出确认"
            case .userPaused: return "处理已暂停"
            case .recordingPriority: return "正在录音，补转等待采集结束"
            case .captionSlot: return "等待当前字幕任务完成"
            case .modelBusy: return "等待当前模型任务完成"
            case .interval: return "等待下一轮摘要时间"
            }
        }
    }
    struct Context: Sendable {
        var now: TimeInterval
        var memoryNormal: Bool
        var captionBacklog: Bool
        var captionPending: Bool
        var recording: Bool
        var allowConcurrent: Bool
        var summaryRunning: Bool
        var paused: Bool
        var lastSummaryStarted: TimeInterval?
        var continuingSummary: Bool
        var lowPower: Bool
        var resources: RuntimeResourceSnapshot?
        var continuingRequestID: String? = nil
    }
    struct Decision: Sendable, Equatable {
        let allowed: Bool
        let interrupt: Bool
        let reason: Reason
    }

    static func decide(_ work: Work, in context: Context) -> Decision {
        if context.paused { return .init(allowed: false, interrupt: true, reason: .userPaused) }
        if !context.memoryNormal { return .init(allowed: false, interrupt: true, reason: .memoryPressure) }
        if context.captionBacklog { return .init(allowed: false, interrupt: true, reason: .captionBacklog) }
        // Low power changes profiles. It does not, by itself, erase progress
        // or revoke an active summary's time slot.
        if work == .summary && context.summaryRunning {
            return .init(allowed: true, interrupt: false, reason: .finishSummary)
        }
        guard var resources = context.resources else {
            return .init(allowed: false, interrupt: false, reason: .releaseUnconfirmed)
        }
        if work == .review, let id = context.continuingRequestID {
            resources.languageWorkers = resources.languageWorkers.mapValues { $0.excludingContinuation(id) }
        }
        if context.now - resources.observedAt > 15 || context.now - resources.asr.observedAt > 15
            || resources.hasUnconfirmedRelease {
            return .init(allowed: false, interrupt: false, reason: .releaseUnconfirmed)
        }
        if work == .repair && context.recording {
            return .init(allowed: false, interrupt: false, reason: .recordingPriority)
        }
        if context.captionPending && !context.allowConcurrent {
            return .init(allowed: false, interrupt: false, reason: .captionSlot)
        }
        if resources.hasActiveRequests && !context.allowConcurrent {
            return .init(allowed: false, interrupt: false, reason: .modelBusy)
        }
        if work == .summary, !context.continuingSummary,
           let last = context.lastSummaryStarted,
           context.now - last < SummaryRefreshPolicy.minimumCycleInterval {
            return .init(allowed: false, interrupt: false, reason: .interval)
        }
        return .init(allowed: true, interrupt: false, reason: .available)
    }
}
