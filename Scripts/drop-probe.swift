import Foundation
import Darwin

actor ProbeASR {
    let process = Process()
    let input = Pipe()
    let output = Pipe()

    init(worker: String, model: String) throws {
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3.13")
        process.arguments = ["-B", worker, model]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let ready = try Self.readLine(output.fileHandleForReading)
        guard (try JSONSerialization.jsonObject(with: ready) as? [String: Any])?["ready"] as? Bool == true
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    static func readLine(_ handle: FileHandle) throws -> Data {
        var result = Data()
        while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { return result }
            result.append(byte)
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    func transcribe(_ url: URL, enhance: Bool) throws -> ASRTranscription {
        var request = try JSONSerialization.data(withJSONObject: ["path": url.path, "enhance": enhance])
        request.append(10)
        try input.fileHandleForWriting.write(contentsOf: request)
        let row = try JSONSerialization.jsonObject(with: Self.readLine(output.fileHandleForReading)) as! [String: Any]
        PreviewDropProbe.shared.record(row.merging(["event": "asr", "file": url.lastPathComponent,
            "enhance": enhance]) { _, new in new })
        var result = ASRTranscription(text: row["text"] as? String ?? "")
        result.parakeetMeanProbability = row["pk_mean_probability"] as? Double
        result.parakeetMinProbability = row["pk_min_probability"] as? Double
        result.parakeetConfidenceValid = row["pk_confidence_valid"] as? Bool
        return result
    }

    func stop() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("{\"stop\":true}\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }
}

@main
struct DropProbeCLI {
    static func main() async {
        do { try await run() }
        catch {
            print("probe_failed: \(error.localizedDescription)")
            Darwin.exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let asr = try ProbeASR(worker: args[3], model: args[4])
        let pipeline = SpeechPipeline(transcriber: { url, _, enhance, mode in
            if mode == .probe { return ASRTranscription(text: "", languageMode: .probe) }
            return try await asr.transcribe(url, enhance: enhance)
        })
        // Isolate the requested Parakeet comparison; no Qwen model is loaded.
        pipeline.update(profile: QwenModelProfile(asrKey: "parakeet", fallbackASRKey: nil,
            translationModel: "qwen3.5-4b-mlx", shortLabel: "Parakeet probe"))
        let ready = await pipeline.cliProbePrepare()
        guard ready else { try await asr.stop(); throw CocoaError(.featureUnsupported) }
        PreviewDropProbe.shared.record(["event": "begin", "lossless": PreviewDropProbe.shared.lossless,
                                        "file": URL(fileURLWithPath: args[1]).lastPathComponent])
        let started = ProcessInfo.processInfo.systemUptime
        try await pipeline.cliReplay(file: URL(fileURLWithPath: args[1]),
            recordingURL: root.appendingPathComponent("recording.wav"), sessionID: UUID()) { event in
            switch event {
            case .identifiedFinal(let commit):
                PreviewDropProbe.shared.record(["event": "final", "text": commit.text,
                    "start": commit.start, "end": commit.end, "repair": commit.isRepair,
                    "wallFromReplay": ProcessInfo.processInfo.systemUptime - started])
            case .failure(let message): PreviewDropProbe.shared.record(["event": "failure", "error": message])
            case .transcriptionIssue(let start, let end, let message):
                PreviewDropProbe.shared.record(["event": "issue", "start": start, "end": end, "error": message])
            default: break
            }
        }
        await pipeline.stop()
        try await asr.stop()
        PreviewDropProbe.shared.record(["event": "finished", "seconds": ProcessInfo.processInfo.systemUptime - started])
        try PreviewDropProbe.shared.save(root.appendingPathComponent("events.jsonl"))
        print("probe_finished")
    }
}
