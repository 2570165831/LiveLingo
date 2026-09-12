import Foundation

// Compile alongside QwenRuntime.swift and TranscriptSegment.swift. The mock
// binds a random loopback port and never contacts the installed model service.
@main
struct QwenStreamingChecks {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    final class Updates {
        var values: [String] = []
        var dates: [Date] = []
        func record(_ text: String) {
            values.append(text)
            dates.append(Date())
        }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(description: message) }
    }

    static func event(_ text: String, reason: String? = nil) throws -> String {
        let choice: [String: Any] = ["text": text, "index": 0, "finish_reason": reason as Any? ?? NSNull()]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self)
    }

    static func parserChecks() throws {
        let thinkingPrompt = try QwenTranslationClient.completionPrompt(input: "Hello", systemPrompt: "Translate", thinking: true)
        try require(thinkingPrompt.hasSuffix("<|im_start|>assistant\n<think>\n"), "Thinking prompt must leave reasoning open")
        for split in 0..."</think>".count {
            var thinking = QwenCompletionStreamState(thinking: true)
            let hidden = try thinking.consume(event("private analysis " + "</think>".prefix(split)))
            try require(hidden == nil, "Reasoning appeared as translation")
            let body = try thinking.consume(event(String("</think>".dropFirst(split)) + "\n译文。", reason: "stop"))
            try require(body == "译文。", "Split reasoning delimiter damaged final text")
            _ = try thinking.consume("[DONE]")
            let final = try thinking.result()
            try require(final == "译文。", "Reasoning included in final result")
        }
        var unfinishedThinking = QwenCompletionStreamState(thinking: true)
        _ = try unfinishedThinking.consume(event("unfinished reasoning", reason: "stop"))
        _ = try unfinishedThinking.consume("[DONE]")
        do {
            _ = try unfinishedThinking.result()
            throw CheckFailure(description: "Reasoning without final answer accepted")
        } catch is QwenRuntimeError { }
        print("PASS thinking: open template, reasoning hidden across every delimiter split, missing final rejected")
        var parser = QwenSSEParser()
        var state = QwenCompletionStreamState()
        var updates: [String] = []
        let first = "{\"choices\":[\n{\"text\":\"你好 α 😀\",\"index\":0,\"finish_reason\":null}]}"
        let stream = "\u{FEFF}: keepalive\r\nevent: message\r\ndata: "
            + first.replacingOccurrences(of: "\n", with: "\r\ndata: ")
            + "\r\n\r\ndata: " + (try event("，世界。", reason: "stop"))
            + "\r\rdata: [DONE]\n\n"
        for byte in stream.utf8 {
            if let frame = try parser.consume(byte), let partial = try state.consume(frame) {
                updates.append(partial)
            }
        }
        let parsedResult = try state.result()
        try require(parsedResult == "你好 α 😀，世界。", "Unicode/SSE multiline result")
        try require(updates == ["你好 α 😀", "你好 α 😀，世界。"], "Cumulative incremental updates")

        for marker in ["<think>", "</think>", "<|im_start|>", "<|im_end|>", "<|endoftext|>"] {
            for split in 1..<marker.count {
                var blocked = QwenCompletionStreamState()
                let prefix = try blocked.consume(event("正文" + marker.prefix(split)))
                try require(prefix == "正文", "Control prefix leaked: \(marker), \(split)")
                do {
                    _ = try blocked.consume(event(String(marker.dropFirst(split))))
                    throw CheckFailure(description: "Control marker accepted: \(marker)")
                } catch is QwenRuntimeError { }
            }
        }
        var invalidUTF8 = QwenSSEParser()
        _ = try invalidUTF8.consume(0xFF)
        do {
            _ = try invalidUTF8.consume(10)
            throw CheckFailure(description: "Invalid UTF-8 accepted")
        } catch is QwenRuntimeError { }
        print("PASS parser: split UTF-8, BOM, CR/LF, multiline data, cumulative output, all control-marker split points")
    }

    @MainActor
    static func main() async throws {
        try parserChecks()
        let evidenceRoot = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : FileManager.default.temporaryDirectory.appending(path: "qwen-streaming-checks", directoryHint: .isDirectory)
        let work = evidenceRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", serverScript, work.path]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var portLine = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            guard !byte.isEmpty else { throw CheckFailure(description: "Mock server failed to start") }
            if byte.first == 10 { break }
            portLine.append(byte)
        }
        guard let port = Int(String(decoding: portLine, as: UTF8.self)) else {
            throw CheckFailure(description: "Missing mock server port")
        }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let updates = Updates()
        let result = try await complete(base.appending(path: "good")) { text in updates.record(text) }
        let finishedAt = try String(contentsOf: work.appending(path: "good-finished.txt"), encoding: .utf8)
        try require(result == "你好，世界。", "Transport final result")
        try require(updates.values == ["你好", "你好，世界。"], "Transport cumulative partials")
        try require(updates.dates[0].timeIntervalSince1970 < Double(finishedAt)!, "Partial arrived only after final")
        print("PASS transport: partial callback before completion, full stop + DONE result")

        for path in ["length", "disconnect", "missing-done", "missing-stop", "empty", "error", "http-error", "wrong-type", "bad-json", "control"] {
            do {
                _ = try await complete(base.appending(path: path))
                throw CheckFailure(description: "Invalid stream accepted: \(path)")
            } catch is CheckFailure { throw CheckFailure(description: "Invalid stream accepted: \(path)") }
            catch { print("PASS rejects \(path): \(error.localizedDescription)") }
        }

        let cancelledUpdates = Updates()
        let request = Task {
            try await complete(base.appending(path: "stall")) { text in cancelledUpdates.record(text) }
        }
        let readyDeadline = Date().addingTimeInterval(5)
        while cancelledUpdates.values.isEmpty, Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(cancelledUpdates.values == ["正在生成"], "No headers/body before cancellation test")
        let cancellationAt = Date()
        request.cancel()
        do {
            _ = try await request.value
            throw CheckFailure(description: "Cancelled generation returned success")
        } catch is CancellationError { }
        let closed = work.appending(path: "stall-closed.txt")
        let closeDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: closed.path), Date() < closeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(FileManager.default.fileExists(atPath: closed.path), "Cancelling after headers left socket open")
        let cancellationSeconds = Date().timeIntervalSince(cancellationAt)
        try require(cancelledUpdates.values == ["正在生成"], "Update after cancellation")
        print("PASS cancellation: request throws CancellationError, server observed socket EOF in \(cancellationSeconds) seconds")

        let survivor = try await complete(base.appending(path: "good"))
        try require(survivor == "你好，世界。", "Cancellation affected other sessions")
        let payloads = try String(contentsOf: work.appending(path: "requests.jsonl"), encoding: .utf8)
        for line in payloads.split(separator: "\n") {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            try require(request["stream"] as? Bool == true, "Non-streaming request")
            try require(request["max_tokens"] as? Int == 160, "Token limit changed")
            try require(request["temperature"] as? Int == 0, "Temperature changed")
            let expectedPrompt = try QwenTranslationClient.nonThinkingPrompt(input: "Hello", systemPrompt: "Translate")
            try require(request["prompt"] as? String == expectedPrompt, "Non-thinking prompt changed")
        }
        print("PASS request contract and independent session after cancellation")
        let preciseUpdates = Updates()
        let precise = try await QwenTranslationClient.streamingCompletion(
            "Hello", modelName: QwenModelProfile.highQuality.translationModel,
            systemPrompt: "Translate", maximumOutputTokens: 8192, timeout: 5,
            thinking: true, endpoint: base.appending(path: "thinking"),
            onUpdate: { preciseUpdates.record($0) }
        )
        try require(precise == "最终译文。" && preciseUpdates.values == ["最终译文。"], "Thinking transport leaked reasoning")
        let updatedPayloads = try String(contentsOf: work.appending(path: "requests.jsonl"), encoding: .utf8)
        let preciseRequest = try JSONSerialization.jsonObject(with: Data(updatedPayloads.split(separator: "\n").last!.utf8)) as! [String: Any]
        try require(preciseRequest["temperature"] as? Double == 1.0, "Thinking used greedy decoding")
        try require(preciseRequest["top_p"] as? Double == 0.95 && preciseRequest["presence_penalty"] as? Double == 1.5, "Thinking sampling changed")
        try require(preciseRequest["max_tokens"] as? Int == 8192, "Thinking budget changed")
        try require((preciseRequest["prompt"] as? String)?.hasSuffix("<|im_start|>assistant\n<think>\n") == true, "Thinking prompt was closed")
        print("PASS thinking request sampling, budget, template and final-only transport")
        let bounded = try await QwenTranslationClient.boundedThinkingTranslation(
            "Hello", modelName: QwenModelProfile.highQuality.translationModel,
            systemPrompt: "Translate", endpoint: base.appending(path: "bounded")
        )
        try require(bounded == "预算译文。", "Bounded thinking failed")
        let boundedLines = try String(contentsOf: work.appending(path: "requests.jsonl"), encoding: .utf8).split(separator: "\n").suffix(2)
        let boundedRequests = try boundedLines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        try require(boundedRequests[0]["max_tokens"] as? Int == 512, "Reasoning budget changed")
        try require(boundedRequests[1]["max_tokens"] as? Int == 2048, "Final output budget changed")
        try require(boundedRequests.allSatisfy { $0["model"] as? String == QwenModelProfile.highQuality.translationModel }, "Bounded thinking changed model")
        let continued = boundedRequests[1]["prompt"] as! String
        try require(continued.contains("mock reasoning") && continued.hasSuffix("</think>\n\n"), "Reasoning was not retained in continuation")
        for path in ["bounded-invalid", "bounded-final-length"] {
            do {
                _ = try await QwenTranslationClient.boundedThinkingTranslation("Hello", modelName: "mock", systemPrompt: "Translate", endpoint: base.appending(path: path))
                throw CheckFailure(description: "Invalid bounded result accepted: \(path)")
            } catch is QwenRuntimeError { }
        }
        print("PASS bounded thinking retains reasoning and model; final truncation and invalid reasoning rejected")
        print("Evidence: \(work.path)")
        print("ALL QWEN STREAMING CHECKS PASSED")
    }

    static func complete(
        _ endpoint: URL,
        onUpdate: (@MainActor @Sendable (String) async -> Void)? = nil
    ) async throws -> String {
        try await QwenTranslationClient.streamingCompletion(
            "Hello", modelName: QwenModelProfile.highQuality.translationModel,
            systemPrompt: "Translate", maximumOutputTokens: 160, timeout: 5,
            endpoint: endpoint, onUpdate: onUpdate
        )
    }

    static let serverScript = #"""
