import Foundation
import Darwin
import XCTest
@testable import LiveLingo

enum DataSafetyFixtures {
    static func make(_ label: String) throws -> URL {
        let designated = TestFixtureDirectory.root
        let url = designated.appendingPathComponent("Safety-\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func preserve(_ root: URL) {
        let destination = TestFixtureDirectory.root
            .appendingPathComponent("fixtures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: destination.appendingPathComponent(root.lastPathComponent))
        } catch { XCTFail("Could not preserve synthetic fixture: \(error)") }
    }
}

final class DataSafetyStorageTests: XCTestCase {
    private func interruptedWrite(_ bytes: Data, to destination: URL, orphan: URL) throws {
        XCTAssertThrowsError(try SensitiveFileIO.$beforeTemporaryCommit.withValue({ pending in
            guard Darwin.rename(pending.path, orphan.path) == 0 else {
                throw SessionStoreError.io(operation: "stage synthetic interruption", code: errno)
            }
            throw SessionStoreError.io(operation: "synthetic process interruption", code: EIO)
        }) { try SessionArchiveCoding.atomicWrite(bytes, destination) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDU05ReopenRetiresOwnedDuplicateAndKeepsUnknownTemporary() throws {
        let root = try DataSafetyFixtures.make("DU05-duplicate")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: destination)
        let orphan = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let unknown = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try bytes.write(to: unknown)
        try interruptedWrite(bytes, to: destination, orphan: orphan)
        XCTAssertEqual(try SessionStore(directory: root).load(), stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "A registered, unused duplicate is safe to retire on reopen")
        XCTAssertEqual(try Data(contentsOf: unknown), bytes, "A familiar name alone proves no ownership")
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testDU05ReopenRetiresOwnedEmptyWriteAndPreservesUniqueCandidate() throws {
        let root = try DataSafetyFixtures.make("DU05-empty")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let original = try Data(contentsOf: destination)
        let empty = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let unique = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let uniqueBytes = Data("synthetic unique uncommitted recovery evidence".utf8)
        try interruptedWrite(Data(), to: destination, orphan: empty)
        try interruptedWrite(uniqueBytes, to: destination, orphan: unique)
        XCTAssertEqual(try SessionStore(directory: root).load(), stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(try Data(contentsOf: unique), uniqueBytes)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testDU05ReopenRetiresOnlyRegisteredEmptyInitialExportSibling() throws {
        let parent = try DataSafetyFixtures.make("DU05-initial")
        defer { DataSafetyFixtures.preserve(parent) }
        let course = parent.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: false)
        let unknown = parent.appendingPathComponent(".course.initial-export-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        var operations = SessionExporter.PublicationOperations()
        operations.exchangeDirectories = { staged, destination in
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw SessionStoreError.io(operation: "synthetic export exchange", code: errno)
            }
            throw SessionStoreError.io(operation: "synthetic interruption after exchange", code: EIO)
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [], sessionDirectory: course, operations: operations))
        let abandoned = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".course.initial-export-") && $0 != unknown }
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertNoThrow(try SessionStore(directory: course).load())
        for item in abandoned { XCTAssertFalse(FileManager.default.fileExists(atPath: item.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.appendingPathComponent("manifest.json").path))
    }

    func testDU05RecoveryKeepsActiveWriterAndRecordsUnknownIdentity() throws {
        let root = try DataSafetyFixtures.make("DU05-active")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let unknown = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try Data().write(to: unknown)
        try SensitiveFileIO.$beforeTemporaryCommit.withValue({ pending in
            let directory = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
            let results = try directory.recoverTemporaryItems()
            XCTAssertEqual(results.first(where: { $0.name == pending.lastPathComponent })?.reason, "active_or_unavailable")
            XCTAssertEqual(results.first(where: { $0.name == unknown.lastPathComponent })?.reason, "unregistered")
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        }) { try SessionArchiveCoding.atomicWrite(Data("synthetic committed body".utf8), destination) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("synthetic committed body".utf8))
    }

    func testDU05WriterWaitsForRecoveryScanHoldingItsNewTemporary() throws {
        let root = try DataSafetyFixtures.make("DU05-lease")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let bytes = Data("synthetic committed body".utf8)
        try SensitiveFileIO.$beforeTemporaryLease.withValue({ pending in
            // A recovery scan that reached the brand-new file first sees no
            // receipt, keeps it, and still holds its lock when the writer asks.
            let directory = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
            XCTAssertEqual(try directory.recoverTemporaryItems().first(where: { $0.name == pending.lastPathComponent })?.reason,
                           "unregistered")
            let scanner = Darwin.open(pending.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard scanner >= 0 else { throw SessionStoreError.io(operation: "open synthetic scanner", code: errno) }
            guard flock(scanner, LOCK_EX | LOCK_NB) == 0 else {
                _ = Darwin.close(scanner)
                throw SessionStoreError.io(operation: "lock synthetic scanner", code: errno)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                _ = flock(scanner, LOCK_UN)
                _ = Darwin.close(scanner)
            }
        }) { try SessionArchiveCoding.atomicWrite(bytes, destination) }
        XCTAssertEqual(try Data(contentsOf: destination), bytes, "A brief scan lock must not fail an ordinary save")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testDU05KillBetweenLinkAndUnlinkLeavesAnOpenableCourse() throws {
        let root = try DataSafetyFixtures.make("DU05-alias")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: destination)
        // Re-create the first-write state: no destination yet, then the new
        // name is linked and the process dies before the temporary is unlinked.
        try FileManager.default.removeItem(at: destination)
        let orphan = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try interruptedWrite(bytes, to: destination, orphan: orphan)
        XCTAssertEqual(link(orphan.path, destination.path), 0)
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_nlink, 2, "Precondition: the committed file still has its temporary name")

        XCTAssertEqual(try SessionStore(directory: root).load(), stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "The receipt-proven second name is retired")
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_nlink, 1)
        XCTAssertEqual(getxattr(destination.path, "com.jianhongli.LiveLingo.temporary-v1", nil, 0, 0, XATTR_NOFOLLOW), -1,
                       "The committed file no longer carries the writer's receipt")
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertNoThrow(try SessionStore(directory: root).save(stored))
    }

    func testDU05UnprovenSecondNameOfCommittedFileStaysRejected() throws {
        let root = try DataSafetyFixtures.make("DU05-unproven-alias")
        defer { DataSafetyFixtures.preserve(root) }
        _ = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        // A familiar temporary name without this inode's receipt proves nothing.
        let alias = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        XCTAssertEqual(link(destination.path, alias.path), 0)
        XCTAssertThrowsError(try SessionStore(directory: root).load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_nlink, 2)
    }

    func testDU05RecoveryPreservesReferencesAndReplacedInodes() throws {
        let root = try DataSafetyFixtures.make("DU05-references")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let bytes = Data("synthetic committed body".utf8)
        try SessionArchiveCoding.atomicWrite(bytes, destination)
        let linked = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let aliased = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let replaced = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        for orphan in [linked, aliased, replaced] { try interruptedWrite(bytes, to: destination, orphan: orphan) }
        XCTAssertEqual(link(linked.path, root.appendingPathComponent("retained-hardlink").path), 0)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("retained-alias").path,
            withDestinationPath: "./" + aliased.lastPathComponent)
        let retained = root.appendingPathComponent("retained-original")
        try FileManager.default.moveItem(at: replaced, to: retained)
        try FileManager.default.copyItem(at: retained, to: replaced)
        let directory = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
        let results = try directory.recoverTemporaryItems()
        XCTAssertEqual(results.first(where: { $0.name == linked.lastPathComponent })?.reason, "unknown_identity")
        XCTAssertEqual(results.first(where: { $0.name == aliased.lastPathComponent })?.reason, "referenced")
        XCTAssertEqual(results.first(where: { $0.name == replaced.lastPathComponent })?.reason, "unknown_receipt")
        for item in [linked, aliased, replaced, retained, destination] { XCTAssertEqual(try Data(contentsOf: item), bytes) }
    }

