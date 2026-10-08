import Darwin
import Foundation
import os

/// Restrict new objects and preserve replacement permissions where supported.
/// Missing capabilities permit portable saves; unexpected permission failures
/// are reported before replacing an existing object or publishing a new file.
enum SensitiveFileIO {
    enum OptionalOperation: Sendable, Hashable { case readACL, setACL, mode, owner, link, swap, exclusiveRename, directorySync }
    #if DEBUG
    @TaskLocal static var unsupportedOperations: Set<OptionalOperation> = []
    @TaskLocal static var operationErrors: [OptionalOperation: Int32] = [:]
    @TaskLocal static var operationObserver: (@Sendable (OptionalOperation) -> Void)?
    @TaskLocal static var aclReadError: Int32?
    @TaskLocal static var beforeTemporaryCommit: (@Sendable (URL) throws -> Void)?
    @TaskLocal static var temporaryTrackingParentUnavailable = false
    #endif

    private static func perform(_ operation: OptionalOperation, _ call: () -> Int32) -> Int32 {
        #if DEBUG
        operationObserver?(operation)
        if let code = operationErrors[operation] { errno = code; return -1 }
        if unsupportedOperations.contains(operation) { errno = ENOTSUP; return -1 }
        #endif
        return call()
    }

    private static func unsupported(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS || code == EINVAL
    }

    private static func unsupportedPermission(_ code: Int32) -> Bool {
        // EINVAL can denote unavailable rename flags, but valid permission
        // arguments must not turn an unexpected failure into a capability gap.
        code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS
    }

    private static func missingPermissionCapability(_ operation: OptionalOperation, fd: Int32, code: Int32) -> Bool {
        #if DEBUG
        // This hook models a volume without the capability, separately from
        // operationErrors, which models an unexpected syscall failure.
        if unsupportedOperations.contains(operation) {
            return unsupportedPermission(code) || code == EPERM || code == EXDEV
        }
        #endif
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0 else { return false }
        let type = withUnsafeBytes(of: volume.f_fstypename) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        // APFS/HFS implement these attributes: even ENOTSUP from an individual
        // call must not be mistaken for a permission-less volume.
        if type == "apfs" || type == "hfs" { return false }
        if type == "msdos" || type == "exfat" {
            return unsupportedPermission(code) || code == EPERM || code == EXDEV
        }
        return unsupportedPermission(code)
    }

    @discardableResult
    private static func setPermission(_ operation: OptionalOperation, fd: Int32, description: String,
                                      _ call: () -> Int32) throws -> Bool {
        if perform(operation, call) == 0 { return true }
        let code = errno
        guard missingPermissionCapability(operation, fd: fd, code: code) else {
            throw Failure.system(operation: description, code: code)
        }
        return false
    }

    private static func canUsePlainRename(_ code: Int32) -> Bool {
        // Some removable/network filesystems reject hard links or extended
        // rename flags with EPERM/EXDEV. The same-directory plain rename still
        // enforces the destination's real permissions and immutable flags.
        unsupported(code) || code == EPERM || code == EXDEV
    }
    enum Failure: Error {
        case unsafePath
        case system(operation: String, code: Int32)
    }

