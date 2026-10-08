import Foundation
import Darwin

enum SessionWorkspaceError: LocalizedError {
    case invalidTemporarySession
    case recordingMissing
    case promotionFailed(source: URL, destination: URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidTemporarySession:
            return "临时录音目录不属于 LiveLingo，已停止文件操作。"
        case .recordingMissing:
            return "临时录音文件不存在。"
        case let .promotionFailed(source, destination, reason):
            return "录音迁移失败；临时录音仍保留在 \(source.path)，目标为 \(destination.path)。\(reason)"
        }
    }
}

enum SessionWorkspace {
    static let temporaryPrefix = "LiveLingo-Live-"
    static let recordingFileName = "recording.wav"
    private static let cleanupDirectoryName = ".LiveLingo-Cleanup"
    private static let cleanupLock = NSRecursiveLock()

    private struct CleanupRecord: Codable {
        let originalPath: String
        let identity: SensitiveFileIO.Identity
        var cleanupRequested = false
        var stagedName: String?
    }

    static func temporaryRoot(fileManager: FileManager = .default) throws -> URL {
        #if LIVELINGO_PREVIEW
        let root = try PreviewDataIsolation.dataURL("Temporary")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
        #else
        return fileManager.temporaryDirectory
        #endif
    }
    private static let recoveryLock = NSLock()

