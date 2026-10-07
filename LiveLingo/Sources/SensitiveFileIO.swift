import Darwin
import Foundation

/// Body-bearing files use owned descriptors, private modes and no allow ACLs.
/// Existing ancestors are opened without following links and are never changed.
enum SensitiveFileIO {
    enum Failure: Error {
        case unsafePath
        case system(operation: String, code: Int32)
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
                        if created || tighten { try makePrivate(next, directory: true) }
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
            var child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            if child < 0, errno == ENOENT, create {
                if mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw system("create private directory") }
                child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard child >= 0 else { throw pathFailure("open private directory") }
            do { try makePrivate(child, directory: true) }
            catch { _ = Darwin.close(child); throw error }
            return Directory(fd: child, url: url.appendingPathComponent(name, isDirectory: true))
        }

        func assertStillAtOriginalPath() throws {
            let current = try Directory.open(at: url, create: false, tighten: false)
            let priorInfo = try status(fd), currentInfo = try status(current.fd)
            guard priorInfo.st_dev == currentInfo.st_dev, priorInfo.st_ino == currentInfo.st_ino else {
                throw Failure.unsafePath
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
            try makePrivate(item, directory: isDirectory)
        }

        func readIfPresent(named name: String) throws -> Data? {
            guard try requireRegularFileIfPresent(named: name) else { return nil }
            let item = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard item >= 0 else { throw pathFailure("open private file") }
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            try makePrivate(item, directory: false)
            return try handle.readToEnd() ?? Data()
        }

        func atomicWrite(_ data: Data, named name: String, requireAbsent: Bool = false,
                         temporaryPrefix: String = ".sensitive-write-") throws {
            let exists = try requireRegularFileIfPresent(named: name)
            if requireAbsent, exists { throw Failure.system(operation: "create private file", code: EEXIST) }
            let temporary = temporaryPrefix + UUID().uuidString + ".tmp"
            try validateName(temporary)
            let item = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard item >= 0 else { throw system("create private temporary file") }
            // Unlink only this invocation's exclusive temporary entry. This
            // also runs if writing, syncing, closing or replacing fails.
            var pending = true
            defer { if pending { _ = unlinkat(fd, temporary, 0) } }
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            try makePrivate(item, directory: false)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if requireAbsent {
                guard linkat(fd, temporary, fd, name, 0) == 0 else { throw pathFailure("commit private file") }
                guard unlinkat(fd, temporary, 0) == 0 else { throw system("unlink private temporary file") }
                pending = false
            } else {
                guard renameat(fd, temporary, fd, name) == 0 else { throw pathFailure("replace private file") }
                pending = false
            }
            try synchronize()
        }

        func append(_ data: Data, named name: String) throws {
            _ = try requireRegularFileIfPresent(named: name)
            let item = openat(fd, name, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard item >= 0 else { throw pathFailure("open private append file") }
            let handle = FileHandle(fileDescriptor: item, closeOnDealloc: true)
            defer { try? handle.close() }
            try makePrivate(item, directory: false)
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
            try makePrivate(item, directory: false)
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

        private func synchronize() throws {
            guard fsync(fd) == 0 else { throw system("sync private directory") }
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
