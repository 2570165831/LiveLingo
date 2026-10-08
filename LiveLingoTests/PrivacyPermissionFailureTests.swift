import Darwin
import Foundation
#if !PRIVACY_PERMISSION_PROBE
import Testing
@testable import LiveLingo
#endif

/// Real synthetic APFS objects; only permission syscall results are injected.
struct PrivacyPermissionFailureTests {
    private struct AssertionFailure: Error { let message: String }

    private func require(_ value: Bool, _ message: String) throws {
        guard value else { throw AssertionFailure(message: message) }
    }

    private func fixture() throws -> URL {
        #if PRIVACY_PERMISSION_PROBE
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        #else
        let base = TestFixtureDirectory.root
        #endif
        let root = base.appendingPathComponent("privacy-permission-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var volume = statfs()
        try require(statfs(root.path, &volume) == 0, "Cannot inspect the synthetic volume")
        let type = withUnsafeBytes(of: volume.f_fstypename) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        try require(type == "apfs", "Permission failure regressions require APFS")
        return root
    }

    private func info(_ url: URL) throws -> stat {
        var value = stat()
        try require(lstat(url.path, &value) == 0, "Cannot inspect the synthetic file")
        return value
    }

    private func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            try require(errno == ENOENT, "Cannot inspect the synthetic ACL")
            return ""
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { throw AssertionFailure(message: "Cannot format the synthetic ACL") }
        defer { _ = acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private func setACL(_ url: URL, deny: Bool, inherit: Bool = false) throws {
        guard let group = getgrnam("everyone"),
              let uuid = UUID(uuidString: String(format: "AAAABBBB-CCCC-DDDD-EEEE-FFFF%08X", group.pointee.gr_gid)) else {
            throw AssertionFailure(message: "Cannot identify the synthetic ACL principal")
        }
        var principal = uuid.uuid
        var acl = acl_init(1)
        defer { if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) } }
        var rawEntry: acl_entry_t?
        try require(acl_create_entry(&acl, &rawEntry) == 0, "Cannot create the synthetic ACL")
        guard let entry = rawEntry else { throw AssertionFailure(message: "Missing synthetic ACL entry") }
        try require(acl_set_tag_type(entry, deny ? ACL_EXTENDED_DENY : ACL_EXTENDED_ALLOW) == 0, "Cannot set ACL type")
        try require(withUnsafePointer(to: &principal) { acl_set_qualifier(entry, $0) } == 0, "Cannot set ACL principal")
        var rawPermissions: acl_permset_t?
        try require(acl_get_permset(entry, &rawPermissions) == 0, "Cannot inspect ACL permissions")
        guard let permissions = rawPermissions else { throw AssertionFailure(message: "Missing ACL permissions") }
        try require(acl_add_perm(permissions, ACL_READ_DATA) == 0, "Cannot set read permission")
        if inherit {
            var rawFlags: acl_flagset_t?
            try require(acl_get_flagset_np(UnsafeMutableRawPointer(entry), &rawFlags) == 0, "Cannot inspect ACL flags")
            guard let flags = rawFlags else { throw AssertionFailure(message: "Missing ACL flags") }
            try require(acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 0, "Cannot set ACL inheritance")
        }
        guard let acl else { throw AssertionFailure(message: "Missing synthetic ACL") }
        try require(acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0, "Cannot install the synthetic ACL")
    }

    private func failure(code: Int32, constraintFailure: Bool = false, _ action: () throws -> Void) throws {
        do { try action() }
        catch SensitiveFileIO.Failure.system(_, let actual) {
            try require(actual == code, "Permission failure did not preserve its error code")
            return
        }
        catch SensitiveFileIO.Failure.unsafePath where constraintFailure { return }
        throw AssertionFailure(message: "Permission failure was silently accepted")
    }