    struct RecordingRecovery: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var directory: URL
        let outputRoot: URL
        var needsPromotion: Bool = true
        var createdAt: Date = Date()
    }
    private struct RecoveryIndex: Codable {
        var version = 1
        let recordings: [RecordingRecovery]
    }
    static var recoverableRecordingRoot: URL {
        #if LIVELINGO_PREVIEW
        return PreviewDataIsolation.dataDirectory.appendingPathComponent("RecoverableRecordings", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/com.jianhongli.LiveLingo/RecoverableRecordings", isDirectory: true)
        #endif
    }

    static func makeRecoverableTemporarySessionDirectory() throws -> URL {
        try makeTemporarySessionDirectory(in: recoverableRecordingRoot, identifier: UUID(), createRoot: true)
    }

    static func recordingRecoveries(in root: URL) throws -> [RecordingRecovery] {
        let url = root.appendingPathComponent("pending-recordings.json")
        try SessionArchiveCoding.requireRegularFileIfPresent(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let bytes = try Data(contentsOf: url)
        // An older reader must never rewrite state it did not understand.
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["version", "recordings"]),
              let records = object["recordings"] as? [[String: Any]],
              records.allSatisfy({ Set($0.keys).isSubset(of: ["id", "directory", "outputRoot", "needsPromotion", "createdAt"]) }) else {
            throw SessionStoreError.invalidState("录音恢复索引含未知状态，原文件已保留")
        }
        let index = try SessionArchiveCoding.decode(RecoveryIndex.self, from: bytes)
        guard index.version == 1, Set(index.recordings.map(\.id)).count == index.recordings.count,
              index.recordings.allSatisfy({ $0.directory.isFileURL && $0.outputRoot.isFileURL }) else {
            throw SessionStoreError.invalidState("录音恢复索引无效，原文件已保留")
        }
        return index.recordings
    }

    @discardableResult
    static func saveRecordingRecoveries(_ recordings: [RecordingRecovery], in root: URL,
                                        retiring: [RecordingRecovery] = [],
                                        expected: [RecordingRecovery] = []) throws -> [RecordingRecovery] {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        try SensitiveFileIO.prepareDirectory(root)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw SessionStoreError.unsafePath(root.path)
        }
        let lockURL = root.appendingPathComponent(".recording-recovery.lock")
        try SessionArchiveCoding.requireRegularFileIfPresent(lockURL)
        let recoveryRoot = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
        let fd = try recoveryRoot.openRegularFile(named: lockURL.lastPathComponent, flags: O_RDWR, create: true)
        defer { _ = Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SessionStoreError.io(operation: "lock recording recoveries", code: errno) }
        defer { _ = flock(fd, LOCK_UN) }
        // Load and validate under the same lock as merge/retirement. A read
        // failure blocks publication and leaves the original bytes intact.
        var merged = try recordingRecoveries(in: root)
        guard Set(recordings.map(\.id)).count == recordings.count,
              recordings.allSatisfy({ $0.directory.isFileURL && $0.outputRoot.isFileURL }) else {
            throw SessionStoreError.invalidState("录音恢复记录无效")
        }
        for retired in retiring {
            if let existing = merged.first(where: { $0.id == retired.id }), existing != retired {
                throw SessionStoreError.identityConflict("录音恢复位置已被更新，保留新记录")
            }
            merged.removeAll { $0.id == retired.id }
        }
        for incoming in recordings {
            if let existing = merged.first(where: { $0.id == incoming.id }), existing != incoming,
               !expected.contains(existing) {
                throw SessionStoreError.identityConflict("录音恢复记录已有新版本，保留原件")
            }
            merged.removeAll { $0.id == incoming.id }
            merged.append(incoming)
        }
        let bytes = try SessionArchiveCoding.encode(RecoveryIndex(recordings: merged))
        try SessionArchiveCoding.atomicWrite(bytes, root.appendingPathComponent("pending-recordings.json"))
        return try SessionArchiveCoding.decode(RecoveryIndex.self, from: bytes).recordings
    }

    static func makeTemporarySessionDirectory(
        fileManager: FileManager = .default,
        identifier: UUID = UUID()
    ) throws -> URL {
        try makeTemporarySessionDirectory(in: temporaryRoot(fileManager: fileManager), identifier: identifier, createRoot: false)
    }

    private static func makeTemporarySessionDirectory(in location: URL, identifier: UUID, createRoot: Bool) throws -> URL {
        cleanupLock.lock(); defer { cleanupLock.unlock() }
        let directory = location.resolvingSymlinksInPath().appendingPathComponent(
            temporaryPrefix + identifier.uuidString,
            isDirectory: true
        )
        let root = try SensitiveFileIO.Directory.open(at: location, create: createRoot, tighten: false)
        let journal = try root.subdirectory(named: cleanupDirectoryName)
        try journal.assertPrivate()
        let owned = try root.createSubdirectory(named: directory.lastPathComponent)
        let record = CleanupRecord(originalPath: directory.path, identity: try owned.identity)
        try journal.atomicWrite(JSONEncoder().encode(record), named: identifier.uuidString + ".json", requireAbsent: true)
        return directory
    }

    static func uniqueFinalDirectory(
        in outputRoot: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) -> URL {
        var candidate = outputRoot.appendingPathComponent(preferredName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = outputRoot.appendingPathComponent("\(preferredName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    static func promoteTemporarySession(
        from temporaryDirectory: URL,
        to outputRoot: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try validateTemporarySession(temporaryDirectory, fileManager: fileManager)
        let sourceRecording = temporaryDirectory.appendingPathComponent(recordingFileName)
        guard fileManager.fileExists(atPath: sourceRecording.path) else {
            throw SessionWorkspaceError.recordingMissing
        }

        let destination = uniqueFinalDirectory(
            in: outputRoot,
            preferredName: preferredName,
            fileManager: fileManager
        )

        let receipt = try SessionTreeMigration.promote(from: temporaryDirectory, to: destination,
            operations: .init(copyTree: { try fileManager.copyItem(at: $0, to: $1) }))
        // Preserve the exact recovery location after full-tree verification.
        if let preserved = receipt.preservedSourceDirectory {
            let recovery = ["source": preserved.path, "destination": destination.path]
            let bytes = try JSONSerialization.data(withJSONObject: recovery, options: [.sortedKeys])
            try SensitiveFileIO.atomicWrite(bytes, to: destination.appendingPathComponent("migration-recovery.json"))
        }
        try forgetPromotedTemporarySession(temporaryDirectory, fileManager: fileManager)
        return receipt.destinationDirectory
    }

    static func discardTemporarySession(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        cleanupLock.lock(); defer { cleanupLock.unlock() }
        try validateTemporarySession(directory, fileManager: fileManager)
        let root = try SensitiveFileIO.Directory.open(at: directory.deletingLastPathComponent(), create: false, tighten: false)
        let journal = try root.subdirectory(named: cleanupDirectoryName, create: false)
        try journal.assertPrivate()
        let name = try recordName(for: directory)
        guard let bytes = try journal.readIfPresent(named: name) else { throw SessionWorkspaceError.invalidTemporarySession }
        var record = try JSONDecoder().decode(CleanupRecord.self, from: bytes)
        let expectedPath = root.url.resolvingSymlinksInPath()
            .appendingPathComponent(directory.lastPathComponent).path
        guard record.originalPath == expectedPath else {
            throw SessionWorkspaceError.invalidTemporarySession
        }
        record.cleanupRequested = true
        try journal.atomicWrite(JSONEncoder().encode(record), named: name)
        try clean(record: &record, name: name, root: root, journal: journal)
    }

    /// Only records created by this App and explicitly marked for cleanup are
    /// retried. Active sessions and unknown historical directories are retained.
    static func retryPendingTemporarySessions(fileManager: FileManager = .default) throws {
        try retryPendingTemporarySessions(in: temporaryRoot(fileManager: fileManager), fileManager: fileManager)
    }

    static func retryPendingTemporarySessions(in location: URL, fileManager: FileManager = .default) throws {
        cleanupLock.lock(); defer { cleanupLock.unlock() }
        guard fileManager.fileExists(atPath: location.path) else { return }
        let root = try SensitiveFileIO.Directory.open(at: location, create: false, tighten: false)
        guard let journal = try root.directoryIfPresent(named: cleanupDirectoryName) else { return }
        try journal.assertPrivate()
        for name in try journal.names().sorted() where isRecordName(name) {
            guard let bytes = try journal.readIfPresent(named: name) else { continue }
            var record = try JSONDecoder().decode(CleanupRecord.self, from: bytes)
            guard record.cleanupRequested else { continue }
            let url = URL(fileURLWithPath: record.originalPath, isDirectory: true)
            try validateTemporarySession(url, fileManager: fileManager)
            guard try recordName(for: url) == name else { throw SessionWorkspaceError.invalidTemporarySession }
            try clean(record: &record, name: name, root: root, journal: journal)
        }
    }

    static func pendingTemporarySessionDirectories(fileManager: FileManager = .default) throws -> [URL] {
        cleanupLock.lock(); defer { cleanupLock.unlock() }
        let root = try SensitiveFileIO.Directory.open(at: temporaryRoot(fileManager: fileManager), create: false, tighten: false)
        guard let journal = try root.directoryIfPresent(named: cleanupDirectoryName) else { return [] }
        return try journal.names().filter(isRecordName).compactMap { name in
            guard let bytes = try journal.readIfPresent(named: name) else { return nil }
            let record = try JSONDecoder().decode(CleanupRecord.self, from: bytes)
            guard record.cleanupRequested else { return nil }
            return record.stagedName.map { journal.url.appendingPathComponent($0, isDirectory: true) }
                ?? URL(fileURLWithPath: record.originalPath, isDirectory: true)
        }
    }

    static func forgetPromotedTemporarySession(_ directory: URL, fileManager: FileManager = .default) throws {
        cleanupLock.lock(); defer { cleanupLock.unlock() }
        try validateTemporarySession(directory, fileManager: fileManager)
        let root = try SensitiveFileIO.Directory.open(at: directory.deletingLastPathComponent(), create: false, tighten: false)
        let journal = try root.subdirectory(named: cleanupDirectoryName, create: false)
        try journal.removeRegularFileIfPresent(named: recordName(for: directory))
    }

    private static func clean(record: inout CleanupRecord, name: String,
                              root: SensitiveFileIO.Directory, journal: SensitiveFileIO.Directory) throws {
        let leaf = URL(fileURLWithPath: record.originalPath).lastPathComponent
        let stagedName = record.stagedName ?? ".cleanup-" + UUID().uuidString
        if let staged = try journal.directoryIfPresent(named: stagedName) {
            guard try staged.identity == record.identity else { throw SessionWorkspaceError.invalidTemporarySession }
        } else {
            // Both checks and the detach use descriptors. Replacing the path
            // with another directory can never authorize deleting that object.
            guard let owned = try root.directoryIfPresent(named: leaf),
                  try owned.identity == record.identity else { throw SessionWorkspaceError.invalidTemporarySession }
            record.stagedName = stagedName
            try journal.atomicWrite(JSONEncoder().encode(record), named: name)
            try root.moveDirectory(named: leaf, matching: record.identity, to: journal, named: stagedName)
        }
        do {
            try journal.removeDirectory(named: stagedName, matching: record.identity)
            try journal.removeRegularFileIfPresent(named: name)
        } catch {
            // Preserve the original location on ordinary failures. If another
            // object already occupies it, keep the journal's exact staged path.
            if (try? journal.moveDirectory(named: stagedName, matching: record.identity, to: root, named: leaf)) != nil {
                record.stagedName = nil
                try journal.atomicWrite(JSONEncoder().encode(record), named: name)
            }
            throw error
        }
    }

    private static func recordName(for directory: URL) throws -> String {
        let suffix = String(directory.lastPathComponent.dropFirst(temporaryPrefix.count))
        guard directory.lastPathComponent.hasPrefix(temporaryPrefix), let id = UUID(uuidString: suffix) else {
            throw SessionWorkspaceError.invalidTemporarySession
        }
        return id.uuidString + ".json"
    }

    private static func isRecordName(_ name: String) -> Bool {
        name.hasSuffix(".json") && UUID(uuidString: String(name.dropLast(5))) != nil
    }

    static func copyTemporarySession(from temporaryDirectory: URL, to outputRoot: URL,
                                     preferredName: String) throws -> SessionMigrationReceipt {
        try validateTemporarySession(temporaryDirectory, fileManager: .default)
        guard FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent(recordingFileName).path) else {
            throw SessionWorkspaceError.recordingMissing
        }
        let destination = uniqueFinalDirectory(in: outputRoot, preferredName: preferredName, fileManager: .default)
        return try SessionTreeMigration.copyVerified(from: temporaryDirectory, to: destination)
    }

    private static func validateTemporarySession(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        let resolvedDirectory = directory.standardizedFileURL
        let resolvedRoot = try temporaryRoot(fileManager: fileManager).standardizedFileURL.resolvingSymlinksInPath()
        let stableRoot = recoverableRecordingRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard [resolvedRoot, stableRoot].contains(resolvedDirectory.deletingLastPathComponent().resolvingSymlinksInPath()),
              resolvedDirectory.lastPathComponent.hasPrefix(temporaryPrefix)
        else {
            throw SessionWorkspaceError.invalidTemporarySession
        }
        _ = try recordName(for: directory)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> UInt64 {
        let values = try fileManager.attributesOfItem(atPath: url.path)
        return (values[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

enum SessionExporter {
    private static let exportLock = NSLock()
    struct PublicationOperations: Sendable {
        var beforeMemberPublication: @Sendable (String) throws -> Void = { _ in }
        var createSymbolicLink: @Sendable (String, URL) throws -> Void = { target, path in
            guard symlink(target, path.path) == 0 else {
                throw SessionStoreError.io(operation: "stage export pointer", code: errno)
            }
        }
        var exchangeDirectories: @Sendable (URL, URL) throws -> Void = { staged, directory in
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, directory.path, UInt32(RENAME_SWAP)) == 0 else {
                throw SessionStoreError.io(operation: "publish initial export", code: errno)
            }
        }
    }
    private struct ExportIndex: Codable {
        var version = 1
        let members: [String: String]
    }
    private struct ExportPointer: Codable {
        var version = 1
        let generation: String
    }
    private struct PortableTransaction: Codable {
        var version = 1
        let rollback: String
        let next: String
        let names: [String]
        let originallyPresent: [String]
    }

    private static func unsupportedPublication(_ error: Error) -> Bool {
        guard let failure = error as? SessionStoreError, case let .io(_, code) = failure else { return false }
        return [ENOTSUP, EXDEV, ENOSYS].contains(code)
    }

    private static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw SessionStoreError.io(operation: "inspect export directory", code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw SessionStoreError.unsafePath(url.path) }
    }

    /// Resolve once, then read an immutable generation. Root aliases all follow
    /// the same atomic pointer; the historical file contents remain unchanged.
    static func currentExportDirectory(in directory: URL) throws -> URL {
        let store = directory.appendingPathComponent(".exports", isDirectory: true)
        var storeInfo = stat()
        if lstat(store.path, &storeInfo) != 0 {
            guard errno == ENOENT else { throw SessionStoreError.io(operation: "inspect export store", code: errno) }
            return directory
        }
        try requireDirectory(store)
        let current = store.appendingPathComponent("current")
        let portable = store.appendingPathComponent("current.json")
        var info = stat()
        let link: String
        if lstat(portable.path, &info) == 0 {
            try SessionArchiveCoding.requireRegularFileIfPresent(portable)
            let pointer = try SessionArchiveCoding.decode(ExportPointer.self, from: Data(contentsOf: portable))
            guard pointer.version == 1, UUID(uuidString: pointer.generation) != nil else {
                throw SessionStoreError.corruptSnapshot
            }
            link = "versions/" + pointer.generation
        } else {
            guard errno == ENOENT else { throw SessionStoreError.io(operation: "read portable export index", code: errno) }
            guard lstat(current.path, &info) == 0 else {
                if errno == ENOENT { return directory }
                throw SessionStoreError.io(operation: "read export index", code: errno)
            }
            guard info.st_mode & S_IFMT == S_IFLNK else { throw SessionStoreError.unsafePath(current.path) }
            link = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        }
        let parts = link.split(separator: "/")
        guard parts.count == 2, parts[0] == "versions", UUID(uuidString: String(parts[1])) != nil else {
            throw SessionStoreError.unsafePath(current.path)
        }
        try requireDirectory(store)
        try requireDirectory(store.appendingPathComponent("versions", isDirectory: true))
        let selected = store.appendingPathComponent(link, isDirectory: true)
        try requireDirectory(selected)
        guard SessionDirectoryLocation.canonical(selected).deletingLastPathComponent()
            == SessionDirectoryLocation.canonical(store.appendingPathComponent("versions", isDirectory: true)) else {
            throw SessionStoreError.unsafePath(selected.path)
        }
        try validateExportGeneration(selected)
        return selected
    }

    private static func validateExportGeneration(_ selected: URL) throws {
        try requireDirectory(selected)
        let indexURL = selected.appendingPathComponent("export-index.json")
        try SessionArchiveCoding.requireRegularFileIfPresent(indexURL)
        let index = try SessionArchiveCoding.decode(ExportIndex.self, from: Data(contentsOf: indexURL))
        guard index.version == 1 else { throw SessionStoreError.unsupportedSchema(index.version) }
        for (name, digest) in index.members {
            guard !name.isEmpty, !name.contains("/"), !name.utf8.contains(0), name != ".", name != "..", SessionArchiveCoding.isDigest(digest) else {
                throw SessionStoreError.corruptSnapshot
            }
            let url = selected.appendingPathComponent(name)
            try SessionArchiveCoding.requireRegularFileIfPresent(url)
            guard SessionArchiveCoding.digest(try Data(contentsOf: url)) == digest else { throw SessionStoreError.corruptSnapshot }
        }
    }

    /// Migration accepts only registered aliases and the relative generation
    /// pointer. Every target is inside a validated immutable export generation.
    static func managedExportLink(at url: URL, in root: URL, generation: URL) throws -> String? {
        guard generation != root else { return nil }
        let fm = FileManager.default
        let target = try fm.destinationOfSymbolicLink(atPath: url.path)
        if url.path == root.appendingPathComponent(".exports/current").path {
            guard target == "versions/" + generation.lastPathComponent else { return nil }
            return target
        }
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().path == root.path,
              target == ".exports/current/" + name else { return nil }
        let index = try SessionArchiveCoding.decode(ExportIndex.self,
            from: Data(contentsOf: generation.appendingPathComponent("export-index.json")))
        guard index.members[name] != nil else { return nil }
        return target
    }

    private static func replaceLink(_ target: String, at destination: URL, operations: PublicationOperations) throws {
        let pending = destination.deletingLastPathComponent().appendingPathComponent(".export-link-\(UUID())")
        try operations.createSymbolicLink(target, pending)
        guard rename(pending.path, destination.path) == 0 else { throw SessionStoreError.io(operation: "publish export pointer", code: errno) }
        try SessionArchiveCoding.syncDirectory(destination.deletingLastPathComponent())
    }

    /// An empty standalone export keeps the frozen, flat file listing. Its
    /// first publication exchanges the whole empty directory with a fully
    /// synchronized sibling. Existing courses use the version pointer below.
    private static func publishInitialExport(_ rendered: [String: Data], in directory: URL, operations: PublicationOperations) throws -> Bool {
        try requireDirectory(directory)
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SessionStoreError.io(operation: "open initial export", code: errno) }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SessionStoreError.io(operation: "lock initial export", code: errno) }
        defer { _ = flock(descriptor, LOCK_UN) }
        var admitted = stat()
        guard fstat(descriptor, &admitted) == 0 else { throw SessionStoreError.io(operation: "inspect initial export", code: errno) }
        func verifyEmptyDirectory() throws -> Bool {
            var current = stat()
            guard lstat(directory.path, &current) == 0,
                  current.st_mode & S_IFMT == S_IFDIR,
                  current.st_dev == admitted.st_dev, current.st_ino == admitted.st_ino else {
                throw SessionStoreError.invalidState("导出目录已被替换，保留现场")
            }
            guard Darwin.access(directory.path, W_OK) == 0 else {
                throw SessionStoreError.io(operation: "write initial export", code: errno)
            }
            return try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
        }
        guard try verifyEmptyDirectory() else { return false }
        let parent = directory.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".\(directory.lastPathComponent).initial-export-\(UUID())", isDirectory: true)
        // Copy the empty directory's metadata as well as its access mode;
        // publication must not widen access or bypass a read-only destination.
        try FileManager.default.copyItem(at: directory, to: staged)
        for (name, bytes) in rendered {
            try SessionArchiveCoding.atomicWrite(bytes, staged.appendingPathComponent(name))
            guard try Data(contentsOf: staged.appendingPathComponent(name)) == bytes else { throw SessionStoreError.corruptSnapshot }
        }
        try SessionArchiveCoding.syncDirectory(staged)
        guard try verifyEmptyDirectory() else { throw SessionStoreError.invalidState("首次导出期间目录出现新内容，保留现场") }
        do {
            try operations.exchangeDirectories(staged, directory)
            // SWAP leaves the verified empty directory at the staging path.
            // It contains no export, recording, or unique recovery evidence.
            if try FileManager.default.contentsOfDirectory(atPath: staged.path).isEmpty {
                try FileManager.default.removeItem(at: staged)
            }
        } catch {
            guard unsupportedPublication(error) else { throw error }
            guard try verifyEmptyDirectory() else { throw SessionStoreError.invalidState("首次导出目录已改变，保留现场") }
            // POSIX rename can atomically replace an empty directory without
            // requiring RENAME_SWAP, symlinks, or hardlinks.
            guard Darwin.rename(staged.path, directory.path) == 0 else {
                throw SessionStoreError.io(operation: "publish initial export with rename", code: errno)
            }
        }
        try SessionArchiveCoding.syncDirectory(parent)
        return true
    }

    private static func publishExport(_ rendered: [String: Data], in directory: URL, operations: PublicationOperations) throws {
        exportLock.lock()
        defer { exportLock.unlock() }
        try SensitiveFileIO.prepareDirectory(directory)
        if try publishInitialExport(rendered, in: directory, operations: operations) { return }
        let fm = FileManager.default
        let store = directory.appendingPathComponent(".exports", isDirectory: true)
        if fm.fileExists(atPath: store.path) {
            let values = try store.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw SessionStoreError.unsafePath(store.path) }
        }
        let versions = store.appendingPathComponent("versions", isDirectory: true)
        var versionInfo = stat()
        if lstat(versions.path, &versionInfo) == 0 { try requireDirectory(versions) }
        else if errno != ENOENT { throw SessionStoreError.io(operation: "inspect export versions", code: errno) }
        try SensitiveFileIO.prepareDirectory(versions)
        try requireDirectory(versions)
        let lockURL = store.appendingPathComponent(".export.lock")
        try SessionArchiveCoding.requireRegularFileIfPresent(lockURL)
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SessionStoreError.io(operation: "open export lock", code: errno) }
        defer { _ = Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SessionStoreError.io(operation: "lock export", code: errno) }
        defer { _ = flock(descriptor, LOCK_UN) }
        try recoverPortablePublication(in: directory)
        let selected = try currentExportDirectory(in: directory)
        var members = rendered
        let priorNames = try fm.contentsOfDirectory(at: selected, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).filter { $0.hasPrefix("summary-") && $0.hasSuffix(".md") }
        for name in priorNames where members[name] == nil {
            let rootMember = directory.appendingPathComponent(name)
            var info = stat()
            let source = lstat(rootMember.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                ? rootMember : selected.appendingPathComponent(name)
            try SessionArchiveCoding.requireRegularFileIfPresent(source)
            members[name] = try Data(contentsOf: source)
        }
        // Read and validate every visible destination before publication. Old
        // writers replace aliases with regular files; preserve that complete
        // root view instead of silently discarding it or blocking all retries.
        var rootFiles: [String: Data] = [:]
        var foreignRoot = false
        for name in members.keys.sorted() {
            let destination = directory.appendingPathComponent(name)
            var info = stat()
            if lstat(destination.path, &info) != 0 {
                guard errno == ENOENT else { throw SessionStoreError.io(operation: "inspect export destination", code: errno) }
                continue
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard selected != directory,
                      try fm.destinationOfSymbolicLink(atPath: destination.path) == ".exports/current/" + name else {
                    throw SessionStoreError.unsafePath(destination.path)
                }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG else { throw SessionStoreError.unsafePath(destination.path) }
            }
            let bytes = try rootMemberBytes(at: destination)
            rootFiles[name] = bytes
            if selected != directory, info.st_mode & S_IFMT == S_IFREG,
               (try? Data(contentsOf: selected.appendingPathComponent(name))) != bytes {
                foreignRoot = true
            }
        }
        func generation(_ files: [String: Data], under parent: URL = versions) throws -> URL {
            try writeExportGeneration(files, under: parent, preservingPermissionsFrom: selected)
        }
        if foreignRoot {
            let recovered = store.appendingPathComponent("recovered", isDirectory: true)
            var info = stat()
            if lstat(recovered.path, &info) == 0 { try requireDirectory(recovered) }
            else {
                guard errno == ENOENT else { throw SessionStoreError.io(operation: "inspect export recovery", code: errno) }
                try fm.createDirectory(at: recovered, withIntermediateDirectories: false)
            }
            _ = try generation(rootFiles, under: recovered)
        }
        let staged = try generation(members)
        var portable = fm.fileExists(atPath: store.appendingPathComponent("current.json").path)
        if !portable {
            let probe = store.appendingPathComponent(".link-capability-\(UUID())")
            do {
                try operations.createSymbolicLink("versions", probe)
                guard unlink(probe.path) == 0 else { throw SessionStoreError.io(operation: "retire export capability probe", code: errno) }
            } catch {
                guard unsupportedPublication(error) else { throw error }
                portable = true
            }
        }
        let previous = selected == directory || portable ? try generation(rootFiles) : selected
        if portable {
            try publishPortable(members, staged: staged, previous: previous,
                                originalFiles: rootFiles, in: directory, operations: operations)
            try requirePublishedExport(members, generation: staged, in: directory)
            return
        }
        let current = store.appendingPathComponent("current")
        if selected == directory {
            try replaceLink("versions/" + previous.lastPathComponent, at: current, operations: operations)
        }
        // Keep partial aliases on failure. Their missing generation members
        // identify unfinished publication, so retry can reuse them. Never delete
        // a public name after checking it: a later writer may have replaced it.
        for name in members.keys.sorted() {
            let url = directory.appendingPathComponent(name)
            try operations.beforeMemberPublication(name)
            try requireRootMemberUnchanged(at: url, original: rootFiles[name])
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { continue }
            try replaceLink(".exports/current/" + name, at: url, operations: operations)
        }
        // Catch earlier-member changes before committing the shared pointer.
        for name in members.keys.sorted() {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
                  try fm.destinationOfSymbolicLink(atPath: url.path) == ".exports/current/" + name else {
                throw SessionStoreError.invalidState("导出期间文件已被另一个写者修改，需重试；停止发布并保留原件")
            }
        }
        try replaceLink("versions/" + staged.lastPathComponent, at: current, operations: operations)
        try requirePublishedExport(members, generation: staged, in: directory)
    }

    private static func requirePublishedExport(_ members: [String: Data], generation: URL, in directory: URL) throws {
        let conflict = SessionStoreError.invalidState("导出一致性检查失败，需重试；完整版本及并发写入的文件已保留")
        guard (try? currentExportDirectory(in: directory)) == generation else { throw conflict }
        for name in members.keys.sorted() {
            guard (try? rootMemberBytes(at: directory.appendingPathComponent(name))) == members[name] else { throw conflict }
        }
        // This is a final observation, not a lock on noncooperating writers.
        // Another App instance or external writer ignoring .export.lock can
        // still change a public name after it was read, including before return.
    }

    private static func writeExportGeneration(_ files: [String: Data], under parent: URL,
                                              preservingPermissionsFrom metadata: URL? = nil) throws -> URL {
        try requireDirectory(parent)
        let url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try SensitiveFileIO.prepareDirectory(url)
        for (name, bytes) in files {
            if let prior = metadata?.appendingPathComponent(name) {
                try SessionArchiveCoding.requireRegularFileIfPresent(prior)
                if FileManager.default.fileExists(atPath: prior.path) {
                    try FileManager.default.copyItem(at: prior, to: url.appendingPathComponent(name))
                }
            }
            try SessionArchiveCoding.atomicWrite(bytes, url.appendingPathComponent(name))
        }
        let index = ExportIndex(members: files.mapValues(SessionArchiveCoding.digest))
        try SessionArchiveCoding.atomicWrite(SessionArchiveCoding.encode(index), url.appendingPathComponent("export-index.json"))
        try SessionArchiveCoding.syncDirectory(url)
        try SessionArchiveCoding.syncDirectory(parent)
        return url
    }

    private static func rootMemberBytes(at url: URL) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw SessionStoreError.io(operation: "inspect export member", code: errno) }
            return nil
        }
        guard info.st_mode & S_IFMT == S_IFREG || (info.st_mode & S_IFMT == S_IFLNK
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == ".exports/current/" + url.lastPathComponent) else {
            throw SessionStoreError.unsafePath(url.path)
        }
        if info.st_mode & S_IFMT == S_IFLNK {
            var target = stat()
            if fstatat(AT_FDCWD, url.path, &target, 0) != 0 {
                guard errno == ENOENT else { throw SessionStoreError.io(operation: "inspect export alias target", code: errno) }
                // A failed first publication can leave a managed alias whose
                // member is absent from current. Keep it and let retry finish.
                return nil
            }
        }
        return try Data(contentsOf: url)
    }

    private static func requireRootMemberUnchanged(at url: URL, original: Data?) throws {
        guard try rootMemberBytes(at: url) == original else {
            throw SessionStoreError.invalidState("导出期间文件已被另一个写者修改，需重试；停止发布并保留原件")
        }
    }

    private static func retireLegacyExportPointer(in store: URL) throws {
        let current = store.appendingPathComponent("current")
        var info = stat()
        if lstat(current.path, &info) != 0 {
            guard errno == ENOENT else { throw SessionStoreError.io(operation: "inspect legacy export pointer", code: errno) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFLNK else { throw SessionStoreError.unsafePath(current.path) }
        let link = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        let parts = link.split(separator: "/")
        guard parts.count == 2, parts[0] == "versions", UUID(uuidString: String(parts[1])) != nil else {
            throw SessionStoreError.unsafePath(current.path)
        }
        try requireDirectory(store.appendingPathComponent("versions", isDirectory: true))
        try validateExportGeneration(store.appendingPathComponent(link, isDirectory: true))
        guard unlink(current.path) == 0 else { throw SessionStoreError.io(operation: "retire legacy export pointer", code: errno) }
        try SessionArchiveCoding.syncDirectory(store)
    }

    private static func replaceRootMember(_ bytes: Data, at destination: URL) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
            try SensitiveFileIO.atomicWrite(bytes, to: destination)
            return
        }
        // The destination was validated under the publication lock. Rename a
        // fully synced regular file over a managed alias without following it.
        let pending = destination.deletingLastPathComponent().appendingPathComponent(".export-file-\(UUID())")
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK,
                  try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
                    == ".exports/current/" + destination.lastPathComponent else {
                throw SessionStoreError.unsafePath(destination.path)
            }
            let selected = try currentExportDirectory(in: destination.deletingLastPathComponent())
            let prior = selected.appendingPathComponent(destination.lastPathComponent)
            try SessionArchiveCoding.requireRegularFileIfPresent(prior)
            try FileManager.default.copyItem(at: prior, to: pending)
        } else if errno != ENOENT {
            throw SessionStoreError.io(operation: "inspect portable export member", code: errno)
        }
        try SessionArchiveCoding.atomicWrite(bytes, pending)
        guard Darwin.rename(pending.path, destination.path) == 0 else {
            throw SessionStoreError.io(operation: "publish portable export member", code: errno)
        }
        try SessionArchiveCoding.syncDirectory(destination.deletingLastPathComponent())
    }

    private static func publishPortable(_ members: [String: Data], staged: URL, previous: URL,
                                        originalFiles: [String: Data], in directory: URL, operations: PublicationOperations) throws {
        let store = directory.appendingPathComponent(".exports", isDirectory: true)
        let marker = store.appendingPathComponent("publishing.json")
        let pointer = store.appendingPathComponent("current.json")
        // A normal file rename provides the immutable generation commit point
        // on volumes that cannot create symlinks. Root compatibility files are
        // recoverable via this durable transaction before the first replacement.
        try SessionArchiveCoding.atomicWrite(SessionArchiveCoding.encode(ExportPointer(generation: previous.lastPathComponent)), pointer)
        let transaction = PortableTransaction(rollback: previous.lastPathComponent, next: staged.lastPathComponent,
            names: members.keys.sorted(), originallyPresent: originalFiles.keys.sorted())
        try SessionArchiveCoding.atomicWrite(SessionArchiveCoding.encode(transaction), marker)
        do {
            for name in members.keys.sorted() {
                try operations.beforeMemberPublication(name)
                try requireRootMemberUnchanged(at: directory.appendingPathComponent(name), original: originalFiles[name])
                try replaceRootMember(members[name]!, at: directory.appendingPathComponent(name))
            }
            // Earlier members may have changed while the rest were written.
            // Keep the transaction until the whole root view matches this version.
            for name in members.keys.sorted() {
                try requireRootMemberUnchanged(at: directory.appendingPathComponent(name), original: members[name])
            }
            try SessionArchiveCoding.atomicWrite(SessionArchiveCoding.encode(ExportPointer(generation: staged.lastPathComponent)), pointer)
            try retireLegacyExportPointer(in: store)
            try FileManager.default.removeItem(at: marker)
            try SessionArchiveCoding.syncDirectory(store)
        } catch {
            // Restore the previous visible set on ordinary failures. If repair
            // itself fails, keep the transaction and both complete generations
            // so the next publication can finish recovery before writing.
            try? recoverPortablePublication(in: directory)
            throw error
        }
    }

    private static func recoverPortablePublication(in directory: URL) throws {
        let fm = FileManager.default
        let store = directory.appendingPathComponent(".exports", isDirectory: true)
        let marker = store.appendingPathComponent("publishing.json")
        try SessionArchiveCoding.requireRegularFileIfPresent(marker)
        guard fm.fileExists(atPath: marker.path) else { return }
        let bytes = try Data(contentsOf: marker)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["version", "rollback", "next", "names", "originallyPresent"]) else {
            throw SessionStoreError.invalidState("导出恢复记录含未知状态，原文件已保留")
        }
        let transaction = try SessionArchiveCoding.decode(PortableTransaction.self, from: bytes)
        guard transaction.version == 1, UUID(uuidString: transaction.rollback) != nil,
              UUID(uuidString: transaction.next) != nil,
              Set(transaction.names).count == transaction.names.count,
              Set(transaction.originallyPresent).isSubset(of: Set(transaction.names)),
              transaction.names.allSatisfy(isExportMemberName) else {
            throw SessionStoreError.invalidState("导出恢复记录无效，原文件已保留")
        }
        let selected = try currentExportDirectory(in: directory)
        let committed = selected.lastPathComponent == transaction.next
        guard committed || selected.lastPathComponent == transaction.rollback else {
            throw SessionStoreError.invalidState("导出恢复记录与当前版本冲突，保留现场")
        }
        let other = store.appendingPathComponent("versions/" + (committed ? transaction.rollback : transaction.next), isDirectory: true)
        try validateExportGeneration(other)
        // Preserve an unexpected root view as a verified immutable recovery
        // before restoring the committed generation. An unavailable backup
        // blocks repair and leaves the external bytes and transaction intact.
        var observed: [String: Data] = [:]
        var hasForeignBytes = false
        for name in transaction.names {
            let root = directory.appendingPathComponent(name)
            guard let bytes = try rootMemberBytes(at: root) else { continue }
            observed[name] = bytes
            if (try? Data(contentsOf: selected.appendingPathComponent(name))) != bytes
                    && (try? Data(contentsOf: other.appendingPathComponent(name))) != bytes {
                hasForeignBytes = true
            }
        }
        if hasForeignBytes {
            let recovered = store.appendingPathComponent("recovered", isDirectory: true)
            if fm.fileExists(atPath: recovered.path) { try requireDirectory(recovered) }
            else { try fm.createDirectory(at: recovered, withIntermediateDirectories: false) }
            let preserved = try writeExportGeneration(observed, under: recovered)
            try validateExportGeneration(preserved)
        }
        for name in transaction.names {
            let root = directory.appendingPathComponent(name)
            try requireRootMemberUnchanged(at: root, original: observed[name])
            if committed || transaction.originallyPresent.contains(name) {
                try replaceRootMember(Data(contentsOf: selected.appendingPathComponent(name)), at: root)
            } else if fm.fileExists(atPath: root.path) {
                try SessionArchiveCoding.requireRegularFileIfPresent(root)
                try fm.removeItem(at: root)
            }
        }
        try SessionArchiveCoding.syncDirectory(directory)
        try retireLegacyExportPointer(in: store)
        try fm.removeItem(at: marker)
        try SessionArchiveCoding.syncDirectory(store)
    }

    private static func isExportMemberName(_ name: String) -> Bool {
        if ["bilingual.jsonl", "bilingual.srt", "manifest.json", "transcript-en.txt", "transcript-target-en.txt"].contains(name) { return true }
        for (prefix, suffix) in [("summary-", ".md"), ("transcript-", ".txt")] {
            if name.hasPrefix(prefix), name.hasSuffix(suffix) {
                return isValidTargetLocale(String(name.dropFirst(prefix.count).dropLast(suffix.count)))
            }
        }
        return false
    }
    struct Manifest: Codable, Equatable {
        let createdAt: Date
        let sourceLocale: String
        let targetLocale: String
        let recordingFile: String
        let segmentCount: Int
        var sourceLanguages: [String]? = nil
        var converterVersion: String? = nil
    }

    static var targetTranscriptFileName: String { targetTranscriptFileName(for: CaptionTranslationTarget.simplifiedChinese.rawValue) }
    static var targetSummaryFileName: String { targetSummaryFileName(for: CaptionTranslationTarget.simplifiedChinese.rawValue) }

    static func targetTranscriptFileName(for locale: String) -> String {
        // The legacy source transcript must remain distinct from English output.
        locale == "en" ? "transcript-target-en.txt" : "transcript-\(locale).txt"
    }

    static func targetSummaryFileName(for locale: String) -> String { "summary-\(locale).md" }

    static func isValidTargetLocale(_ locale: String) -> Bool {
        locale.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil
    }

    /// Saved courses keep the target recorded at export time. Pre-manifest
    /// courses retain their legacy summary name and identity fingerprint.
    static func savedSummaryURL(in directory: URL) -> URL {
        // This convenience entry point is for callers outside SessionStore's
        // lock. Store readers must use the explicit-target overload below.
        let snapshotURL = directory.appendingPathComponent(SessionStore.snapshotFileName)
        let snapshot = FileManager.default.fileExists(atPath: snapshotURL.path)
            ? try? SessionStore(directory: directory).load() : nil
        return savedSummaryURL(in: directory, targetLocale: snapshot?.targetLocale)
    }

    /// Does not acquire a SessionStore lock or read a snapshot. The caller
    /// supplies its already known target (nil for a legacy import).
    static func savedSummaryURL(in directory: URL, targetLocale: String?) -> URL {
        struct TargetMetadata: Decodable { let targetLocale: String }
        var names: [String] = []
        if let locale = targetLocale, isValidTargetLocale(locale) {
            names.append(targetSummaryFileName(for: locale))
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let metadata = try? JSONDecoder().decode(TargetMetadata.self, from: data),
           isValidTargetLocale(metadata.targetLocale) {
            names.append(targetSummaryFileName(for: metadata.targetLocale))
        }
        for name in ["summary-zh-Hans.md"] where !names.contains(name) {
            names.append(name)
        }
        return names.map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            ?? directory.appendingPathComponent(names[0])
    }

    /// Language labels are UI metadata, never part of copied/exported text.
    static func sourceLine(_ segment: TranscriptSegment) -> String { segment.english }

    static func targetLine(_ segment: TranscriptSegment, target: CaptionTranslationTarget = .simplifiedChinese) -> String {
        if target.keepsSourceAsCaption(language: segment.sourceLanguage) {
            return segment.hasUsableTranslation ? segment.chinese : target.renderPassThrough(segment.english)
        }
        if target != .simplifiedChinese {
            if segment.translationState == .failed { return ClassroomFixedText.failedAgainstSource.text(targetCode: target.rawValue) }
            return segment.hasUsableTranslation ? segment.chinese : ClassroomFixedText.pendingTranslation.text(targetCode: target.rawValue)
        }
        if segment.sourceLanguage != nil, segment.translationState == .failed {
            return "（本段翻译未完成，可对照原文）"
        }
        return humanReadableChinese(segment.chinese)
    }

    static func captionLines(_ segment: TranscriptSegment, target: CaptionTranslationTarget = .simplifiedChinese) -> [String] {
        target.keepsSourceAsCaption(language: segment.sourceLanguage)
            ? [targetLine(segment, target: target)] : [sourceLine(segment), targetLine(segment, target: target)]
    }

    static func sourceLanguages(in segments: [TranscriptSegment]) -> [String]? {
        let codes = Set(segments.compactMap(\.sourceLanguage)).sorted()
        return codes.isEmpty ? nil : codes
    }

    static func srtCue(_ segment: TranscriptSegment, index: Int, target: CaptionTranslationTarget = .simplifiedChinese) -> String {
        return "\(index + 1)\n\(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))\n"
            + captionLines(segment, target: target).joined(separator: "\n")
    }

    /// Saved text can be verified before its language is released for generation.
    static func targetLine(_ segment: TranscriptSegment, outputLanguage: OutputLanguage) -> String {
        if let generated = outputLanguage.generationTarget {
            return targetLine(segment, target: generated)
        }
        if outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage) {
            return segment.hasUsableTranslation ? segment.chinese : segment.english
        }
        if segment.translationState == .failed {
            return ClassroomFixedText.failedAgainstSource.text(targetCode: outputLanguage.rawValue)
        }
        if !segment.hasUsableTranslation {
            return ClassroomFixedText.pendingTranslation.text(targetCode: outputLanguage.rawValue)
        }
        return segment.chinese
    }

    static func captionLines(_ segment: TranscriptSegment, outputLanguage: OutputLanguage) -> [String] {
        let translated = targetLine(segment, outputLanguage: outputLanguage)
        if outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage) {
            return [translated]
        }
        return [sourceLine(segment), translated]
    }

    static func srtCue(_ segment: TranscriptSegment, index: Int, outputLanguage: OutputLanguage) -> String {
        "\(index + 1)\n\(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))\n"
            + captionLines(segment, outputLanguage: outputLanguage).joined(separator: "\n")
    }

    /// The existing targetLine/captionLines/srtCue APIs remain generation text
    /// for UI callers. Export and saved-output verification render exactly once.
    static func renderedTargetLine(_ segment: TranscriptSegment, outputLanguage: OutputLanguage,
                                   converter: ChineseScriptConverter = .shared) throws -> String {
        var draft = targetLine(segment, outputLanguage: outputLanguage)
        let sourceOnly = outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage)
        if outputLanguage.profile.renderer != .identity, !sourceOnly, segment.translationState == .failed {
            draft = (segment.sourceLanguage == nil ? ClassroomFixedText.failedAgainstEnglish : .failedAgainstSource)
                .text(targetCode: "zh-Hans")
        }
        return !sourceOnly && !segment.hasUsableTranslation
            ? try outputLanguage.renderFixedText(draft, converter: converter)
            : try outputLanguage.render(draft, converter: converter)
    }

    static func renderedCaptionLines(_ segment: TranscriptSegment, outputLanguage: OutputLanguage,
                                    converter: ChineseScriptConverter = .shared) throws -> [String] {
        let translated = try renderedTargetLine(segment, outputLanguage: outputLanguage, converter: converter)
        return outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage)
            ? [translated] : [sourceLine(segment), translated]
    }

    static func renderedSRTCue(_ segment: TranscriptSegment, index: Int, outputLanguage: OutputLanguage,
                               converter: ChineseScriptConverter = .shared) throws -> String {
        "\(index + 1)\n\(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))\n"
            + (try renderedCaptionLines(segment, outputLanguage: outputLanguage, converter: converter))
                .joined(separator: "\n")
    }

    static func export(
        segments: [TranscriptSegment],
        sessionDirectory: URL,
        recordingFileName: String = "recording.wav",
        summary: String = "",
        createdAt: Date = Date(),
        target: OutputLanguage = .simplifiedChinese,
        summaryIsLegacyRendered: Bool = false,
        summaryEvidence: [TranscriptSegment] = [],
        converter: ChineseScriptConverter = .shared,
        operations: PublicationOperations = .init()
    ) throws {
        // Check the actual dictionary, including empty/legacy-only exports.
        // Release metadata does not determine whether saved text can render.
        if target.profile.renderer != .identity {
            try converter.prepare()
        }
        let english = segments.map(sourceLine).joined(separator: "\n")
        let chinese = try segments.map { try renderedTargetLine($0, outputLanguage: target, converter: converter) }.joined(separator: "\n")
        let srt = try segments.enumerated().map { index, segment in
            try renderedSRTCue(segment, index: index, outputLanguage: target, converter: converter)
        }.joined(separator: "\n\n") + "\n"
        let trimmedSummary = try ClassroomMarkdownRendering.render(summary, language: target,
            isLegacyRendered: summaryIsLegacyRendered,
            scheduleEvidence: summaryEvidence.isEmpty ? segments : summaryEvidence,
            converter: converter).trimmingCharacters(in: .whitespacesAndNewlines)
        var members = ["transcript-en.txt": Data(english.appending("\n").utf8),
            targetTranscriptFileName(for: target.rawValue): Data(chinese.appending("\n").utf8)]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let jsonl = try segments.map { segment -> String in
            let data = try ChineseOutputDefaults.encodeBilingualDraft(segment, using: encoder)
            guard let line = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return line
        }.joined(separator: "\n") + "\n"
        members["bilingual.jsonl"] = Data(jsonl.utf8)
        members["bilingual.srt"] = Data(srt.utf8)

        if !trimmedSummary.isEmpty {
            members[targetSummaryFileName(for: target.rawValue)] = Data((trimmedSummary + "\n").utf8)
        }

        let manifest = Manifest(
            createdAt: createdAt,
            sourceLocale: "en-US",
            targetLocale: target.rawValue,
            recordingFile: recordingFileName,
            segmentCount: segments.count,
            sourceLanguages: sourceLanguages(in: segments),
            converterVersion: target.profile.renderer == .identity ? nil : ChineseScriptConverter.version
        )
        members["manifest.json"] = try encoder.encode(manifest)
        try publishExport(members, in: sessionDirectory, operations: operations)
    }

    /// 2026-09-18：给人看的出口（字幕/转写/笔记导出）不该出现 `[翻译失败：…]` 这种英文错误串 ✗。
    /// 内存里的占位符原样保留 ✓（它是应用的重试信号 ✓，5 处 `hasPrefix("[翻译失败：")` 依赖它 ✓），
    /// 只在**渲染**时换成中性中文 ✓ —— 与既有的"（本段暂无译文）"同一风格 ✓。
    static func humanReadableChinese(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "（本段暂无译文）" }
        if trimmed.hasPrefix("[翻译失败：") { return "（本段翻译未完成，可对照英文）" }
        return raw
    }

    static func srtTimestamp(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, Int((interval * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }
}

// MARK: - 摘要导出（Markdown / 纯文本 / PDF）

import AppKit
import UniformTypeIdentifiers

enum NotesExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case plainText
    case word
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "纯文本"
        case .word: return "Word"
        case .pdf: return "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .word: return "docx"
        case .pdf: return "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .plainText: return .plainText
        case .word: return UTType("org.openxmlformats.wordprocessingml.document")
                ?? UTType(filenameExtension: "docx") ?? .data
        case .pdf: return .pdf
        }
    }
}

