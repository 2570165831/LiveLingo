import Foundation
import Darwin

// One owned process per model. No LM Studio server, global ports or foreign PIDs.
actor MLXRuntime {
    static let shared = MLXRuntime()
    private struct Event: Decodable, Sendable {
        let event: String
        let id: String?
        let wire: String?
        let text: String?
        let message: String?
        let version: Int?
        let recoverable: Bool?
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
        if let existing = workers[model], existing.process.isRunning { return existing }
        try Self.checkModel(model)
        let (python, script, directory, state) = try Self.paths(model)
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = python
        process.arguments = ["-u", script.path, "--model", directory.path, "--state-directory", state.path]
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
            worker.lastActivity = ProcessInfo.processInfo.systemUptime
            worker.buffer.removeSubrange(...newline)
            if event.event == "ready" {
                guard event.version == 1 else {
                    throw QwenRuntimeError.requestFailed("内置语言运行库协议版本不匹配。")
                }
                worker.ready = true
                continue
            }
            guard worker.ready else { throw QwenRuntimeError.invalidResponse }
            guard let id = event.id, worker.requests.contains(id), let continuation = streams[id] else { continue }
            requestActivity[id] = worker.lastActivity
            if event.event == "error" {
                let message = event.message ?? "本机模型生成失败"
                continuation.finish(throwing: event.recoverable == true
                    ? QwenRuntimeError.generationInterrupted(message) : QwenRuntimeError.requestFailed(message))
                forget(id, worker: worker)
            } else {
                continuation.yield(event)
                if event.event == "done" { continuation.finish(); forget(id, worker: worker) }
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
            let message = "本机模型进程已退出。\(details.suffix(1000))"
            streams[id]?.finish(throwing: error ?? (resumableRequests.contains(id)
                ? QwenRuntimeError.generationInterrupted(message) : QwenRuntimeError.requestFailed(message)))
            streams[id] = nil; requestModels[id] = nil
            resumableRequests.remove(id)
            requestActivity[id] = nil
        }
        workers[model] = nil
        if worker.process.isRunning { worker.process.terminate() }
    }

    private func send(_ object: [String: Any], to worker: Worker) async throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try await worker.writer.write(data)
    }

    private func pause(_ id: String, timedOut: Bool = false, stalled: Bool = false) async {
        guard let model = requestModels[id], let worker = workers[model] else { return }
        let resumable = resumableRequests.contains(id)
        streams[id]?.finish(throwing: timedOut ? (resumable
            ? QwenRuntimeError.generationInterrupted("本机模型请求超时，已保留已有文字进度。")
            : QwenRuntimeError.requestFailed("本机模型请求超时。")) : CancellationError())
        forget(id, worker: worker)
        if stalled, ProcessInfo.processInfo.systemUptime - worker.lastActivity >= 30 {
            ended(model, workerID: worker.id, error: QwenRuntimeError.generationInterrupted("本机模型进程无响应，已停止，可重新发起请求。"))
            return
        }
        try? await send(["op":resumable ? "pause" : "cancel", "id":id], to: worker)
    }

    func unload(_ model: String) async {
        guard let worker = workers[model], worker.requests.isEmpty else { return }
        try? await send(["op":"shutdown"], to: worker)
        // Only this owned process is retired; an unresponsive helper must not
        // indefinitely block future model selection.
        for _ in 0..<100 {
            if !worker.process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if worker.process.isRunning { worker.process.terminate() }
        if workers[model]?.id == worker.id { workers[model] = nil }
    }

    func generate(model: String, prompt: String, input: String, prefix: String,
                  thinking: Bool, purpose: String, finalBudget: Int, timeout: TimeInterval,
                  thinkingBudget: Int = 16384,
                  inactivityTimeout: TimeInterval? = nil,
                  onUpdate: @escaping @MainActor @Sendable (String) async throws -> Void) async throws -> String {
        let id = UUID().uuidString
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
                        try await send(["op":"ack", "id":id], to: worker)
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