    private func noTemporaryFiles(_ root: URL) throws {
        try require(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
            !$0.hasPrefix(".sensitive-write-") && !$0.hasPrefix(".session-write-")
        }, "Failed save left a temporary file")
    }

    private func preservedReplacement(operation: SensitiveFileIO.OptionalOperation, code: Int32,
                                      writeOnly: Bool = false, constraintFailure: Bool = false) throws {
        let root = try fixture()
        let leaf = root.appendingPathComponent("existing.json")
        let original = Data("Synthetic retained body".utf8)
        try original.write(to: leaf)
        let reader = try FileHandle(forReadingFrom: leaf)
        defer { try? reader.close() }
        try require(chmod(leaf.path, writeOnly ? 0o200 : 0o644) == 0, "Cannot set the original mode")
        if !writeOnly { try setACL(leaf, deny: true) }
        let before = try info(leaf), beforeACL = try aclText(leaf)
        try SensitiveFileIO.$operationErrors.withValue([operation: code]) {
            try failure(code: code, constraintFailure: constraintFailure) {
                try SensitiveFileIO.atomicWrite(Data("Synthetic replacement".utf8), to: leaf)
            }
        }
        let after = try info(leaf)
        try require(SensitiveFileIO.Identity(after) == SensitiveFileIO.Identity(before), "Failed save replaced the original inode")
        try require(after.st_mode == before.st_mode && after.st_gid == before.st_gid, "Failed save changed original permissions")
        try require(try aclText(leaf) == beforeACL, "Failed save changed the original ACL")
        let readable = Darwin.open(leaf.path, O_RDONLY | O_NOFOLLOW)
        if readable >= 0 { _ = Darwin.close(readable) }
        try require(readable < 0 && errno == EACCES, "Failed save made a previously unreadable file readable")
        try require(try reader.readToEnd() == original, "Failed save changed the original body")
        try noTemporaryFiles(root)
        // Retry without the fault and check the new inode's constraints.
        let updated = Data("Synthetic successful retry".utf8)
        try SensitiveFileIO.atomicWrite(updated, to: leaf)
        let retried = try info(leaf)
        try require(retried.st_mode == before.st_mode && retried.st_gid == before.st_gid, "Retry widened the mode or group")
        try require(try aclText(leaf) == beforeACL, "Retry lost the original ACL")
        let retryReader = Darwin.open(leaf.path, O_RDONLY | O_NOFOLLOW)
        if retryReader >= 0 { _ = Darwin.close(retryReader) }
        try require(retryReader < 0 && errno == EACCES, "Retry widened read access")
        // Restore only this synthetic leaf for payload verification.
        let empty = acl_init(0)!
        defer { _ = acl_free(UnsafeMutableRawPointer(empty)) }
        try require(acl_set_file(leaf.path, ACL_TYPE_EXTENDED, empty) == 0 && chmod(leaf.path, 0o600) == 0,
                    "Cannot read back the synthetic retry")
        try require(try Data(contentsOf: leaf) == updated, "Retry did not save the complete body")
        try noTemporaryFiles(root)
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [EPERM, EXDEV, EIO, EACCES, EINVAL])
    #endif
    func H1ACLCopyFailurePreservesOriginalAndCanRetry(code: Int32) throws {
        try preservedReplacement(operation: .setACL, code: code)
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [EPERM, EXDEV, EIO, EACCES, EINVAL])
    #endif
    func H1ACLReadFailurePreservesOriginalAndCanRetry(code: Int32) throws {
        try preservedReplacement(operation: .readACL, code: code)
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [EPERM, EXDEV, EIO, EACCES, EINVAL])
    #endif
    func H1ModeFailurePreservesWriteOnlyOriginalAndCanRetry(code: Int32) throws {
        try preservedReplacement(operation: .mode, code: code, writeOnly: true)
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [EPERM, EXDEV, EIO, EACCES, EINVAL])
    #endif
    func H1OwnerFailurePreservesOriginalAndCanRetry(code: Int32) throws {
        try preservedReplacement(operation: .owner, code: code)
    }

    private func privateCreationFailure(operation: SensitiveFileIO.OptionalOperation, code: Int32) throws {
        let root = try fixture()
        if operation == .setACL { try setACL(root, deny: false, inherit: true) }
        let directory = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
        for name in ["atomic.json", "append.json", "exclusive.json"] {
            let leaf = root.appendingPathComponent(name)
            try SensitiveFileIO.$operationErrors.withValue([operation: code]) {
                try failure(code: code) {
                    if name == "atomic.json" { try SensitiveFileIO.atomicWrite(Data("Synthetic new body".utf8), to: leaf) }
                    else if name == "append.json" { try SensitiveFileIO.append(Data("Synthetic new body".utf8), to: leaf) }
                    else { _ = Darwin.close(try directory.createPrivateFile(named: name)) }
                }
            }
            try require(!FileManager.default.fileExists(atPath: leaf.path), "Failed private creation published a file")
            try noTemporaryFiles(root)
        }
        let retry = root.appendingPathComponent("retry.json")
        let body = Data("Synthetic private retry".utf8)
        try SensitiveFileIO.atomicWrite(body, to: retry)
        try require(try info(retry).st_mode & 0o777 == 0o600, "Private retry has broad permissions")
        try require(!(try aclText(retry)).contains("allow"), "Private retry retained inherited allow access")
        try require(try Data(contentsOf: retry) == body, "Private retry lost its body")
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [EPERM, EXDEV, EIO, EACCES, EINVAL])
    #endif
    func H1NewACLFailureDoesNotPublishPrivateFile(code: Int32) throws {
        try privateCreationFailure(operation: .setACL, code: code)
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [EPERM, EXDEV, EIO, EACCES, EINVAL])
    #endif
    func H1NewModeFailureDoesNotPublishPrivateFile(code: Int32) throws {
        try privateCreationFailure(operation: .mode, code: code)
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [ENOTSUP, EOPNOTSUPP, ENOSYS])
    #endif
    func H1UnsupportedUpdateCannotDiscardKnownACL(code: Int32) throws {
        try preservedReplacement(operation: .setACL, code: code, constraintFailure: true)
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [ENOTSUP, EOPNOTSUPP, ENOSYS])
    #endif
    func H1UnsupportedModeCannotAddOwnerReadAccess(code: Int32) throws {
        try preservedReplacement(operation: .mode, code: code, writeOnly: true, constraintFailure: true)
    }

    #if !PRIVACY_PERMISSION_PROBE
    @Test(arguments: [ENOTSUP, EOPNOTSUPP, ENOSYS])
    #endif
    func H1UnsupportedPermissionsStillSaveNewAndReplacementFiles(code: Int32) throws {
        let root = try fixture(), leaf = root.appendingPathComponent("portable.json")
        let operations: [SensitiveFileIO.OptionalOperation] = [.readACL, .setACL, .mode, .owner]
        try SensitiveFileIO.$unsupportedOperations.withValue(Set(operations)) {
        try SensitiveFileIO.$operationErrors.withValue(Dictionary(uniqueKeysWithValues: operations.map { ($0, code) })) {
            for body in ["Synthetic new body", "Synthetic replacement body"] {
                try SensitiveFileIO.atomicWrite(Data(body.utf8), to: leaf)
                try require(try Data(contentsOf: leaf) == Data(body.utf8), "Unsupported permissions blocked a portable save")
            }
        }
        }
        try noTemporaryFiles(root)
    }
}