enum NotesExportScope: String, CaseIterable, Identifiable, Sendable {
    case latest
    case wholeLesson

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最近更新"
        case .wholeLesson: return "整课笔记"
        }
    }

    /// Used in the default file name and inside the document header.
    var fileLabel: String {
        switch self {
        case .latest: return "最近更新"
        case .wholeLesson: return "整课笔记"
        }
    }
}

/// Everything the exporter needs, snapshotted on the main actor before the save
/// panel opens. Building a document never calls a model and never reads or
/// writes the recording.
///
/// 复查意见从 2026-09-19 起只以**整篇 Markdown**（`reviewMarkdown`）进入快照 ✓：
/// 四种格式渲染同一个章节 ✓，不再各自编号拼装 ✓，也就不可能出现"复查批次 1"这类
/// 与报告正文重复、又可能对不上号的标题 ✓。
struct NotesExportSnapshot: Equatable, Sendable {
    let className: String
    let sessionName: String?
    let scope: NotesExportScope
    let scopeDetail: String
    let coverageLine: String
    let notesMarkdown: String
    /// 复查报告全文（含顶层进度标题与批次小节）；没有复查意见时为 nil。
    let reviewMarkdown: String?
    let transcript: [TranscriptSegment]
    let generatedAt: Date
    let includesReviewAdvice: Bool
    let includesTranscript: Bool
    var target: OutputLanguage = .simplifiedChinese
    /// Legacy summaries are already rendered; review advice still uses its
    /// independently stored generation text.
    var notesAreLegacyRendered: Bool = false
    /// Evidence remains available even when the user omits the transcript.
    var scheduleEvidence: [TranscriptSegment] = []

