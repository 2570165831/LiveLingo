import Foundation
import Darwin
import OSLog

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
        init(_ handle: FileHandle) { self.handle = handle }
        func write(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do { try self.handle.write(contentsOf: data); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
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
    private var requestModels: [String: String] = [:]
    private var resumableRequests: Set<String> = []
    private var requestActivity: [String: TimeInterval] = [:]
    private struct Control {
        let workerID: UUID
        let expected: String
        var result: Result<Void, Error>?
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
    struct TestConfiguration: Sendable {
        let python: URL
        let script: URL
        let models: URL
        let state: URL
        var controlTimeout: TimeInterval = 1
        var interpreterArguments: [String] = []
    }
    private var testConfiguration: TestConfiguration?
    init(testConfiguration: TestConfiguration? = nil) {
        self.testConfiguration = testConfiguration
        if let testConfiguration { controlTimeout = testConfiguration.controlTimeout }
    }
    #endif
    private static let relativeModels = [
        "qwen3.5-4b-mlx": "mlx-community/Qwen3.5-4B-MLX-8bit",
        "qwen/qwen3.5-9b": "lmstudio-community/Qwen3.5-9B-MLX-4bit"
    ]

    private static func paths(_ model: String) throws -> (URL, URL, URL, URL) {
        guard let relative = relativeModels[model] else { throw QwenRuntimeError.modelUnavailable(model) }
        let env = ProcessInfo.processInfo.environment
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
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
        return (python, script, models.appendingPathComponent(relative),
                state.appendingPathComponent(model == "qwen3.5-4b-mlx" ? "4b" : "9b"))
    }

    static func checkModel(_ model: String) throws {
        let (python, script, directory, _) = try paths(model)
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else {
            throw QwenRuntimeError.requestFailed("缺少内置语言模型运行库，请重新安装完整离线包。")
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
        let worker = Worker(process: process, input: input.fileHandleForWriting)
        try process.run()
        workers[model] = worker
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
                    throw QwenRuntimeError.requestFailed("内置语言运行库协议版本不匹配。")
                }
                worker.ready = true
                continue
            }
            guard worker.ready else { throw QwenRuntimeError.invalidResponse }
            if event.event == "model_state", let loaded = event.loaded {
                worker.modelLoaded = loaded
                continue
            }
            if let token = event.controlID, var control = controls[token], control.workerID == workerID {
                if event.event == control.expected && event.state != "checkpoint_failed" {
                    control.result = .success(())
                } else {
                    control.result = .failure(QwenRuntimeError.generationInterrupted("模型未确认保存或释放请求；保留上次有效进度。"))
                }
                controls[token] = control
                continue
            }
            guard let id = event.id, worker.requests.contains(id), let continuation = streams[id] else { continue }
            requestActivity[id] = worker.lastActivity
            if event.event == "error" {
                let message = event.message ?? "本机模型生成失败"
                continuation.finish(throwing: event.recoverable == true
                    ? QwenRuntimeError.generationInterrupted(message) : QwenRuntimeError.requestFailed(message))
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

    private func ended(_ model: String, workerID: UUID, error: Error?) {
        guard let worker = workers[model], worker.id == workerID else { return }
        let details = String(data: worker.diagnostics, encoding: .utf8) ?? ""
        for id in worker.requests {
            let message = "本机模型通信已结束，正在确认进程退出。\(details.suffix(1000))"
            streams[id]?.finish(throwing: error ?? (resumableRequests.contains(id)
                ? QwenRuntimeError.generationInterrupted(message) : QwenRuntimeError.requestFailed(message)))
            streams[id] = nil; requestModels[id] = nil
            resumableRequests.remove(id)
            requestActivity[id] = nil
        }
        workers[model] = nil
        for token in Array(controls.keys) where controls[token]?.workerID == workerID && controls[token]?.result == nil {
            controls[token]?.result = .failure(error ?? QwenRuntimeError.generationInterrupted("模型进程在确认请求前退出；保留上次有效进度。"))
        }
        if worker.process.isRunning {
            retiringWorkers[model] = worker
            worker.process.terminate()
            Task { await self.waitForExit(worker, model: model) }
        }
    }

    private func waitForExit(_ worker: Worker, model: String) async {
        let deadline = ProcessInfo.processInfo.systemUptime + controlTimeout
        while worker.process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if worker.process.isRunning {
            // Process is a child owned by this Worker instance. Never enumerate
            // or signal another application's model processes.
            _ = Darwin.kill(worker.process.processIdentifier, SIGKILL)
        }
        let killDeadline = ProcessInfo.processInfo.systemUptime + 2
        while worker.process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !worker.process.isRunning, retiringWorkers[model]?.id == worker.id {
            retiringWorkers[model] = nil
        }
    }

    private func send(_ object: [String: Any], to worker: Worker) async throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try await worker.writer.write(data)
    }

    private func control(_ operation: String, id: String?, worker: Worker) async throws {
        let token = UUID().uuidString
        controls[token] = Control(workerID: worker.id, expected: operation == "pause" ? "paused" : operation)
        if let id { requestControls[id] = token }
        defer {
            controls[token] = nil
            if let id, requestControls[id] == token { requestControls[id] = nil }
        }
        var command: [String: Any] = ["op": operation, "controlID": token]
        if let id { command["id"] = id }
        try await send(command, to: worker)
        let deadline = ProcessInfo.processInfo.systemUptime + controlTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let result = controls[token]?.result { return try result.get() }
            // Cleanup acknowledgement must outlive cancellation of the caller.
            // Dispatch sleep is independent of task cancellation and creates no
            // chain of polling Tasks.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
                    continuation.resume()
                }
            }
        }
        throw QwenRuntimeError.generationInterrupted("模型暂停或退出未及时确认；保留上次有效进度。")
    }

    private func pause(_ id: String, timedOut: Bool = false, stalled: Bool = false) async {
        guard let model = requestModels[id], let worker = workers[model] else { return }
        guard requestControls[id] == nil else { return }
        let resumable = resumableRequests.contains(id)
        streams[id]?.finish(throwing: timedOut ? (resumable
            ? QwenRuntimeError.generationInterrupted("本机模型请求超时，已保留已有文字进度。")
            : QwenRuntimeError.requestFailed("本机模型请求超时。")) : CancellationError())
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

    func generate(model: String, prompt: String, input: String, prefix: String,
                  thinking: Bool, purpose: String, finalBudget: Int, timeout: TimeInterval,
                  thinkingBudget: Int = 16384,
                  inactivityTimeout: TimeInterval? = nil,
                  onRequestIdentity: (@Sendable (String) -> Void)? = nil,
                  onUpdate: @escaping @MainActor @Sendable (String) async throws -> Void) async throws -> String {
        let id = UUID().uuidString
        onRequestIdentity?(id)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let worker = try worker(model)
            let pair = AsyncThrowingStream<Event, Error>.makeStream()
            streams[id] = pair.continuation; requestModels[id] = model; worker.requests.insert(id)
            if purpose != "text" { resumableRequests.insert(id) }
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
            defer { deadline.cancel() }
            do {
                try await send(["op":"generate", "id":id, "prompt":prompt, "input":input, "prefix":prefix,
                                "thinking":thinking, "purpose":purpose, "thinkingBudget":thinkingBudget,
                                "finalBudget":finalBudget], to: worker)
                for try await event in pair.stream {
                    try Task.checkCancellation()
                    if let wire = event.wire { try await onUpdate(wire) }
                    if event.event == "done", let text = event.text {
                        try Task.checkCancellation()
                        // The complete wire has reached the caller's text journal.
                        // Domain validation still decides whether to commit notes.
                        try await control("ack", id: id, worker: worker)
                        forget(id, worker: worker)
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
