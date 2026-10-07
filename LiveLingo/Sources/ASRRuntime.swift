import Darwin
import Foundation
import OSLog

/// The JSON line `qwen_asr_service.py` prints once it is bound.
///
/// The service never prints its request token, so the token only exists inside
/// this process and inside the child's environment.
private struct ASRServiceAnnouncement: Sendable, Decodable {
    let protocolVersion: Int
    let host: String
    let port: Int
    let pid: Int32
    let auth: Bool
    let supervised: Bool
    let modelsRoot: String

    private enum CodingKeys: String, CodingKey {
        case host, port, pid, auth, supervised
        case protocolVersion = "protocol"
        case modelsRoot = "models_root"
    }
}

/// Supervises the ASR service that ships inside the app bundle.
///
/// The service script lives at `Contents/Resources/ASRRuntime/qwen_asr_service.py`
/// and runs on the portable interpreter at
/// `Contents/Resources/ASRRuntime/python/bin/python3`. Every path is derived
/// from the bundle: the model root is passed explicitly with `--models-dir`,
/// the socket binds loopback on a kernel-chosen ephemeral port, and each launch
/// gets its own random request token.
///
/// The runtime never consults `$HOME`, never falls back to the historical fixed
/// port 18765, and never signals a process it did not spawn itself.
actor ASRRuntime {
    static let shared = ASRRuntime()

    /// Created exclusively for one service, never reconstructed from a path.
    /// Refuse cleanup if the root was replaced, moved or is still in use.
    final class OwnedTemporaryDirectory: @unchecked Sendable {
        let url: URL
        private let device: dev_t
        private let inode: ino_t
        private let lock = NSLock()
        private var removed = false

        init(parent: URL = FileManager.default.temporaryDirectory) throws {
            guard parent.isFileURL else {
                throw QwenRuntimeError.requestFailed("内置 ASR 服务无法准备私有临时目录。")
            }
            let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
            let url = parent.appendingPathComponent("LiveLingo-ASR-" + UUID().uuidString, isDirectory: true)
            guard mkdir(url.path, 0o700) == 0 else {
                throw QwenRuntimeError.requestFailed("内置 ASR 服务无法准备私有临时目录。")
            }
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), status.st_uid == getuid() else {
                throw QwenRuntimeError.requestFailed("内置 ASR 服务无法确认私有临时目录归属。")
            }
            self.url = url
            device = status.st_dev
            inode = status.st_ino
        }

        @discardableResult
        func removeAfterExit(_ processExited: Bool) -> Bool {
            guard processExited else { return false }
            return lock.withLock {
                if removed { return true }
                var status = stat()
                if lstat(url.path, &status) != 0 {
                    if errno == ENOENT { removed = true; return true }
                    return false
                }
                guard status.st_dev == device, status.st_ino == inode,
                      status.st_uid == getuid(),
                      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }
                do {
                    try FileManager.default.removeItem(at: url)
                    removed = true
                    return true
                } catch { return false }
            }
        }
    }

    enum StartupFailure: CaseIterable, Sendable {
        case exitedBeforeReady, readinessTimeout, protocolMismatch, processMismatch
        case authorizationMissing, modelDirectoryMismatch, nonLoopbackHost, invalidPort

        fileprivate var message: String {
            switch self {
            case .exitedBeforeReady: return "内置 ASR 服务在报告就绪前退出。"
            case .readinessTimeout: return "内置 ASR 服务在 \(Int(ASRRuntime.readinessTimeout)) 秒内未报告就绪。"
            case .protocolMismatch: return "内置 ASR 服务协议版本不匹配。"
            case .processMismatch: return "内置 ASR 服务的进程标识不匹配。"
            case .authorizationMissing: return "内置 ASR 服务未启用请求令牌，拒绝连接。"
            case .modelDirectoryMismatch: return "内置转写服务使用了不匹配的模型目录。"
            case .nonLoopbackHost: return "内置 ASR 服务绑定了非回环地址。"
            case .invalidPort: return "内置 ASR 服务报告了无效端口。"
            }
        }
    }

    /// A live service the app may talk to.
    struct Endpoint: Sendable, Hashable {
        let baseURL: URL
        let token: String
        /// Only endpoints created by this runtime carry an owned child identity.
        /// An isolated external test endpoint leaves both values nil.
        let runtimeID: UUID?
        let processIdentifier: Int32?

        init(baseURL: URL, token: String, runtimeID: UUID? = nil, processIdentifier: Int32? = nil) {
            self.baseURL = baseURL
            self.token = token
            self.runtimeID = runtimeID
            self.processIdentifier = processIdentifier
        }
    }

    private static let logger = Logger(subsystem: "com.jianhongli.LiveLingo", category: "ASRRuntime")
    /// Must match `READY_PREFIX` in qwen_asr_service.py.
    private static let readyPrefix = "LIVELINGO_ASR_READY"
    /// Must match `PROTOCOL_VERSION` in qwen_asr_service.py.
    private static let protocolVersion = 2
    // A newly signed offline bundle can take longer to load its Python/MLX
    // runtime on first launch. Keep waiting while the supervised child is
    // alive; the failure path below still reports a bounded timeout.
    private static let readinessTimeout: TimeInterval = 90
    private static let exitTimeout: TimeInterval = 5
    private static let logLimit = 16_000

    private var service: Service?
    private var startTask: Task<Endpoint, Error>?
    private var stopTask: Task<Void, Never>?
    private var retiringServiceID: UUID?
    // Only an observed exit of an exact owned endpoint is positive evidence.
    // Bounded history handles callers that still hold a recently retired URL.
    private var exitedEndpoints: [Endpoint] = []

    #if DEBUG
    struct TestConfiguration: Sendable {
        let interpreter: URL
        let script: URL
        let models: URL
        var onChildLaunched: (@Sendable (Process) -> Void)?
        var onCrashCleanup: (@Sendable () async -> Void)?
    }
    private let testConfiguration: TestConfiguration?
    init(testConfiguration: TestConfiguration? = nil) {
        self.testConfiguration = testConfiguration
    }
    #endif

    // MARK: - Public entry points

    /// Returns the endpoint of a running service, starting — or restarting
    /// after a crash — the bundled one when necessary.
    ///
    /// Concurrent callers share a single launch, and cancelling one caller
    /// never cancels that shared launch or the service itself.
    func endpoint() async throws -> Endpoint {
        while true {
            if let stopTask {
                await stopTask.value
                try Task.checkCancellation()
                continue
            }
            try Task.checkCancellation()
            if let service, retiringServiceID == service.id, service.isAlive {
                throw QwenRuntimeError.requestFailed("上一个转写进程尚未退出，任务已保留。")
            }
            if let service, let endpoint = service.endpoint, service.isAlive {
                return endpoint
            }
            if let service {
                // Recheck admission after exit confirmation: another caller
                // may have finished a replacement while this actor yielded.
                Self.logger.error(
                    "ASR service event=exited pid=\(service.processIdentifier)"
                )
                rememberExit(of: service)
                self.service = nil
                service.closePipes()
                retiringServiceID = nil
                if let endpoint = service.endpoint {
                    #if DEBUG
                    if let onCrashCleanup = testConfiguration?.onCrashCleanup { await onCrashCleanup() }
                    #endif
                    await ASRRequestCoordinator.shared.confirmServiceExited(endpoint)
                }
                continue
            }
            _ = try await start()
            // Launch also yields. A stop or replacement must be admitted again
            // before its endpoint can be returned to this caller.
        }
    }

    /// Best-effort start used by the app lifecycle; failures stay in the log
    /// and surface later through the readiness check.
    func warmUp() async {
        do {
            _ = try await endpoint()
        } catch is CancellationError {
            // The view that asked for the warm-up went away. The shared launch
            // is not owned by that caller and continues on its own.
        } catch {
            Self.logger.error("ASR runtime event=warmup_failed")
        }
    }

    /// Stops the supervised service and closes its pipes.
    ///
    /// Safe to call twice and safe while a launch is still in flight: the child
    /// this runtime spawned has its stdin closed first, is waited for with a
    /// bound, and is only then signalled.
    func stop() async {
        if let stopTask { await stopTask.value; return }
        let task = Task { await self.finishStop() }
        stopTask = task
        await task.value
    }

    private func finishStop() async {
        defer { stopTask = nil }
        if let startTask {
            startTask.cancel()
            _ = try? await startTask.value
            self.startTask = nil
        }
        guard let service else { return }
        retiringServiceID = service.id
        await Self.terminate(service)
        // Keep the exact child owned if even SIGKILL has not produced an exit.
        // No replacement endpoint can then be returned as though it were idle.
        guard !service.isAlive else { return }
        rememberExit(of: service)
        self.service = nil
        retiringServiceID = nil
        if let endpoint = service.endpoint {
            await ASRRequestCoordinator.shared.confirmServiceExited(endpoint)
        }
    }

    /// Bounded, synchronous stop for `applicationWillTerminate`, which cannot
    /// await. The child also exits on its own when this process disappears, so
    /// the timeout is only a backstop.
    nonisolated func stopBeforeApplicationExit(timeout: TimeInterval = 4) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await ASRRuntime.shared.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// Whether a supervised service is currently running.
    var isRunning: Bool { service?.isAlive ?? false }

    /// Read-only: querying resources never starts a service or loads weights.
    func resourceState() async -> ASRResourceSnapshot {
        guard let service else {
            return .init(status: startTask == nil ? .stopped : .starting)
        }
        guard let endpoint = service.endpoint else {
            return .init(status: service.isAlive ? (retiringServiceID == service.id ? .retiring : .starting) : .stopped,
                         runtimeID: service.id, processIdentifier: service.processIdentifier)
        }
        guard service.isAlive else {
            rememberExit(of: service)
            await ASRRequestCoordinator.shared.confirmServiceExited(endpoint)
            guard self.service?.id == service.id else {
                return .init(status: .unavailable, diagnostic: "转写服务已切换，等待刷新资源状态。")
            }
            return .init(status: .stopped)
        }
        let snapshot = await ASRRequestCoordinator.shared.resourceState(endpoint: endpoint)
        // An old HTTP health response cannot describe a replacement process.
        guard self.service?.id == service.id, service.isAlive else {
            return .init(status: .unavailable, diagnostic: "转写服务已切换，等待刷新资源状态。")
        }
        if retiringServiceID == service.id {
            return snapshot.withStatus(.retiring)
        }
        return snapshot
    }

    func hasExited(_ endpoint: Endpoint) -> Bool? {
        guard endpoint.runtimeID != nil, let pid = endpoint.processIdentifier, pid > 0 else { return nil }
        if let service, service.endpoint == endpoint {
            if service.isAlive { return false }
            rememberExit(of: service)
            return true
        }
        return exitedEndpoints.contains(endpoint) ? true : nil
    }

    private func rememberExit(of service: Service) {
        guard !service.isAlive else { return }
        service.cleanupTemporaryDirectory()
        guard let endpoint = service.endpoint,
              !exitedEndpoints.contains(endpoint) else { return }
        exitedEndpoints.append(endpoint)
        if exitedEndpoints.count > 256 { exitedEndpoints.removeFirst() }
    }

    // MARK: - Launch

    private func start() async throws -> Endpoint {
        try Task.checkCancellation()
        if let service, retiringServiceID == service.id, service.isAlive {
            throw QwenRuntimeError.requestFailed("上一个转写进程尚未退出，任务已保留。")
        }
        if let service, let endpoint = service.endpoint, service.isAlive { return endpoint }
        if let startTask {
            let endpoint = try await startTask.value
            // The caller may have been cancelled while waiting; the shared
            // launch keeps running and is not owned by this caller.
            try Task.checkCancellation()
            return endpoint
        }
        let task = Task<Endpoint, Error> { try await self.runStart() }
        startTask = task
        let endpoint = try await task.value
        try Task.checkCancellation()
        return endpoint
    }

    /// Owns one launch. The dedupe slot is cleared here — and only here — once
    /// that launch settles, so a cancelled waiter can never start a duplicate.
    private func runStart() async throws -> Endpoint {
        defer { startTask = nil }
        let launched = try await launch()
        service = launched.service
        return launched.endpoint
    }

    private func launch() async throws -> (service: Service, endpoint: Endpoint) {
        let paths: Paths
        #if DEBUG
        if let testConfiguration {
            paths = Paths(interpreter: testConfiguration.interpreter, service: testConfiguration.script,
                          models: testConfiguration.models)
        } else { paths = try Self.resolvePaths() }
        #else
        paths = try Self.resolvePaths()
        #endif
        let token = Self.makeToken()
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let log = LogBuffer()
        let temporaryDirectory = try OwnedTemporaryDirectory()

        process.executableURL = paths.interpreter
        // `--supervised` makes the child exit when this process dies or closes
        // the pipe below; `--port 0` asks the kernel for an ephemeral port.
        process.arguments = [
            paths.service.path,
            "--supervised",
            "--host", "127.0.0.1",
            "--port", "0",
            "--models-dir", paths.models.path,
        ]
        #if DEBUG
        if testConfiguration != nil {
            process.environment = Self.serviceEnvironment(token: token, models: paths.models,
                temporaryDirectory: temporaryDirectory.url, inherited: [:])
        } else {
            process.environment = Self.serviceEnvironment(token: token, models: paths.models,
                temporaryDirectory: temporaryDirectory.url)
        }
        #else
        process.environment = Self.serviceEnvironment(token: token, models: paths.models,
            temporaryDirectory: temporaryDirectory.url)
        #endif
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { finished in
            log.recordExit(status: finished.terminationStatus, reason: finished.terminationReason)
            if !temporaryDirectory.removeAfterExit(true) {
                Self.logger.error("ASR runtime event=temporary_cleanup_failed")
            }
        }

        do {
            try process.run()
        } catch {
            _ = temporaryDirectory.removeAfterExit(!process.isRunning)
            throw QwenRuntimeError.requestFailed("内置 ASR 服务无法启动。")
        }
        #if DEBUG
        testConfiguration?.onChildLaunched?(process)
        #endif

        Self.startReading(standardOutput.fileHandleForReading, into: log, fromStandardError: false)
        Self.startReading(standardError.fileHandleForReading, into: log, fromStandardError: true)

        let service = Service(
            process: process,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError,
            log: log,
            token: token,
            temporaryDirectory: temporaryDirectory
        )

        do {
            let announcement = try await Self.awaitAnnouncement(service)
            let endpoint = try Self.endpoint(from: announcement, service: service, expectedModels: paths.models)
            service.setEndpoint(endpoint)
            Self.logger.notice(
                "ASR service ready pid=\(service.processIdentifier) port=\(announcement.port) supervised=\(announcement.supervised)"
            )
            return (service, endpoint)
        } catch {
            // Never leave a half-started child behind, including on cancellation
            // (which is how `stop()` interrupts a launch in flight).
            await Self.terminate(service)
            if service.isAlive {
                self.service = service
                self.retiringServiceID = service.id
            }
            throw error
        }
    }

    // MARK: - Readiness

    private static func awaitAnnouncement(_ service: Service) async throws -> ASRServiceAnnouncement {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        while true {
            if let announcement = service.log.announcement() {
                return announcement
            }
            if !service.isAlive {
                throw failure(.exitedBeforeReady, service: service)
            }
            if Date() >= deadline {
                throw failure(.readinessTimeout, service: service)
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private static func endpoint(
        from announcement: ASRServiceAnnouncement,
        service: Service,
        expectedModels: URL
    ) throws -> Endpoint {
        guard announcement.protocolVersion == protocolVersion else {
            throw failure(.protocolMismatch, service: service)
        }
        guard announcement.pid == service.processIdentifier else {
            throw failure(.processMismatch, service: service)
        }
        guard announcement.auth && announcement.supervised else {
            throw failure(.authorizationMissing, service: service)
        }
        guard modelDirectoryMatches(announcement.modelsRoot, expected: expectedModels) else {
            throw failure(.modelDirectoryMismatch, service: service)
        }
        let host = announcement.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host == "127.0.0.1" || host == "::1" || host == "localhost" else {
            throw failure(.nonLoopbackHost, service: service)
        }
        guard (1...65_535).contains(announcement.port) else {
            throw failure(.invalidPort, service: service)
        }
        guard let baseURL = URL(string: "http://127.0.0.1:\(announcement.port)") else {
            throw failure(.invalidPort, service: service)
        }
        logger.notice(
            "ASR service event=models_root_verified auth=\(announcement.auth)"
        )
        return Endpoint(baseURL: baseURL, token: service.token,
                        runtimeID: service.id, processIdentifier: service.processIdentifier)
    }

    /// Foundation can preserve a different trailing-slash directory hint when
    /// resolving a symlink. Compare canonical filesystem paths after checking
    /// both are existing directories; URL equality also compares that hint.
    /// No prefix matching or fallback directory is allowed.
    static func modelDirectoryMatches(_ reportedPath: String, expected: URL) -> Bool {
        guard reportedPath.hasPrefix("/"), !reportedPath.utf8.contains(0), expected.isFileURL else { return false }
        let reported = URL(fileURLWithPath: reportedPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let required = expected.standardizedFileURL.resolvingSymlinksInPath()
        var reportedIsDirectory: ObjCBool = false
        var expectedIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: reported.path, isDirectory: &reportedIsDirectory),
              reportedIsDirectory.boolValue,
              FileManager.default.fileExists(atPath: required.path, isDirectory: &expectedIsDirectory),
              expectedIsDirectory.boolValue else { return false }
        return reported.path == required.path
    }

    // MARK: - Teardown

    /// Closes the child's stdin, waits for the supervised exit, and only then
    /// signals it — always the exact process this runtime spawned.
    private static func terminate(_ service: Service) async {
        service.closeStandardInput()
        if await waitForExit(service) {
            service.closePipes()
            return
        }
        if service.isAlive {
            service.process.terminate()
        }
        if await waitForExit(service) {
            service.closePipes()
            return
        }
        if service.isAlive {
            // Last resort; still limited to our own child pid.
            kill(service.processIdentifier, SIGKILL)
        }
        _ = await waitForExit(service)
        service.closePipes()
    }

    private static func waitForExit(_ service: Service) async -> Bool {
        let deadline = Date().addingTimeInterval(exitTimeout)
        while service.isAlive {
            if Date() >= deadline { return false }
            await pause(0.05)
        }
        return true
    }

    /// Cancellation-immune sleep: teardown must finish even when the task that
    /// triggered it was already cancelled (for example a cancelled request).
    private static func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    // MARK: - Bundle paths

    private struct Paths: Sendable {
        let interpreter: URL
        let service: URL
        let models: URL
    }

    /// Resolves the bundled runtime. Nothing here consults `$HOME`: a missing
    /// runtime is a hard, diagnosed failure instead of a silent fallback.
    private static func resolvePaths() throws -> Paths {
        guard let resources = Bundle.main.resourceURL else {
            throw QwenRuntimeError.requestFailed("内置 ASR 运行时不可用：无法定位 App 资源目录。")
        }
        let runtime = resources.appendingPathComponent("ASRRuntime", isDirectory: true)
        let interpreter = runtime.appendingPathComponent("python/bin/python3")
        let service = runtime.appendingPathComponent("qwen_asr_service.py")
        let models = resources.appendingPathComponent("Models", isDirectory: true)

        var missing: [String] = []
        if !FileManager.default.isExecutableFile(atPath: interpreter.path) {
            missing.append("解释器 python/bin/python3")
        }
        if !FileManager.default.isReadableFile(atPath: service.path) {
            missing.append("服务脚本 qwen_asr_service.py")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: models.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            missing.append("模型目录 Models")
        }
        guard missing.isEmpty else {
            throw QwenRuntimeError.requestFailed(
                "内置 ASR 运行时缺失，且不会回退到用户目录：\n" + missing.joined(separator: "\n")
            )
        }
        return Paths(interpreter: interpreter, service: service, models: models)
    }

    /// The child gets an explicit environment. The model root is passed on the
    /// command line and repeated here; the request token travels through the
    /// environment only, so it never appears in `ps` output.
    static func serviceEnvironment(token: String, models: URL, temporaryDirectory: URL,
                                   inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        environment["TMPDIR"] = temporaryDirectory.path
        environment["LIVELINGO_ASR_TOKEN"] = token
        environment["LIVELINGO_ASR_MODELS"] = models.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        // A user-level PYTHONPATH/PYTHONHOME would silently steer the bundled
        // interpreter away from the runtime that shipped with the app.
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        return environment
    }

    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    // MARK: - Diagnostics

    private static func failure(_ reason: StartupFailure, service: Service) -> QwenRuntimeError {
        let error = startupFailure(reason, diagnostics: service.log.diagnostics(),
                                   processIdentifier: service.processIdentifier, running: service.isAlive)
        if case .exitedBeforeReady = reason, let exit = service.exitDescription {
            // Only Foundation's observed numeric exit status may supplement
            // the fixed reason. Captured child output never reaches the UI.
            return .requestFailed(reason.message + "\n退出状态：" + exit)
        }
        return error
    }

    static func startupFailure(_ reason: StartupFailure, diagnostics: (output: String, error: String),
                               processIdentifier: Int32, running: Bool) -> QwenRuntimeError {
        // Captured output is used only for byte counts, never for a free-text error.
        logger.error("ASR runtime event=failed pid=\(processIdentifier) running=\(running) stdout_bytes=\(diagnostics.output.utf8.count) stderr_bytes=\(diagnostics.error.utf8.count)")
        return .requestFailed(reason.message)
    }

    private static func startReading(
        _ handle: FileHandle,
        into log: LogBuffer,
        fromStandardError: Bool
    ) {
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            log.append(data, fromStandardError: fromStandardError)
        }
    }

    // MARK: - Child process state

    /// One supervised child: its pipes are retained from launch until `stop()`.
    private final class Service: @unchecked Sendable {
        let id = UUID()
        let process: Process
        let token: String
        let standardInput: Pipe
        let standardOutput: Pipe
        let standardError: Pipe
        let log: LogBuffer
        let temporaryDirectory: OwnedTemporaryDirectory

        private let lock = NSLock()
        private var storedEndpoint: Endpoint?

        init(
            process: Process,
            standardInput: Pipe,
            standardOutput: Pipe,
            standardError: Pipe,
            log: LogBuffer,
            token: String,
            temporaryDirectory: OwnedTemporaryDirectory
        ) {
            self.process = process
            self.standardInput = standardInput
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.log = log
            self.token = token
            self.temporaryDirectory = temporaryDirectory
        }

        var isAlive: Bool { process.isRunning }

        var processIdentifier: Int32 { process.processIdentifier }

        var endpoint: Endpoint? {
            lock.lock()
            defer { lock.unlock() }
            return storedEndpoint
        }

        func setEndpoint(_ endpoint: Endpoint) {
            lock.lock()
            storedEndpoint = endpoint
            lock.unlock()
        }

        var exitDescription: String? {
            guard !process.isRunning else { return nil }
            switch process.terminationReason {
            case .exit: return "exit code \(process.terminationStatus)"
            case .uncaughtSignal: return "signal \(process.terminationStatus)"
            @unknown default: return "status \(process.terminationStatus)"
            }
        }

        /// Closing the parent's end of the pipe is what asks the supervised
        /// child to exit; the child keeps its own handles until then.
        func closeStandardInput() {
            try? standardInput.fileHandleForWriting.close()
        }

        func closePipes() {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            try? standardInput.fileHandleForWriting.close()
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
            cleanupTemporaryDirectory()
        }

        func cleanupTemporaryDirectory() {
            guard !isAlive else { return }
            if !temporaryDirectory.removeAfterExit(true) {
                ASRRuntime.logger.error("ASR runtime event=temporary_cleanup_failed")
            }
        }
    }

    /// Thread-safe, bounded capture of the child's stdout/stderr.
    private final class LogBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var standardOutput = ""
        private var standardError = ""
        private var cachedAnnouncement: ASRServiceAnnouncement?

        func append(_ data: Data, fromStandardError: Bool) {
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            lock.lock()
            defer { lock.unlock() }
            if fromStandardError {
                standardError = Self.bounded(standardError + chunk)
            } else {
                standardOutput = Self.bounded(standardOutput + chunk)
                if cachedAnnouncement == nil {
                    cachedAnnouncement = Self.announcement(in: standardOutput)
                }
            }
        }

        func announcement() -> ASRServiceAnnouncement? {
            lock.lock()
            defer { lock.unlock() }
            return cachedAnnouncement
        }

        func recordExit(status: Int32, reason: Process.TerminationReason) {
            lock.lock()
            let description: String
            switch reason {
            case .exit: description = "exit code \(status)"
            case .uncaughtSignal: description = "signal \(status)"
            @unknown default: description = "status \(status)"
            }
            standardError = Self.bounded(standardError + "\n[ASR service exited: \(description)]\n")
            lock.unlock()
        }

        func diagnostics() -> (output: String, error: String) {
            lock.lock()
            defer { lock.unlock() }
            return (
                standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        /// Only complete lines are parsed, so a partially delivered ready line
        /// is retried on the next read instead of being cached as invalid.
        private static func announcement(in text: String) -> ASRServiceAnnouncement? {
            guard let lastNewline = text.lastIndex(of: "\n") else { return nil }
            for line in text[text.startIndex...lastNewline].split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(ASRRuntime.readyPrefix + " ") else { continue }
                let json = String(trimmed.dropFirst(ASRRuntime.readyPrefix.count + 1))
                guard let data = json.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode(ASRServiceAnnouncement.self, from: data)
                else { continue }
                return parsed
            }
            return nil
        }

        private static func bounded(_ text: String) -> String {
            guard text.count > ASRRuntime.logLimit else { return text }
            return String(text.suffix(ASRRuntime.logLimit))
        }
    }
}
