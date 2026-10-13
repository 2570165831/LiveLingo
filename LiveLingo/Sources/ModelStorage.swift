import Combine
import CryptoKit
import Darwin
import Foundation
import os

/// The inventory is sealed with the App, never trusted from an external model
/// package. 0.3.0 only stages data; its runtime continues using bundle Models.
struct ModelStorageManifest: Codable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
        let sampleSHA256: String
    }
    struct Model: Codable, Equatable, Sendable {
        let name: String
        let version: String
        let sourceRelativePath: String
        let files: [File]
    }
    let schemaVersion: Int
    let sampleAlgorithm: String
    let fullHashMaxBytes: Int
    let models: [Model]

    static let filename = "model-storage-manifest.json"
    static let fullLimit = 1 << 20
    static let sampleBytes = 64 << 10

    static func component(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 180 && value != "." && value != ".."
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
    static func relative(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component(String($0)) }
    }
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func validate() throws {
        guard schemaVersion == 1, sampleAlgorithm == "first-middle-last-64KiB-v1",
              fullHashMaxBytes == Self.fullLimit, !models.isEmpty,
              Set(models.map(\.name)).count == models.count,
              Set(models.map(\.sourceRelativePath)).count == models.count else { throw ModelStorage.Failure.manifest }
        for model in models {
            guard Self.component(model.name), model.version.hasPrefix("sha256-"),
                  Self.digest(String(model.version.dropFirst(7))), Self.relative(model.sourceRelativePath),
                  !model.files.isEmpty, Set(model.files.map(\.path)).count == model.files.count else {
                throw ModelStorage.Failure.manifest
            }
            let paths = Set(model.files.map(\.path))
            for file in model.files {
                guard Self.relative(file.path), file.size >= 0, Self.digest(file.sha256),
                      Self.digest(file.sampleSHA256), file.size > Self.fullLimit || file.sha256 == file.sampleSHA256,
                      file.path != ModelStorage.receiptName,
                      !file.path.hasPrefix(ModelStorage.receiptName + "/") else { throw ModelStorage.Failure.manifest }
                var parent = (file.path as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    guard !paths.contains(parent) else { throw ModelStorage.Failure.manifest }
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 << 20 else { throw ModelStorage.Failure.manifest }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }
}

enum ModelStorage {
    enum Failure: Error, Equatable {
        case manifest, unsafePath, mismatch, deferred, busy
        case system(Int32)
    }
    enum Verification: String, Codable, Sendable { case sampledPrecloneV1, fullSHA256 }
    enum Outcome: String, Sendable { case cloned, alreadyPresent, refreshed, repaired }
    /// Content versions survive reinstalling the App; source inodes do not.
    /// This is conservative provenance, not a physical-extent measurement or
    /// an authentication claim based on a writable receipt.
    struct FileIdentity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
        func sameDataObject(as other: Self) -> Bool {
            device == other.device && inode == other.inode && size == other.size
                && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
                && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }
    struct Receipt: Codable, Equatable {
        let schemaVersion: Int
        let model: String
        let version: String
        let manifestSHA256: String
        let verification: Verification
        var sourceFiles: [String: FileIdentity]? = nil
        var clonedFiles: [String: FileIdentity]? = nil
        func belongs(to model: ModelStorageManifest.Model) -> Bool {
            schemaVersion == 1 && self.model == model.name && version == model.version
                && ModelStorageManifest.digest(manifestSHA256) && verification == .sampledPrecloneV1
        }
    }
    static let receiptName = "preclone-state.json"
    static let log = Logger(subsystem: "com.jianhongli.LiveLingo", category: "ModelPreclone")
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func diagnostic(_ error: Error) -> String {
        switch error {
        case Failure.system(let code): return "clone_or_io_errno_\(code)"
        case Failure.manifest: return "manifest_invalid"
        case Failure.unsafePath: return "unsafe_path"
        case Failure.mismatch: return "verification_mismatch"
        case Failure.deferred, is CancellationError: return "deferred"
        case Failure.busy: return "another_preclone_active"
        default: return "io_failed"
        }
    }

    /// All paths below a granted root are walked relative to open descriptors;
    /// symlinks, hard links, non-regular files and replaced directories fail.
    final class Directory {
        let fd: Int32
        init(fd: Int32) { self.fd = fd }
        deinit { _ = Darwin.close(fd) }
        static func open(_ url: URL, owned: Bool) throws -> Directory {
            guard url.isFileURL, !url.path.utf8.contains(0) else { throw Failure.unsafePath }
            // Darwin's documented system aliases only, not arbitrary symlinks.
            var path = url.path
            for alias in ["/var", "/tmp"] where path == alias || path.hasPrefix(alias + "/") {
                path = "/private" + path
            }
            let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW_ANY)
            guard fd >= 0 else { throw Failure.system(errno) }
            let result = Directory(fd: fd)
            let info = try result.status()
            guard !owned || info.st_uid == getuid() else { throw Failure.unsafePath }
            return result
        }
        func status() throws -> stat {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw Failure.system(errno) }
            return info
        }
        func assertBound(to url: URL) throws {
            let bound = try Self.open(url, owned: true)
            let original = try status(), current = try bound.status()
            guard original.st_dev == current.st_dev, original.st_ino == current.st_ino else { throw Failure.unsafePath }
        }
        func child(_ name: String, create: Bool, owned: Bool = true) throws -> Directory {
            guard ModelStorageManifest.component(name) else { throw Failure.unsafePath }
            if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw Failure.system(errno) }
            let opened = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard opened >= 0 else { throw Failure.system(errno) }
            let result = Directory(fd: opened)
            let info = try result.status()
            guard !owned || info.st_uid == getuid() else { throw Failure.unsafePath }
            return result
        }
        func descendant(_ path: String, create: Bool, owned: Bool) throws -> Directory {
            guard ModelStorageManifest.relative(path) else { throw Failure.unsafePath }
            var result = self
            for component in path.split(separator: "/") {
                result = try result.child(String(component), create: create, owned: owned)
            }
            return result
        }
        func file(_ name: String, create: Bool = false) throws -> Int32 {
            guard ModelStorageManifest.component(name) else { throw Failure.unsafePath }
            let flags = O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (create ? O_RDWR | O_CREAT | O_EXCL : O_RDONLY)
            let opened = openat(fd, name, flags, 0o600)
            guard opened >= 0 else { throw Failure.system(errno) }
            var info = stat()
            guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                _ = Darwin.close(opened); throw Failure.unsafePath
            }
            return opened
        }
        func read(_ name: String) throws -> Data {
            let opened = try file(name)
            defer { _ = Darwin.close(opened) }
            var info = stat()
            guard fstat(opened, &info) == 0, info.st_size <= 16 << 20 else { throw Failure.unsafePath }
            let handle = FileHandle(fileDescriptor: opened, closeOnDealloc: false)
            return try handle.readToEnd() ?? Data()
        }
        func writeReceipt(_ value: Receipt) throws {
            let opened = try file(receiptName, create: true)
            defer { _ = Darwin.close(opened) }
            try FileHandle(fileDescriptor: opened, closeOnDealloc: false).write(contentsOf: JSONEncoder().encode(value))
            guard fsync(opened) == 0, fsync(fd) == 0 else { throw Failure.system(errno) }
        }
        func receiptSnapshot() throws -> (Receipt, stat) {
            let opened = try file(receiptName)
            defer { _ = Darwin.close(opened) }
            var before = stat(), after = stat()
            guard fstat(opened, &before) == 0, before.st_uid == getuid(), before.st_size <= 16 << 20 else {
                throw Failure.unsafePath
            }
            let data = try FileHandle(fileDescriptor: opened, closeOnDealloc: false).readToEnd() ?? Data()
            guard fstat(opened, &after) == 0, sameSnapshot(before, after) else { throw Failure.unsafePath }
            return (try JSONDecoder().decode(Receipt.self, from: data), after)
        }
        func replaceStagingReceipt(_ value: Receipt) throws {
            let (original, info) = try receiptSnapshot()
            guard original.schemaVersion == value.schemaVersion, original.model == value.model,
                  original.version == value.version, original.manifestSHA256 == value.manifestSHA256,
                  original.verification == value.verification else { throw Failure.mismatch }
            let temporary = ".receipt-" + UUID().uuidString
            let opened = try file(temporary, create: true)
            defer { _ = Darwin.close(opened) }
            try FileHandle(fileDescriptor: opened, closeOnDealloc: false).write(contentsOf: JSONEncoder().encode(value))
            var current = stat()
            guard fsync(opened) == 0, fstatat(fd, receiptName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  sameSnapshot(info, current) else { throw Failure.unsafePath }
            guard renameatx_np(fd, temporary, fd, receiptName, UInt32(RENAME_SWAP)) == 0 else { throw Failure.system(errno) }
            // Only the staging marker we just exchanged is released, never an
            // arbitrary path or a marker from the old committed model.
            guard fstatat(fd, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                  current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                  current.st_uid == getuid() else { throw Failure.unsafePath }
            guard unlinkat(fd, temporary, 0) == 0, fsync(fd) == 0 else { throw Failure.system(errno) }
        }
        func matches(_ child: Directory, name: String) throws -> Bool {
            var linked = stat()
            let opened = try child.status()
            guard fstatat(fd, name, &linked, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.system(errno) }
            return linked.st_mode & S_IFMT == S_IFDIR && linked.st_dev == opened.st_dev
                && linked.st_ino == opened.st_ino && linked.st_uid == getuid()
        }
        func move(_ child: Directory, from: String, to: String) throws {
            guard try matches(child, name: from) else { throw Failure.unsafePath }
            guard renameatx_np(fd, from, fd, to, UInt32(RENAME_EXCL)) == 0 else { throw Failure.system(errno) }
            guard try matches(child, name: to), fsync(fd) == 0 else { throw Failure.unsafePath }
        }
        func exchange(_ staging: Directory, named stagingName: String,
                      with committed: Directory, named version: String) throws {
            guard try matches(staging, name: stagingName), try matches(committed, name: version) else {
                throw Failure.unsafePath
            }
            // The old version stays published until this single atomic swap.
            guard renameatx_np(fd, stagingName, fd, version, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure.system(errno)
            }
            guard try matches(staging, name: version), try matches(committed, name: stagingName),
                  fsync(fd) == 0 else { throw Failure.unsafePath }
        }
        func names() throws -> [String] {
            let duplicate = dup(fd)
            guard duplicate >= 0 else { throw Failure.system(errno) }
            guard let stream = fdopendir(duplicate) else { _ = Darwin.close(duplicate); throw Failure.system(errno) }
            defer { closedir(stream) }
            rewinddir(stream)
            var names: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw Failure.system(errno) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != ".", name != ".." { names.append(name) }
            }
            return names
        }
    }

    static func modelsIncludedInTimeMachine(in preferences: UserDefaults = .standard) -> Bool {
        preferences.bool(forKey: "modelsIncludedInTimeMachine")
    }

    struct Operations {
        var clone: (Int32, Int32, String) throws -> Void = { source, parent, name in
            guard fclonefileat(source, parent, name, UInt32(CLONE_NOOWNERCOPY)) == 0 else {
                throw Failure.system(errno)  // Deliberately no copy fallback.
            }
        }
        var checkpoint: () throws -> Void = { try Task.checkCancellation() }
        var modelsIncludedInTimeMachine: () -> Bool = { ModelStorage.modelsIncludedInTimeMachine() }
        var excludeFromBackup: (Int32) throws -> Void = { fd in
            // The on-disk backing for NSURLIsExcludedFromBackupKey. Use the
            // opened directory, so replacing its URL cannot mark a neighbor.
            let data = try PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0)
            try data.withUnsafeBytes { bytes in
                guard fsetxattr(fd, "com.apple.metadata:com_apple_backup_excludeItem", bytes.baseAddress,
                               bytes.count, 0, 0) == 0 else { throw Failure.system(errno) }
            }
        }
        var isExcludedFromBackup: (URL) throws -> Bool = { destination in
            // Read the actual resource state without the caller's cached values.
            var url = URL(fileURLWithPath: destination.path, isDirectory: true)
            url.removeAllCachedResourceValues()
            return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
        }
    }

    static func sourceIdentities(_ model: ModelStorageManifest.Model, at source: Directory,
                                 checkpoint: () throws -> Void = {},
                                 verification: Verification? = nil) throws -> [String: FileIdentity] {
        var result: [String: FileIdentity] = [:]
        for file in model.files {
            try checkpoint()
            let parts = file.path.split(separator: "/").map(String.init)
            var parent = source
            for part in parts.dropLast() { parent = try parent.child(part, create: false, owned: false) }
            let opened = try parent.file(parts.last!)
            defer { _ = Darwin.close(opened) }
            var info = stat()
            guard fstat(opened, &info) == 0, info.st_size == file.size else { throw Failure.mismatch }
            if let verification { info = try verifyFile(file, fd: opened, verification: verification, checkpoint: checkpoint) }
            result[file.path] = FileIdentity(info)
        }
        return result
    }

    /// Release only a recognized, same-version, regenerable cache whose whole
    /// tree contains inventory paths and our receipt. Preflight the entire tree
    /// before unlinking anything. Unknown entries/links/receipts stay retained.
    /// This is used only while 0.3.0 loaders still read the bundled models.
    static func releaseCache(_ model: ModelStorageManifest.Model, parent: Directory,
                             name: String, checkpoint: () throws -> Void) throws -> Bool {
        let directory = try parent.child(name, create: false)
        let cacheDevice = try directory.status().st_dev
        guard try parent.status().st_dev == cacheDevice else { return false }
        guard let (receipt, receiptInfo) = try? directory.receiptSnapshot(),
              receipt.belongs(to: model) else { return false }
        let payloadPaths = Set(model.files.map(\.path))
        var allowed: Set<String> = [receiptName]
        for file in model.files {
            var path = file.path
            while !path.isEmpty {
                allowed.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        var files: [(Directory, String, stat)] = []
        var directories: [(Directory, String, Directory)] = []
        func plan(_ current: Directory, prefix: String) throws -> Bool {
            for entry in try current.names() {
                try checkpoint()
                guard allowed.contains(prefix + entry) else { return false }
                var info = stat()
                guard fstatat(current.fd, entry, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.system(errno) }
                guard info.st_uid == getuid(), info.st_dev == cacheDevice else { return false }
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard !payloadPaths.contains(prefix + entry), prefix + entry != receiptName else { return false }
                    let child = try current.child(entry, create: false)
                    guard try plan(child, prefix: prefix + entry + "/") else { return false }
                    directories.append((current, entry, child))
                } else {
                    guard payloadPaths.contains(prefix + entry) || prefix + entry == receiptName,
                          info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return false }
                    files.append((current, entry, info))
                }
            }
            return true
        }
        guard try plan(directory, prefix: "") else { return false }
        // Keep the ownership marker until the payload has been released, so
        // capture interruption/crash can resume cleanup on a later idle launch.
        func unlink(_ owner: Directory, _ entry: String, _ original: stat) throws {
            try checkpoint()
            guard try parent.matches(directory, name: name) else { throw Failure.unsafePath }
            var boundReceipt = stat()
            guard fstatat(directory.fd, receiptName, &boundReceipt, AT_SYMLINK_NOFOLLOW) == 0,
                  sameSnapshot(receiptInfo, boundReceipt) else { throw Failure.unsafePath }
            for (ancestor, component, child) in directories where owner.fd != directory.fd {
                // Payload removals happen before any directory removal.
                guard try ancestor.matches(child, name: component) else { throw Failure.unsafePath }
            }
            var current = stat()
            guard fstatat(owner.fd, entry, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  sameSnapshot(original, current) else { throw Failure.unsafePath }
            guard unlinkat(owner.fd, entry, 0) == 0 else { throw Failure.system(errno) }
        }
        let marker = files.filter { $0.0.fd == directory.fd && $0.1 == receiptName }
        guard marker.count == 1, sameSnapshot(receiptInfo, marker[0].2) else { return false }
        for (owner, entry, original) in files where !(owner.fd == directory.fd && entry == receiptName) {
            try unlink(owner, entry, original)
        }
        for (index, item) in directories.enumerated() {
            let (owner, entry, child) = item
            try checkpoint()
            guard try parent.matches(directory, name: name), try owner.matches(child, name: entry) else {
                throw Failure.unsafePath
            }
            var boundReceipt = stat()
            guard fstatat(directory.fd, receiptName, &boundReceipt, AT_SYMLINK_NOFOLLOW) == 0,
                  sameSnapshot(receiptInfo, boundReceipt) else { throw Failure.unsafePath }
            for (ancestor, component, descendant) in directories.dropFirst(index) {
                guard try ancestor.matches(descendant, name: component) else { throw Failure.unsafePath }
            }
            guard unlinkat(owner.fd, entry, AT_REMOVEDIR) == 0 else { throw Failure.system(errno) }
        }
        try unlink(marker[0].0, marker[0].1, marker[0].2)
        try checkpoint()
        guard try parent.matches(directory, name: name) else { throw Failure.unsafePath }
        guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0, fsync(parent.fd) == 0 else { throw Failure.system(errno) }
        return true
    }

    static func releaseRetainedCaches(_ model: ModelStorageManifest.Model, root: Directory, parent: Directory,
                                      destinationModels: URL, checkpoint: () throws -> Void) throws {
        let prefix = ".retained-" + model.version + "-"
        for name in try parent.names() where name.hasPrefix(prefix) {
            try checkpoint()
            try root.assertBound(to: destinationModels)
            guard try root.matches(parent, name: model.name) else { throw Failure.unsafePath }
            guard UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  (try? parent.child(name, create: false)) != nil else { continue }
            let released = try releaseCache(model, parent: parent, name: name, checkpoint: {
                try checkpoint()
                try root.assertBound(to: destinationModels)
                guard try root.matches(parent, name: model.name) else { throw Failure.unsafePath }
            })
            if !released { log.notice("model=\(model.name, privacy: .public) cache=retained_unknown_entries") }
        }
    }

    static func sameSnapshot(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino
            && before.st_uid == after.st_uid && before.st_mode == after.st_mode
            && before.st_nlink == after.st_nlink && before.st_size == after.st_size
            && before.st_birthtimespec.tv_sec == after.st_birthtimespec.tv_sec
            && before.st_birthtimespec.tv_nsec == after.st_birthtimespec.tv_nsec
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    @discardableResult
    static func verifyFile(_ file: ModelStorageManifest.File, fd: Int32, verification: Verification,
                           checkpoint: () throws -> Void) throws -> stat {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size == file.size else { throw Failure.mismatch }
        var hash = SHA256()
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        if verification == .fullSHA256 || file.size <= ModelStorageManifest.fullLimit {
            try handle.seek(toOffset: 0)
            while true {
                try checkpoint()
                guard let data = try handle.read(upToCount: ModelStorageManifest.fullLimit), !data.isEmpty else { break }
                hash.update(data: data)
            }
        } else {
            let count = Int64(ModelStorageManifest.sampleBytes)
            for offset in [0, (file.size - count) / 2, file.size - count] {
                try checkpoint()
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: Int(count)) ?? Data()
                guard data.count == count else { throw Failure.mismatch }
                hash.update(data: data)
            }
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let expected = verification == .fullSHA256 || file.size <= ModelStorageManifest.fullLimit ? file.sha256 : file.sampleSHA256
        var after = stat()
        guard fstat(fd, &after) == 0, sameSnapshot(before, after),
              digest == expected else { throw Failure.mismatch }
        return after
    }

    /// 0.3.1 must call with fullSHA256 against the inventory in its signed App
    /// before activating imported or previously precloned data.
    static func verify(_ model: ModelStorageManifest.Model, at directory: Directory,
                       verification: Verification, checkpoint: () throws -> Void) throws {
        var expected: Set<String> = [receiptName]
        var fileSnapshots: [String: stat] = [:]
        var directorySnapshots = ["": try directory.status()]
        for file in model.files {
            try checkpoint()
            let parts = file.path.split(separator: "/").map(String.init)
            var parent = directory
            var prefix = ""
            for part in parts.dropLast() {
                prefix += part + "/"; expected.insert(String(prefix.dropLast()))
                parent = try parent.child(part, create: false)
                let path = String(prefix.dropLast()), info = try parent.status()
                if let previous = directorySnapshots[path], !sameSnapshot(previous, info) { throw Failure.unsafePath }
                directorySnapshots[path] = info
            }
            let opened = try parent.file(parts.last!)
            defer { _ = Darwin.close(opened) }
            fileSnapshots[file.path] = try verifyFile(file, fd: opened, verification: verification, checkpoint: checkpoint)
            expected.insert(file.path)
        }
        func walk(_ parent: Directory, _ prefix: String) throws {
            let path = prefix.isEmpty ? "" : String(prefix.dropLast())
            guard let original = directorySnapshots[path], sameSnapshot(original, try parent.status()) else {
                throw Failure.unsafePath
            }
            for name in try parent.names() {
                try checkpoint()
                let relative = prefix + name
                guard expected.contains(relative) else { throw Failure.mismatch }
                var info = stat()
                guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.system(errno) }
                if info.st_mode & S_IFMT == S_IFDIR {
                    try walk(parent.child(name, create: false), relative + "/")
                } else if info.st_mode & S_IFMT != S_IFREG || info.st_nlink != 1 { throw Failure.unsafePath }
                else if let verified = fileSnapshots[relative], !sameSnapshot(verified, info) { throw Failure.mismatch }
            }
            guard sameSnapshot(original, try parent.status()) else { throw Failure.unsafePath }
        }
        try walk(directory, "")
    }

    static func preclone(_ model: ModelStorageManifest.Model, manifestSHA256: String,
                         bundledModels: URL, destinationModels: URL,
                         operations: Operations = Operations()) throws -> Outcome {
        // Validate even independently constructed entries, not only decoded JSON.
        try ModelStorageManifest(schemaVersion: 1, sampleAlgorithm: "first-middle-last-64KiB-v1",
            fullHashMaxBytes: ModelStorageManifest.fullLimit, models: [model]).validate()
        guard ModelStorageManifest.digest(manifestSHA256) else { throw Failure.manifest }
        try operations.checkpoint()
        let sourceRoot = try Directory.open(bundledModels, owned: false)
        let source = try sourceRoot.descendant(model.sourceRelativePath, create: false, owned: false)
        let sourceFiles = try sourceIdentities(model, at: source, checkpoint: operations.checkpoint)
        try SensitiveFileIO.prepareDirectory(destinationModels)
        let root = try Directory.open(destinationModels, owned: true)
        try root.assertBound(to: destinationModels)
        // 0.3.1 owns the UI and removal of an existing exclusion marker. An
        // older App must leave that policy untouched when inclusion is chosen.
        if !operations.modelsIncludedInTimeMachine() {
            try operations.excludeFromBackup(root.fd)
            try root.assertBound(to: destinationModels)
            guard try operations.isExcludedFromBackup(destinationModels) else { throw Failure.mismatch }
        }
        try root.assertBound(to: destinationModels)
        let parent = try root.child(model.name, create: true)
        let lock = openat(parent.fd, ".preclone-lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw Failure.system(errno) }
        defer { _ = Darwin.close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(), lockInfo.st_nlink == 1 else { throw Failure.unsafePath }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        let receipt = Receipt(schemaVersion: 1, model: model.name, version: model.version,
                              manifestSHA256: manifestSHA256, verification: .sampledPrecloneV1)
        // Retire only marked incomplete directories. Release safe same-version
        // cache trees only after a verified replacement is available.
        let partialPrefix = ".partial-" + model.version + "-"
        for name in try parent.names() where name.hasPrefix(partialPrefix) {
            try operations.checkpoint()
            guard UUID(uuidString: String(name.dropFirst(partialPrefix.count))) != nil,
                  let candidate = try? parent.child(name, create: false),
                  let data = try? candidate.read(receiptName),
                  let marker = try? JSONDecoder().decode(Receipt.self, from: data), marker.belongs(to: model) else { continue }
            try parent.move(candidate, from: name, to: ".retained-" + model.version + "-" + UUID().uuidString)
        }
        var previous: Directory?
        var previousReceipt: stat?
        var outcome: Outcome = .cloned
        var existing = stat()
        if fstatat(parent.fd, model.version, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            let committed = try parent.child(model.version, create: false)
            let marker = try? committed.receiptSnapshot()
            let stored = marker?.0
            let recognized = stored?.belongs(to: model) == true
            var damaged = !recognized
            if recognized {
                previousReceipt = marker?.1
                do {
                    try verify(model, at: committed, verification: .sampledPrecloneV1, checkpoint: operations.checkpoint)
                } catch Failure.mismatch { damaged = true }
                catch Failure.unsafePath { damaged = true }
                catch Failure.system(let code) where [ENOENT, ELOOP, ENOTDIR].contains(code) { damaged = true }
            }
            try root.assertBound(to: destinationModels)
            guard try root.matches(parent, name: model.name), try parent.matches(committed, name: model.version) else {
                throw Failure.unsafePath
            }
            if !damaged, stored?.sourceFiles == sourceFiles,
               try stored?.clonedFiles == sourceIdentities(model, at: committed, checkpoint: operations.checkpoint) {
                try releaseRetainedCaches(model, root: root, parent: parent, destinationModels: destinationModels,
                                          checkpoint: operations.checkpoint)
                return .alreadyPresent
            }
            previous = committed
            outcome = damaged ? .repaired : .refreshed
        } else {
            guard errno == ENOENT else { throw Failure.system(errno) }
        }
        guard try source.status().st_dev == parent.status().st_dev else { throw Failure.system(EXDEV) }
        if previous != nil {
            // A bad current bundle must never authorize replacing a cache.
            guard try sourceIdentities(model, at: source, checkpoint: operations.checkpoint,
                                       verification: .sampledPrecloneV1) == sourceFiles else { throw Failure.unsafePath }
        }
        try operations.checkpoint()
        let partialName = partialPrefix + UUID().uuidString
        let staging = try parent.child(partialName, create: true)
        try staging.writeReceipt(receipt)
        var clonedSourceFiles: [String: FileIdentity] = [:]
        for file in model.files {
            try operations.checkpoint()
            let parts = file.path.split(separator: "/").map(String.init)
            var sourceParent = source, targetParent = staging
            for part in parts.dropLast() {
                sourceParent = try sourceParent.child(part, create: false, owned: false)
                targetParent = try targetParent.child(part, create: true)
            }
            let opened = try sourceParent.file(parts.last!)
            defer { _ = Darwin.close(opened) }
            var info = stat()
            guard fstat(opened, &info) == 0, info.st_size == file.size else { throw Failure.mismatch }
            guard FileIdentity(info) == sourceFiles[file.path] else { throw Failure.unsafePath }
            try operations.clone(opened, targetParent.fd, parts.last!)
            var after = stat()
            guard fstat(opened, &after) == 0,
                  FileIdentity(info).sameDataObject(as: FileIdentity(after)) else { throw Failure.unsafePath }
            // A clone operation may change source metadata (ctime). Record its
            // completed identity, and reject any later change before publish.
            clonedSourceFiles[file.path] = FileIdentity(after)
            let cloned = try targetParent.file(parts.last!)
            defer { _ = Darwin.close(cloned) }
            guard fchmod(cloned, 0o600) == 0 else { throw Failure.system(errno) }
        }
        var completedReceipt = receipt
        completedReceipt.sourceFiles = clonedSourceFiles
        completedReceipt.clonedFiles = try sourceIdentities(model, at: staging, checkpoint: operations.checkpoint)
        try staging.replaceStagingReceipt(completedReceipt)
        try verify(model, at: staging, verification: .sampledPrecloneV1, checkpoint: operations.checkpoint)
        try operations.checkpoint()
        let currentSourceRoot = try Directory.open(bundledModels, owned: false)
        let currentSource = try currentSourceRoot.descendant(model.sourceRelativePath, create: false, owned: false)
        let originalSource = try source.status(), reopenedSource = try currentSource.status()
        guard originalSource.st_dev == reopenedSource.st_dev, originalSource.st_ino == reopenedSource.st_ino,
              try sourceIdentities(model, at: currentSource, checkpoint: operations.checkpoint) == clonedSourceFiles else {
            throw Failure.unsafePath
        }
        guard fsync(staging.fd) == 0 else { throw Failure.system(errno) }
        try root.assertBound(to: destinationModels)
        guard try root.matches(parent, name: model.name) else { throw Failure.unsafePath }
        if let previous {
            if let previousReceipt {
                let (marker, current) = try previous.receiptSnapshot()
                guard marker.belongs(to: model), sameSnapshot(previousReceipt, current) else { throw Failure.unsafePath }
            }
            // A missing/unknown marker permits repair by preserving the old
            // tree, never by declaring it disposable cache.
            try operations.checkpoint()
            try root.assertBound(to: destinationModels)
            guard try root.matches(parent, name: model.name) else { throw Failure.unsafePath }
            try parent.exchange(staging, named: partialName, with: previous, named: model.version)
            try parent.move(previous, from: partialName, to: ".retained-" + model.version + "-" + UUID().uuidString)
        } else {
            try operations.checkpoint()
            try root.assertBound(to: destinationModels)
            guard try root.matches(parent, name: model.name) else { throw Failure.unsafePath }
            try parent.move(staging, from: partialName, to: model.version)
        }
        try operations.checkpoint()
        try root.assertBound(to: destinationModels)
        guard try root.matches(parent, name: model.name), try parent.matches(staging, name: model.version) else {
            throw Failure.unsafePath
        }
        try releaseRetainedCaches(model, root: root, parent: parent, destinationModels: destinationModels,
                                  checkpoint: operations.checkpoint)
        return outcome
    }

    /// A bad model must not starve later entries. Capture deferral/cancellation
    /// stops the batch immediately; ordinary failures are reported per model.
    static func precloneAll(_ models: [ModelStorageManifest.Model], manifestSHA256: String,
                            bundledModels: URL, destinationModels: URL, operations: Operations = Operations(),
                            report: (String, Result<Outcome, Error>) -> Void) -> Bool {
        for model in models {
            do {
                try operations.checkpoint()
                let result = try preclone(model, manifestSHA256: manifestSHA256,
                    bundledModels: bundledModels, destinationModels: destinationModels, operations: operations)
                report(model.name, .success(result))
            } catch {
                report(model.name, .failure(error))
                if diagnostic(error) == "deferred" { return true }
            }
        }
        return false
    }
}

/// The audio/UI path only updates this tiny flag. Disk work is detached at
/// background priority and yields at each file/read boundary when capture starts.
final class ModelPrecloneGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: true)
    func setBlocked(_ blocked: Bool) { state.withLock { $0 = blocked } }
    func checkpoint() throws {
        try Task.checkCancellation()
        if state.withLock({ $0 }) { throw ModelStorage.Failure.deferred }
    }
}