    struct Identity: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let owner: UInt32

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; owner = info.st_uid
        }
    }

    // An inode number alone can be reused after deletion. The birth time and
    // containing directory bind this creation receipt to the actual object.
    private struct TemporaryIdentity: Codable, Equatable {
        let identity: Identity
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        init(_ info: stat) {
            identity = Identity(info)
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }
    }

    private struct TemporaryReceipt: Codable {
        var version = 1
        let kind: String
        let parent: TemporaryIdentity
        let item: TemporaryIdentity
        let destination: String
        let digest: String?
        let replacement: TemporaryIdentity?
    }
    private static let temporaryAttribute = "com.jianhongli.LiveLingo.temporary-v1"
    private static let recoveryLog = Logger(subsystem: "com.jianhongli.LiveLingo", category: "TemporaryRecovery")

    struct TemporaryRecovery: Equatable {
        let name: String
        let reason: String
        var removed: Bool { reason == "removed_empty" || reason == "removed_duplicate" }
    }

    static func recordTemporaryRecoveryScanFailure() {
        recoveryLog.notice("temporary_recovery reason=scan_failed")
    }

    static func prepareDirectory(_ url: URL) throws {
        _ = try Directory.open(at: url, create: true, tighten: true)
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let parent = try Directory.open(at: url.deletingLastPathComponent(), create: false, tighten: false)
        try parent.atomicWrite(data, named: url.lastPathComponent)
    }

    static func append(_ data: Data, to url: URL) throws {
        let parent = try Directory.open(at: url.deletingLastPathComponent(), create: false, tighten: false)
        try parent.append(data, named: url.lastPathComponent)
    }

    static func tightenIfPresent(at url: URL) throws {
        do {
            let parent = try Directory.open(at: url.deletingLastPathComponent(), create: false, tighten: false)
            try parent.tightenIfPresent(named: url.lastPathComponent)
        } catch Failure.system(_, let code) where code == ENOENT {
            return
        }
    }

    static func tightenFileIfPresent(_ url: URL) throws {
        let parent: Directory
        do {
            parent = try Directory.open(at: url.deletingLastPathComponent(), create: false, tighten: false)
        } catch Failure.system(_, let code) where code == ENOENT {
            return
        }
        guard try parent.requireRegularFileIfPresent(named: url.lastPathComponent) else { return }
        try parent.tightenIfPresent(named: url.lastPathComponent)
    }

    final class Directory: @unchecked Sendable {
        private let fd: Int32
        let url: URL

        private init(fd: Int32, url: URL) {
            self.fd = fd
            self.url = url
        }

        deinit { _ = Darwin.close(fd) }

        static func open(at url: URL, create: Bool, tighten: Bool) throws -> Directory {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
                throw Failure.unsafePath
            }
            let components = try systemAliasPath(url.path).split(separator: "/").map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw Failure.unsafePath }
            var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard current >= 0 else { throw system("open root") }
            defer { if current >= 0 { _ = Darwin.close(current) } }
            for (index, component) in components.enumerated() {
                var created = false
                var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                if next < 0, errno == ENOENT, create {
                    if mkdirat(current, component, 0o700) == 0 { created = true }
                    else if errno != EEXIST { throw system("create directory") }
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard next >= 0 else { throw pathFailure("open directory") }
                do {
                    let info = try status(next)
                    guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
                    if created || index == components.count - 1 {
                        try requireOwner(info)
                        if created { try makePrivate(next, directory: true) }
                    }
                } catch {
                    _ = Darwin.close(next)
                    throw error
                }
                _ = Darwin.close(current)
                current = next
            }
            let result = Directory(fd: current, url: url)
            current = -1
            return result
        }

        func subdirectory(named name: String, create: Bool = true) throws -> Directory {
            try validateName(name)
            var created = false
            var child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            if child < 0, errno == ENOENT, create {
                if mkdirat(fd, name, 0o700) == 0 { created = true }
                else if errno != EEXIST { throw system("create private directory") }
                child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard child >= 0 else { throw pathFailure("open private directory") }
            do {
                try requireOwner(status(child))
                if created { try makePrivate(child, directory: true) }
            }
            catch { _ = Darwin.close(child); throw error }
            return Directory(fd: child, url: url.appendingPathComponent(name, isDirectory: true))
        }

        func createSubdirectory(named name: String) throws -> Directory {
            try validateName(name)
            guard mkdirat(fd, name, 0o700) == 0 else { throw system("create exclusive directory") }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard child >= 0 else { throw pathFailure("bind new directory") }
            do { try makePrivate(child, directory: true) }
            catch { _ = Darwin.close(child); throw error }
            return Directory(fd: child, url: url.appendingPathComponent(name, isDirectory: true))
        }

        func assertPrivate() throws {
            guard try status(fd).st_mode & 0o077 == 0 else { throw Failure.unsafePath }
            guard let acl = try readACL(fd) else { return }
            defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
            guard try firstAllowEntry(acl) == nil else { throw Failure.unsafePath }
        }

        func assertStillAtOriginalPath() throws {
            let current = try Directory.open(at: url, create: false, tighten: false)
            let priorInfo = try status(fd), currentInfo = try status(current.fd)
            guard Identity(priorInfo) == Identity(currentInfo) else {
                throw Failure.unsafePath
            }
        }

        var identity: Identity { get throws { Identity(try status(fd)) } }

        /// Shared ancestors remain usable for export, but do not become a
        /// trusted cleanup namespace merely because this child is ours.
        func ownedParentForTemporaryRecovery() throws -> Directory? {
            let parentFD = openat(fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard parentFD >= 0 else { throw system("bind temporary parent") }
            var transferred = false
            defer { if !transferred { _ = Darwin.close(parentFD) } }
            let info = try status(parentFD)
            #if DEBUG
            let unavailable = temporaryTrackingParentUnavailable
            #else
            let unavailable = false
            #endif
            guard info.st_uid == getuid(), !unavailable else {
                recoveryLog.notice("temporary_recovery reason=shared_parent_preserved")
                return nil
            }
            let parent = Directory(fd: parentFD, url: url.deletingLastPathComponent())
            transferred = true
            try parent.assertStillAtOriginalPath()
            return parent
        }

        /// The caller owns the returned descriptor. An existing leaf is never
        /// opened for writing by this creation-only operation.
        func createPrivateFile(named name: String) throws -> Int32 {
            try validateName(name)
            let item = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard item >= 0 else { throw pathFailure("create private file") }
            do { try makePrivate(item, directory: false) }
            catch {
                let owned = try? status(item)
                _ = Darwin.close(item)
                if let owned { removeIfMatching(name, identity: Identity(owned)) }
                throw error
            }
            return item
        }

        func openRegularFile(named name: String, flags: Int32, create: Bool) throws -> Int32 {
            guard let before = try entryStatus(name) else {
                guard create else { throw Failure.system(operation: "open file", code: ENOENT) }
                return try createPrivateFile(named: name)
            }
            try requireRegular(before)
            let item = openat(fd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard item >= 0 else { throw pathFailure("open existing file") }
            do {
                let opened = try status(item)
                try requireRegular(opened)
                guard Identity(opened) == Identity(before) else { throw Failure.unsafePath }
            } catch { _ = Darwin.close(item); throw error }
            return item
        }

        func directoryIfPresent(named name: String) throws -> Directory? {
            guard let before = try entryStatus(name) else { return nil }
            try requireOwner(before)
            guard before.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
            let result = try subdirectory(named: name, create: false)
            guard try result.identity == Identity(before) else { throw Failure.unsafePath }
            return result
        }

        /// Detach the expected directory into a private namespace before any
        /// recursive deletion. A name swapped during rename is restored (when
        /// free) and is never passed to the recursive remover.
        func moveDirectory(named name: String, matching identity: Identity,
                           to destination: Directory, named destinationName: String) throws {
            try validateName(destinationName)
            guard let source = try directoryIfPresent(named: name),
                  try source.identity == identity else { throw Failure.unsafePath }
            guard renameatx_np(fd, name, destination.fd, destinationName, UInt32(RENAME_EXCL)) == 0 else {
                throw pathFailure("detach temporary directory")
            }
            guard let detached = try destination.directoryIfPresent(named: destinationName),
                  try detached.identity == identity else {
                _ = renameatx_np(destination.fd, destinationName, fd, name, UInt32(RENAME_EXCL))
                throw Failure.unsafePath
            }
            try synchronize()
            try destination.synchronize()
        }

        func removeDirectory(named name: String, matching identity: Identity) throws {
            guard let owned = try directoryIfPresent(named: name),
                  try owned.identity == identity else { throw Failure.unsafePath }
            try owned.removeContents()
            guard let current = try entryStatus(name), Identity(current) == identity else { throw Failure.unsafePath }
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw system("remove owned directory") }
            try synchronize()
        }

        private func removeContents() throws {
            for name in try names() {
                guard let before = try entryStatus(name) else { throw Failure.unsafePath }
                try requireOwner(before)
                if before.st_mode & S_IFMT == S_IFDIR {
                    try removeDirectory(named: name, matching: Identity(before))
                } else {
                    try requireRegular(before)
                    guard let current = try entryStatus(name), Identity(current) == Identity(before) else {
                        throw Failure.unsafePath
                    }
                    guard unlinkat(fd, name, 0) == 0 else { throw system("remove owned file") }
                }
            }
        }

        @discardableResult
        func requireRegularFileIfPresent(named name: String) throws -> Bool {
            guard let info = try entryStatus(name) else { return false }
            try requireRegular(info)
            return true
        }

        func tightenIfPresent(named name: String) throws {
            guard let info = try entryStatus(name) else { return }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            guard isDirectory || info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafePath }
            try requireOwner(info)
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (isDirectory ? O_DIRECTORY : 0)
            let item = openat(fd, name, flags)
            guard item >= 0 else { throw pathFailure("open private object") }
            defer { _ = Darwin.close(item) }
            let opened = try status(item)
            guard Identity(opened) == Identity(info) else { throw Failure.unsafePath }
            try requireOwner(opened)
        }

        func readIfPresent(named name: String) throws -> Data? {
            guard try requireRegularFileIfPresent(named: name) else { return nil }
            let item = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard item >= 0 else { throw pathFailure("open private file") }
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            try requireRegular(status(item))
            return try handle.readToEnd() ?? Data()
        }

        func atomicWrite(_ data: Data, named name: String, requireAbsent: Bool = false,
                         temporaryPrefix: String = ".sensitive-write-") throws {
            let original = try entryStatus(name)
            if let original { try requireRegular(original) }
            if requireAbsent, original != nil { throw Failure.system(operation: "create private file", code: EEXIST) }
            // Opening without truncation asks the kernel about effective write
            // access, including ACL denials, before any replacement is made.
            var originalFD: Int32 = -1
            var originalACL: acl_t?
            defer {
                if originalFD >= 0 { _ = Darwin.close(originalFD) }
                if let originalACL { _ = acl_free(UnsafeMutableRawPointer(originalACL)) }
            }
            if let original {
                originalFD = openat(fd, name, O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                guard originalFD >= 0 else { throw pathFailure("write access to existing file") }
                guard Identity(try status(originalFD)) == Identity(original) else { throw Failure.unsafePath }
                originalACL = try readACL(originalFD)
            }
            let temporary = temporaryPrefix + UUID().uuidString + ".tmp"
            try validateName(temporary)
            let item = try createPrivateFile(named: temporary)
            let pendingIdentity = Identity(try status(item))
            // Unlink only this invocation's exclusive temporary entry. This
            // also runs if writing, syncing, closing or replacing fails.
            var pending = true
            defer { if pending { removeIfMatching(temporary, identity: pendingIdentity) } }
            // Keep the lease through close/rename. Recovery never treats an
            // active writer's temporary inode as abandoned.
            let lease = dup(item)
            guard lease >= 0 else { _ = Darwin.close(item); throw system("lease private temporary file") }
            defer { _ = Darwin.close(lease) }
            guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
                _ = Darwin.close(item)
                throw system("lock private temporary file")
            }
            recordTemporary(item: lease, kind: "write", destination: name,
                            digest: SessionArchiveCoding.digest(data), replacement: nil)
            defer { if !pending { _ = fremovexattr(lease, temporaryAttribute, 0) } }
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            try writeBytes(data, to: item)
            if let original {
                // Only capability errors allow a fallback. Check the new
                // inode, not just the original, before committing its bytes.
                try setPermission(.owner, fd: item, description: "preserve file owner") {
                    fchown(item, original.st_uid, original.st_gid)
                }
                let modeSet = try setPermission(.mode, fd: item, description: "preserve file mode") {
                    fchmod(item, original.st_mode & 0o7777)
                }
                if let originalACL {
                    try setPermission(.setACL, fd: item, description: "preserve file ACL", { acl_set_fd(item, originalACL) })
                    let copiedACL = try readACL(item)
                    defer { if let copiedACL { _ = acl_free(UnsafeMutableRawPointer(copiedACL)) } }
                    try compareAvailableACLs(copiedACL, originalACL)
                }
                let copied = try status(item)
                guard copied.st_uid == original.st_uid, copied.st_gid == original.st_gid else { throw Failure.unsafePath }
                if modeSet {
                    guard copied.st_mode & 0o7777 == original.st_mode & 0o7777 else { throw Failure.unsafePath }
                } else {
                    guard copied.st_mode & 0o7777 & ~(original.st_mode & 0o7777) == 0 else { throw Failure.unsafePath }
                }
            }
            try handle.synchronize()
            #if DEBUG
            try beforeTemporaryCommit?(url.appendingPathComponent(temporary))
            #endif
            try handle.close()
            if let original {
                guard let current = try entryStatus(name), Identity(current) == Identity(original),
                      current.st_mode == original.st_mode else { throw Failure.unsafePath }
                let currentACL = try readACL(originalFD)
                defer { if let currentACL { _ = acl_free(UnsafeMutableRawPointer(currentACL)) } }
                try compareAvailableACLs(currentACL, originalACL)
            } else if try entryStatus(name) != nil { throw Failure.unsafePath }
            if original == nil {
                if perform(.link, { linkat(fd, temporary, fd, name, 0) }) == 0 {
                    guard unlinkat(fd, temporary, 0) == 0 else { throw system("unlink private temporary file") }
                } else {
                    guard canUsePlainRename(errno) else { throw pathFailure("commit private file") }
                    try commitByRename(temporary, to: name, requireAbsent: true)
                }
                pending = false
            } else if let original {
                // Swap keeps the replaced inode reachable until its identity
                // and constraints have been checked after the atomic commit.
                // A concurrent chmod/ACL edit or pathname replacement is
                // rolled back instead of silently losing that restriction.
                if perform(.swap, { renameatx_np(fd, temporary, fd, name, UInt32(RENAME_SWAP)) }) != 0 {
                    guard canUsePlainRename(errno) else { throw pathFailure("replace private file") }
                    try commitByRename(temporary, to: name, requireAbsent: false)
                    pending = false
                    try synchronize()
                    ExitDeadline.storageDidProgress()
                    return
                }
                do {
                    guard let replaced = try entryStatus(temporary), Identity(replaced) == Identity(original),
                          replaced.st_mode == original.st_mode, replaced.st_gid == original.st_gid else {
                        throw Failure.unsafePath
                    }
                    let replacedACL = try readACL(originalFD)
                    defer { if let replacedACL { _ = acl_free(UnsafeMutableRawPointer(replacedACL)) } }
                    try compareAvailableACLs(replacedACL, originalACL)
                    guard unlinkat(fd, temporary, 0) == 0 else { throw system("retire replaced file") }
                } catch {
                    if let current = try entryStatus(name), Identity(current) == pendingIdentity {
                        _ = renameatx_np(fd, temporary, fd, name, UInt32(RENAME_SWAP))
                    }
                    throw error
                }
                pending = false
            }
            try synchronize()
            ExitDeadline.storageDidProgress()
        }

        private func commitByRename(_ temporary: String, to name: String, requireAbsent: Bool) throws {
            if requireAbsent {
                if perform(.exclusiveRename, { renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) }) == 0 { return }
                guard canUsePlainRename(errno) else { throw pathFailure("commit private file") }
                guard try entryStatus(name) == nil else { throw Failure.unsafePath }
            }
            // Plain same-directory rename is the baseline-compatible fallback.
            // The last-check/rename race against same-user attackers is an
            // explicitly documented limitation, not a filesystem requirement.
            guard renameat(fd, temporary, fd, name) == 0 else { throw pathFailure("commit private file") }
        }

        func append(_ data: Data, named name: String) throws {
            let original = try entryStatus(name)
            if let original { try requireRegular(original) }
            let item: Int32
            if original == nil { item = try createPrivateFile(named: name) }
            else { item = openat(fd, name, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
            guard item >= 0 else { throw pathFailure("open private append file") }
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            let opened = try status(item)
            try requireRegular(opened)
            if let original, Identity(opened) != Identity(original) { throw Failure.unsafePath }
            guard fcntl(item, F_SETFL, fcntl(item, F_GETFL) | O_APPEND) == 0 else { throw system("set append mode") }
            try writeBytes(data, to: item)
            try handle.synchronize()
            try handle.close()
            try synchronize()
            ExitDeadline.storageDidProgress()
        }

        func truncate(named name: String, to length: UInt64) throws {
            guard try requireRegularFileIfPresent(named: name) else { throw Failure.unsafePath }
            let item = openat(fd, name, O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard item >= 0 else { throw pathFailure("open private repair file") }
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            try requireRegular(status(item))
            try handle.truncate(atOffset: length)
            try handle.synchronize()
        }

        func removeRegularFileIfPresent(named name: String) throws {
            guard try requireRegularFileIfPresent(named: name) else { return }
            guard unlinkat(fd, name, 0) == 0 else { throw system("remove private marker") }
        }

        func names() throws -> [String] {
            // A fresh open description avoids sharing a directory scan offset.
            let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard scan >= 0 else { throw system("open private directory scan") }
            guard let stream = fdopendir(scan) else {
                let error = system("scan private directory")
                _ = Darwin.close(scan)
                throw error
            }
            defer { _ = closedir(stream) }
            var result: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw system("read private directory") }
                    return result
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if name != ".", name != ".." { result.append(name) }
            }
        }

        private func recordTemporary(item: Int32, kind: String, destination: String,
                                     digest: String?, replacement: TemporaryIdentity?) {
            do {
                let receipt = TemporaryReceipt(kind: kind, parent: TemporaryIdentity(try status(fd)),
                    item: TemporaryIdentity(try status(item)), destination: destination,
                    digest: digest, replacement: replacement)
                let bytes = try JSONEncoder().encode(receipt)
                let result = bytes.withUnsafeBytes {
                    fsetxattr(item, temporaryAttribute, $0.baseAddress, $0.count, 0, 0)
                }
                guard result == 0, fsync(item) == 0 else {
                    recoveryLog.notice("temporary_recovery reason=receipt_unavailable")
                    return
                }
            } catch {
                recoveryLog.notice("temporary_recovery reason=receipt_unavailable")
            }
        }

        /// The caller holds the empty destination's publication lock. After a
        /// swap, only that exact empty inode and the exact published replacement
        /// can establish that the staging entry has no recovery value.
        func recordInitialExportReplacement(destination: String, staged: String) throws {
            guard let original = try directoryIfPresent(named: destination),
                  let replacement = try directoryIfPresent(named: staged),
                  try original.names().isEmpty else { throw Failure.unsafePath }
            recordTemporary(item: original.fd, kind: "initial_empty", destination: destination,
                digest: nil, replacement: TemporaryIdentity(try status(replacement.fd)))
        }

        func removeEmptyDirectory(named name: String, matching identity: Identity) throws {
            guard let owned = try directoryIfPresent(named: name), try owned.identity == identity,
                  try owned.names().isEmpty,
                  let current = try entryStatus(name), Identity(current) == identity else { throw Failure.unsafePath }
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw system("retire empty temporary directory") }
            try synchronize()
        }

        /// No recursive removal, no filename-only ownership, and no disposal
        /// of unique uncommitted bytes. Unsupported/missing receipts are kept.
        @discardableResult
        func recoverTemporaryItems(initialExportTarget: String? = nil) throws -> [TemporaryRecovery] {
            try assertStillAtOriginalPath()
            let allNames = try names().sorted()
            var results: [TemporaryRecovery] = []
            for name in allNames {
                let write = initialExportTarget == nil && [".session-write-", ".sensitive-write-"].contains { prefix in
                    name.hasPrefix(prefix) && name.hasSuffix(".tmp") &&
                        UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil
                }
                let initial = name.hasPrefix(".") && name.range(of: ".initial-export-", options: .backwards).map {
                    UUID(uuidString: String(name[$0.upperBound...])) != nil &&
                        (initialExportTarget == nil || String(name[name.index(after: name.startIndex)..<$0.lowerBound]) == initialExportTarget)
                } == true
                guard write || initial else { continue }
                let reason: String
                do { reason = try recoverTemporaryItem(name, allNames: allNames, write: write) }
                catch { reason = "inspection_failed" }
                results.append(TemporaryRecovery(name: name, reason: reason))
                let fingerprint = SessionArchiveCoding.digest(Data(name.utf8))
                recoveryLog.notice("temporary_recovery id=\(fingerprint, privacy: .public) reason=\(reason, privacy: .public)")
            }
            return results
        }

        private func recoverTemporaryItem(_ name: String, allNames: [String], write: Bool) throws -> String {
            guard let before = try entryStatus(name) else { return "already_absent" }
            try requireOwner(before)
            let kind = before.st_mode & S_IFMT
            guard (write && kind == S_IFREG && before.st_nlink == 1) || (!write && kind == S_IFDIR) else {
                return "unknown_identity"
            }
            let item = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (write ? 0 : O_DIRECTORY))
            guard item >= 0 else { throw pathFailure("inspect temporary object") }
            defer { _ = Darwin.close(item) }
            guard TemporaryIdentity(try status(item)) == TemporaryIdentity(before) else { return "identity_changed" }
            guard flock(item, LOCK_EX | LOCK_NB) == 0 else { return "active_or_unavailable" }
            defer { _ = flock(item, LOCK_UN) }
            let length = fgetxattr(item, temporaryAttribute, nil, 0, 0, 0)
            guard length > 0, length <= 4096 else { return "unregistered" }
            var bytes = Data(count: length)
            let read = bytes.withUnsafeMutableBytes { fgetxattr(item, temporaryAttribute, $0.baseAddress, $0.count, 0, 0) }
            guard read == length,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys).isSubset(of: ["version", "kind", "parent", "item", "destination", "digest", "replacement"]),
                  let receipt = try? JSONDecoder().decode(TemporaryReceipt.self, from: bytes), receipt.version == 1,
                  receipt.parent == TemporaryIdentity(try status(fd)), receipt.item == TemporaryIdentity(before),
                  receipt.kind == (write ? "write" : "initial_empty") else { return "unknown_receipt" }
            try validateName(receipt.destination)
            // Sibling aliases are references too. Never follow them or read
            // arbitrary files while deciding whether a temporary item is unused.
            for sibling in allNames {
                guard let info = try entryStatus(sibling), info.st_mode & S_IFMT == S_IFLNK else { continue }
                guard let value = try linkTarget(named: sibling) else { return "reference_unknown" }
                guard let referenced = try referencesTemporary(value, name: name, identity: receipt.item) else {
                    return "reference_unknown"
                }
                if referenced { return "referenced" }
            }
            let reason: String
            var destinationIdentity: TemporaryIdentity?
            if write {
                let current = try status(item)
                guard current.st_nlink == 1 else { return "referenced" }
                if current.st_size == 0 { reason = "removed_empty" }
                else {
                    guard let expected = receipt.digest, SessionArchiveCoding.isDigest(expected),
                          let destination = try entryStatus(receipt.destination) else { return "unique_candidate" }
                    try requireRegular(destination)
                    let target = try openRegularFile(named: receipt.destination, flags: O_RDONLY, create: false)
                    let handle = FileHandle(fileDescriptor: target, closeOnDealloc: true)
                    defer { try? handle.close() }
                    let pending = FileHandle(fileDescriptor: item, closeOnDealloc: false)
                    guard SessionArchiveCoding.digest(try pending.readToEnd() ?? Data()) == expected,
                          SessionArchiveCoding.digest(try handle.readToEnd() ?? Data()) == expected else { return "unique_candidate" }
                    destinationIdentity = TemporaryIdentity(destination)
                    reason = "removed_duplicate"
                }
            } else {
                let owned = Directory(fd: dup(item), url: url.appendingPathComponent(name, isDirectory: true))
                guard owned.fd >= 0, try owned.names().isEmpty else { return "nonempty_candidate" }
                guard name.hasPrefix("." + receipt.destination + ".initial-export-"),
                      let replacement = receipt.replacement,
                      let destination = try entryStatus(receipt.destination), destination.st_mode & S_IFMT == S_IFDIR,
                      TemporaryIdentity(destination) == replacement, replacement != receipt.item else { return "publication_unknown" }
                destinationIdentity = replacement
                reason = "removed_empty"
            }
            try assertStillAtOriginalPath()
            guard let current = try entryStatus(name), TemporaryIdentity(current) == receipt.item,
                  !write || current.st_nlink == 1 else { return "identity_changed" }
            if let destinationIdentity {
                guard let destination = try entryStatus(receipt.destination), TemporaryIdentity(destination) == destinationIdentity else {
                    return "destination_changed"
                }
            }
            guard unlinkat(fd, name, write ? 0 : AT_REMOVEDIR) == 0 else { throw system("retire unused temporary object") }
            try synchronize()
            return reason
        }

        private func linkTarget(named name: String) throws -> String? {
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(fd, name, &target, target.count - 1)
            guard count >= 0, count < target.count - 1 else { return nil }
            return String(bytes: target.prefix(Int(count)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
        }

        /// Resolve only inside this bound directory. Outside references,
        /// ambiguous '..' paths and cycles are unknown, so the item is kept.
        private func referencesTemporary(_ target: String, name: String,
                                         identity: TemporaryIdentity) throws -> Bool? {
            let base = try systemAliasPath(url.standardizedFileURL.path)
            let candidate = try systemAliasPath(url.appendingPathComponent(name).standardizedFileURL.path)
            var pending = target.hasPrefix("/") ? URL(fileURLWithPath: target) : url.appendingPathComponent(target)
            if target.split(separator: "/").contains("..") { return nil }
            for _ in 0..<32 {
                let path = try systemAliasPath(pending.standardizedFileURL.path)
                guard path == base || path.hasPrefix(base + "/") else { return nil }
                if path == candidate || path.hasPrefix(candidate + "/") { return true }
                let parts = path.dropFirst(base.count).split(separator: "/").map(String.init)
                if parts.isEmpty { return true }
                var directory = self
                var redirected = false
                for (index, part) in parts.enumerated() {
                    guard let info = try directory.entryStatus(part) else { return nil }
                    let kind = info.st_mode & S_IFMT
                    if kind == S_IFLNK {
                        guard let link = try directory.linkTarget(named: part),
                              !link.split(separator: "/").contains("..") else { return nil }
                        pending = link.hasPrefix("/") ? URL(fileURLWithPath: link) : directory.url.appendingPathComponent(link)
                        for remaining in parts.dropFirst(index + 1) { pending.appendPathComponent(remaining) }
                        redirected = true
                        break
                    }
                    if index == parts.count - 1 { return TemporaryIdentity(info) == identity }
                    guard kind == S_IFDIR, let next = try directory.directoryIfPresent(named: part) else { return nil }
                    directory = next
                }
                if !redirected { return nil }
            }
            return nil
        }

        private func entryStatus(_ name: String) throws -> stat? {
            try validateName(name)
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
            if errno == ENOENT { return nil }
            throw system("inspect private entry")
        }

        private func removeIfMatching(_ name: String, identity: Identity) {
            guard let current = try? entryStatus(name), Identity(current) == identity else { return }
            _ = unlinkat(fd, name, 0)
        }

        private func synchronize() throws {
            guard perform(.directorySync, { fsync(fd) }) == 0 || unsupported(errno) else { throw system("sync private directory") }
        }
    }

    private static func aclText(_ acl: acl_t) throws -> String {
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { throw system("read ACL constraints") }
        defer { _ = acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private static func writeBytes(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(1_048_576, bytes.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    if count == 0 { errno = EIO }
                    throw system("write private file")
                }
                offset += count
                ExitDeadline.storageDidProgress()
            }
        }
    }

    private static func readACL(_ fd: Int32) throws -> acl_t? {
        #if DEBUG
        operationObserver?(.readACL)
        if let code = operationErrors[.readACL] {
            if missingPermissionCapability(.readACL, fd: fd, code: code) { return nil }
            throw Failure.system(operation: "read existing ACL", code: code)
        }
        if let aclReadError {
            if missingPermissionCapability(.readACL, fd: fd, code: aclReadError) { return nil }
            throw Failure.system(operation: "read existing ACL", code: aclReadError)
        }
        if unsupportedOperations.contains(.readACL) { return nil }
        #endif
        if let acl = acl_get_fd(fd) { return acl }
        let code = errno
        if missingPermissionCapability(.readACL, fd: fd, code: code) { return nil }
        guard code == ENOENT else {
            throw Failure.system(operation: "read existing ACL", code: code)
        }
        guard let empty = acl_init(0) else { throw system("create empty ACL") }
        return empty
    }

    private static func compareAvailableACLs(_ lhs: acl_t?, _ rhs: acl_t?) throws {
        // Unsupported metadata cannot discard constraints we already read.
        guard let rhs else { return }
        if let lhs {
            guard try aclText(lhs) == aclText(rhs) else { throw Failure.unsafePath }
        } else {
            guard let empty = acl_init(0) else { throw system("compare ACL constraints") }
            defer { _ = acl_free(UnsafeMutableRawPointer(empty)) }
            guard try aclText(empty) == aclText(rhs) else { throw Failure.unsafePath }
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw Failure.unsafePath
        }
    }

    private static func systemAliasPath(_ path: String) throws -> String {
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            var info = stat()
            guard lstat(alias, &info) == 0 else { throw system("inspect system alias") }
            if info.st_mode & S_IFMT == S_IFDIR { return path }
            guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFLNK else { throw Failure.unsafePath }
            let expected = "/private" + alias
            var bytes = [CChar](repeating: 0, count: 128)
            let length = readlink(alias, &bytes, bytes.count)
            guard length > 0, length < bytes.count else { throw Failure.unsafePath }
            let target = bytes.prefix(length).map { UInt8(bitPattern: $0) }
            let targetPath = String(bytes: target, encoding: .utf8)
            // These aliases live directly under '/', so the fixed relative
            // form private/... names the same verified system directory.
            guard targetPath == expected || targetPath == String(expected.dropFirst()) else {
                throw Failure.unsafePath
            }
            return expected + path.dropFirst(alias.count)
        }
        return path
    }

    private static func status(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw system("inspect private descriptor") }
        return info
    }

    private static func requireOwner(_ info: stat) throws {
        guard info.st_uid == getuid() else { throw Failure.unsafePath }
    }

    private static func requireRegular(_ info: stat) throws {
        try requireOwner(info)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.unsafePath }
    }

    private static func makePrivate(_ fd: Int32, directory: Bool) throws {
        let info = try status(fd)
        try requireOwner(info)
        if directory {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
        } else { try requireRegular(info) }
        // Remove group/other and executable-file bits without restoring an
        // owner permission the user deliberately removed (for example 0500).
        let mode: mode_t = info.st_mode & (directory ? 0o700 : 0o600)
        if try setPermission(.mode, fd: fd, description: "set private mode", { fchmod(fd, mode) }) {
            guard try status(fd).st_mode & 0o7777 == mode else { throw Failure.unsafePath }
        }
        // Creation callers remove their exclusive file if privacy fails.
        // Volumes without the capability may still use the portable fallback.
        try removeAllowACLs(fd)
    }

    private static func firstAllowEntry(_ acl: acl_t) throws -> acl_entry_t? {
        guard acl_valid(acl) == 0 else { throw system("validate private ACL") }
        var cursor = Int32(ACL_FIRST_ENTRY.rawValue)
        while true {
            var entry: acl_entry_t?
            if acl_get_entry(acl, cursor, &entry) != 0 {
                if errno == EINVAL { return nil } // Darwin's end-of-ACL result.
                throw system("read private ACL entry")
            }
            // Darwin also reports the end of a valid empty ACL as success
            // with a nil entry. It is not an unsafe object.
            guard let entry else { return nil }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw system("read private ACL tag") }
            if tag == ACL_EXTENDED_ALLOW { return entry }
            guard tag == ACL_EXTENDED_DENY else { throw Failure.unsafePath }
            cursor = Int32(ACL_NEXT_ENTRY.rawValue)
        }
    }

    private static func removeAllowACLs(_ fd: Int32) throws {
        guard let acl = try readACL(fd) else { return }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var changed = false
        while let entry = try firstAllowEntry(acl) {
            guard acl_delete_entry(acl, entry) == 0 else { throw system("remove private allow ACL") }
            changed = true
        }
        if changed {
            guard try setPermission(.setACL, fd: fd, description: "set private ACL", { acl_set_fd(fd, acl) }) else { return }
        }
        guard let verified = try readACL(fd) else { return }
        defer { _ = acl_free(UnsafeMutableRawPointer(verified)) }
        guard try firstAllowEntry(verified) == nil else { throw Failure.unsafePath }
    }

    private static func system(_ operation: String) -> Failure {
        .system(operation: operation, code: errno)
    }

    private static func pathFailure(_ operation: String) -> Failure {
        if errno == ELOOP || errno == ENOTDIR { return .unsafePath }
        return system(operation)
    }
}