    func testDU05RecoveryNeverFollowsTemporarySymlinksOrCorruptReceipts() throws {
        let root = try DataSafetyFixtures.make("DU05-unsafe")
        defer { DataSafetyFixtures.preserve(root) }
        let protected = root.appendingPathComponent("protected.json")
        let bytes = Data("synthetic protected body".utf8)
        try SessionArchiveCoding.atomicWrite(bytes, protected)
        let symlink = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let corrupt = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: protected)
        try interruptedWrite(bytes, to: protected, orphan: corrupt)
        let fd = Darwin.open(corrupt.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = Darwin.close(fd) }
        let bad = Data("not a creation receipt".utf8)
        XCTAssertEqual(bad.withUnsafeBytes { fsetxattr(fd, "com.jianhongli.LiveLingo.temporary-v1", $0.baseAddress, $0.count, 0, 0) }, 0)
        let results = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false).recoverTemporaryItems()
        XCTAssertEqual(results.first(where: { $0.name == symlink.lastPathComponent })?.reason, "unknown_identity")
        XCTAssertEqual(results.first(where: { $0.name == corrupt.lastPathComponent })?.reason, "inspection_failed")
        XCTAssertEqual(try Data(contentsOf: corrupt), bytes)
        XCTAssertEqual(try Data(contentsOf: protected), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), protected.path)
    }

    func testDU05RecoveryKeepsIndirectSiblingReferences() throws {
        let root = try DataSafetyFixtures.make("DU05-indirect-reference")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let bytes = Data("synthetic committed body".utf8)
        try SessionArchiveCoding.atomicWrite(bytes, destination)
        let orphan = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try interruptedWrite(bytes, to: destination, orphan: orphan)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("directory-alias").path,
            withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("indirect-reference").path,
            withDestinationPath: "directory-alias/" + orphan.lastPathComponent)
        let results = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false).recoverTemporaryItems()
        XCTAssertEqual(results.first(where: { $0.name == orphan.lastPathComponent })?.reason, "referenced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDU05StartupInventoryPreservesUncommittedInitialExport() throws {
        let parent = try DataSafetyFixtures.make("DU05-uncommitted-export")
        defer { DataSafetyFixtures.preserve(parent) }
        let course = parent.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: false)
        var operations = SessionExporter.PublicationOperations()
        operations.exchangeDirectories = { _, _ in throw SessionStoreError.io(operation: "synthetic interruption before exchange", code: EIO) }
        XCTAssertThrowsError(try SessionExporter.export(segments: [], sessionDirectory: course, operations: operations))
        let staged = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".course.initial-export-") })
        let manifest = try Data(contentsOf: staged.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try SessionWorkspace.recordingRecoveries(in: parent), [])
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("manifest.json")), manifest)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: course.path).isEmpty)
    }

    func testDU05UnavailableTrackingParentDoesNotBlockInitialExport() throws {
        let parent = try DataSafetyFixtures.make("DU05-unavailable-parent")
        defer { DataSafetyFixtures.preserve(parent) }
        let course = parent.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: false)
        try SensitiveFileIO.$temporaryTrackingParentUnavailable.withValue(true) {
            try SessionExporter.export(segments: [], sessionDirectory: course)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.appendingPathComponent("manifest.json").path))
        let siblings = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".course.initial-export-") }
        XCTAssertEqual(siblings.count, 1, "An unavailable trusted parent permits publication but preserves its residual")
        for sibling in siblings { XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sibling.path).isEmpty) }
    }

    func testN02StaleRecoveryIndexSaveMergesAnotherRecording() throws {
        let root = try DataSafetyFixtures.make("N02")
        defer { DataSafetyFixtures.preserve(root) }
        let a = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("a"), outputRoot: root)
        let b = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("b"), outputRoot: root)
        let emptyA = try SessionWorkspace.recordingRecoveries(in: root)
        let emptyB = try SessionWorkspace.recordingRecoveries(in: root)
        try SessionWorkspace.saveRecordingRecoveries(emptyA + [a], in: root)
        try SessionWorkspace.saveRecordingRecoveries(emptyB + [b], in: root)
        XCTAssertEqual(Set(try SessionWorkspace.recordingRecoveries(in: root).map(\.id)), Set([a.id, b.id]))
    }

    func testN03InvalidRecoveryIndexCannotBeOverwrittenAfterReadFailure() throws {
        for raw in [#"{"version":99,"recordings":[],"futureState":"SYNTHETIC_RETAIN"}"#,
                    #"{"version":1,"recordings":[],"futureState":"SYNTHETIC_RETAIN"}"#,
                    "{synthetic truncated index"] {
            let root = try DataSafetyFixtures.make("N03")
            defer { DataSafetyFixtures.preserve(root) }
            let index = root.appendingPathComponent("pending-recordings.json"), bytes = Data(raw.utf8)
            try bytes.write(to: index)
            XCTAssertThrowsError(try SessionWorkspace.recordingRecoveries(in: root))
            let next = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("new"), outputRoot: root)
            XCTAssertThrowsError(try SessionWorkspace.saveRecordingRecoveries([next], in: root))
            XCTAssertEqual(try Data(contentsOf: index), bytes)
        }
    }

    func testN06LegacyRegularExportsArePreservedAndReconciled() throws {
        let root = try DataSafetyFixtures.make("N06")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic v1.", chinese: "合成课程。")
        _ = try SessionStore(directory: root).save(SessionSnapshot(segments: [segment]))
        try SessionExporter.export(segments: [segment], sessionDirectory: root, summary: "Original synthetic note", createdAt: Date(timeIntervalSince1970: 0))
        let selectedBefore = try SessionExporter.currentExportDirectory(in: root)
        let original = try Data(contentsOf: selectedBefore.appendingPathComponent("summary-zh-Hans.md"))
        let legacy = Data("Synthetic old-writer updated note\n".utf8)
        // v0.2.0's atomic writes replace root symlinks with regular files.
        let summary = root.appendingPathComponent("summary-zh-Hans.md")
        try legacy.write(to: summary, options: .atomic)
        let oldManifest = Data(#"{"createdAt":"2026-10-08T00:00:00Z","sourceLocale":"en-US","targetLocale":"zh-Hans","recordingFile":"recording.wav","segmentCount":1}"#.utf8)
        try oldManifest.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        try SessionExporter.export(segments: [segment], sessionDirectory: root, summary: "New synthetic note", createdAt: Date(timeIntervalSince1970: 0))
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in ["summary-zh-Hans.md", "manifest.json", "bilingual.srt", "bilingual.jsonl", "transcript-en.txt", "transcript-zh-Hans.txt"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)))
        }
        XCTAssertEqual(try Data(contentsOf: selectedBefore.appendingPathComponent("summary-zh-Hans.md")), original)
        let preserved = root.appendingPathComponent(".exports/recovered")
        let recoveries = try FileManager.default.contentsOfDirectory(at: preserved, includingPropertiesForKeys: nil)
        XCTAssertTrue(try recoveries.contains { try Data(contentsOf: $0.appendingPathComponent("summary-zh-Hans.md")) == legacy })
    }

    func testN10UnsupportedSymlinkPublishesCompletePortableGeneration() throws {
        for code in [ENOTSUP, EXDEV] {
            let root = try DataSafetyFixtures.make("N10-link")
            defer { DataSafetyFixtures.preserve(root) }
            try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
            var operations = SessionExporter.PublicationOperations()
            operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: code) }
            let caption = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic fallback.", chinese: "合成回退。")
            try SessionExporter.export(segments: [caption], sessionDirectory: root, summary: "合成笔记", operations: operations)
            try SessionExporter.export(segments: [caption], sessionDirectory: root, summary: "合成新笔记", operations: operations)
            let selected = try SessionExporter.currentExportDirectory(in: root)
            XCTAssertNotEqual(selected, root)
            for name in ["summary-zh-Hans.md", "manifest.json", "bilingual.srt", "bilingual.jsonl", "transcript-en.txt", "transcript-zh-Hans.txt"] {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)))
            }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), Data("synthetic recording".utf8))
        }
    }

    func testN10UnsupportedDirectorySwapHasPortableFallback() throws {
        for code in [ENOTSUP, EXDEV] {
            let root = try DataSafetyFixtures.make("N10-swap")
            defer { DataSafetyFixtures.preserve(root) }
            var operations = SessionExporter.PublicationOperations()
            operations.exchangeDirectories = { _, _ in throw SessionStoreError.io(operation: "injected swap", code: code) }
            try SessionExporter.export(segments: [], sessionDirectory: root, summary: "合成空课程", operations: operations)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("summary-zh-Hans.md"), encoding: .utf8), "合成空课程\n")
            let selected = try SessionExporter.currentExportDirectory(in: root)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), try Data(contentsOf: selected.appendingPathComponent("manifest.json")))
        }
    }

    func testN02ConditionalRetirementKeepsAnotherWritersNewLocation() throws {
        let root = try DataSafetyFixtures.make("N02-retirement")
        defer { DataSafetyFixtures.preserve(root) }
        let a = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("a"), outputRoot: root)
        let saved = try SessionWorkspace.saveRecordingRecoveries([a], in: root)
        var moved = try XCTUnwrap(saved.first)
        moved.directory = root.appendingPathComponent("new-a")
        let b = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("b"), outputRoot: root)
        try SessionWorkspace.saveRecordingRecoveries([moved, b], in: root, expected: saved)
        let bytes = try Data(contentsOf: root.appendingPathComponent("pending-recordings.json"))
        XCTAssertThrowsError(try SessionWorkspace.saveRecordingRecoveries([], in: root, retiring: saved))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pending-recordings.json")), bytes)
        let latest = try SessionWorkspace.recordingRecoveries(in: root)
        let result = try SessionWorkspace.saveRecordingRecoveries([], in: root, retiring: latest.filter { $0.id == a.id })
        XCTAssertEqual(result.map(\.id), [b.id])
    }

    func testN10PortableMidPublicationFailureRestoresEveryPriorRootMember() throws {
        let root = try DataSafetyFixtures.make("N10-rollback")
        defer { DataSafetyFixtures.preserve(root) }
        try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: ENOTSUP) }
        let first = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic original.", chinese: "合成原文。")
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "原合成笔记", operations: operations)
        let names = ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"]
        let before = try names.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        operations.beforeMemberPublication = { name in
            if name == "bilingual.srt" { throw SessionStoreError.io(operation: "injected member publication", code: EIO) }
        }
        let next = TranscriptSegment(startTime: 1, endTime: 2, english: "Synthetic newer.", chinese: "合成新文。")
        XCTAssertThrowsError(try SessionExporter.export(segments: [first, next], sessionDirectory: root, summary: "新合成笔记", operations: operations))
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for (index, name) in names.enumerated() {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), before[index])
            XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(name)), before[index])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".exports/publishing.json").path))
    }

    func testN10InterruptedPortablePublicationRecoversBeforeNextExport() throws {
        let root = try DataSafetyFixtures.make("N10-interrupted")
        defer { DataSafetyFixtures.preserve(root) }
        try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: EXDEV) }
        let first = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic original.", chinese: "合成原文。")
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "原合成笔记", operations: operations)
        let previous = try SessionExporter.currentExportDirectory(in: root)
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "新合成笔记", operations: operations)
        let next = try SessionExporter.currentExportDirectory(in: root)
        let names = ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"]
        let store = root.appendingPathComponent(".exports")
        let transaction: [String: Any] = ["version": 1, "rollback": previous.lastPathComponent,
            "next": next.lastPathComponent, "names": names, "originallyPresent": names]
        try JSONSerialization.data(withJSONObject: transaction).write(to: store.appendingPathComponent("publishing.json"))
        try JSONSerialization.data(withJSONObject: ["version": 1, "generation": previous.lastPathComponent])
            .write(to: store.appendingPathComponent("current.json"), options: .atomic)
        try Data(contentsOf: previous.appendingPathComponent("manifest.json"))
            .write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        // The marker and mixed root files represent an interrupted publication;
        // the immutable reader remains on the whole previous generation.
        XCTAssertEqual(try SessionExporter.currentExportDirectory(in: root), previous)
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "重试合成笔记", operations: operations)
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in names {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("publishing.json").path))
    }

    func testN10PortableTransitionRetiresLegacyPointerAndCanBeMigrated() throws {
        let outer = try DataSafetyFixtures.make("N10-pointer-transition")
        defer { DataSafetyFixtures.preserve(outer) }
        let root = outer.appendingPathComponent("course"), target = outer.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic transition.", chinese: "合成切换。")
        try SessionExporter.export(segments: [segment], sessionDirectory: root, summary: "旧合成笔记")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".exports/current").path))
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: ENOTSUP) }
        try SessionExporter.export(segments: [segment], sessionDirectory: root, summary: "新合成笔记", operations: operations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".exports/current").path))
        let receipt = try SessionTreeMigration.copyVerified(from: root, to: target)
        XCTAssertEqual(try SessionTreeMigration.manifest(of: target), receipt.entries)
        let selected = try SessionExporter.currentExportDirectory(in: target)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("summary-zh-Hans.md")), try Data(contentsOf: selected.appendingPathComponent("summary-zh-Hans.md")))
    }

    func testN06ConcurrentForeignRootBytesArePreservedBeforeRollback() throws {
        let root = try DataSafetyFixtures.make("N06-concurrent-root")
        defer { DataSafetyFixtures.preserve(root) }
        try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
        let first = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic original.", chinese: "合成原文。")
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: ENOTSUP) }
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "旧合成笔记", operations: operations)
        let foreign = Data("SYNTHETIC_EXTERNAL_WRITER\n".utf8)
        operations.beforeMemberPublication = { name in
            if name == "manifest.json" {
                try foreign.write(to: root.appendingPathComponent(name), options: .atomic)
            }
        }
        let second = TranscriptSegment(startTime: 1, endTime: 2, english: "Synthetic newer.", chinese: "合成新文。")
        XCTAssertThrowsError(try SessionExporter.export(segments: [first, second], sessionDirectory: root, summary: "新合成笔记", operations: operations))
        let recovered = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".exports/recovered"), includingPropertiesForKeys: nil)
        XCTAssertTrue(try recovered.contains { try Data(contentsOf: $0.appendingPathComponent("manifest.json")) == foreign })
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)))
        }
        operations.beforeMemberPublication = { _ in }
        try SessionExporter.export(segments: [first, second], sessionDirectory: root, summary: "重试合成笔记", operations: operations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".exports/publishing.json").path))
    }
    func testN14FirstExportEIOAllowsNormalRetryWithoutInjection() throws {
        let root = try DataSafetyFixtures.make("N14-first-export-retry")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic retry source.", chinese: "合成重试原文。")
        let store = SessionStore(directory: root)
        let snapshot = try store.save(SessionSnapshot(segments: [segment]))
        let snapshotBytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let recording = Data("SYNTHETIC_RECORDING_RETAINED".utf8)
        try recording.write(to: root.appendingPathComponent("recording.wav"))
        var operations = SessionExporter.PublicationOperations()
        operations.beforeMemberPublication = { name in
            if name == "bilingual.srt" {
                throw SessionStoreError.io(operation: "synthetic first export failure", code: EIO)
            }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成首次笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations)) { error in
            guard let failure = error as? SessionStoreError, case let .io(_, code) = failure else {
                return XCTFail("Expected the injected EIO, got \(error)")
            }
            XCTAssertEqual(code, EIO)
        }
        // Retry with the default operations: no failure/capability injection remains.
        XCTAssertNoThrow(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成重试笔记", createdAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), snapshotBytes)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), recording)
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)),
                           try Data(contentsOf: selected.appendingPathComponent(name)), name)
        }
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("summary-zh-Hans.md")), Data("合成重试笔记\n".utf8))
    }

    func testN15SymlinkLateForeignSummaryRejectsInconsistentSuccessAndPreservesVersions() throws {
        try assertN15LateForeignSummaryPreserved(portable: false)
    }

    func testN15PortableLateForeignSummaryRejectsInconsistentSuccessAndPreservesVersions() throws {
        try assertN15LateForeignSummaryPreserved(portable: true)
    }

    private func assertN15LateForeignSummaryPreserved(portable: Bool) throws {
        let root = try DataSafetyFixtures.make(portable ? "N15-late-foreign-portable" : "N15-late-foreign-symlink")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic late-writer source.", chinese: "合成并发原文。")
        let store = SessionStore(directory: root)
        let snapshot = try store.save(SessionSnapshot(segments: [segment]))
        let snapshotBytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let recording = Data("SYNTHETIC_RECORDING_RETAINED".utf8)
        try recording.write(to: root.appendingPathComponent("recording.wav"))
        var operations = SessionExporter.PublicationOperations()
        if portable {
            operations.createSymbolicLink = { _, _ in
                throw SessionStoreError.io(operation: "synthetic unavailable symlink", code: ENOTSUP)
            }
        }
        try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成旧笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations)
        let names = ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"]
        let previous = try SessionExporter.currentExportDirectory(in: root)
        let previousIndex = try Data(contentsOf: previous.appendingPathComponent("export-index.json"))
        var previousFiles: [String: Data] = [:]
        for name in names { previousFiles[name] = try Data(contentsOf: previous.appendingPathComponent(name)) }
        let foreign = Data("SYNTHETIC_FOREIGN_NOTE_AFTER_MEMBER_CHECK\n".utf8)
        operations.beforeMemberPublication = { name in
            if name == "transcript-zh-Hans.txt" {
                // Replace an already checked member just before the last member.
                try foreign.write(to: root.appendingPathComponent("summary-zh-Hans.md"), options: .atomic)
            }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成新笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations))
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in names {
            XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(name)), previousFiles[name], name)
            XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent(name)), previousFiles[name], name)
        }
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent("export-index.json")), previousIndex)
        let recoveredRoot = root.appendingPathComponent(".exports/recovered")
        let recoveries = FileManager.default.fileExists(atPath: recoveredRoot.path)
            ? try FileManager.default.contentsOfDirectory(at: recoveredRoot, includingPropertiesForKeys: nil) : []
        let recoveredForeign = recoveries.filter {
            (try? Data(contentsOf: $0.appendingPathComponent("summary-zh-Hans.md"))) == foreign
        }
        XCTAssertTrue((try? Data(contentsOf: root.appendingPathComponent("summary-zh-Hans.md"))) == foreign
            || !recoveredForeign.isEmpty, "The late foreign summary must remain readable at the root or in a verified recovery")
        let versions = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".exports/versions"), includingPropertiesForKeys: nil)
        let nextSummary = Data("合成新笔记\n".utf8)
        let next = try XCTUnwrap(versions.first {
            (try? Data(contentsOf: $0.appendingPathComponent("summary-zh-Hans.md"))) == nextSummary
        }, "The complete attempted generation must be retained")
        let nextIndexObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: next.appendingPathComponent("export-index.json"))) as? [String: Any])
        let nextIndex = try XCTUnwrap(nextIndexObject["members"] as? [String: String])
        XCTAssertEqual(Set(nextIndex.keys), Set(names))
        for name in names {
            let bytes = try Data(contentsOf: next.appendingPathComponent(name))
            XCTAssertEqual(bytes, name == "summary-zh-Hans.md" ? nextSummary : previousFiles[name], name)
            XCTAssertEqual(nextIndex[name], SessionArchiveCoding.digest(bytes), name)
        }
        for recovery in recoveredForeign {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recovery.appendingPathComponent("export-index.json"))) as? [String: Any])
            let index = try XCTUnwrap(object["members"] as? [String: String])
            XCTAssertEqual(index["summary-zh-Hans.md"], SessionArchiveCoding.digest(foreign))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), snapshotBytes)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), recording)
    }

    func testN17FailedExportRetainsUnfinishedAliasAndForeignWriterForRetry() throws {
        let root = try DataSafetyFixtures.make("N17-retained-alias")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic retained source.", chinese: "合成保留原文。")
        let store = SessionStore(directory: root)
        let snapshot = try store.save(SessionSnapshot(segments: [segment]))
        let snapshotBytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let recording = Data("SYNTHETIC_N17_RECORDING".utf8)
        try recording.write(to: root.appendingPathComponent("recording.wav"))
        let alias = root.appendingPathComponent("bilingual.jsonl")
        let originalIdentity = StorageTestIdentity()
        var operations = SessionExporter.PublicationOperations()
        operations.beforeMemberPublication = { name in
            if name == "bilingual.srt" {
                var info = stat()
                guard lstat(alias.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else {
                    throw SessionStoreError.invalidState("Synthetic alias was not published")
                }
                originalIdentity.value = info
                throw SessionStoreError.io(operation: "synthetic N17 failure", code: EIO)
            }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成未完成笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations)) { error in
            guard let failure = error as? SessionStoreError, case let .io(_, code) = failure else {
                return XCTFail("Expected the injected EIO, got \(error)")
            }
            XCTAssertEqual(code, EIO)
        }
        // A failure must not delete a public name. Retain the unfinished alias;
        // a retry can reuse it without a check-then-unlink ownership race.
        var retained = stat()
        XCTAssertEqual(lstat(alias.path, &retained), 0)
        XCTAssertEqual(retained.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(retained.st_dev, originalIdentity.value?.st_dev)
        XCTAssertEqual(retained.st_ino, originalIdentity.value?.st_ino)
        XCTAssertNoThrow(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成重试笔记", createdAt: Date(timeIntervalSince1970: 0)))
        let foreign = Data("SYNTHETIC_N17_FOREIGN_WRITER\n".utf8)
        try foreign.write(to: alias, options: .atomic)
        operations.beforeMemberPublication = { name in
            if name == "bilingual.srt" { throw SessionStoreError.io(operation: "synthetic next failure", code: EIO) }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成再次笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations))
        XCTAssertNoThrow(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成最终笔记", createdAt: Date(timeIntervalSince1970: 0)))
        let recovered = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".exports/recovered"), includingPropertiesForKeys: nil)
        XCTAssertTrue(recovered.contains { (try? Data(contentsOf: $0.appendingPathComponent("bilingual.jsonl"))) == foreign })
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)), name)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), snapshotBytes)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), recording)
    }

    func testN15PointerBoundaryConflictRequiresRetryAndPreservesBothVersions() throws {
        let root = try DataSafetyFixtures.make("N15-pointer-boundary")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic boundary source.", chinese: "合成边界原文。")
        let store = SessionStore(directory: root)
        let snapshot = try store.save(SessionSnapshot(segments: [segment]))
        let snapshotBytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let recording = Data("SYNTHETIC_N15_RECORDING".utf8)
        try recording.write(to: root.appendingPathComponent("recording.wav"))
        try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成边界旧笔记", createdAt: Date(timeIntervalSince1970: 0))
        let previous = try SessionExporter.currentExportDirectory(in: root)
        let foreign = Data("SYNTHETIC_N15_AFTER_FINAL_PRECHECK\n".utf8)
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { target, pending in
            guard symlink(target, pending.path) == 0 else {
                throw SessionStoreError.io(operation: "synthetic pointer link", code: errno)
            }
            if target.hasPrefix("versions/") {
                // The prepublication member check has finished. The next
                // operation commits current, so this is the reviewed late window.
                try foreign.write(to: root.appendingPathComponent("summary-zh-Hans.md"), options: .atomic)
            }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成边界新笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations)) { error in
            XCTAssertTrue(error.localizedDescription.contains("需重试"), "A published but inconsistent root view requires an explicit retry: \(error)")
        }
        let selected = try SessionExporter.currentExportDirectory(in: root)
        XCTAssertNotEqual(selected, previous)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("summary-zh-Hans.md")), Data("合成边界新笔记\n".utf8))
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent("summary-zh-Hans.md")), Data("合成边界旧笔记\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("summary-zh-Hans.md")), foreign)
        XCTAssertNoThrow(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成边界重试笔记", createdAt: Date(timeIntervalSince1970: 0)))
        let recovered = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".exports/recovered"), includingPropertiesForKeys: nil)
        XCTAssertTrue(recovered.contains { (try? Data(contentsOf: $0.appendingPathComponent("summary-zh-Hans.md"))) == foreign })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), snapshotBytes)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), recording)
    }

    private final class StorageTestIdentity: @unchecked Sendable {
        var value: stat?
    }

    private func checkpoint(_ value: SessionSnapshot) -> SessionGenerationCheckpoint {
        let input = "Synthetic frozen input"
        return SessionGenerationCheckpoint(sessionID: value.sessionID, inputRevision: value.inputRevision,
            modelName: "synthetic", protocolVersion: 2,
            inputDigest: SessionArchiveCoding.digest(Data(input.utf8)),
            promptDigest: SessionArchiveCoding.digest(Data("synthetic prompt".utf8)),
            input: input, prefix: "{\"topic\":\"retained", evidenceIDs: value.segments.map(\.id))
    }

    private func envelopeVersion(in root: URL) throws -> Int {
        let data = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["schemaVersion"] as? Int)
    }

    func testDU01ModernLanguagesRejectLegacyReaderBeforeResave() throws {
        let root = try DataSafetyFixtures.make("DU01"); defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "El curso es sintético.", chinese: "合成课程。", sourceLanguage: "es")
        let value = try SessionStore(directory: root).save(SessionSnapshot(segments: [segment], targetLocale: "en"))
        XCTAssertGreaterThan(try envelopeVersion(in: root), 1, "v0.2.0 accepts schema 1 and drops modern fields")
        XCTAssertEqual(try SessionStore(directory: root).load(), value)
    }

    func testDU02AnnotatedCourseRejectsLegacyWriterBeforeRevision() throws {
        let root = try DataSafetyFixtures.make("DU02"); defer { DataSafetyFixtures.preserve(root) }
        var segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic formula.", chinese: "合成公式。")
        segment.updateCaptionAnnotation(targetCode: "en", formulaUncertain: true)
        let value = try SessionStore(directory: root).save(SessionSnapshot(segments: [segment]))
        XCTAssertGreaterThan(try envelopeVersion(in: root), 1, "legacy revisions omit the annotation and cannot replay safely")
        XCTAssertEqual(try SessionStore(directory: root).load(), value)
    }

    func testDU03StaleWriterPreservesCheckpointWithoutJournal() async throws {
        let root = try DataSafetyFixtures.make("DU03-direct"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        let old = try store.save(SessionSnapshot())
        let writer = SessionArchiveWriter(directory: root, restored: old)
        var newer = old
        newer.generationCheckpoints = [checkpoint(old)]
        let durable = try store.save(newer)
        let saved = try await writer.commit(old)
        XCTAssertEqual(saved.generationCheckpoints, durable.generationCheckpoints)
        XCTAssertEqual(try store.load()?.generationCheckpoints, durable.generationCheckpoints)
    }

    func testDU03StaleWriterPreservesJournalCheckpoint() async throws {
        let root = try DataSafetyFixtures.make("DU03-journal"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        let old = try store.save(SessionSnapshot())
        let writer = SessionArchiveWriter(directory: root, restored: old)
        let durable = try store.append(.generationCheckpoint(checkpoint(old)))
        let saved = try await writer.commit(old)
        XCTAssertEqual(saved.generationCheckpoints, durable.generationCheckpoints)
    }

    func testDU03DirectSaveCannotSilentlyDeleteCheckpoint() throws {
        let root = try DataSafetyFixtures.make("DU03-deletion"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        var value = SessionSnapshot()
        value.generationCheckpoints = [checkpoint(value)]
        var saved = try store.save(value)
        let original = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        saved.generationCheckpoints = []
        XCTAssertThrowsError(try store.save(saved))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), original)
    }

    func testDU03CoalescedRetirementCannotDeleteResumedProgress() async throws {
        let root = try DataSafetyFixtures.make("DU03-coalesced"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        var value = SessionSnapshot()
        value.generationCheckpoints = [checkpoint(value)]
        let saved = try store.save(value)
        let writer = SessionArchiveWriter(directory: root, restored: saved)
        var resumed = saved
        resumed.generationCheckpoints[0].prefix += " newer synthetic progress"
        let result = try await writer.commit(resumed, retiringCheckpoints: saved.generationCheckpoints)
        XCTAssertEqual(result.generationCheckpoints, resumed.generationCheckpoints)
        XCTAssertEqual(try store.load()?.generationCheckpoints, resumed.generationCheckpoints)
    }

    func testDU04ExportFailureKeepsEntirePreviousVersion() throws {
        let root = try DataSafetyFixtures.make("DU04"); defer { DataSafetyFixtures.preserve(root) }
        let first = TranscriptSegment(startTime: 0, endTime: 1, english: "First synthetic segment.", chinese: "第一段。")
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "原合成笔记")
        let names = ["transcript-en.txt", "transcript-zh-Hans.txt", "bilingual.jsonl", "manifest.json", "summary-zh-Hans.md"]
        let originals = try names.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let srt = root.appendingPathComponent("bilingual.srt")
        try FileManager.default.moveItem(at: srt, to: root.appendingPathComponent("previous.srt"))
        try FileManager.default.createDirectory(at: srt, withIntermediateDirectories: false)
        let second = TranscriptSegment(startTime: 1, endTime: 2, english: "Second synthetic segment.", chinese: "第二段。")
        XCTAssertThrowsError(try SessionExporter.export(segments: [first, second], sessionDirectory: root, summary: "新合成笔记"))
        for (index, name) in names.enumerated() {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), originals[index], name)
        }
    }

    func testAtomicExportCourseCanBeMigratedWithOnlyManagedLinks() throws {
        let root = try DataSafetyFixtures.make("DU04-migration"); defer { DataSafetyFixtures.preserve(root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let caption = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic migration.", chinese: "合成迁移。")
        _ = try SessionStore(directory: source).save(SessionSnapshot(segments: [caption]))
        try SessionExporter.export(segments: [caption], sessionDirectory: source, summary: "合成笔记")
        let receipt = try SessionTreeMigration.copyVerified(from: source, to: target)
        XCTAssertEqual(try SessionTreeMigration.manifest(of: source), receipt.entries)
        XCTAssertEqual(try SessionTreeMigration.manifest(of: target), receipt.entries)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("bilingual.jsonl")),
                       try Data(contentsOf: target.appendingPathComponent("bilingual.jsonl")))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside synthetic bytes".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("unknown-link"), withDestinationURL: outside)
        XCTAssertThrowsError(try SessionTreeMigration.manifest(of: source))
    }

    func testInitialExportKeepsPrivateDirectoryPermissions() throws {
        let root = try DataSafetyFixtures.make("DU04-permissions"); defer { DataSafetyFixtures.preserve(root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try SessionExporter.export(segments: [], sessionDirectory: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700, "Publishing a directory must preserve its private access mode")
    }

    func testAtomicExportCannotFollowAnExternalVersionsDirectory() throws {
        let root = try DataSafetyFixtures.make("DU04-confinement"); defer { DataSafetyFixtures.preserve(root) }
        let course = root.appendingPathComponent("course"), outside = root.appendingPathComponent("outside")
        let store = course.appendingPathComponent(".exports"), identifier = UUID().uuidString
        let generation = outside.appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data(#"{"version":1,"members":{}}"#.utf8).write(to: generation.appendingPathComponent("export-index.json"))
        try FileManager.default.createSymbolicLink(at: store.appendingPathComponent("versions"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(atPath: store.appendingPathComponent("current").path,
                                                  withDestinationPath: "versions/" + identifier)
        XCTAssertThrowsError(try SessionExporter.currentExportDirectory(in: course))
    }
}