import http.server, json, pathlib, socket, sys, time
root = pathlib.Path(sys.argv[1])
def event(text='', reason=None):
    return ('data: ' + json.dumps({'choices': [{'index': 0, 'text': text, 'finish_reason': reason}]}, ensure_ascii=False) + '\n\n').encode()
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        with (root / 'requests.jsonl').open('a') as log: log.write(body.decode() + '\n')
        path = self.path.strip('/')
        if path.startswith('bounded') and not json.loads(body).get('stream'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.close_connection = True
            self.wfile.write(json.dumps({'choices':[{'text':'<|im_start|>' if path == 'bounded-invalid' else 'mock reasoning','finish_reason':'length'}]}).encode())
            return
        self.send_response(503 if path == 'http-error' else 200)
        self.send_header('Content-Type', 'application/json' if path in ('http-error', 'wrong-type') else 'text/event-stream; charset=utf-8')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        def send(data): self.wfile.write(data); self.wfile.flush()
        try:
            if path == 'http-error': return send(b'{"error":{"message":"mock unavailable"}}')
            if path.startswith('bounded'):
                return send(event('预算译文。', 'length' if path == 'bounded-final-length' else 'stop') + b'data: [DONE]\n\n')
            if path == 'thinking':
                send(event('private analysis</thi'))
                return send(event('nk>\n最终译文。', 'stop') + b'data: [DONE]\n\n')
            if path == 'wrong-type': return send(b'{"choices":[]}')
            if path == 'bad-json': return send(b'data: {bad}\n\n')
            if path == 'error': return send(b'data: {"error":{"message":"mock stream failure"}}\n\n')
            if path == 'control':
                send(event('<thi')); time.sleep(.05); return send(event('nk>hidden', 'stop') + b'data: [DONE]\n\n')
            if path == 'empty': return send(event('', 'stop') + b'data: [DONE]\n\n')
            if path == 'length': return send(event('truncated', 'length') + b'data: [DONE]\n\n')
            if path == 'missing-stop': return send(event('unfinished') + b'data: [DONE]\n\n')
            if path == 'missing-done': return send(event('unfinished', 'stop'))
            if path == 'disconnect': return send(event('unfinished'))
            if path == 'stall':
                send(event('正在生成'))
                self.connection.settimeout(.1)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        if not self.connection.recv(1):
                            (root / 'stall-closed.txt').write_text(str(time.time()))
                            return
                    except socket.timeout: pass
                return
            for byte in event('你好'): send(bytes([byte]))
            time.sleep(.2)
            (root / 'good-finished.txt').write_text(str(time.time()))
            send(event('，世界。', 'stop') + b'data: [DONE]\n\n')
        except (BrokenPipeError, ConnectionResetError):
            if path == 'stall': (root / 'stall-closed.txt').write_text(str(time.time()))
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
"""#
}