@MainActor
final class ModelPrecloneController {
    /// Cancellation is the only handle exposed to the owner. In particular,
    /// there is no Task.value for a higher-priority caller to await/escalate.
    struct Job: Sendable {
        let cancel: @Sendable () -> Void
    }
    typealias Scheduler = @MainActor (Duration, TaskPriority,
        @escaping @Sendable () -> Bool,
        @escaping @MainActor @Sendable (Bool) -> Void) -> Job

    private let gate = ModelPrecloneGate()
    private var subscription: AnyCancellable?
    private var job: Job?
    private var activeRun: UUID?
    private var finished = false
    private var blocked = true
    private let enabled: Bool
    private let scheduler: Scheduler
    private let work: @Sendable (ModelPrecloneGate) throws -> Bool

    static func blocksPreclone(_ phase: AppPhase) -> Bool {
        switch phase {
        case .idle, .saved, .liveEnded, .failed: return false
        default: return true
        }
    }
    convenience init(model: AppModel) {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let destination: @Sendable () throws -> URL = {
            #if LIVELINGO_PREVIEW
            return try PreviewDataIsolation.dataURL("Models")
            #else
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: false)
            return support.appendingPathComponent("LiveLingo/Models", isDirectory: true)
            #endif
        }
        self.init(phases: model.$phase.eraseToAnyPublisher(), scheduler: { delay, priority, work, completion in
                      Self.scheduleBackground(delay: delay, priority: priority, work: work, completion: completion)
                  },
                  work: { gate in try Self.preclone(resources: resources, destination: destination, gate: gate) },
                  enabled: !AppRuntimeEnvironment.isUnitTesting)
    }

    /// Tests must inject both scheduling and work: this initializer has no
    /// default that can reach bundled models, standard defaults or user data.
    /// A scheduler delivers completion after returning its cancellation handle.
    init(phases: AnyPublisher<AppPhase, Never>, scheduler: @escaping Scheduler,
         work: @escaping @Sendable (ModelPrecloneGate) throws -> Bool, enabled: Bool = true) {
        self.enabled = enabled
        self.scheduler = scheduler
        self.work = work
        subscription = phases.sink { [weak self] phase in self?.update(phase) }
    }

    nonisolated static func scheduleBackground(delay: Duration, priority: TaskPriority,
        work: @escaping @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void,
        wait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) -> Job {
        // This independent task owns the grace period and all disk work. Its
        // owner never awaits it; only the final bookkeeping hops to MainActor.
        let task = Task.detached(priority: priority) {
            let deferred: Bool
            do {
                try await wait(delay)
                try Task.checkCancellation()
                deferred = work()
            } catch {
                deferred = true
            }
            await completion(deferred)
        }
        return Job(cancel: { task.cancel() })
    }

    nonisolated private static func preclone(resources: URL, destination: @Sendable () throws -> URL,
                                             gate: ModelPrecloneGate) throws -> Bool {
        let directory = try ModelStorage.Directory.open(resources, owned: false)
        let data = try directory.read(ModelStorageManifest.filename)
        let inventory = try ModelStorageManifest.decode(data)
        let root = try destination()
        let manifestDigest = ModelStorage.sha256(data)
        return ModelStorage.precloneAll(inventory.models, manifestSHA256: manifestDigest,
            bundledModels: resources.appendingPathComponent("Models"), destinationModels: root,
            operations: .init(checkpoint: { try gate.checkpoint() })) { name, result in
            switch result {
            case .success(let outcome):
                ModelStorage.log.info("model=\(name, privacy: .public) result=\(outcome.rawValue, privacy: .public)")
            case .failure(let error):
                let code = ModelStorage.diagnostic(error)
                ModelStorage.log.notice("model=\(name, privacy: .public) preclone=\(code, privacy: .public)")
            }
        }
    }
    private func update(_ phase: AppPhase) {
        blocked = Self.blocksPreclone(phase)
        gate.setBlocked(blocked)
        if !blocked { schedule() }
    }
    private func schedule() {
        guard enabled, !finished, activeRun == nil, !blocked else { return }
        let gate = gate, work = work, run = UUID()
        activeRun = run
        job = scheduler(.seconds(15), .background, {
            do {
                try gate.checkpoint()
                return try work(gate)
            } catch {
                let code = ModelStorage.diagnostic(error)
                ModelStorage.log.notice("preclone=\(code, privacy: .public)")
                return code == "deferred"
            }
        }, { [weak self] deferred in
            guard let self, self.activeRun == run else { return }
            self.job = nil
            self.activeRun = nil
            self.finished = !deferred  // Other failures retry on the next App launch.
            if deferred, !self.blocked { self.schedule() }
        })
    }
    deinit {
        gate.setBlocked(true)
        job?.cancel()
    }
}