    var classDate: String { NotesExportDocument.classDate(of: self) }
}

enum NotesExportError: LocalizedError {
    case emptyNotes
    case pdfContextUnavailable
    case rendererUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyNotes: return "所选范围还没有可导出的笔记内容。"
        case .pdfContextUnavailable: return "无法创建 PDF 输出上下文。"
        case .rendererUnavailable: return "课程输出语言的渲染器尚不可用，暂时无法导出笔记。"
        case .writeFailed(let detail): return "写入文件失败：\(detail)"
        }
    }
}

enum NotesExportDocument {
    /// Prepared fields are shared by all four formats. Source quotations,
    /// recording names and source caption lines are never a conversion input.
    struct RenderedFields {
        let className: String
        let scopeDetail: String
        let coverageLine: String
        let notesMarkdown: String
        var reviewBody: String?
        let labels: [ClassroomFixedText: String]
        let transcriptHeading: String
        let captionLines: [[String]]
    }

    static func prepare(_ snapshot: NotesExportSnapshot,
                        converter: ChineseScriptConverter = .shared) throws -> RenderedFields? {
        let target = snapshot.target
        guard target.profile.renderer != .identity else { return nil }
        do {
            // A supplied missing dictionary must fail even when no Han text is
            // present or the legacy notes themselves need no conversion.
            try converter.prepare()
            let keys: [ClassroomFixedText] = [.notesHeading, .exportReviewHeading, .exportDisclaimer,
                .latestScope, .wholeScope, .exportScopeLine, .exportCoverageLine, .exportReviewScope,
                .exportSessionLine, .exportTimeLine, .exportExplanationLine, .exportProgressLine, .emptyNotes]
            let labels = try Dictionary(uniqueKeysWithValues: keys.map {
                ($0, try target.renderFixedText($0.text(targetCode: target.rawValue), converter: converter))
            })
            var fields = RenderedFields(
                className: try target.render(snapshot.className, converter: converter),
                scopeDetail: try target.render(snapshot.scopeDetail, converter: converter),
                coverageLine: try target.render(snapshot.coverageLine, converter: converter),
                notesMarkdown: try ClassroomMarkdownRendering.render(snapshot.notesMarkdown, language: target,
                    isLegacyRendered: snapshot.notesAreLegacyRendered,
                    scheduleEvidence: snapshot.scheduleEvidence.isEmpty ? snapshot.transcript : snapshot.scheduleEvidence,
                    converter: converter),
                reviewBody: nil,
                labels: labels,
                transcriptHeading: try target.renderFixedText(transcriptHeading(for: target), converter: converter),
                captionLines: snapshot.includesTranscript ? try snapshot.transcript.map {
                    try SessionExporter.renderedCaptionLines($0, outputLanguage: target, converter: converter)
                } : []
            )
            if snapshot.includesReviewAdvice, let review = snapshot.reviewMarkdown,
               !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let renderedReview = try ClassroomMarkdownRendering.render(review, language: target,
                    scheduleEvidence: snapshot.scheduleEvidence, converter: converter)
                let body = reviewSection(renderedReview, target: target, rendered: fields)
                fields.reviewBody = body.isEmpty ? nil : body
            }
            return fields
        } catch {
            throw NotesExportError.rendererUnavailable
        }
    }

    static func fixed(_ key: ClassroomFixedText, target: OutputLanguage,
                      rendered: RenderedFields? = nil) -> String {
        rendered?.labels[key] ?? key.text(targetCode: target.rawValue)
    }
    static func fixed(_ key: ClassroomFixedText, _ args: [String], target: OutputLanguage,
                      rendered: RenderedFields? = nil) -> String {
        guard let rendered else { return key.format(args: args, targetCode: target.rawValue) }
        // Convert the template before inserting arguments. Searching/replacing
        // an assembled line could rewrite a quote or a recording folder name.
        let template = fixed(key, target: target, rendered: rendered)
        let regex = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        var result = ""
        var cursor = template.startIndex
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template),
                  let digits = Range(match.range(at: 1), in: template),
                  let index = Int(template[digits]), args.indices.contains(index) else { continue }
            result += template[cursor..<range.lowerBound]
            result += args[index]
            cursor = range.upperBound
        }
        return result + template[cursor...]
    }
    static func notesHeading(for target: OutputLanguage, rendered: RenderedFields? = nil) -> String {
        fixed(.notesHeading, target: target, rendered: rendered)
    }
    static func reviewHeading(for target: OutputLanguage, rendered: RenderedFields? = nil) -> String {
        fixed(.exportReviewHeading, target: target, rendered: rendered)
    }
    static func disclaimer(for target: OutputLanguage, rendered: RenderedFields? = nil) -> String {
        fixed(.exportDisclaimer, target: target, rendered: rendered)
    }
    static func scopeLabel(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) -> String {
        fixed(snapshot.scope == .latest ? .latestScope : .wholeScope, target: snapshot.target, rendered: rendered)
    }

    static let notesHeading = "学习笔记"
    static let reviewHeading = "9B 复查意见（仅供核对，未合并进笔记正文）"
    static let transcriptHeading = "双语字幕（含时间戳）"
    static func transcriptHeading(for target: OutputLanguage) -> String {
        target == .english ? ClassroomFixedText.transcriptHeading.text(targetCode: target.rawValue) : transcriptHeading
    }
    static let disclaimer = "本文件由本机模型生成，未经人工逐句核对；正文按主题整理，“需要回听”和“来源检查”两节列出的内容仍需自行核对。"

    static func classDate(of snapshot: NotesExportSnapshot) -> String {
        // Prefer the date inside the recording folder name (the class date).
        if let name = snapshot.sessionName, let range = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(name[range])
        }
        return dateFormatter.string(from: snapshot.generatedAt)
    }

    static func defaultFileName(_ snapshot: NotesExportSnapshot, format: NotesExportFormat) -> String {
        "\(snapshot.className) \(classDate(of: snapshot)) \(scopeLabel(snapshot)).\(format.fileExtension)"
    }

    static func timestamp(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total / 60) % 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    static func header(_ snapshot: NotesExportSnapshot, markdown: Bool, rendered: RenderedFields? = nil) -> [String] {
        var lines: [String] = []
        let title = "\(rendered?.className ?? snapshot.className) · \(scopeLabel(snapshot, rendered: rendered)) · \(classDate(of: snapshot))"
        lines.append(markdown ? "# \(title)" : title)
        lines.append("")
        lines.append("- " + fixed(.exportScopeLine, [scopeLabel(snapshot, rendered: rendered), rendered?.scopeDetail ?? snapshot.scopeDetail], target: snapshot.target, rendered: rendered))
        lines.append("- " + fixed(.exportCoverageLine, [rendered?.coverageLine ?? snapshot.coverageLine], target: snapshot.target, rendered: rendered))
        // 「最近更新」只限制笔记正文的范围；复查意见是**整场录音**的。
        if snapshot.includesReviewAdvice, snapshot.reviewMarkdown != nil, snapshot.scope == .latest {
            lines.append("- " + fixed(.exportReviewScope, target: snapshot.target, rendered: rendered))
        }
        if let session = snapshot.sessionName {
            lines.append("- " + fixed(.exportSessionLine, [session], target: snapshot.target, rendered: rendered))
        }
        lines.append("- " + fixed(.exportTimeLine, [timestampFormatter.string(from: snapshot.generatedAt)], target: snapshot.target, rendered: rendered))
        lines.append("- " + fixed(.exportExplanationLine, [disclaimer(for: snapshot.target, rendered: rendered)], target: snapshot.target, rendered: rendered))
        lines.append("")
        return lines
    }

    /// 复查章节正文（四种格式共用 ✓）。
    ///
    /// - 顶层报告标题（`# …`）转成一行"复查进度"文字 ✓（不再和章节标题抢层级 ✓）；
    /// - 批次标题（`## 第 N 批 …`）降为子级（`### …`）✓，保留原有的批号与主题 ✓；
    /// - 正常建议原样保留；旧机器失败行改为固定说明，不再次导出自由诊断；
    /// - 不再另加"复查批次 1/2/3"编号 ✓（报告里已经有批号，重复编号会对不上 ✓）。
    private static func legacyFailureLine(_ line: String) -> Bool {
        // These complete wrappers originate in the queue/load error paths.
        // An ordinary "失败：先检查…" recommendation has no failure identity.
        let explicit = ["本批复查失败，保留原笔记：", "复查进度读取失败，已保留现场：",
                        "复查报告读取失败，未导出：", "读取复查报告目录失败，未导出：",
                        "局部复查报告读取失败，未导出：", "课程已打开；复查报告读取失败："]
        if explicit.contains(where: { line.hasPrefix($0) && line.count > $0.count }) { return true }
        let generic = ["读取路径失败：", "复查报告读取失败：", "报告保存失败：", "复查报告保存失败："]
        guard let prefix = generic.first(where: line.hasPrefix) else { return false }
        let detail = String(line.dropFirst(prefix.count))
        let fixed = ["超时", "输出超出长度上限", "生成被中断", "本机模型不可用", "输出格式不合格", "笔记未通过校验", "请求失败"]
        if fixed.contains(detail) { return true }
        // Legacy diagnostic code plus an optional ASCII path; match the full
        // payload grammar instead of treating every colon-prefixed sentence as
        // an error. Free prose with this ambiguous prefix is preserved.
        return detail.range(of: #"^[A-Z][A-Z0-9]*_[A-Z0-9_]+(?: [A-Za-z0-9_./-]+)?$"#,
                            options: .regularExpression) != nil
            || detail.range(of: #"^Error Domain=[A-Za-z0-9.]+ Code=-?[0-9]+(?: .*)?$"#,
                            options: .regularExpression) != nil
    }

    static func reviewSection(_ markdown: String, target: OutputLanguage = .simplifiedChinese,
                              rendered: RenderedFields? = nil) -> String {
        var output: [String] = []
        var progressTaken = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if legacyFailureLine(trimmed) {
                output.append("本批复查未完成，原笔记已保留。")
                continue
            }
            if trimmed.hasPrefix("# "), !progressTaken {
                progressTaken = true
                output.append("- " + fixed(.exportProgressLine, [trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)], target: target, rendered: rendered))
                continue
            }
            if trimmed.hasPrefix("## ") {
                output.append("### " + trimmed.dropFirst(3))
                continue
            }
            output.append(text)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 有复查意见时才存在的章节正文（层级已转换）；没有就是 nil。
    static func reviewBody(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) -> String? {
        if let rendered { return rendered.reviewBody }
        guard snapshot.includesReviewAdvice, let review = snapshot.reviewMarkdown,
              !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let body = reviewSection(review, target: snapshot.target)
        return body.isEmpty ? nil : body
    }

    /// 有复查意见时才存在的章节（Markdown / 纯文本两种渲染）。
    private static func reviewBlock(_ snapshot: NotesExportSnapshot, markdown: Bool,
                                    rendered: RenderedFields? = nil) -> String? {
        guard let body = reviewBody(snapshot, rendered: rendered) else { return nil }
        let heading = reviewHeading(for: snapshot.target, rendered: rendered)
        return markdown ? "## \(heading)\n\n" + body : heading + "\n\n" + strippingMarkdown(body)
    }

    static func markdown(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) -> String {
        var sections: [String] = [header(snapshot, markdown: true, rendered: rendered).joined(separator: "\n")]
        let notes = (rendered?.notesMarkdown ?? snapshot.notesMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("## \(notesHeading(for: snapshot.target, rendered: rendered))\n\n" + (notes.isEmpty ? fixed(.emptyNotes, target: snapshot.target, rendered: rendered) : notes))
        if let review = reviewBlock(snapshot, markdown: true, rendered: rendered) {
            sections.append(review)
        }
        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            let lines = snapshot.transcript.enumerated().map { index, segment -> String in
                let stamp = "\(timestamp(segment.startTime))–\(timestamp(segment.endTime))"
                let captions = rendered?.captionLines[index] ?? SessionExporter.captionLines(segment, outputLanguage: snapshot.target)
                return "[\(stamp)] " + captions.joined(separator: "\n")
            }
            sections.append("## \(rendered?.transcriptHeading ?? transcriptHeading(for: snapshot.target))\n\n" + lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func plainText(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) -> String {
        var sections: [String] = []
        sections.append(header(snapshot, markdown: true, rendered: rendered)
            .map { $0.hasPrefix("- ") ? "  " + String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n"))
        let notes = strippingMarkdown(rendered?.notesMarkdown ?? snapshot.notesMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(notesHeading(for: snapshot.target, rendered: rendered) + "\n\n" + (notes.isEmpty ? fixed(.emptyNotes, target: snapshot.target, rendered: rendered) : notes))
        if let review = reviewBlock(snapshot, markdown: false, rendered: rendered) {
            sections.append(review)
        }
        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            let lines = snapshot.transcript.enumerated().map { index, segment -> String in
                let stamp = "\(timestamp(segment.startTime))–\(timestamp(segment.endTime))"
                let captions = rendered?.captionLines[index] ?? SessionExporter.captionLines(segment, outputLanguage: snapshot.target)
                return "[\(stamp)] " + captions.joined(separator: "\n")
            }
            sections.append((rendered?.transcriptHeading ?? transcriptHeading(for: snapshot.target)) + "\n\n" + lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n\n") + "\n"
    }

    static func data(_ snapshot: NotesExportSnapshot, format: NotesExportFormat,
                     converter: ChineseScriptConverter = .shared) throws -> Data {
        let rendered = try prepare(snapshot, converter: converter)
        switch format {
        case .markdown: return Data(markdown(snapshot, rendered: rendered).utf8)
        case .plainText: return Data(plainText(snapshot, rendered: rendered).utf8)
        case .word: return try wordData(snapshot, rendered: rendered)
        case .pdf: return try PDFNotesWriter.data(snapshot, rendered: rendered)
        }
    }

    /// `.docx` through the same attributed content the PDF uses: AppKit writes a
    /// real OOXML package, so Word opens it as an editable document with the
    /// headings, bold labels and sub/superscript formulas intact.
    static func wordData(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) throws -> Data {
        let attributed = PDFNotesWriter.attributedDocument(snapshot, rendered: rendered)
        do {
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
        } catch {
            throw NotesExportError.writeFailed(error.localizedDescription)
        }
    }

    static func write(_ snapshot: NotesExportSnapshot, format: NotesExportFormat, to url: URL,
                      converter: ChineseScriptConverter = .shared) throws {
        let payload = try data(snapshot, format: format, converter: converter)
        do {
            try SensitiveFileIO.atomicWrite(payload, to: url)
        } catch {
            throw NotesExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Drops Markdown syntax while keeping headings, paragraphs, formulas,
    /// timestamps and the “待核对/待确认” markers readable in plain text.
    /// Fenced and indented code blocks are copied verbatim, and only `**` that
    /// really pairs up as bold is removed (see `MarkdownBold`).
    static func strippingMarkdown(_ source: String) -> String {
        let bytes = Array(source.utf8)
        let masks = ChineseScriptConverter.RenderText.protectedMasks(source)
        var lines: [String] = [], start = 0
        while start <= bytes.count {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.count
            defer { start = end + 1 }
            if start < end, masks.blocks[start] {
                lines.append(String(decoding: bytes[start..<end], as: UTF8.self))
                continue
            }
            var text = MarkdownBold.segments(Array(bytes[start..<end]), protected: Array(masks.all[start..<end]))
                .map(\.text).joined()
            if let range = text.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
            if text.hasPrefix("> ") { text = String(text.dropFirst(2)) }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// PDF output through AppKit's text system: it paginates and wraps CJK text and
/// keeps sub/superscript formulas readable, without adding a PDF library.
enum PDFNotesWriter {
    static let pageSize = CGSize(width: 595, height: 842) // A4 in points
    static let margin: CGFloat = 48
    static let bodySize: CGFloat = 11

    static func data(_ snapshot: NotesExportSnapshot, rendered: NotesExportDocument.RenderedFields? = nil) throws -> Data {
        let attributed = attributedDocument(snapshot, rendered: rendered)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw NotesExportError.pdfContextUnavailable
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NotesExportError.pdfContextUnavailable
        }

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        // Each container consumes the glyphs it lays out, so the loop keeps
        // adding pages until every glyph has been drawn.
        while true {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphRange = layoutManager.glyphRange(for: container)
            context.beginPDFPage(nil)
            // TextKit 按"y 向下"排布行位置；PDF 上下文默认是"y 向上"。
            // 不翻转的话，每段文字的行序会上下颠倒（标题落到条目下方、文档标题跑到页尾），
            // 视觉与文本层都能看出来。这里把每页的坐标系翻成 y 向下再绘制。
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.current = nil
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            if NSMaxRange(glyphRange) >= layoutManager.numberOfGlyphs || glyphRange.length == 0 { break }
        }
        context.closePDF()
        return output as Data
    }

    static func attributedDocument(_ snapshot: NotesExportSnapshot,
                                   rendered: NotesExportDocument.RenderedFields? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString()
        func append(_ text: String, style: Style) {
            output.append(line(text, style: style))
        }

        append("\(rendered?.className ?? snapshot.className) · \(NotesExportDocument.scopeLabel(snapshot, rendered: rendered)) · \(snapshot.classDate)", style: .title)
        append(NotesExportDocument.fixed(.exportScopeLine, [NotesExportDocument.scopeLabel(snapshot, rendered: rendered), rendered?.scopeDetail ?? snapshot.scopeDetail], target: snapshot.target, rendered: rendered), style: .meta)
        append(NotesExportDocument.fixed(.exportCoverageLine, [rendered?.coverageLine ?? snapshot.coverageLine], target: snapshot.target, rendered: rendered), style: .meta)
        if snapshot.includesReviewAdvice, snapshot.reviewMarkdown != nil, snapshot.scope == .latest {
            append(NotesExportDocument.fixed(.exportReviewScope, [], target: snapshot.target, rendered: rendered), style: .meta)
        }
        if let session = snapshot.sessionName { append(NotesExportDocument.fixed(.exportSessionLine, [session], target: snapshot.target, rendered: rendered), style: .meta) }
        append(NotesExportDocument.fixed(.exportTimeLine, [NotesExportDocument.timestampFormatter.string(from: snapshot.generatedAt)], target: snapshot.target, rendered: rendered), style: .meta)
        append(NotesExportDocument.disclaimer(for: snapshot.target, rendered: rendered), style: .meta)

        append(NotesExportDocument.notesHeading(for: snapshot.target, rendered: rendered), style: .heading)
        let notes = (rendered?.notesMarkdown ?? snapshot.notesMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty {
            append(NotesExportDocument.fixed(.emptyNotes, target: snapshot.target, rendered: rendered), style: .body)
        } else {
            for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
                append(String(line), style: Style.markdown(String(line)))
            }
        }

        if let review = NotesExportDocument.reviewBody(snapshot, rendered: rendered) {
            append(NotesExportDocument.reviewHeading(for: snapshot.target, rendered: rendered), style: .heading)
            for line in review.split(separator: "\n", omittingEmptySubsequences: false) {
                append(String(line), style: Style.markdown(String(line)))
            }
        }

        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            append(rendered?.transcriptHeading ?? NotesExportDocument.transcriptHeading(for: snapshot.target), style: .heading)
            for (index, segment) in snapshot.transcript.enumerated() {
                let stamp = "\(NotesExportDocument.timestamp(segment.startTime))–\(NotesExportDocument.timestamp(segment.endTime))"
                let lines = rendered?.captionLines[index] ?? SessionExporter.captionLines(segment, outputLanguage: snapshot.target)
                append("[\(stamp)] \(lines[0])", style: .body)
                for translation in lines.dropFirst() { append(translation, style: .translation) }
            }
        }
        return output
    }

    enum Style {
        case title, heading, subheading, body, translation, bullet(Int), meta

        static func markdown(_ line: String) -> Style {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .meta }
            if trimmed.hasPrefix("### ") { return .subheading }
            if trimmed.hasPrefix("## ") { return .heading }
            if trimmed.hasPrefix("# ") { return .heading }
            let indentation = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return .bullet(indentation / 2) }
            return .body
        }
    }

    static func text(of style: Style, line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        switch style {
        case .heading, .subheading, .title:
            for prefix in ["### ", "## ", "# "] where trimmed.hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count))
                break
            }
        case .bullet:
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { trimmed = String(trimmed.dropFirst(2)) }
        default:
            break
        }
        return trimmed
    }

    static func line(_ source: String, style: Style) -> NSAttributedString {
        let text = text(of: style, line: source)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2.5
        paragraph.paragraphSpacing = 3
        switch style {
        case .title:
            paragraph.paragraphSpacing = 8
        case .heading:
            paragraph.paragraphSpacingBefore = 12
            paragraph.paragraphSpacing = 6
        case .subheading:
            paragraph.paragraphSpacingBefore = 8
        case .bullet(let depth):
            paragraph.firstLineHeadIndent = CGFloat(depth) * 16
            paragraph.headIndent = CGFloat(16 * (depth + 1))
        default:
            break
        }

        let size: CGFloat
        switch style {
        case .title: size = 18
        case .heading: size = 14
        case .subheading: size = 12
        case .meta: size = 9
        default: size = bodySize
        }
        let bold: Bool
        switch style {
        case .title, .heading, .subheading: bold = true
        default: bold = false
        }

        let result = NSMutableAttributedString()
        for run in inlineRuns(text, size: size, bold: bold) {
            result.append(run)
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        if case .meta = style {
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: result.length))
        }
        // A blank line still needs a paragraph so it keeps its vertical space.
        if result.length == 0 { result.append(NSAttributedString(string: " ")) }
        result.append(NSAttributedString(string: "\n"))
        return result
    }

    /// Inline runs: `**bold**` (paired by `MarkdownBold`) plus `$…$` / `\(…)`
    /// formulas, which are rendered with real sub/superscript baselines
    /// instead of raw LaTeX-ish markers.
    static func inlineRuns(_ source: String, size: CGFloat, bold: Bool) -> [NSAttributedString] {
        var runs: [NSAttributedString] = []

        func appendPlain(_ piece: String, strong: Bool) {
            guard !piece.isEmpty else { return }
            for run in FormulaDisplay.runs(piece) {
                let fontSize = run.script == 0 ? size : size * 0.72
                let font = font(size: fontSize, bold: strong || (run.math && !run.text.isEmpty))
                var attributes: [NSAttributedString.Key: Any] = [.font: font]
                if run.script != 0 {
                    attributes[.baselineOffset] = run.script > 0 ? size * 0.34 : -size * 0.16
                }
                if run.math {
                    attributes[.foregroundColor] = NSColor.labelColor
                }
                runs.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }

        for segment in MarkdownBold.segments(source) {
            appendPlain(segment.text, strong: segment.bold || bold)
        }
        if runs.isEmpty { runs.append(NSAttributedString(string: source, attributes: [.font: font(size: size, bold: bold)])) }
        return runs
    }

    /// PDF 的文字层必须能被搜索和复制。实测（2026-09-18）：用 AppKit 排版嵌入后，
    /// PingFang SC 与 STHeiti SC 会把 149 个汉字写成**康熙部首码点**
    /// （「一」→U+2F00、「水」→U+2F54、「而」→U+2F7D、「氏」→U+2F52…），共 33 种；
    /// 人眼看不出差别，但从 PDF 搜索、复制、朗读全部失效。Hiragino Sans GB 不受影响，
    /// 因此把它提到首选（原先它是第二备选）。docx 路径不受此影响（写的是 Unicode 文本）。
    static func font(size: CGFloat, bold: Bool) -> NSFont {
        let candidates = bold
            ? ["HiraginoSansGB-W6", "PingFangSC-Semibold", "STHeitiSC-Medium"]
            : ["HiraginoSansGB-W3", "PingFangSC-Regular", "STHeitiSC-Light"]
        for name in candidates {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
}

/// `**bold**` pairing shared by the plain-text and PDF/Word exports. A `**`
/// run opens only before non-whitespace and closes only after non-whitespace,
/// pairs stay on one line, and runs inside code spans or formulas never count,
/// so `x ** 2`, a lone `**` and `` `a**b` `` stay literal. A run with an ASCII
/// letter or digit on both sides (`x**2`, `(a+b)**2`) is an operator, never a
/// delimiter. In `***x***` the inner two stars are bold and the outer `*`
/// stays. `__` is never bold here: in these notes it is far more often
/// `__init__` than emphasis.
enum MarkdownBold {
    /// The line split into plain and bold pieces, with paired delimiters removed.
    static func segments(_ line: String) -> [(text: String, bold: Bool)] {
        segments(Array(line.utf8), protected: ChineseScriptConverter.RenderText.protectedMasks(line).all)
    }

    static func segments(_ bytes: [UInt8], protected: [Bool]) -> [(text: String, bold: Bool)] {
        var result: [(text: String, bold: Bool)] = []
        var start = 0, depth = 0
        for delimiter in delimiters(bytes, protected: protected) {
            if delimiter.offset > start {
                result.append((String(decoding: bytes[start..<delimiter.offset], as: UTF8.self), depth > 0))
            }
            depth += delimiter.opens ? 1 : -1
            start = delimiter.offset + 2
        }
        if start < bytes.count { result.append((String(decoding: bytes[start...], as: UTF8.self), false)) }
        return result
    }

    /// Offsets of the `**` runs that pair up, in order, each marked as opener
    /// or closer. A closer takes the nearest open opener, as in CommonMark.
    static func delimiters(_ bytes: [UInt8], protected: [Bool]) -> [(offset: Int, opens: Bool)] {
        var openers: [Int] = [], pairs: [(offset: Int, opens: Bool)] = []
        var index = 0
        while index < bytes.count {
            // The LaTeX scan reads `\Omega**` as the starred command `\Omega*`;
            // a protected `*` that ends such a command and is followed by a
            // free `*` is really the start of a closing `**`.
            let starredSuffix = index > 0 && protected[index - 1] && index + 1 < bytes.count
                && bytes[index + 1] == 42 && !protected[index + 1]
            guard bytes[index] == 42, !protected[index] || starredSuffix else { index += 1; continue }
            var end = index + 1
            while end < bytes.count, bytes[end] == 42, !protected[end] { end += 1 }
            var backslashes = 0
            while index - backslashes > 0, bytes[index - backslashes - 1] == 92 { backslashes += 1 }
            let operand = index > 0 && end < bytes.count && alphanumeric(bytes[index - 1]) && alphanumeric(bytes[end])
            if (2...3).contains(end - index), backslashes % 2 == 0, !operand {
                let closes = index > 0 && !whitespace(bytes, endingAt: index)
                let opens = end < bytes.count && !whitespace(bytes, startingAt: end)
                if closes, let opener = openers.popLast() {
                    pairs += [(opener, true), (index, false)]
                } else if opens {
                    openers.append(end - 2)
                }
            }
            index = end
        }
        return pairs.sorted { $0.offset < $1.offset }
    }

    private static func alphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func whitespace(_ bytes: [UInt8], startingAt index: Int) -> Bool {
        let scalar = String(decoding: bytes[index..<min(index + 4, bytes.count)], as: UTF8.self).unicodeScalars.first
        return scalar?.properties.isWhitespace ?? true
    }

    private static func whitespace(_ bytes: [UInt8], endingAt index: Int) -> Bool {
        var start = index - 1
        while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
        return whitespace(bytes, startingAt: start)
    }
}
