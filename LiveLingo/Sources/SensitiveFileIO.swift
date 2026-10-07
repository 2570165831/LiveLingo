import Darwin
import Foundation

/// Newly created objects are private. Existing objects are validated without
/// changing their permissions; replacements preserve their access constraints.
enum SensitiveFileIO {
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
            let acl = try readACL(fd)
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
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            if let original, let originalACL {
                guard fchown(item, original.st_uid, original.st_gid) == 0 else { throw system("preserve file owner") }
                guard fchmod(item, original.st_mode & 0o7777) == 0 else { throw system("preserve file mode") }
                guard acl_set_fd(item, originalACL) == 0 else { throw system("preserve file ACL") }
                let verified = try readACL(item)
                defer { _ = acl_free(UnsafeMutableRawPointer(verified)) }
                guard try aclText(verified) == aclText(originalACL),
                      try status(item).st_mode & 0o7777 == original.st_mode & 0o7777 else { throw Failure.unsafePath }
            }
            try handle.synchronize()
            try handle.close()
            if let original {
                guard let current = try entryStatus(name), Identity(current) == Identity(original),
                      current.st_mode == original.st_mode,
                      let originalACL else { throw Failure.unsafePath }
                let currentACL = try readACL(originalFD)
                defer { _ = acl_free(UnsafeMutableRawPointer(currentACL)) }
                guard try aclText(currentACL) == aclText(originalACL) else { throw Failure.unsafePath }
            } else if try entryStatus(name) != nil { throw Failure.unsafePath }
            if original == nil {
                guard linkat(fd, temporary, fd, name, 0) == 0 else { throw pathFailure("commit private file") }
                guard unlinkat(fd, temporary, 0) == 0 else { throw system("unlink private temporary file") }
                pending = false
            } else if let original, let originalACL {
                // Swap keeps the replaced inode reachable until its identity
                // and constraints have been checked after the atomic commit.
                // A concurrent chmod/ACL edit or pathname replacement is
                // rolled back instead of silently losing that restriction.
                guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_SWAP)) == 0 else {
                    throw pathFailure("replace private file")
                }
                do {
                    guard let replaced = try entryStatus(temporary), Identity(replaced) == Identity(original),
                          replaced.st_mode == original.st_mode, replaced.st_gid == original.st_gid else {
                        throw Failure.unsafePath
                    }
                    let replacedACL = try readACL(originalFD)
                    defer { _ = acl_free(UnsafeMutableRawPointer(replacedACL)) }
                    guard try aclText(replacedACL) == aclText(originalACL) else { throw Failure.unsafePath }
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
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try synchronize()
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
            guard fsync(fd) == 0 else { throw system("sync private directory") }
        }
    }

    private static func aclText(_ acl: acl_t) throws -> String {
        var length: ssize_t = 0
        guard let text = acl_to_text(acl, &length) else { throw system("read ACL constraints") }
        defer { _ = acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private static func readACL(_ fd: Int32) throws -> acl_t {
        if let acl = acl_get_fd(fd) { return acl }
        guard errno == ENOENT, let empty = acl_init(0) else { throw system("read existing ACL") }
        return empty
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
        guard fchmod(fd, mode) == 0 else { throw system("set private permissions") }
        try removeAllowACLs(fd)
        guard try status(fd).st_mode & 0o777 == mode else { throw Failure.unsafePath }
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
        guard let acl = acl_get_fd(fd) else {
            if errno == ENOENT { return }
            throw system("read private ACL")
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var changed = false
        while let entry = try firstAllowEntry(acl) {
            guard acl_delete_entry(acl, entry) == 0 else { throw system("remove private allow ACL") }
            changed = true
        }
        if changed {
            guard acl_set_fd(fd, acl) == 0 else { throw system("set private ACL") }
        }
        guard let verified = acl_get_fd(fd) else {
            if errno == ENOENT { return }
            throw system("verify private ACL")
        }
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
