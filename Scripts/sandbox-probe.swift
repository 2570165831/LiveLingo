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

    /// Mirror checkpoints._state_fd's Darwin calls without starting Python.
    /// The bound is an existing container directory; every absolute attempt
    /// must stay at or below it, even when the checkpoint tail is absent.
    static func checkpointDirectory(_ url: URL, create: Bool, bound: URL) throws -> Int32 {
        let components = url.path.split(separator: "/").map(String.init)
        var existing = components.count
        var fd: Int32
        while true {
            let prefix = "/" + components.prefix(existing).joined(separator: "/")
            try require(prefix == bound.path || prefix.hasPrefix(bound.path + "/"),
                        "checkpoint attempted an ancestor above its grant")
            fd = Darwin.open(prefix, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
            if fd >= 0 { break }
            let code = errno
            guard create, code == ENOENT, existing > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            existing -= 1
        }
        do {
            for component in components.dropFirst(existing) {
                var claimed: stat?
                let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW
                var child = openat(fd, component, flags)
                if child < 0, errno == ENOENT, create {
                    if mkdirat(fd, component, 0o700) == 0 {
                        var value = stat()
                        guard fstatat(fd, component, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                            throw POSIXError(.EIO)
                        }
                        claimed = value
                    } else if errno != EEXIST { throw POSIXError(.EIO) }
                    child = openat(fd, component, flags)
                }
                guard child >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                _ = Darwin.close(fd)
                fd = child
                if let claimed {
                    var current = stat()
                    try require(fstat(fd, &current) == 0 && current.st_mode & S_IFMT == S_IFDIR
                                && current.st_uid == getuid()
                                && current.st_dev == claimed.st_dev && current.st_ino == claimed.st_ino,
                                "checkpoint creation identity or owner changed")
                    try require(fchmod(fd, 0o700) == 0, "checkpoint mode failed")
                    try checkpointStripAllows(fd)
                }
            }
            var final = stat()
            try require(fstat(fd, &final) == 0 && final.st_mode & S_IFMT == S_IFDIR && final.st_uid == getuid(),
                        "checkpoint directory owner or type invalid")
            return fd
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
    }

    static func checkpointStripAllows(_ fd: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            let code = errno
            try require([ENOENT, ENOTSUP, EOPNOTSUPP, ENOSYS, EINVAL].contains(code), "checkpoint ACL read failed")
            return
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var changed = false
        while true {
            var selector = Int32(ACL_FIRST_ENTRY.rawValue)
            var allow: acl_entry_t?
            while true {
                var entry: acl_entry_t?
                errno = 0
                let result = acl_get_entry(acl, selector, &entry)
                if entry == nil, result >= 0 || (result == -1 && errno == EINVAL) { break }
                try require(result >= 0 && entry != nil, "checkpoint ACL enumeration failed")
                var tag = ACL_UNDEFINED_TAG
                try require(acl_get_tag_type(entry!, &tag) == 0, "checkpoint ACL tag failed")
                if tag == ACL_EXTENDED_ALLOW { allow = entry; break }
                selector = Int32(ACL_NEXT_ENTRY.rawValue)
            }
            guard let allow else { break }
            try require(acl_delete_entry(acl, allow) == 0, "checkpoint ACL deletion failed")
            changed = true
        }
        if changed { try require(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0, "checkpoint ACL update failed") }
    }

    static func detail(_ error: Error) -> String {
        switch error {
        case SensitiveFileIO.Failure.system(let operation, let code): return "\(operation): errno=\(code)"
        case SensitiveFileIO.Failure.unsafePath: return "unsafe_path"
        case ProbeError.assertion(let message): return message
        case SessionStoreError.io(let operation, let code): return "\(operation): errno=\(code)"
        default: return "\(type(of: error)): \(error.localizedDescription)"
        }
    }

    /// The probe's container is synthetic, but messages may still carry paths;
    /// keep them relative to the container so result.json names no user home.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path, with: "~")
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            // A setup denial is a failed probe, never an uncaught Swift error
            // that generates a system crash report/dialog.
            FileHandle.standardError.write(Data((redacted(detail(error)) + "\n").utf8))
            _exit(1)
        }
    }

    @MainActor
    static func run() async throws {
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
            catch { checks.append(Check(name: name, passed: false, detail: redacted(detail(error)))) }
        }
        func checkAsync(_ name: String, _ action: () async throws -> Void) async {
            do { try await action(); checks.append(Check(name: name, passed: true, detail: nil)) }
            catch { checks.append(Check(name: name, passed: false, detail: redacted(detail(error)))) }
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
            func testAsync(_ name: String, _ action: () async throws -> Void) async { await checkAsync(location + "." + name, action) }
            test("open_existing") {
                let directory = try SensitiveFileIO.Directory.open(at: base, create: false, tighten: false)
                try directory.assertStillAtOriginalPath()
            }
            // These run in the signed probe's own sandbox, using the Python
            // directory syscall sequence rather than an inherited interpreter.
            let checkpointRoot = base.resolvingSymlinksInPath()
            test("checkpoint_python_existing") {
                let fd = try checkpointDirectory(checkpointRoot, create: false, bound: checkpointRoot)
                _ = Darwin.close(fd)
            }
            test("checkpoint_python_create") {
                let target = checkpointRoot.appendingPathComponent("checkpoints/translation/new")
                let fd = try checkpointDirectory(target, create: true, bound: checkpointRoot)
                defer { _ = Darwin.close(fd) }
                let directory = try SensitiveFileIO.Directory.open(at: target, create: false, tighten: false)
                try directory.assertPrivate()
            }
            test("checkpoint_python_missing_read") {
                do {
                    let fd = try checkpointDirectory(checkpointRoot.appendingPathComponent("absent-checkpoint"),
                                                     create: false, bound: checkpointRoot)
                    _ = Darwin.close(fd)
                } catch let error as POSIXError where error.code == .ENOENT { return }
                throw ProbeError.assertion("missing read checkpoint was accepted")
            }
            test("checkpoint_python_symlink") {
                let link = checkpointRoot.appendingPathComponent("checkpoint-link")
                try fm.createSymbolicLink(at: link, withDestinationURL: checkpointRoot)
                for target in [link, link.appendingPathComponent("missing/deep")] {
                    do {
                        let fd = try checkpointDirectory(target, create: true, bound: checkpointRoot)
                        _ = Darwin.close(fd)
                    } catch let error as POSIXError where error.code == .ELOOP || error.code == .ENOTDIR { continue }
                    throw ProbeError.assertion("checkpoint symlink was accepted")
                }
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
            test("recording_recovery_bookmark") {
                // The app-scope entitlement must let the sandbox create and
                // resolve the grants a relaunched recovery depends on.
                let directory = base.appendingPathComponent("recovery-bookmark")
                let selected = base.appendingPathComponent("bookmark-selected", isDirectory: true)
                let course = selected.appendingPathComponent("course", isDirectory: true)
                try fm.createDirectory(at: course, withIntermediateDirectories: true)
                let value = SessionWorkspace.RecordingRecovery(id: UUID(), directory: target, outputRoot: base,
                                                               createdAt: Date(timeIntervalSince1970: 1_700_000_000))
                    .withOutputRoot(selected).promoted(to: course)
                try require(value.outputRootBookmark != nil && value.directoryBookmark != nil, "security bookmark was not created")
                _ = try SessionWorkspace.saveRecordingRecoveries([value], in: directory)
                let stored = try SessionWorkspace.recordingRecoveries(in: directory)
                try require(stored == [value], "bookmarked recovery index differs")
                let moved = base.appendingPathComponent("bookmark-moved", isDirectory: true)
                try fm.moveItem(at: selected, to: moved)
                let access = try SessionWorkspace.ScopedFolderAccess(bookmark: stored[0].directoryBookmark!)
                defer { access.stop() }
                try require(access.url.resolvingSymlinksInPath().path
                            == moved.appendingPathComponent("course").resolvingSymlinksInPath().path, "bookmark did not follow the move")
                try SensitiveFileIO.atomicWrite(Data("synthetic".utf8), to: access.url.appendingPathComponent("probe.txt"))
                _ = try SessionWorkspace.saveRecordingRecoveries([], in: directory, retiring: stored)
            }
            // The checks below run the App's own persistence entry points end to
            // end inside the container; none of them is reimplemented here.
            let segment = TranscriptSegment(id: UUID(), startTime: 1, endTime: 3,
                                            english: "Synthetic sandbox caption.", chinese: "合成沙盒字幕。")
            test("session_store_roundtrip") {
                let directory = base.appendingPathComponent("session-store", isDirectory: true)
                let store = SessionStore(directory: directory)
                let initial = try store.save(SessionSnapshot(createdAt: Date(timeIntervalSince1970: 1_000)))
                let appended = try store.append(.upsertSegment(segment), expectedRevision: initial.storageRevision)
                for name in [SessionStore.snapshotFileName, SessionStore.journalFileName, ".session-store.lock"] {
                    try require(try info(directory.appendingPathComponent(name)).st_mode & S_IFMT == S_IFREG,
                                "store did not create \(name)")
                }
                let loaded = try SessionStore(directory: directory).loadDetailed()
                try require(loaded.origin == .snapshot && loaded.incompleteTailBytes == 0, "store reload origin differs")
                try require(loaded.snapshot == appended && loaded.snapshot?.segments == [segment], "store reload differs")
                try require(loaded.snapshot?.lastJournalSequence == 1, "journal replay differs")
            }
            func recordedSession() throws -> URL {
                let session = location == "tmp" ? try SessionWorkspace.makeTemporarySessionDirectory()
                    : try SessionWorkspace.makeRecoverableTemporarySessionDirectory()
                try SensitiveFileIO.atomicWrite(Data("synthetic audio placeholder".utf8),
                                                to: session.appendingPathComponent(SessionWorkspace.recordingFileName))
                return session
            }
            test("temporary_session_copy") {
                let session = try recordedSession()
                let courses = base.appendingPathComponent("copied-courses", isDirectory: true)
                try fm.createDirectory(at: courses, withIntermediateDirectories: false)
                let receipt = try SessionWorkspace.copyTemporarySession(from: session, to: courses, preferredName: "Course")
                try require(receipt.destinationDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
                            == courses.resolvingSymlinksInPath().path, "copy left the container destination")
                try require(try SessionTreeMigration.manifest(of: receipt.destinationDirectory) == receipt.entries
                            && receipt.fileCount == 1, "copied tree differs")
                try require(fm.fileExists(atPath: session.path), "copy removed its source")
                try SessionWorkspace.discardTemporarySession(session)
            }
            test("temporary_session_promote") {
                let session = try recordedSession()
                let courses = base.appendingPathComponent("promoted-courses", isDirectory: true)
                try fm.createDirectory(at: courses, withIntermediateDirectories: false)
                let promoted = try SessionWorkspace.promoteTemporarySession(from: session, to: courses, preferredName: "Course")
                try require(promoted.deletingLastPathComponent().resolvingSymlinksInPath().path
                            == courses.resolvingSymlinksInPath().path, "promotion left the container destination")
                try require(try Data(contentsOf: promoted.appendingPathComponent(SessionWorkspace.recordingFileName))
                            == Data("synthetic audio placeholder".utf8), "promoted recording differs")
                let recovery = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: promoted.appendingPathComponent("migration-recovery.json"))) as? [String: String]
                guard let source = recovery?["source"] else { throw ProbeError.assertion("recovery record missing") }
                try require(!fm.fileExists(atPath: session.path) && fm.fileExists(atPath: source),
                            "source was not retired to a recoverable sibling")
                let record = session.deletingLastPathComponent().appendingPathComponent(".LiveLingo-Cleanup")
                    .appendingPathComponent(String(session.lastPathComponent.dropFirst(SessionWorkspace.temporaryPrefix.count)) + ".json")
                try require(!fm.fileExists(atPath: record.path), "promoted session is still pending cleanup")
            }
            await testAsync("review_queue_journal") {
                let journal = base.appendingPathComponent("review", isDirectory: true)
                    .appendingPathComponent("learning-review-queue.json")
                let first = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled)
                first.togglePause()
                try await first.waitForPendingStorage()
                try require(first.userPaused, "pause was not applied")
                for url in [journal, journal.appendingPathExtension("lock")] {
                    try require(try info(url).st_mode & S_IFMT == S_IFREG, "queue did not create \(url.lastPathComponent)")
                }
                let second = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled)
                try require(second.userPaused && second.journalForTesting.version == LearningReviewQueue.journalVersion,
                            "reloaded journal differs")
                // A reloaded queue must be able to write back over its own read.
                second.togglePause()
                try await second.waitForPendingStorage()
                let third = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled)
                try require(!second.userPaused && !third.userPaused, "journal write-back after reload failed")
                for queue in [first, second, third] { await queue.shutdownForTesting() }
            }
            test("export_subfolder") {
                let course = base.appendingPathComponent("exports/course", isDirectory: true)
                try fm.createDirectory(at: course, withIntermediateDirectories: true)
                let target = SessionExporter.targetTranscriptFileName(for: OutputLanguage.simplifiedChinese.rawValue)
                func requireExport(_ chinese: String, in directory: URL) throws {
                    try require(try Data(contentsOf: course.appendingPathComponent("transcript-en.txt"))
                                == Data("Synthetic sandbox caption.\n".utf8), "exported transcript differs")
                    try require(try Data(contentsOf: course.appendingPathComponent(target))
                                == Data((chinese + "\n").utf8), "exported target transcript differs")
                    for name in ["bilingual.jsonl", "bilingual.srt", "manifest.json"] {
                        try require(fm.fileExists(atPath: directory.appendingPathComponent(name).path), "export missed \(name)")
                    }
                }
                // The first export swaps a staged folder in through the parent;
                // a re-export publishes a versioned generation inside the course.
                try SessionExporter.export(segments: [segment], sessionDirectory: course,
                                           createdAt: Date(timeIntervalSince1970: 1_700_000_000))
                try require(try SessionExporter.currentExportDirectory(in: course).path == course.path, "initial export differs")
                try requireExport("合成沙盒字幕。", in: course)
                var revised = segment
                revised.chinese = "修订后的合成沙盒字幕。"
                try SessionExporter.export(segments: [revised], sessionDirectory: course,
                                           createdAt: Date(timeIntervalSince1970: 1_700_000_100))
                let generation = try SessionExporter.currentExportDirectory(in: course)
                try require(generation.path != course.path, "re-export did not publish a generation")
                try requireExport("修订后的合成沙盒字幕。", in: generation)
                try require(try fm.contentsOfDirectory(atPath: base.appendingPathComponent("exports").path) == ["course"],
                            "export left staging residue")
            }
        }
        let passed = checks.allSatisfy(\.passed)
        let result = Result(bundle_id: Bundle.main.bundleIdentifier ?? "", passed: passed, checks: checks)
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        exit(passed ? 0 : 1)
    }
}
