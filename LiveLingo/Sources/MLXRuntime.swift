import Foundation
import Darwin
import OSLog

enum MLXRequestContext {
    @TaskLocal static var retainsCheckpoint = true
}

// One owned process per model. No LM Studio server, global ports or foreign PIDs.
actor MLXRuntime {
    static let shared = MLXRuntime()
    private static let memoryLog = Logger(subsystem: "com.jianhongli.LiveLingo", category: "MLXMemory")
    private struct Event: Decodable, Sendable {
        let event: String
        let id: String?
        let wire: String?
        let text: String?
        let message: String?
        let version: Int?
        let recoverable: Bool?
        let code: String?
        let activeBytes: UInt64?
        let cacheBytes: UInt64?
        let peakBytes: UInt64?
        let cacheLimitBytes: UInt64?
        let controlID: String?
        let state: String?
        let loaded: Bool?
    }
    private final class Writer: @unchecked Sendable {
        let handle: FileHandle
        let queue = DispatchQueue(label: "LiveLingo.MLX.write")
        // Accessed only on queue. A partial command must never be followed by
        // another command on the same stream after its deadline expires.
        private var failure: Error?
        init(_ handle: FileHandle) {
            self.handle = handle
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0
                || fcntl(descriptor, F_SETNOSIGPIPE, 1) < 0 {
                failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        func write(_ data: Data, deadline: ExitDeadline) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        if let failure = self.failure { throw failure }
                        try data.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < bytes.count {
                                try deadline.check()
                                let count = Darwin.write(self.handle.fileDescriptor,
                                    bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                                if count > 0 { offset += count; continue }
                                if count < 0, errno == EINTR { continue }
                                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                                }
                                var descriptor = pollfd(fd: self.handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                                let milliseconds = Int32(max(1, min(50, (deadline.remaining * 1000).rounded(.up))))
                                let ready = Darwin.poll(&descriptor, 1, milliseconds)
                                if ready < 0, errno != EINTR {
                                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                                }
                                if ready > 0, descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                                    throw POSIXError(.EPIPE)
                                }
                            }
                        }
                        try deadline.check()
                        continuation.resume()
                    } catch {
                        self.failure = error
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    private final class Worker: @unchecked Sendable {
        let id = UUID()
        let process: Process
        let writer: Writer
        var buffer = Data()
        var diagnostics = Data()
        var requests: Set<String> = []
        var ready = false
        var retiring = false
        var modelLoaded = false
        var lastActivity = ProcessInfo.processInfo.systemUptime
        init(process: Process, input: FileHandle) {
            self.process = process; writer = Writer(input)
        }
    }
    private var workers: [String: Worker] = [:]
    private var streams: [String: AsyncThrowingStream<Event, Error>.Continuation] = [:]
    // A request may terminate while its initial send is still blocked. Retain
    // the first stream failure until generate() can observe it, even if worker
    // retirement has already removed its stream and ownership entries.
    private var requestFailures: [String: Error] = [:]
    private var requestModels: [String: String] = [:]
    private var resumableRequests: Set<String> = []
    private var requestActivity: [String: TimeInterval] = [:]
    private struct Control {
        let workerID: UUID
        let expected: String
        var writeFinished = false
        var result: Result<Void, Error>?
        var waiter: CheckedContinuation<Void, Error>?
    }
    private var controls: [String: Control] = [:]
    private var requestControls: [String: String] = [:]
    private var retiringWorkers: [String: Worker] = [:]
    private var controlTimeout: TimeInterval = 5

    struct ResourceState: Sendable {
        let workerID: UUID
        let processIdentifier: Int32
        let modelLoaded: Bool
        let outstandingRequests: Int
        let pendingControls: Int
        let retiring: Bool
        var requestIDs: Set<String> = []
        var acknowledgingRequestIDs: Set<String> = []

        /// Admission for an existing request must not count that same request
        /// as a competitor. This view never releases its actual runtime lease.
        func excludingContinuation(_ id: String) -> Self {
            guard requestIDs.contains(id), outstandingRequests >= requestIDs.count else { return self }
            var remaining = requestIDs
            remaining.remove(id)
            var acknowledgements = acknowledgingRequestIDs
            let ownsAcknowledgement = acknowledgements.remove(id) != nil
            return Self(workerID: workerID, processIdentifier: processIdentifier,
                modelLoaded: modelLoaded, outstandingRequests: outstandingRequests - 1,
                pendingControls: max(0, pendingControls - (ownsAcknowledgement ? 1 : 0)),
                retiring: retiring, requestIDs: remaining, acknowledgingRequestIDs: acknowledgements)
        }
    }

    func resourceStates() -> [String: ResourceState] {
        var visible = workers
        for (model, worker) in retiringWorkers where worker.process.isRunning {
            visible[model] = worker
        }
        return visible.mapValues { worker in
            ResourceState(workerID: worker.id, processIdentifier: worker.process.processIdentifier,
                          modelLoaded: worker.modelLoaded,
                          outstandingRequests: worker.requests.count,
                          pendingControls: controls.values.filter { $0.workerID == worker.id && $0.result == nil }.count,
                          retiring: worker.retiring || retiringWorkers.values.contains(where: { $0.id == worker.id }),
                          requestIDs: worker.requests,
                          acknowledgingRequestIDs: Set(requestControls.compactMap { request, controlID in
                              guard let control = controls[controlID], control.workerID == worker.id,
                                    control.result == nil, control.expected == "ack" else { return nil }
                              return request
                          }))
        }
    }

    #if DEBUG
    enum RetryWaitPhaseForTesting: Sendable {
        case requestRelease, workerExit
    }
    struct TestConfiguration: Sendable {
        let python: URL
        let script: URL
        let models: URL
        let state: URL
        var controlTimeout: TimeInterval = 1
        var interpreterArguments: [String] = []
        var onCancellationControlResolved: (@Sendable () async -> Void)?
        var onRetryWait: (@Sendable (RetryWaitPhaseForTesting) async -> Void)?
        var onWorkerLaunched: (@Sendable (Process, FileHandle) -> Void)?
        var onExitWait: (@Sendable () -> Void)?
    }
    private var testConfiguration: TestConfiguration?
    init(testConfiguration: TestConfiguration? = nil) {
        self.testConfiguration = testConfiguration
        if let testConfiguration { controlTimeout = testConfiguration.controlTimeout }
    }
    static func writeForExitTesting(_ data: Data, to handle: FileHandle, timeout: TimeInterval) async throws {
        try await Writer(handle).write(data, deadline: ExitDeadline(seconds: timeout))
    }
    func controlForExitTesting(to handle: FileHandle, timeout: TimeInterval) async throws {
        controlTimeout = timeout
        try await control("shutdown", id: nil, worker: Worker(process: Process(), input: handle))
    }
    #endif
    private static let relativeModels = [
        "qwen3.5-4b-mlx": "mlx-community/Qwen3.5-4B-MLX-8bit",
        "qwen/qwen3.5-9b": "lmstudio-community/Qwen3.5-9B-MLX-4bit"
    ]

    private static func paths(_ model: String) throws -> (URL, URL, URL, URL) {
        guard let relative = relativeModels[model] else { throw QwenRuntimeError.modelUnavailable(model) }
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        #if LIVELINGO_PREVIEW
        // Never inherit production CLI paths, including its checkpoint root.
        let python = resources.appendingPathComponent("LanguageRuntime/python/bin/python3")
        let script = resources.appendingPathComponent("LanguageRuntime/worker.py")
        let models = resources.appendingPathComponent("Models")
        let state = try PreviewDataIsolation.dataURL("LanguageRuntime/Checkpoints")
        #else
        let env = ProcessInfo.processInfo.environment
        let python = env["LIVELINGO_MLX_PYTHON"].map { URL(fileURLWithPath: $0) }
            ?? resources.appendingPathComponent("LanguageRuntime/python/bin/python3")
        let script = env["LIVELINGO_MLX_WORKER"].map { URL(fileURLWithPath: $0) }
            ?? resources.appendingPathComponent("LanguageRuntime/worker.py")
        let models = env["LIVELINGO_MLX_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? resources.appendingPathComponent("Models")
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let state = env["LIVELINGO_MLX_STATE"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("LiveLingo/LanguageRuntime/Checkpoints")
        #endif
        return (python, script, models.appendingPathComponent(relative),
                state.appendingPathComponent(model == "qwen3.5-4b-mlx" ? "4b" : "9b"))
    }

    static func checkModel(_ model: String) throws {
        let (python, script, directory, _) = try paths(model)
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            throw QwenRuntimeError.runtimeUnavailable
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path) else {
            throw QwenRuntimeError.modelUnavailable(model)
        }
    }

    private static func chunks(_ handle: FileHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue(label: "LiveLingo.MLX.read.\(UUID())").async {
                do {
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        continuation.yield(Data(buffer.prefix(count)))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                try? handle.close()
            }
        }
    }

    private func worker(_ model: String) throws -> Worker {
        if let retiring = retiringWorkers[model], retiring.process.isRunning {
            throw QwenRuntimeError.generationInterrupted("上一个模型进程正在退出，任务保留等待重试。")
        }
        if let existing = workers[model], existing.process.isRunning {
            guard !existing.retiring else {
                throw QwenRuntimeError.generationInterrupted("模型正在卸载，任务保留等待重试。")
            }
            return existing
        }
        let python: URL, script: URL, directory: URL, state: URL
        #if DEBUG
        if let testConfiguration {
            (python, script, directory, state) = (testConfiguration.python, testConfiguration.script,
                                                 testConfiguration.models, testConfiguration.state)
        } else {
            try Self.checkModel(model)
            (python, script, directory, state) = try Self.paths(model)
        }
        #else
        try Self.checkModel(model)
        (python, script, directory, state) = try Self.paths(model)
        #endif
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = python
        #if DEBUG
        let interpreterArguments = testConfiguration?.interpreterArguments ?? ["-u"]
        #else
        let interpreterArguments = ["-u"]
        #endif
        process.arguments = interpreterArguments + [script.path, "--model", directory.path,
                                                     "--state-directory", state.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PYTHONHOME"); environment.removeValue(forKey: "PYTHONPATH")
        environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"; environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        let worker = Worker(process: process, input: input.fileHandleForWriting)
        try process.run()
        workers[model] = worker
        #if DEBUG
        testConfiguration?.onWorkerLaunched?(process, input.fileHandleForWriting)
        #endif
        let identifier = worker.id
        Task {
            do {
                for try await chunk in Self.chunks(output.fileHandleForReading) {
                    try receive(chunk, model: model, workerID: identifier)
                }
                ended(model, workerID: identifier, error: nil)
            } catch { ended(model, workerID: identifier, error: error) }
        }
        Task {
            do {
                for try await chunk in Self.chunks(errors.fileHandleForReading) {
                    guard workers[model]?.id == identifier else { break }
                    worker.diagnostics.append(chunk)
                    if worker.diagnostics.count > 8_192 { worker.diagnostics = Data(worker.diagnostics.suffix(8_192)) }
                }
            } catch { /* stdout/exit reports the actual request failure */ }
        }
        return worker
    }

    private func receive(_ data: Data, model: String, workerID: UUID) throws {
        guard let worker = workers[model], worker.id == workerID else { return }
        worker.buffer.append(data)
        while let newline = worker.buffer.firstIndex(of: 10) {
            let line = worker.buffer[..<newline]
            guard line.count <= 2_097_152 else { throw QwenRuntimeError.invalidResponse }
            let event = try JSONDecoder().decode(Event.self, from: line)
            worker.buffer.removeSubrange(...newline)
            if event.event == "memory" {
                guard worker.ready else { throw QwenRuntimeError.invalidResponse }
                if let active = event.activeBytes, let cache = event.cacheBytes,
                   let peak = event.peakBytes, let limit = event.cacheLimitBytes {
                    Self.memoryLog.notice("model=\(model, privacy: .public) active_bytes=\(active) cache_bytes=\(cache) peak_bytes=\(peak) cache_limit_bytes=\(limit)")
                }
                // Telemetry is not generation progress and must not extend a timeout.
                continue
            }
            worker.lastActivity = ProcessInfo.processInfo.systemUptime
            if event.event == "ready" {
                guard event.version == 2 else {
                    throw QwenRuntimeError.runtimeUnavailable
                }
                worker.ready = true
                continue
            }
            guard worker.ready else { throw QwenRuntimeError.invalidResponse }
            if event.event == "model_state", let loaded = event.loaded {
                worker.modelLoaded = loaded
                continue
            }
            if let token = event.controlID, let control = controls[token], control.workerID == workerID {
                if event.event == control.expected && event.state != "checkpoint_failed" {
                    resolveControl(token, with: .success(()))
                } else {
                    resolveControl(token, with: .failure(QwenRuntimeError.generationInterrupted("模型未确认保存或释放请求；保留上次有效进度。")))
                }
                continue
            }
            guard let id = event.id, worker.requests.contains(id), let continuation = streams[id] else { continue }
            requestActivity[id] = worker.lastActivity
            if event.event == "error" {
                let message = event.message.flatMap(ReviewFailure.parseWorkerMessage).map {
                    "review failure " + $0.logLine
                } ?? "本机模型生成失败；上游详情已省略。"
                let failure: QwenRuntimeError
                if event.code == "output_budget_exhausted" {
                    failure = .outputLimitReached(message)
                } else {
                    failure = event.recoverable == true
                        ? .generationInterrupted(message) : .requestFailed(message)
                }
                finishRequest(id, throwing: failure)
                forget(id, worker: worker)
            } else {
                continuation.yield(event)
                // Delivery is not release: keep ownership through the caller's
                // journal write and the worker's explicit acknowledgement.
                if event.event == "done" { continuation.finish(); requestActivity[id] = nil }
            }
        }
        guard worker.buffer.count <= 2_097_152 else { throw QwenRuntimeError.invalidResponse }
    }

    private func forget(_ id: String, worker: Worker) {
        streams[id] = nil; requestModels[id] = nil; requestActivity[id] = nil
        resumableRequests.remove(id); worker.requests.remove(id)
    }

    private func finishRequest(_ id: String, throwing error: Error) {
        guard let continuation = streams[id] else { return }
        let failure = requestFailures[id] ?? error
        requestFailures[id] = failure
        continuation.finish(throwing: failure)
    }

    private func ended(_ model: String, workerID: UUID, error: Error?) {
        guard let worker = workers[model], worker.id == workerID else { return }
        for id in worker.requests {
            let message = "本机模型通信已结束，正在确认进程退出。"
            finishRequest(id, throwing: error ?? (resumableRequests.contains(id)
                ? QwenRuntimeError.generationInterrupted(message) : QwenRuntimeError.processExited))
            streams[id] = nil; requestModels[id] = nil
            resumableRequests.remove(id)
            requestActivity[id] = nil
        }
        workers[model] = nil
        for token in Array(controls.keys) where controls[token]?.workerID == workerID && controls[token]?.result == nil {
            resolveControl(token, with: .failure(error ?? QwenRuntimeError.generationInterrupted("模型进程在确认请求前退出；保留上次有效进度。")))
        }
        if worker.process.isRunning {
            retiringWorkers[model] = worker
            worker.process.terminate()
            Task { await self.waitForExit(worker, model: model) }
        }
    }

    private func waitForExit(_ worker: Worker, model: String) async {
        let deadline = (ExitDeadline.current ?? ExitDeadline(seconds: controlTimeout + 2)).limited(to: controlTimeout)
        while worker.process.isRunning && !deadline.isExpired {
            #if DEBUG
            testConfiguration?.onExitWait?()
            #endif
            await Self.sleepForRetirement(0.05)
        }
        if worker.process.isRunning {
            // Process is a child owned by this Worker instance. Never enumerate
            // or signal another application's model processes.
            _ = Darwin.kill(worker.process.processIdentifier, SIGKILL)
        }
        let killDeadline = (ExitDeadline.current ?? ExitDeadline(seconds: 2)).limited(to: 2)
        while worker.process.isRunning && !killDeadline.isExpired {
            #if DEBUG
            testConfiguration?.onExitWait?()
            #endif
            await Self.sleepForRetirement(0.02)
        }
        if !worker.process.isRunning, retiringWorkers[model]?.id == worker.id {
            retiringWorkers[model] = nil
        }
    }

    private static func sleepForRetirement(_ seconds: TimeInterval) async {
        // Retirement belongs to this exact worker even if its caller was
        // cancelled. A cancelled Task.sleep must not turn polling into a spin.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    /// A timeout can reach its caller before the cancel acknowledgement (and
    /// possible retirement) finishes. Settle that existing ownership first;
    /// never unload a healthy model or touch foreign PIDs for a caption retry.
    func finishRetirementBeforeRetry(_ model: String) async throws {
        guard let worker = workers[model] ?? retiringWorkers[model] else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + controlTimeout + 2
        func requestReleasePending() -> Bool {
            // A resolved control still owns its request until control()'s
            // defer and pause()'s forget()/ended() have run. In particular, a
            // failed cancellation must not admit a retry onto a doomed worker.
            if controls.values.contains(where: {
                $0.workerID == worker.id && ["cancel", "paused"].contains($0.expected)
            }) { return true }
            if workers[model]?.id == worker.id {
                return worker.requests.contains { streams[$0] == nil }
            }
            return false
        }
        while requestReleasePending(), ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            #if DEBUG
            if let onRetryWait = testConfiguration?.onRetryWait { await onRetryWait(.requestRelease) }
            #endif
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        guard !requestReleasePending() else {
            throw QwenRuntimeError.generationInterrupted("上一个请求的取消尚未确认，暂缓翻译补试。")
        }
        if retiringWorkers[model]?.id == worker.id {
            // The existing retirement task owns termination. The retry caller
            // only waits, and can cancel without spinning a cancelled sleep or
            // issuing a second termination against the same worker.
            let exitDeadline = ProcessInfo.processInfo.systemUptime + controlTimeout + 2
            while retiringWorkers[model]?.id == worker.id, ProcessInfo.processInfo.systemUptime < exitDeadline {
                try Task.checkCancellation()
                #if DEBUG
                if let onRetryWait = testConfiguration?.onRetryWait { await onRetryWait(.workerExit) }
                #endif
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            guard retiringWorkers[model]?.id != worker.id else {
                throw QwenRuntimeError.generationInterrupted("上一个模型进程尚未退出，暂缓翻译补试。")
            }
        }
    }

    private func send(_ object: [String: Any], to worker: Worker, deadline: ExitDeadline? = nil,
                      ignoringTaskCancellation: Bool = false) async throws {
        let deadline = deadline ?? (ExitDeadline.current ?? ExitDeadline(seconds: controlTimeout)).limited(to: controlTimeout)
        try deadline.check(ignoringTaskCancellation: ignoringTaskCancellation)
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        do { try await worker.writer.write(data, deadline: deadline) }
        catch is ExitDeadlineExceeded {
            throw QwenRuntimeError.generationInterrupted("模型管道发送超时；保留上次有效进度。")
        }
    }

    private func resolveControl(_ token: String, with result: Result<Void, Error>) {
        guard var control = controls[token], control.result == nil else { return }
        control.result = result
        let waiter = control.waiter
        control.waiter = nil
        controls[token] = control
        waiter?.resume(with: result)
    }

    private func control(_ operation: String, id: String?, worker: Worker) async throws {
        let deadline = (ExitDeadline.current ?? ExitDeadline(seconds: controlTimeout)).limited(to: controlTimeout)
        // Cancelled generation tasks still own the pause/ack lease until the
        // matching worker reply. Cancellation never removes the time limit.
        try deadline.check(ignoringTaskCancellation: true)
        let token = UUID().uuidString
        controls[token] = Control(workerID: worker.id, expected: operation == "pause" ? "paused" : operation)
        if let id { requestControls[id] = token }
        defer {
            controls[token] = nil
            if let id, requestControls[id] == token { requestControls[id] = nil }
        }
        var command: [String: Any] = ["op": operation, "controlID": token]
        if let id { command["id"] = id }
        // Unstructured timeout and checked continuation deliberately outlive
        // caller cancellation. Include writer queueing and pipe backpressure.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(deadline.remaining)) }
            catch { return }
            guard let control = controls[token], control.result == nil else { return }
            let failure = QwenRuntimeError.generationInterrupted("模型暂停或退出未及时确认；保留上次有效进度。")
            resolveControl(token, with: .failure(failure))
            if !control.writeFinished,
               let model = workers.first(where: { $0.value.id == worker.id })?.key {
                // Signal only the retained child, independently of its blocked
                // writer. Observed exit then releases the pipe and retirement.
                ended(model, workerID: worker.id, error: failure)
            }
        }
        defer { timeout.cancel() }
        var failure: Error?
        do {
            // Send once; queueing, pipe backpressure and acknowledgement all
            // consume the same deadline, even for a cancelled owner.
            try await send(command, to: worker, deadline: deadline, ignoringTaskCancellation: true)
            controls[token]?.writeFinished = true
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                // send() yields the actor, so a reply or exit may already be stored.
                guard var control = controls[token] else {
                    waiter.resume(throwing: QwenRuntimeError.invalidResponse)
                    return
                }
                if let result = control.result { waiter.resume(with: result); return }
                control.waiter = waiter
                controls[token] = control
            }
        } catch {
            if case .failure(let recorded)? = controls[token]?.result { failure = recorded }
            else { failure = error }
        }
        #if DEBUG
        // Hold the real resolved-entry/pre-retirement window only when a
        // scripted-worker test explicitly supplies a hook. Normal calls add
        // no suspension between resolution, entry removal and request release.
        if ["cancel", "pause"].contains(operation), controls[token]?.result != nil,
           let onResolved = testConfiguration?.onCancellationControlResolved {
            await onResolved()
        }
        #endif
        if let failure { throw failure }
    }

    private func pause(_ id: String, timedOut: Bool = false, stalled: Bool = false) async {
        guard let model = requestModels[id], let worker = workers[model] else { return }
        guard requestControls[id] == nil else { return }
        let resumable = resumableRequests.contains(id)
        finishRequest(id, throwing: timedOut ? (resumable
            ? QwenRuntimeError.generationInterrupted("本机模型请求超时，已保留已有文字进度。")
            : QwenRuntimeError.requestTimedOut) : CancellationError())
        streams[id] = nil
        requestActivity[id] = nil
        if stalled, ProcessInfo.processInfo.systemUptime - worker.lastActivity >= 30 {
            ended(model, workerID: worker.id, error: QwenRuntimeError.generationInterrupted("本机模型进程无响应，已停止，可重新发起请求。"))
            return
        }
        do {
            try await control(resumable ? "pause" : "cancel", id: id, worker: worker)
            forget(id, worker: worker)
        } catch {
            ended(model, workerID: worker.id, error: error)
        }
    }

    func unload(_ model: String) async {
        guard let worker = workers[model], worker.requests.isEmpty, !worker.retiring else { return }
        worker.retiring = true
        do { try await control("shutdown", id: nil, worker: worker) }
        catch { Self.memoryLog.error("model=\(model, privacy: .public) shutdown_unacknowledged") }
        retiringWorkers[model] = worker
        await waitForExit(worker, model: model)
        if !worker.process.isRunning, workers[model]?.id == worker.id { workers[model] = nil }
    }

    func shutdown() async {
        for model in Array(workers.keys) { await unload(model) }
    }

    func generate(model: String, prompt: String, input: String, prefix: String,
                  thinking: Bool, purpose: String, finalBudget: Int, timeout: TimeInterval,
                  thinkingBudget: Int = 16384,
                  inactivityTimeout: TimeInterval? = nil,
                  usePrefixCache: Bool = true,
                  onRequestIdentity: (@Sendable (String) -> Void)? = nil,
                  onUpdate: @escaping @MainActor @Sendable (String) async throws -> Void) async throws -> String {
        let id = UUID().uuidString
        onRequestIdentity?(id)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let worker = try worker(model)
            let pair = AsyncThrowingStream<Event, Error>.makeStream()
            streams[id] = pair.continuation; requestModels[id] = model; worker.requests.insert(id)
            if purpose != "text", MLXRequestContext.retainsCheckpoint { resumableRequests.insert(id) }
            let started = ProcessInfo.processInfo.systemUptime
            requestActivity[id] = started
            let inactivityLimit = inactivityTimeout ?? min(timeout, 180)
            let deadline = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(1))
                        guard let last = requestActivity[id] else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        let stalled = now - last >= inactivityLimit
                        if stalled || now - started >= timeout {
                            await self.pause(id, timedOut: true, stalled: stalled)
                            return
                        }
                    }
                }
                catch { }
            }
            defer {
                deadline.cancel()
                requestFailures[id] = nil
            }
            do {
                var command: [String: Any] = ["op":"generate", "id":id, "prompt":prompt, "input":input, "prefix":prefix,
                                "thinking":thinking, "purpose":purpose, "thinkingBudget":thinkingBudget,
                                "finalBudget":finalBudget, "retainCheckpoint":MLXRequestContext.retainsCheckpoint]
                if !usePrefixCache || !MLXRequestContext.retainsCheckpoint { command["usePrefixCache"] = false }
                do { try await send(command, to: worker) }
                catch {
                    // Timeout/exit may have finished the stream during send().
                    // A later EPIPE must not erase that established outcome.
                    throw requestFailures[id] ?? error
                }
                for try await event in pair.stream {
                    try Task.checkCancellation()
                    if let wire = event.wire { try await onUpdate(wire) }
                    if event.event == "done", let text = event.text {
                        try Task.checkCancellation()
                        // The complete wire has reached the caller's text journal.
                        // Domain validation still decides whether to commit notes.
                        try await control("ack", id: id, worker: worker)
                        forget(id, worker: worker)
                        try Task.checkCancellation()
                        return text
                    }
                }
                try Task.checkCancellation()
                throw QwenRuntimeError.invalidResponse
            } catch {
                await pause(id)
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw error
            }
        } onCancel: { Task { await self.pause(id) } }
    }
}

@MainActor
final class MLXCompletionPresentation {
    private let thinking: Bool
    private var previous = ""
    private var state: QwenCompletionStreamState
    init(thinking: Bool) { self.thinking = thinking; state = .init(thinking: thinking) }
    func update(_ wire: String) throws -> String? {
        if !wire.hasPrefix(previous) {
            state = .init(thinking: thinking); previous = ""
        }
        let delta = String(wire.dropFirst(previous.count)); previous = wire
        let data = try JSONSerialization.data(withJSONObject: ["choices":[["text":delta]]])
        return try state.consume(String(decoding: data, as: UTF8.self))
    }
    var raw: String { state.rawText }
    var wire: String { state.wireText }
    func finish() throws -> String {
        _ = try state.consume("{\"choices\":[{\"text\":\"\",\"finish_reason\":\"stop\"}]}")
        _ = try state.consume("[DONE]")
        return try state.result()
    }
}
