import Darwin
import Foundation

@main
enum SandboxProbe {
    struct Check: Codable {
        let name: String
        let passed: Bool
        let detail: String?
    }
    struct Result: Encodable {
        let version = 1
        let bundle_id: String
        let passed: Bool
        let checks: [Check]
    }
    enum ProbeError: Error { case assertion(String) }

    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeError.assertion(message) }
    }
    static func expectUnsafePath(_ body: () throws -> Void) throws {
        do { try body() }
        catch SensitiveFileIO.Failure.unsafePath { return }
        throw ProbeError.assertion("unsafe path was accepted")
    }
    static func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }
    static func root(_ location: String) -> URL {
        let fm = FileManager.default
        let base = location == "tmp" ? fm.temporaryDirectory : fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("SandboxProbeCases", isDirectory: true)
    }
    static func sandboxIdentity() throws {
        let id = Bundle.main.bundleIdentifier ?? ""
        try require(id.hasPrefix("com.jianhongli.LiveLingo.sandboxprobe."), "unexpected bundle identity")
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        try require(home.contains("/Library/Containers/" + id + "/Data"), "home is not the probe container")
        for location in ["tmp", "support"] {
            try require(root(location).resolvingSymlinksInPath().path.hasPrefix(home + "/"), "fixture is outside container")
        }
        let ancestor = Darwin.open("/Users", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        let code = errno
        if ancestor >= 0 { _ = Darwin.close(ancestor) }
        try require(ancestor < 0 && code == EPERM, "ancestor access was not denied by sandbox")
    }

    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--seed-recovery" {
            try sandboxIdentity()
            let destination = root(CommandLine.arguments[2]).appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let bytes = Data("synthetic interrupted duplicate".utf8)
            try bytes.write(to: destination.appendingPathComponent("committed.json"))
            try SensitiveFileIO.$beforeTemporaryCommit.withValue({ _ in _exit(73) }) {
                try SensitiveFileIO.atomicWrite(bytes, to: destination.appendingPathComponent("committed.json"))
            }
            _exit(74)
        }
        var checks: [Check] = []
        func check(_ name: String, _ action: () throws -> Void) {
            do { try action(); checks.append(Check(name: name, passed: true, detail: nil)) }
            catch {
                let detail: String
                switch error {
                case SensitiveFileIO.Failure.system(let operation, let code): detail = "\(operation): errno=\(code)"
                case SensitiveFileIO.Failure.unsafePath: detail = "unsafe_path"
                case ProbeError.assertion(let message): detail = message
                default: detail = "\(type(of: error))"
                }
                checks.append(Check(name: name, passed: false, detail: detail))
            }
        }
        check("sandbox_identity") { try sandboxIdentity() }
        guard checks[0].passed else {
            // Never touch fixtures unless the independent container is established.
            throw ProbeError.assertion("sandbox identity failed")
        }
        check("container_parent_tracking") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let bound = try SensitiveFileIO.Directory.open(at: home, create: false, tighten: false)
            let parentFD = Darwin.open(home.deletingLastPathComponent().path,
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            let code = errno
            if parentFD >= 0 { _ = Darwin.close(parentFD) }
            try require(parentFD < 0 && (code == EPERM || code == EACCES),
                        "optional parent access was not denied by sandbox")
            let tracked = try bound.ownedParentForTemporaryRecovery()
            try require(tracked == nil, "inaccessible optional parent was admitted")
        }
        for location in ["tmp", "support"] {
            let fm = FileManager.default, base = root(location)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            func test(_ name: String, _ action: () throws -> Void) { check(location + "." + name, action) }
            test("open_existing") {
                let directory = try SensitiveFileIO.Directory.open(at: base, create: false, tighten: false)
                try directory.assertStillAtOriginalPath()
            }
            test("missing_without_create") {
                do { _ = try SensitiveFileIO.Directory.open(at: base.appendingPathComponent("absent/deep"), create: false, tighten: false) }
                catch SensitiveFileIO.Failure.system(_, ENOENT) { return }
                throw ProbeError.assertion("missing directory was accepted")
            }
            test("create_private_components") {
                let existing = base.appendingPathComponent("existing")
                try fm.createDirectory(at: existing, withIntermediateDirectories: false)
                try require(chmod(existing.path, 0o755) == 0, "fixture chmod failed")
                let created = existing.appendingPathComponent("new/deep")
                let directory = try SensitiveFileIO.Directory.open(at: created, create: true, tighten: true)
                try directory.assertPrivate()
                for path in [created, created.deletingLastPathComponent()] {
                    let value = try info(path)
                    try require(value.st_uid == getuid() && value.st_mode & 0o777 == 0o700, "new directory permissions")
                }
                try require(try info(existing).st_mode & 0o777 == 0o755, "existing permissions changed")
            }
            let target = base.appendingPathComponent("symlink-target")
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            let linked = base.appendingPathComponent("linked")
            try fm.createSymbolicLink(at: linked, withDestinationURL: target)
            try fm.createDirectory(at: target.appendingPathComponent("present"), withIntermediateDirectories: false)
            test("reject_leaf_symlink") { try expectUnsafePath { _ = try SensitiveFileIO.Directory.open(at: linked, create: false, tighten: false) } }
            test("reject_ancestor_symlink") { try expectUnsafePath { _ = try SensitiveFileIO.Directory.open(at: linked.appendingPathComponent("present"), create: false, tighten: false) } }
            test("reject_missing_below_symlink") {
                try expectUnsafePath { _ = try SensitiveFileIO.Directory.open(at: linked.appendingPathComponent("missing/deep"), create: true, tighten: true) }
                try require(!fm.fileExists(atPath: target.appendingPathComponent("missing").path), "created through symlink")
            }
            test("reject_non_directory") {
                let file = base.appendingPathComponent("regular")
                try Data().write(to: file)
                try expectUnsafePath { _ = try SensitiveFileIO.Directory.open(at: file.appendingPathComponent("child"), create: true, tighten: false) }
            }
            test("atomic_write_read") {
                let file = base.appendingPathComponent("payload.json"), bytes = Data("synthetic payload".utf8)
                try SensitiveFileIO.atomicWrite(bytes, to: file)
                let directory = try SensitiveFileIO.Directory.open(at: base, create: false, tighten: false)
                try require(try directory.readIfPresent(named: file.lastPathComponent) == bytes, "read differs")
                try require(try info(file).st_mode & 0o777 == 0o600, "file is not private")
            }
            test("atomic_replace_permissions") {
                let file = base.appendingPathComponent("replace.json")
                try Data("before".utf8).write(to: file)
                try require(chmod(file.path, 0o640) == 0, "fixture chmod failed")
                try SensitiveFileIO.atomicWrite(Data("after".utf8), to: file)
                try require(try Data(contentsOf: file) == Data("after".utf8), "replacement differs")
                try require(try info(file).st_mode & 0o777 == 0o640, "replacement mode changed")
            }
            test("append_read") {
                let file = base.appendingPathComponent("append.jsonl")
                try SensitiveFileIO.append(Data("one".utf8), to: file)
                try SensitiveFileIO.append(Data("two".utf8), to: file)
                try require(try Data(contentsOf: file) == Data("onetwo".utf8), "append differs")
            }
            test("reject_file_symlink") {
                let file = target.appendingPathComponent("sentinel")
                let bytes = Data("preserve synthetic sentinel".utf8)
                try bytes.write(to: file)
                let link = base.appendingPathComponent("linked-file")
                try fm.createSymbolicLink(at: link, withDestinationURL: file)
                try expectUnsafePath { try SensitiveFileIO.atomicWrite(Data(), to: link) }
                try require(try Data(contentsOf: file) == bytes, "symlink target changed")
            }
            test("assert_path_identity") {
                let original = base.appendingPathComponent("identity")
                try fm.createDirectory(at: original, withIntermediateDirectories: false)
                let bound = try SensitiveFileIO.Directory.open(at: original, create: false, tighten: false)
                try fm.moveItem(at: original, to: base.appendingPathComponent("identity-preserved"))
                try fm.createDirectory(at: original, withIntermediateDirectories: false)
                try expectUnsafePath { try bound.assertStillAtOriginalPath() }
            }
            test("move_remove_directory") {
                let parent = try SensitiveFileIO.Directory.open(at: base, create: false, tighten: false)
                let child = try parent.createSubdirectory(named: "to-move")
                let identity = try child.identity
                try child.atomicWrite(Data("synthetic".utf8), named: "member")
                let staging = try parent.createSubdirectory(named: "staging")
                try parent.moveDirectory(named: "to-move", matching: identity, to: staging, named: "detached")
                try staging.removeDirectory(named: "detached", matching: identity)
                try require(try staging.names().isEmpty, "directory was not removed")
            }
            test("recovery_scan") {
                let directory = try SensitiveFileIO.Directory.open(at: base.appendingPathComponent("recovery"), create: false, tighten: false)
                let unknown = ".sensitive-write-" + UUID().uuidString + ".tmp"
                try Data("synthetic unregistered".utf8).write(to: directory.url.appendingPathComponent(unknown))
                let results = try directory.recoverTemporaryItems()
                try require(results.contains { $0.reason == "removed_duplicate" }, "registered duplicate was not recovered")
                try require(results.contains { $0.name == unknown && $0.reason == "unregistered" }, "unknown temporary was not preserved")
                try require(try directory.names().filter { $0.hasPrefix(".sensitive-write-") } == [unknown], "unexpected recovery residue")
            }
            test("temporary_session_cleanup") {
                let session = location == "tmp" ? try SessionWorkspace.makeTemporarySessionDirectory()
                    : try SessionWorkspace.makeRecoverableTemporarySessionDirectory()
                try SensitiveFileIO.atomicWrite(Data("synthetic audio placeholder".utf8), to: session.appendingPathComponent("recording.wav"))
                try SessionWorkspace.discardTemporarySession(session)
                try require(!fm.fileExists(atPath: session.path), "temporary session was not removed")
            }
            test("pending_cleanup_retry") {
                let session = location == "tmp" ? try SessionWorkspace.makeTemporarySessionDirectory()
                    : try SessionWorkspace.makeRecoverableTemporarySessionDirectory()
                let journal = session.deletingLastPathComponent().appendingPathComponent(".LiveLingo-Cleanup")
                let record = journal.appendingPathComponent(String(session.lastPathComponent.dropFirst(SessionWorkspace.temporaryPrefix.count)) + ".json")
                var object = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
                object["cleanupRequested"] = true
                try SensitiveFileIO.atomicWrite(JSONSerialization.data(withJSONObject: object), to: record)
                try SessionWorkspace.retryPendingTemporarySessions(in: session.deletingLastPathComponent())
                try require(!fm.fileExists(atPath: session.path) && !fm.fileExists(atPath: record.path), "pending cleanup was not retried")
            }
            test("recording_recovery_index") {
                let directory = base.appendingPathComponent("recovery-index")
                let value = SessionWorkspace.RecordingRecovery(id: UUID(), directory: target, outputRoot: base,
                                                               createdAt: Date(timeIntervalSince1970: 1_700_000_000))
                _ = try SessionWorkspace.saveRecordingRecoveries([value], in: directory)
                try require(try SessionWorkspace.recordingRecoveries(in: directory) == [value], "recovery index differs")
                _ = try SessionWorkspace.saveRecordingRecoveries([], in: directory, retiring: [value])
                try require(try SessionWorkspace.recordingRecoveries(in: directory).isEmpty, "recovery retirement failed")
            }
        }
        let passed = checks.allSatisfy(\.passed)
        let result = Result(bundle_id: Bundle.main.bundleIdentifier ?? "", passed: passed, checks: checks)
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        exit(passed ? 0 : 1)
    }
}
