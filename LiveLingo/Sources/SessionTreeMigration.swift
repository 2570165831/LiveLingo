import Foundation
import CryptoKit
import Darwin

struct SessionTreeEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case directory, file }
    let relativePath: String
    let kind: Kind
    let byteCount: UInt64
    let sha256: String?
}

struct SessionMigrationReceipt: Sendable {
    let sourceDirectory: URL
    let destinationDirectory: URL
    /// Promotion retires the source by rename, leaving an exact recoverable copy.
    let preservedSourceDirectory: URL?
    let entries: [SessionTreeEntry]
    var fileCount: Int { entries.filter { $0.kind == .file }.count }
}

enum SessionMigrationError: LocalizedError {
    case invalidDirectory(URL)
    case destinationExists(URL)
    case overlappingDirectories
    case unsupportedEntry(URL)
    case sourceChanged(URL)
    case verificationFailed(URL)
    case failed(source: URL, destination: URL, preservedSource: URL?, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidDirectory(let url): return "课程目录无效：\(url.path)。"
        case .destinationExists(let url): return "迁移目标已存在：\(url.path)，没有覆盖。"
        case .overlappingDirectories: return "迁移源目录与目标目录重叠，已停止操作。"
        case .unsupportedEntry(let url): return "课程目录含软链接或特殊文件，需先确认其归属：\(url.path)。"
        case .sourceChanged(let url): return "迁移期间课程文件发生变化：\(url.path)，已保留原件。"
        case .verificationFailed(let url): return "课程副本完整性核对失败：\(url.path)，已保留现场。"
        case let .failed(source, destination, preserved, reason):
            return "课程迁移失败。源路径：\(source.path)；目标路径：\(destination.path)。"
                + (preserved.map { "原件保留于：\($0.path)。" } ?? "") + reason
        }
    }
}

/// Call only after capture and ALL session writers have stopped. File hashes
/// and source metadata detect changes during copying; they do not lock writers
/// belonging to other subsystems. Nothing is permanently removed by this API.
enum SessionTreeMigration {
    struct Operations {
        var copyTree: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
        var beforeVerification: () throws -> Void = {}
        var beforeRetirement: () throws -> Void = {}
    }

    static func copyVerified(
        from source: URL, to destination: URL, operations: Operations = .init()
    ) throws -> SessionMigrationReceipt {
        let pair = try validate(source: source, destination: destination)
        let baseline = try scan(pair.source)
        do {
            try operations.copyTree(pair.source, pair.destination)
            try operations.beforeVerification()
            let copied = try scan(pair.destination, synchronizeFiles: true)
            guard copied.entries == baseline.entries else {
                throw SessionMigrationError.verificationFailed(pair.destination)
            }
            try syncDirectory(pair.destination.deletingLastPathComponent())
            let finalSource = try scan(pair.source)
            guard finalSource == baseline else { throw SessionMigrationError.sourceChanged(pair.source) }
            return .init(sourceDirectory: pair.source, destinationDirectory: pair.destination,
                         preservedSourceDirectory: nil, entries: baseline.entries)
        } catch {
            throw SessionMigrationError.failed(source: pair.source, destination: pair.destination,
                                               preservedSource: nil, reason: error.localizedDescription)
        }
    }