#if PRIVACY_PERMISSION_PROBE
@main
struct PrivacyPermissionProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let tests = PrivacyPermissionFailureTests()
        let cases: [(String, (Int32) throws -> Void)] = [
            ("H1ACLCopyFailurePreservesOriginalAndCanRetry", tests.H1ACLCopyFailurePreservesOriginalAndCanRetry),
            ("H1ACLReadFailurePreservesOriginalAndCanRetry", tests.H1ACLReadFailurePreservesOriginalAndCanRetry),
            ("H1ModeFailurePreservesWriteOnlyOriginalAndCanRetry", tests.H1ModeFailurePreservesWriteOnlyOriginalAndCanRetry),
            ("H1OwnerFailurePreservesOriginalAndCanRetry", tests.H1OwnerFailurePreservesOriginalAndCanRetry),
            ("H1NewACLFailureDoesNotPublishPrivateFile", tests.H1NewACLFailureDoesNotPublishPrivateFile),
            ("H1NewModeFailureDoesNotPublishPrivateFile", tests.H1NewModeFailureDoesNotPublishPrivateFile),
            ("H1UnsupportedUpdateCannotDiscardKnownACL", tests.H1UnsupportedUpdateCannotDiscardKnownACL),
            ("H1UnsupportedModeCannotAddOwnerReadAccess", tests.H1UnsupportedModeCannotAddOwnerReadAccess),
            ("H1UnsupportedPermissionsStillSaveNewAndReplacementFiles", tests.H1UnsupportedPermissionsStillSaveNewAndReplacementFiles)
        ]
        var results: [[String: Any]] = []
        for (name, action) in cases {
            for code in name.contains("Unsupported") ? [ENOTSUP, EOPNOTSUPP, ENOSYS] : [EPERM, EXDEV, EIO, EACCES, EINVAL] {
                do { try action(code); results.append(["test": name, "code": code, "passed": true]) }
                catch { results.append(["test": name, "code": code, "passed": false, "error": String(describing: error)]) }
            }
        }
        let failed = results.filter { $0["passed"] as? Bool == false }.count
        let data = try JSONSerialization.data(withJSONObject: ["total": results.count, "failed": failed, "results": results], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
