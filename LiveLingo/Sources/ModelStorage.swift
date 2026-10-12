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
    enum Outcome: String, Sendable { case cloned, alreadyPresent }
    struct Receipt: Codable, Equatable {
        let schemaVersion: Int
        let model: String
        let version: String
        let manifestSHA256: String
        let verification: Verification
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

    struct Operations {
        var clone: (Int32, Int32, String) throws -> Void = { source, parent, name in
            guard fclonefileat(source, parent, name, UInt32(CLONE_NOOWNERCOPY)) == 0 else {
                throw Failure.system(errno)  // Deliberately no copy fallback.
            }
        }
        var checkpoint: () throws -> Void = { try Task.checkCancellation() }
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
        try SensitiveFileIO.prepareDirectory(destinationModels)
        let root = try Directory.open(destinationModels, owned: true)
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
        // Retire only our marked incomplete directories, by renaming them. No
        // recursive deletion, Trash operation, or arbitrary residual cleanup.
        let partialPrefix = ".partial-" + model.version + "-"
        for name in try parent.names() where name.hasPrefix(partialPrefix) {
            try operations.checkpoint()
            guard UUID(uuidString: String(name.dropFirst(partialPrefix.count))) != nil,
                  let candidate = try? parent.child(name, create: false),
                  let data = try? candidate.read(receiptName),
                  let marker = try? JSONDecoder().decode(Receipt.self, from: data), marker.belongs(to: model) else { continue }
            try parent.move(candidate, from: name, to: ".retained-" + model.version + "-" + UUID().uuidString)
        }
        var existing = stat()
        if fstatat(parent.fd, model.version, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            let committed = try parent.child(model.version, create: false)
            let stored = try JSONDecoder().decode(Receipt.self, from: committed.read(receiptName))
            guard stored.belongs(to: model) else { throw Failure.mismatch }
            try verify(model, at: committed, verification: .sampledPrecloneV1, checkpoint: operations.checkpoint)
            try root.assertBound(to: destinationModels)
            guard try root.matches(parent, name: model.name), try parent.matches(committed, name: model.version) else {
                throw Failure.unsafePath
            }
            return .alreadyPresent
        }
        guard errno == ENOENT else { throw Failure.system(errno) }
        guard try source.status().st_dev == parent.status().st_dev else { throw Failure.system(EXDEV) }
        try operations.checkpoint()
        let partialName = partialPrefix + UUID().uuidString
        let staging = try parent.child(partialName, create: true)
        try staging.writeReceipt(receipt)
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
            try operations.clone(opened, targetParent.fd, parts.last!)
            let cloned = try targetParent.file(parts.last!)
            defer { _ = Darwin.close(cloned) }
            guard fchmod(cloned, 0o600) == 0 else { throw Failure.system(errno) }
        }
        try verify(model, at: staging, verification: .sampledPrecloneV1, checkpoint: operations.checkpoint)
        try operations.checkpoint()
        guard fsync(staging.fd) == 0 else { throw Failure.system(errno) }
        try root.assertBound(to: destinationModels)
        guard try root.matches(parent, name: model.name) else { throw Failure.unsafePath }
        try parent.move(staging, from: partialName, to: model.version)
        try operations.checkpoint()
        try root.assertBound(to: destinationModels)
        guard try root.matches(parent, name: model.name), try parent.matches(staging, name: model.version) else {
            throw Failure.unsafePath
        }
        return .cloned
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
    private let gate = ModelPrecloneGate()
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var finished = false
    private var blocked = true
    private let resources: URL
    private let destination: @Sendable () throws -> URL

    static func blocksPreclone(_ phase: AppPhase) -> Bool {
        switch phase {
        case .idle, .saved, .liveEnded, .failed: return false
        default: return true
        }
    }
    init(model: AppModel) {
        resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        destination = {
            #if LIVELINGO_PREVIEW
            return try PreviewDataIsolation.dataURL("Models")
            #else
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: false)
            return support.appendingPathComponent("LiveLingo/Models", isDirectory: true)
            #endif
        }
        subscription = model.$phase.sink { [weak self] phase in self?.update(phase) }
    }
    private func update(_ phase: AppPhase) {
        blocked = Self.blocksPreclone(phase)
        gate.setBlocked(blocked)
        if !blocked { schedule() }
    }
    private func schedule() {
        guard !finished, task == nil, !blocked, !AppRuntimeEnvironment.isUnitTesting else { return }
        let resources = resources, destination = destination, gate = gate
        task = Task { [weak self] in
            // Allow launch/readiness and an immediate record click to settle.
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            let deferred = await Task.detached(priority: .background) {
                do {
                    try gate.checkpoint()
                    let directory = try ModelStorage.Directory.open(resources, owned: false)
                    let data = try directory.read(ModelStorageManifest.filename)
                    let inventory = try ModelStorageManifest.decode(data)
                    let root = try destination()
                    let manifestDigest = ModelStorage.sha256(data)
                    for model in inventory.models {
                        try gate.checkpoint()
                        let result = try ModelStorage.preclone(model, manifestSHA256: manifestDigest,
                            bundledModels: resources.appendingPathComponent("Models"), destinationModels: root,
                            operations: .init(checkpoint: { try gate.checkpoint() }))
                        ModelStorage.log.info("model=\(model.name, privacy: .public) result=\(result.rawValue, privacy: .public)")
                    }
                    return false
                } catch {
                    let code = ModelStorage.diagnostic(error)
                    ModelStorage.log.notice("preclone=\(code, privacy: .public)")
                    return code == "deferred"
                }
            }.value
            guard let self else { return }
            task = nil
            finished = !deferred  // Other failures retry on the next App launch.
            if deferred, !blocked { schedule() }
        }
    }
    deinit { gate.setBlocked(true); task?.cancel() }
}