    /// Same contract as copyVerified, then atomically removes the old *location*
    /// by renaming it to a unique sibling on its original volume. The receipt
    /// exposes that copy for the caller's explicit, recoverable cleanup policy.
    static func promote(
        from source: URL, to destination: URL, operations: Operations = .init()
    ) throws -> SessionMigrationReceipt {
        let pair = try validate(source: source, destination: destination)
        let baseline = try scan(pair.source)
        var retired: URL?
        do {
            try operations.copyTree(pair.source, pair.destination)
            try operations.beforeVerification()
            guard try scan(pair.destination, synchronizeFiles: true).entries == baseline.entries else {
                throw SessionMigrationError.verificationFailed(pair.destination)
            }
            guard try scan(pair.source) == baseline else { throw SessionMigrationError.sourceChanged(pair.source) }
            try operations.beforeRetirement()
            guard try scan(pair.source) == baseline else { throw SessionMigrationError.sourceChanged(pair.source) }
            let preservation = pair.source.deletingLastPathComponent()
                .appendingPathComponent(".\(pair.source.lastPathComponent).migrated-\(UUID().uuidString)", isDirectory: true)
            // RENAME_EXCL refuses a collision rather than replacing a sibling.
            guard renamex_np(pair.source.path, preservation.path, UInt32(RENAME_EXCL)) == 0 else {
                throw SessionStoreError.io(operation: "retire migrated source", code: errno)
            }
            retired = preservation
            // Rename changes the root's ctime. Every child must remain stable.
            let preserved = try scan(preservation)
            guard preserved.entries == baseline.entries,
                  preserved.stamps.filter({ $0.key != "" }) == baseline.stamps.filter({ $0.key != "" }) else {
                throw SessionMigrationError.sourceChanged(preservation)
            }
            guard try scan(pair.destination).entries == baseline.entries else {
                throw SessionMigrationError.verificationFailed(pair.destination)
            }
            try syncDirectory(pair.source.deletingLastPathComponent())
            try syncDirectory(pair.destination.deletingLastPathComponent())
            return .init(sourceDirectory: pair.source, destinationDirectory: pair.destination,
                         preservedSourceDirectory: preservation, entries: baseline.entries)
        } catch {
            // A failed retirement check restores the original name when free.
            // Never overwrite a new source created by another caller.
            if let preservation = retired,
               renamex_np(preservation.path, pair.source.path, UInt32(RENAME_EXCL)) == 0 {
                retired = nil
            }
            throw SessionMigrationError.failed(source: pair.source, destination: pair.destination,
                                               preservedSource: retired, reason: error.localizedDescription)
        }
    }

    /// Read-only inventory suitable for receipts and synthetic test assertions.
    static func manifest(of directory: URL) throws -> [SessionTreeEntry] { try scan(directory).entries }

    /// Retire only after dependent journals have committed their new locator.
    /// Both trees must still equal the verified copy. Failure restores the old
    /// source name where possible and leaves both copies recoverable.
    static func retireVerifiedCopy(_ receipt: SessionMigrationReceipt) throws -> SessionMigrationReceipt {
        guard receipt.preservedSourceDirectory == nil else {
            throw SessionMigrationError.invalidDirectory(receipt.sourceDirectory)
        }
        let source = receipt.sourceDirectory, destination = receipt.destinationDirectory
        guard try scan(source).entries == receipt.entries,
              try scan(destination).entries == receipt.entries else {
            throw SessionMigrationError.sourceChanged(source)
        }
        let preserved = source.deletingLastPathComponent()
            .appendingPathComponent(".\(source.lastPathComponent).migrated-\(UUID().uuidString)", isDirectory: true)
        guard renamex_np(source.path, preserved.path, UInt32(RENAME_EXCL)) == 0 else {
            throw SessionStoreError.io(operation: "retire verified source", code: errno)
        }
        do {
            guard try scan(preserved).entries == receipt.entries else {
                throw SessionMigrationError.sourceChanged(preserved)
            }
            try syncDirectory(source.deletingLastPathComponent())
            return .init(sourceDirectory: source, destinationDirectory: destination,
                         preservedSourceDirectory: preserved, entries: receipt.entries)
        } catch {
            let restored = renamex_np(preserved.path, source.path, UInt32(RENAME_EXCL)) == 0
            throw SessionMigrationError.failed(source: source, destination: destination,
                preservedSource: restored ? nil : preserved, reason: error.localizedDescription)
        }
    }

    private struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let mode: UInt16
        let bytes: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; mode = info.st_mode; bytes = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    private struct Inventory: Equatable {
        let entries: [SessionTreeEntry]
        let stamps: [String: Stamp]
    }

