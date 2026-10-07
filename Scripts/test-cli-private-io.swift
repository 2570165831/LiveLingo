import Foundation
import Darwin

/// Tests only file creation and isolated state; never starts model workers.
@main struct CLIPrivateIOTests {
    enum Failure: Error { case invalidArguments }

    static func hasACL(_ path: URL) throws -> Bool {
        guard let acl = acl_get_file(path.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw Failure.invalidArguments
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
    }

    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.invalidArguments }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw Failure.invalidArguments }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read,write,execute,readattr,readextattr,readsecurity,file_inherit,directory_inherit", root.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.invalidArguments }
        var results: [String: Bool] = [:]
        let body = root.appendingPathComponent("synthetic-body.jsonl")
        let handle = try LiveLingoCLI.createPrivateFile(body)
        try handle.write(contentsOf: Data("synthetic translation".utf8))
        try handle.close()
        results["new_cli_body_removes_inherited_acl"] = try !hasACL(body)
        // Clear only test routing overrides; never display their values.
        for key in ["LIVELINGO_ASR_ENDPOINT", "LIVELINGO_ASR_TOKEN", "LIVELINGO_MLX_PYTHON",
                    "LIVELINGO_MLX_WORKER", "LIVELINGO_MLX_MODELS"] { unsetenv(key) }
        let run = try LiveLingoCLI.configureIsolation(output: root.appendingPathComponent("run"))
        let folders = [run, run.appendingPathComponent(".cli-runtime"),
                       run.appendingPathComponent(".cli-runtime/data"),
                       run.appendingPathComponent(".cli-runtime/checkpoints")]
        results["new_cli_model_state_removes_inherited_acl"] = try folders.allSatisfy { try !hasACL($0) }
        let before = try Data(contentsOf: body)
        do { _ = try LiveLingoCLI.createPrivateFile(body); results["existing_cli_body_is_preserved"] = false }
        catch { results["existing_cli_body_is_preserved"] = try Data(contentsOf: body) == before }
        let summary = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        FileHandle.standardOutput.write(summary)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(results.values.allSatisfy { $0 } ? 0 : 1)
    }
}
