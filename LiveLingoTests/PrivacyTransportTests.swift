import Darwin
import Foundation
import XCTest
@testable import LiveLingo

/// Every request is answered in memory, including disallowed destinations.
/// A missed rejection therefore records a test failure without opening a socket.
private final class PrivacyMemoryURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var observed: [URLRequest] = []
    }
    private static let storage = Storage()

    static func reset() { storage.lock.withLock { storage.observed = [] } }
    static var requests: [URLRequest] { storage.lock.withLock { storage.observed } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while body.count < 65_536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBodyStream = nil
            recorded.httpBody = body
        }
        Self.storage.lock.withLock { Self.storage.observed.append(recorded) }
        let payload = recorded.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let thinking = payload?["stream"] as? Bool == false
        let body: Data
        let contentType: String
        if recorded.url?.lastPathComponent == "response-outside-loopback" {
            body = Data()
            contentType = "application/json"
        } else if recorded.url?.lastPathComponent == "health" {
            body = Data(#"{"ok":true,"pid":1234,"protocol":2,"loaded_models":[],"requests":{}}"#.utf8)
            contentType = "application/json"
        } else if thinking {
            body = Data(#"{"choices":[{"text":"A synthetic check.","finish_reason":"stop"}]}"#.utf8)
            contentType = "application/json"
        } else {
            body = Data((
                "data: {\"choices\":[{\"text\":\"模拟译文。\",\"index\":0,\"finish_reason\":\"stop\"}]}\n\n"
                    + "data: [DONE]\n\n"
            ).utf8)
            contentType = "text/event-stream; charset=utf-8"
        }
        let responseURL = recorded.url?.lastPathComponent == "response-outside-loopback"
            ? URL(string: "http://example.invalid/response") : recorded.url
        guard let url = responseURL,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                  httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor PrivacyASRTransportRecorder {
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) throws -> ASRHTTPResult {
        requests.append(request)
        if request.url?.lastPathComponent == "health" {
            return .init(data: Data(#"{"ok":true,"pid":1234,"protocol":2,"loaded_models":[],"requests":{}}"#.utf8),
                         status: 200)
        }
        let response = ["request_id": request.value(forHTTPHeaderField: "X-LiveLingo-Request-ID") ?? "",
                        "model": "0.6b", "text": "A synthetic sentence."]
        return .init(data: try JSONSerialization.data(withJSONObject: response), status: 200)
    }
}

private final class PrivacyRedirectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var destination: URL?

    func record(_ request: URLRequest?) {
        lock.withLock { calls += 1; destination = request?.url }
    }
    var value: (calls: Int, destination: URL?) { lock.withLock { (calls, destination) } }
}

@MainActor
final class PrivacyTransportTests: XCTestCase {
    private let rejectedEndpoints = [
        "http://example.invalid:19191",
        "https://example.invalid:19191",
        "http://127.0.0.1.example.invalid:19191",
        "http://localhost.example.invalid:19191",
        "http://192.0.2.1:19191",
        "http://[::ffff:192.0.2.1]:19191",
        "http://synthetic:secret@127.0.0.1:19191",
        "http://127.0.0.1:19191/#synthetic-secret",
    ]

    func testASRRejectsUnsafeEndpointBeforeSendingAudioOrToken() async throws {
        let audio = try syntheticAudio()
        for address in rejectedEndpoints {
            let recorder = PrivacyASRTransportRecorder()
            let coordinator = ASRRequestCoordinator(confirmationTimeout: 0,
                transport: { try await recorder.send($0) }, observeExit: { _ in false })
            let endpoint = ASRRuntime.Endpoint(baseURL: try XCTUnwrap(URL(string: address)),
                                               token: "synthetic-private-token")
            do {
                _ = try await coordinator.transcribe(endpoint: endpoint, audioURL: audio,
                    modelKey: "0.6b", requestID: "privacy-test")
                XCTFail("Unsafe ASR endpoint was accepted: \(address)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("synthetic-private-token"))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-secret"))
            }
            let requests = await recorder.requests
            XCTAssertTrue(requests.isEmpty, "No audio or token may reach the transport for \(address)")
        }
    }

    func testASRHealthRejectsUnsafeEndpointBeforeSendingToken() async throws {
        for address in rejectedEndpoints {
            let recorder = PrivacyASRTransportRecorder()
            let coordinator = ASRRequestCoordinator(transport: { try await recorder.send($0) },
                                                     observeExit: { _ in false })
            let endpoint = ASRRuntime.Endpoint(baseURL: try XCTUnwrap(URL(string: address)),
                                               token: "synthetic-private-token")
            let snapshot = await coordinator.resourceState(endpoint: endpoint)
            XCTAssertEqual(snapshot.status, .unavailable, address)
            let requests = await recorder.requests
            XCTAssertTrue(requests.isEmpty, address)
        }
    }

    func testASRPreservesLoopbackAudioHeadersAndURLBytes() async throws {
        let recorder = PrivacyASRTransportRecorder()
        let coordinator = ASRRequestCoordinator(transport: { try await recorder.send($0) },
                                                 observeExit: { _ in false })
        let endpoint = ASRRuntime.Endpoint(baseURL: URL(string: "http://127.0.0.1:19191")!,
                                           token: "synthetic-private-token")
        let audio = try syntheticAudio()
        let output = try await coordinator.transcribe(endpoint: endpoint, audioURL: audio,
            modelKey: "0.6b", requestID: "privacy-test")
        XCTAssertEqual(output, "A synthetic sentence.")
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:19191/transcribe?model=0.6b&enhance=off")
        XCTAssertEqual(request.httpBody, Data([82, 73, 70, 70, 0, 0, 0, 0]))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-LiveLingo-Token"), "synthetic-private-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-LiveLingo-Request-ID"), "privacy-test")
    }

    func testStreamingCompletionRejectsUnsafeEndpointBeforeSendingPrompt() async throws {
        let configuration = memoryConfiguration()
        for address in rejectedEndpoints {
            PrivacyMemoryURLProtocol.reset()
            do {
                _ = try await QwenTranslationClient.streamingCompletion(
                    "Synthetic private input.", modelName: "synthetic-model", systemPrompt: "Translate.",
                    maximumOutputTokens: 32, timeout: 1,
                    endpoint: try XCTUnwrap(URL(string: address + (address.contains("#") ? "" : "/completion"))),
                    sessionConfiguration: configuration)
                XCTFail("Unsafe completion endpoint was accepted: \(address)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("Synthetic private input."))
                XCTAssertFalse(error.localizedDescription.contains("synthetic-secret"))
            }
            XCTAssertTrue(PrivacyMemoryURLProtocol.requests.isEmpty, address)
        }
    }

    func testThinkingCompletionRejectsUnsafeEndpointBeforeSendingPrompt() async throws {
        let configuration = memoryConfiguration()
        for address in rejectedEndpoints {
            PrivacyMemoryURLProtocol.reset()
            do {
                _ = try await QwenTranslationClient.boundedThinkingTranslation(
                    "Synthetic private input.", modelName: "synthetic-model", systemPrompt: "Translate.",
                    endpoint: try XCTUnwrap(URL(string: address + (address.contains("#") ? "" : "/completion"))),
                    sessionConfiguration: configuration)
                XCTFail("Unsafe thinking endpoint was accepted: \(address)")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("Synthetic private input."))
            }
            XCTAssertTrue(PrivacyMemoryURLProtocol.requests.isEmpty, address)
        }
    }

    func testLoopbackCompletionPreservesSyntheticChineseOutputAndPromptBytes() async throws {
        let configuration = memoryConfiguration()
        let endpoint = URL(string: "http://127.0.0.1:19191/completion")!
        let input = "Synthetic private input."
        let systemPrompt = "Translate."
        let output = try await QwenTranslationClient.streamingCompletion(input,
            modelName: "synthetic-model", systemPrompt: systemPrompt,
            maximumOutputTokens: 32, timeout: 1, endpoint: endpoint, sessionConfiguration: configuration)
        XCTAssertEqual(output, "模拟译文。")
        let request = try XCTUnwrap(PrivacyMemoryURLProtocol.requests.first)
        XCTAssertEqual(request.url, endpoint)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let expected = try QwenTranslationClient.completionPrompt(input: input, systemPrompt: systemPrompt, thinking: false)
        XCTAssertEqual((payload["prompt"] as? String).map { Array($0.utf8) }, Array(expected.utf8))
        XCTAssertEqual(payload["model"] as? String, "synthetic-model")
        XCTAssertEqual(payload["stream"] as? Bool, true)
    }

    func testLoopbackThinkingCompletionRetainsBothMemoryHTTPStages() async throws {
        let configuration = memoryConfiguration()
        let endpoint = URL(string: "http://127.0.0.1:19191/completion")!
        let output = try await QwenTranslationClient.boundedThinkingTranslation(
            "Synthetic input.", modelName: "synthetic-model", systemPrompt: "Translate.", endpoint: endpoint,
            sessionConfiguration: configuration)
        XCTAssertEqual(output, "模拟译文。")
        XCTAssertEqual(PrivacyMemoryURLProtocol.requests.count, 2)
        XCTAssertTrue(PrivacyMemoryURLProtocol.requests.allSatisfy { $0.url == endpoint })
    }

    // Source guards additionally cover the private production entry points.
    func testASRDoesNotUseSharedURLSession() throws {
        let coordinator = try source("ResourceScheduling.swift")
        let qwen = try source("QwenRuntime.swift")
        let asr = try XCTUnwrap(qwen.components(separatedBy: "enum QwenASRClient {").last?
            .components(separatedBy: "enum QwenTranslationClient {").first)
        XCTAssertFalse(coordinator.contains("URLSession.shared"))
        XCTAssertFalse(asr.contains("URLSession.shared"))
    }

    func testASROverrideIsOnlyCompiledForDebugOrCLI() throws {
        let qwen = try source("QwenRuntime.swift")
        let override = try XCTUnwrap(qwen.range(of: "private static var endpointOverride"))
        let resolver = try XCTUnwrap(qwen.range(of: "private static func resolveService", range: override.lowerBound..<qwen.endIndex))
        let implementation = String(qwen[override.lowerBound..<resolver.lowerBound])
        XCTAssertTrue(implementation.contains("#if DEBUG || LIVELINGO_CLI"))
    }

    func testHandshakeFailureDoesNotReturnCapturedOutput() throws {
        let runtime = try source("ASRRuntime.swift")
        XCTAssertFalse(runtime.contains(#"lines.append("stderr：\n\(captured.error)")"#))
        XCTAssertFalse(runtime.contains(#"lines.append("stdout：\n\(captured.output)")"#))
        XCTAssertFalse(runtime.contains(#"非回环地址：\(announcement.host)"#))
    }

    func testASRChildReceivesAnOwnedTemporaryDirectory() throws {
        let runtime = try source("ASRRuntime.swift")
        XCTAssertTrue(runtime.contains(#"environment["TMPDIR"]"#))
    }

    func testSessionHasNoProxyCookieCacheOrCredentialStorage() throws {
        let configuration = memoryConfiguration()
        configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "example.invalid"]
        let session = LoopbackHTTPTransport.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        XCTAssertTrue(session.delegate is LoopbackHTTPTransport.RedirectDelegate)
        let hardened = session.configuration
        XCTAssertNil(hardened.urlCache)
        XCTAssertNil(hardened.httpCookieStorage)
        XCTAssertNil(hardened.urlCredentialStorage)
        XCTAssertFalse(hardened.httpShouldSetCookies)
        XCTAssertEqual(hardened.requestCachePolicy, .reloadIgnoringLocalCacheData)
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            XCTAssertEqual(hardened.connectionProxyDictionary?[key] as? Int, 0, key)
        }
        XCTAssertEqual(configuration.connectionProxyDictionary?["HTTPEnable"] as? Int, 1)
        XCTAssertEqual(hardened.protocolClasses?.count, 1)
        XCTAssertEqual(hardened.protocolClasses?.first.map { ObjectIdentifier($0) },
                       ObjectIdentifier(PrivacyMemoryURLProtocol.self))
    }

    func testDelegateRejectsEveryRedirectIncludingLoopback() throws {
        let session = LoopbackHTTPTransport.makeSession(configuration: memoryConfiguration())
        defer { session.invalidateAndCancel() }
        let delegate = try XCTUnwrap(session.delegate as? LoopbackHTTPTransport.RedirectDelegate)
        let originalURL = URL(string: "http://127.0.0.1:19191/transcribe")!
        var original = URLRequest(url: originalURL)
        original.httpMethod = "POST"
        original.httpBody = Data("synthetic-private-audio".utf8)
        original.setValue("synthetic-private-token", forHTTPHeaderField: "X-LiveLingo-Token")
        let task = session.dataTask(with: original) // Suspended; it is never resumed.
        for status in [301, 302, 303, 307, 308] {
            for address in ["http://127.0.0.1:19191/another-route", "http://example.invalid/transcribe"] {
                var redirected = original
                redirected.url = try XCTUnwrap(URL(string: address))
                let response = try XCTUnwrap(HTTPURLResponse(url: originalURL, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Location": address]))
                let result = PrivacyRedirectResult()
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                    newRequest: redirected) { result.record($0) }
                XCTAssertEqual(result.value.calls, 1)
                XCTAssertNil(result.value.destination, "Neither loopback nor remote redirects may replay audio")
            }
        }
        XCTAssertTrue(PrivacyMemoryURLProtocol.requests.isEmpty)
    }

    func testLoopbackValidationPinsLocalhostWithoutChangingPathOrQuery() throws {
        for address in ["http://127.0.0.1:19191/health?synthetic=1", "http://[::1]:19191/health",
                        "https://127.0.0.1/health"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertEqual(try LoopbackHTTPTransport.loopbackURL(url), url)
        }
        let localhost = URL(string: "http://localhost:19191/health?synthetic=1")!
        XCTAssertEqual(try LoopbackHTTPTransport.loopbackURL(localhost).absoluteString,
                       "http://127.0.0.1:19191/health?synthetic=1")
        for address in rejectedEndpoints + ["ftp://127.0.0.1:19191/health", "file:///synthetic", "http://127.0.0.1:0/health"] {
            XCTAssertThrowsError(try LoopbackHTTPTransport.loopbackURL(try XCTUnwrap(URL(string: address))))
        }
    }

    func testDedicatedTransportRejectsUnsafeTargetsBeforeProtocolLoads() async throws {
        let session = LoopbackHTTPTransport.makeSession(configuration: memoryConfiguration())
        defer { session.invalidateAndCancel() }
        for address in rejectedEndpoints {
            var request = URLRequest(url: try XCTUnwrap(URL(string: address)))
            request.httpBody = Data("synthetic-private-audio".utf8)
            request.setValue("synthetic-private-token", forHTTPHeaderField: "X-LiveLingo-Token")
            do {
                _ = try await LoopbackHTTPTransport.data(for: request, session: session)
                XCTFail("Unsafe transport target was accepted")
            } catch {}
        }
        XCTAssertTrue(PrivacyMemoryURLProtocol.requests.isEmpty)
    }

    func testDedicatedTransportAcceptsHealthEntirelyInMemory() async throws {
        let session = LoopbackHTTPTransport.makeSession(configuration: memoryConfiguration())
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://localhost:19191/health")!)
        request.setValue("synthetic-private-token", forHTTPHeaderField: "X-LiveLingo-Token")
        let (data, response) = try await LoopbackHTTPTransport.data(for: request, session: session)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Any] != nil, true)
        XCTAssertEqual(PrivacyMemoryURLProtocol.requests.count, 1)
        XCTAssertEqual(PrivacyMemoryURLProtocol.requests.first?.url?.host, "127.0.0.1")
        XCTAssertEqual(PrivacyMemoryURLProtocol.requests.first?.value(forHTTPHeaderField: "X-LiveLingo-Token"),
                       "synthetic-private-token")
    }

    func testTransportRejectsAResponseClaimingANonLoopbackFinalURL() async throws {
        let session = LoopbackHTTPTransport.makeSession(configuration: memoryConfiguration())
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:19191/response-outside-loopback")!)
        do {
            _ = try await LoopbackHTTPTransport.data(for: request, session: session)
            XCTFail("A non-loopback final URL was accepted")
        } catch QwenRuntimeError.requestFailed {} catch { XCTFail("Unexpected final URL rejection") }
        XCTAssertEqual(PrivacyMemoryURLProtocol.requests.count, 1)
    }

    func testHandshakeFailureUsesOnlyFixedReasonsForSyntheticCapturedOutput() {
        let privateOutput = "SYNTHETIC_CLASSROOM_STDOUT /synthetic/private-recording.wav synthetic-private-token"
        let privateError = "SYNTHETIC_CLASSROOM_STDERR /synthetic/private-notes.txt synthetic-private-token"
        for reason in ASRRuntime.StartupFailure.allCases {
            let error = ASRRuntime.startupFailure(reason, diagnostics: (privateOutput, privateError),
                                                 processIdentifier: 1234, running: false)
            XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_CLASSROOM"))
            XCTAssertFalse(error.localizedDescription.contains("/synthetic/"))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-token"))
            let empty = ASRRuntime.startupFailure(reason, diagnostics: ("", ""),
                                                 processIdentifier: 5678, running: true)
            XCTAssertEqual(error.localizedDescription, empty.localizedDescription)
        }
    }

    func testPrivateTemporaryRootIsUniqueAndCleanupRequiresExit() throws {
        let parent = try syntheticRoot()
        let first = try ASRRuntime.OwnedTemporaryDirectory(parent: parent)
        let second = try ASRRuntime.OwnedTemporaryDirectory(parent: parent)
        XCTAssertNotEqual(first.url, second.url)
        let mode = try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let firstAudio = first.url.appendingPathComponent("synthetic.wav")
        let secondAudio = second.url.appendingPathComponent("synthetic.wav")
        try Data("synthetic-audio-1".utf8).write(to: firstAudio)
        try Data("synthetic-audio-2".utf8).write(to: secondAudio)
        XCTAssertFalse(first.removeAfterExit(false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAudio.path))
        XCTAssertTrue(first.removeAfterExit(true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try Data(contentsOf: secondAudio), Data("synthetic-audio-2".utf8))
        XCTAssertTrue(first.removeAfterExit(true))
        XCTAssertTrue(second.removeAfterExit(true))
    }

    func testPrivateTemporaryCleanupDoesNotFollowAReplacedRootSymlink() throws {
        let parent = try syntheticRoot()
        let owned = try ASRRuntime.OwnedTemporaryDirectory(parent: parent)
        let other = try ASRRuntime.OwnedTemporaryDirectory(parent: parent)
        let sentinel = other.url.appendingPathComponent("synthetic.txt")
        try Data("synthetic-retained".utf8).write(to: sentinel)
        try FileManager.default.moveItem(at: owned.url, to: parent.appendingPathComponent("retained-original"))
        try FileManager.default.createSymbolicLink(at: owned.url, withDestinationURL: other.url)
        XCTAssertFalse(owned.removeAfterExit(true))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("synthetic-retained".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.url.path))
    }

    func testPrivateTemporaryCleanupPreservesAReplacementDirectory() throws {
        let parent = try syntheticRoot()
        let owned = try ASRRuntime.OwnedTemporaryDirectory(parent: parent)
        try FileManager.default.moveItem(at: owned.url, to: parent.appendingPathComponent("retained-original"))
        try FileManager.default.createDirectory(at: owned.url, withIntermediateDirectories: false)
        let sentinel = owned.url.appendingPathComponent("synthetic.txt")
        try Data("synthetic-retained".utf8).write(to: sentinel)
        XCTAssertFalse(owned.removeAfterExit(true))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("synthetic-retained".utf8))
    }

    func testChildEnvironmentPinsTMPDIRAndOfflineSettingsUsingOnlySyntheticValues() throws {
        let parent = try syntheticRoot()
        let owned = try ASRRuntime.OwnedTemporaryDirectory(parent: parent)
        let models = parent.appendingPathComponent("synthetic-models", isDirectory: true)
        let result = ASRRuntime.serviceEnvironment(token: "synthetic-private-token", models: models,
            temporaryDirectory: owned.url,
            inherited: ["TMPDIR": "/synthetic/previous-temp", "PYTHONPATH": "/synthetic/python",
                        "PYTHONHOME": "/synthetic/home", "SYNTHETIC_PRESERVED": "yes"])
        XCTAssertEqual(result["TMPDIR"], owned.url.path)
        XCTAssertEqual(result["LIVELINGO_ASR_TOKEN"], "synthetic-private-token")
        XCTAssertEqual(result["LIVELINGO_ASR_MODELS"], models.path)
        XCTAssertEqual(result["SYNTHETIC_PRESERVED"], "yes")
        XCTAssertEqual(result["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(result["TRANSFORMERS_OFFLINE"], "1")
        XCTAssertEqual(result["HF_HUB_DISABLE_TELEMETRY"], "1")
        XCTAssertNil(result["PYTHONPATH"])
        XCTAssertNil(result["PYTHONHOME"])
        XCTAssertTrue(owned.removeAfterExit(true))
    }

    private func memoryConfiguration() -> URLSessionConfiguration {
        PrivacyMemoryURLProtocol.reset()
        addTeardownBlock { PrivacyMemoryURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyMemoryURLProtocol.self]
        return configuration
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent("LiveLingo/Sources/" + name), encoding: .utf8)
    }

    private func syntheticRoot() throws -> URL {
        let temporary = TestFixtureDirectory.root.resolvingSymlinksInPath()
        let root = temporary.appendingPathComponent("LiveLingo-Test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func syntheticAudio() throws -> URL {
        let root = try syntheticRoot()
        let audio = root.appendingPathComponent("synthetic.wav")
        try Data([82, 73, 70, 70, 0, 0, 0, 0]).write(to: audio)
        return audio
    }
}