    private static func scan(_ requestedRoot: URL, synchronizeFiles: Bool = false) throws -> Inventory {
        let rootInfo = try information(requestedRoot)
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw SessionMigrationError.invalidDirectory(requestedRoot) }
        let root = try canonicalDirectory(requestedRoot)
        var entries: [SessionTreeEntry] = []
        var stamps: [String: Stamp] = ["": Stamp(rootInfo)]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw SessionMigrationError.invalidDirectory(root) }
        for case let url as URL in enumerator {
            let before = try information(url)
            let rootComponents = root.pathComponents
            let itemComponents = url.pathComponents
            guard itemComponents.starts(with: rootComponents), itemComponents.count > rootComponents.count else {
                throw SessionMigrationError.unsupportedEntry(url)
            }
            let relativePath = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
            try SessionArchiveCoding.validateRelativePath(relativePath)
            let type = before.st_mode & S_IFMT
            if type == S_IFDIR {
                entries.append(.init(relativePath: relativePath, kind: .directory, byteCount: 0, sha256: nil))
            } else if type == S_IFREG {
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw SessionStoreError.io(operation: "read migrated file", code: errno) }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var opened = stat()
                guard fstat(fd, &opened) == 0, Stamp(opened) == Stamp(before) else {
                    throw SessionMigrationError.sourceChanged(url)
                }
                var hash = SHA256()
                var count: UInt64 = 0
                while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
                    hash.update(data: bytes)
                    count += UInt64(bytes.count)
                }
                if synchronizeFiles { try file.synchronize() }
                try file.close()
                guard Stamp(try information(url)) == Stamp(before), before.st_size >= 0,
                      count == UInt64(before.st_size) else { throw SessionMigrationError.sourceChanged(url) }
                entries.append(.init(relativePath: relativePath, kind: .file, byteCount: count,
                                     sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
            } else { throw SessionMigrationError.unsupportedEntry(url) }
            stamps[relativePath] = Stamp(before)
        }
        if let enumerationError { throw enumerationError }
        // Directory stamps catch entries created/removed during enumeration.
        for (path, before) in stamps where before.mode & S_IFMT == S_IFDIR {
            let directory = path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
            guard Stamp(try information(directory)) == before else { throw SessionMigrationError.sourceChanged(directory) }
        }
        if synchronizeFiles {
            let directories = stamps.filter { $0.value.mode & S_IFMT == S_IFDIR }.keys
                .sorted { $0.count > $1.count }
            for path in directories {
                try syncDirectory(path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true))
            }
        }
        return .init(entries: entries.sorted { $0.relativePath < $1.relativePath }, stamps: stamps)
    }

    private static func validate(source: URL, destination: URL) throws -> (source: URL, destination: URL) {
        // Ancestor aliases (including macOS /var) are ordinary locators. Reject
        // the session root itself when it is a symlink; do not follow leaf links.
        guard source.isFileURL, destination.isFileURL else {
            throw SessionMigrationError.invalidDirectory(source)
        }
        let requestedSource = URL(fileURLWithPath: source.path).standardizedFileURL
        let requestedDestination = URL(fileURLWithPath: destination.path).standardizedFileURL
        guard try information(requestedSource).st_mode & S_IFMT == S_IFDIR else {
            throw SessionMigrationError.invalidDirectory(source)
        }
        let from = try canonicalDirectory(requestedSource)
        let parent = try canonicalDirectory(requestedDestination.deletingLastPathComponent())
        let to = parent.appendingPathComponent(requestedDestination.lastPathComponent, isDirectory: true)
        guard from.path != "/", to.path != "/", from.deletingLastPathComponent().path != "/" else {
            throw SessionMigrationError.invalidDirectory(source)
        }
        guard from != to, !to.path.hasPrefix(from.path + "/"), !from.path.hasPrefix(to.path + "/") else {
            throw SessionMigrationError.overlappingDirectories
        }
        var existing = stat()
        if lstat(to.path, &existing) == 0 { throw SessionMigrationError.destinationExists(to) }
        guard errno == ENOENT else { throw SessionStoreError.io(operation: "check migration target", code: errno) }
        return (from, to)
    }

    /// Foundation intentionally abbreviates /private/var on some systems;
    /// POSIX realpath keeps enumeration and containment comparisons consistent.
    private static func canonicalDirectory(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw SessionStoreError.io(operation: "resolve session directory", code: errno)
        }
        defer { free(resolved) }
        let result = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        guard try information(result).st_mode & S_IFMT == S_IFDIR else {
            throw SessionMigrationError.invalidDirectory(url)
        }
        return result
    }

    private static func information(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw SessionStoreError.io(operation: "inspect migration entry", code: errno)
        }
        return info
    }

    private static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard fd >= 0 else { throw SessionStoreError.io(operation: "open migration directory", code: errno) }
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw SessionStoreError.io(operation: "sync migration directory", code: errno) }
    }
}
