import Darwin
import Foundation
import Testing
@testable import LiveLingo

struct PrivacyFollowupStorageTests {
    private final class TemporaryFileManager: FileManager, @unchecked Sendable {
        let root: URL
        init(_ root: URL) { self.root = root; super.init() }
        override var temporaryDirectory: URL { root }
    }

    private func fixture() throws -> URL {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work/privacy-followup/storage", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("LiveLingo-PrivacyFollowup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func retain(_ root: URL) {
        let evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work/privacy-followup/storage/superseded", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: evidence.appendingPathComponent(root.lastPathComponent))
        } catch { Issue.record(error) }
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info.st_mode & 0o7777
    }

    private func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            try #require(errno == ENOENT)
            return ""
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        var length: ssize_t = 0
        let value = try #require(acl_to_text(acl, &length))
        defer { _ = acl_free(UnsafeMutableRawPointer(value)) }
        return String(cString: value)
    }

    private func setACL(_ permissions: [acl_perm_t], deny: Bool, at url: URL) throws {
        let group = try #require(getgrnam("everyone"))
        var principal = try #require(UUID(uuidString:
            String(format: "AAAABBBB-CCCC-DDDD-EEEE-FFFF%08X", group.pointee.gr_gid))).uuid
        var acl: acl_t? = acl_init(1)
        defer { if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) } }
        var rawEntry: acl_entry_t?
        try #require(acl_create_entry(&acl, &rawEntry) == 0)
        let entry = try #require(rawEntry)
        try #require(acl_set_tag_type(entry, deny ? ACL_EXTENDED_DENY : ACL_EXTENDED_ALLOW) == 0)
        try #require(withUnsafePointer(to: &principal) { acl_set_qualifier(entry, $0) } == 0)
        var rawPermissions: acl_permset_t?
        try #require(acl_get_permset(entry, &rawPermissions) == 0)
        let values = try #require(rawPermissions)
        for permission in permissions { try #require(acl_add_perm(values, permission) == 0) }
        let value = try #require(acl)
        try #require(acl_set_file(url.path, ACL_TYPE_EXTENDED, value) == 0)
    }

    @Test func R01ReplacedTemporaryRootIsPreserved() throws {
        let root = try fixture(); defer { retain(root) }
        let manager = TemporaryFileManager(root)
        let original = try SessionWorkspace.makeTemporarySessionDirectory(fileManager: manager)
        let moved = root.appendingPathComponent("retained-original")
        try manager.moveItem(at: original, to: moved)
        try manager.createDirectory(at: original, withIntermediateDirectories: false)
        let marker = original.appendingPathComponent("another-course.json")
        let bytes = Data("Synthetic replacement course".utf8)
        try bytes.write(to: marker)
        #expect(throws: (any Error).self) {
            try SessionWorkspace.discardTemporarySession(original, fileManager: manager)
        }
        #expect(try Data(contentsOf: marker) == bytes)
        #expect(manager.fileExists(atPath: moved.path))
    }

    @Test func R04ExistingACLOnlyAccessIsNotMigrated() throws {
        let root = try fixture(); defer {
            _ = chmod(root.path, 0o700)
            retain(root)
        }
        let leaf = root.appendingPathComponent("existing.json")
        let bytes = Data("Synthetic existing body".utf8)
        try bytes.write(to: leaf)
        try setACL([ACL_READ_DATA, ACL_READ_SECURITY, ACL_WRITE_SECURITY], deny: false, at: leaf)
        try #require(chmod(leaf.path, 0) == 0)
        let before = try aclText(leaf)
        try #require(Data(contentsOf: leaf) == bytes)
        try SensitiveFileIO.tightenFileIfPresent(leaf)
        #expect(try mode(leaf) == 0)
        #expect(try aclText(leaf) == before)
        #expect(try Data(contentsOf: leaf) == bytes)
    }

    @Test func R01LinkedReplacementKeepsPersistentRetryRecord() throws {
        let root = try fixture(); defer { retain(root) }
        let manager = TemporaryFileManager(root)
        let original = try SessionWorkspace.makeTemporarySessionDirectory(fileManager: manager)
        let retained = root.appendingPathComponent("retained-original")
        try manager.moveItem(at: original, to: retained)
        let outside = root.appendingPathComponent("another-course")
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        let marker = outside.appendingPathComponent("recording.wav")
        let bytes = Data("Synthetic other course".utf8)
        try bytes.write(to: marker)
        try manager.createSymbolicLink(at: original, withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try SessionWorkspace.discardTemporarySession(original, fileManager: manager)
        }
        #expect(try SessionWorkspace.pendingTemporarySessionDirectories(fileManager: TemporaryFileManager(root)) == [original])
        #expect(try Data(contentsOf: marker) == bytes)
        #expect(manager.fileExists(atPath: retained.path))
    }

    @Test func R04ExistingDirectoryACLAndModeAreUnchanged() throws {
        let root = try fixture(); defer {
            _ = chmod(root.path, 0o700)
            retain(root)
        }
        try setACL([ACL_READ_DATA, ACL_EXECUTE, ACL_READ_SECURITY, ACL_WRITE_SECURITY], deny: false, at: root)
        try #require(chmod(root.path, 0o300) == 0)
        let before = try aclText(root)
        try SensitiveFileIO.prepareDirectory(root)
        #expect(try mode(root) == 0o300)
        #expect(try aclText(root) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func R03FailedCleanupSurvivesNewSessionAndDiskReload() throws {
        let root = try fixture(); defer { retain(root) }
        let manager = TemporaryFileManager(root)
        let original = try SessionWorkspace.makeTemporarySessionDirectory(fileManager: manager)
        let recording = original.appendingPathComponent(SessionWorkspace.recordingFileName)
        let bytes = Data("Synthetic old recording".utf8)
        try bytes.write(to: recording)
        try #require(chflags(recording.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(recording.path, 0) }
        #expect(throws: (any Error).self) {
            try SessionWorkspace.discardTemporarySession(original, fileManager: manager)
        }
        #expect(try Data(contentsOf: recording) == bytes)
        let next = try SessionWorkspace.makeTemporarySessionDirectory(fileManager: manager)
        // A new manager reads the persistent records, rather than any old
        // AppModel/session reference or in-memory cleanup list.
        let reopened = TemporaryFileManager(root)
        #expect(try SessionWorkspace.pendingTemporarySessionDirectories(fileManager: reopened) == [original])
        #expect(throws: (any Error).self) { try SessionWorkspace.retryPendingTemporarySessions(fileManager: reopened) }
        try #require(chflags(recording.path, 0) == 0)
        try SessionWorkspace.retryPendingTemporarySessions(fileManager: reopened)
        #expect(!manager.fileExists(atPath: original.path))
        #expect(try SessionWorkspace.pendingTemporarySessionDirectories(fileManager: reopened).isEmpty)
        #expect(manager.fileExists(atPath: next.path))
        try SessionWorkspace.discardTemporarySession(next, fileManager: reopened)
    }

    @Test func R05ReadOnlyAtomicSaveIsRejectedWithoutChanges() throws {
        let root = try fixture(); defer { retain(root) }
        let leaf = root.appendingPathComponent("existing.json")
        let bytes = Data("Synthetic read-only body".utf8)
        try bytes.write(to: leaf)
        try #require(chmod(leaf.path, 0o400) == 0)
        let before = try aclText(leaf)
        #expect(throws: (any Error).self) { try SensitiveFileIO.atomicWrite(Data("replacement".utf8), to: leaf) }
        #expect(try mode(leaf) == 0o400)
        #expect(try aclText(leaf) == before)
        #expect(try Data(contentsOf: leaf) == bytes)
    }

    @Test func R05DenyWriteAtomicSaveIsRejectedWithoutChanges() throws {
        let root = try fixture(); defer { retain(root) }
        let leaf = root.appendingPathComponent("existing.json")
        let bytes = Data("Synthetic deny-write body".utf8)
        try bytes.write(to: leaf)
        try setACL([ACL_WRITE_DATA, ACL_APPEND_DATA], deny: true, at: leaf)
        let before = try aclText(leaf), originalMode = try mode(leaf)
        #expect(throws: (any Error).self) { try SensitiveFileIO.atomicWrite(Data("replacement".utf8), to: leaf) }
        #expect(try mode(leaf) == originalMode)
        #expect(try aclText(leaf) == before)
        #expect(try Data(contentsOf: leaf) == bytes)
    }

    @Test func R05WritableAtomicReplacementPreservesModeAndACL() throws {
        let root = try fixture(); defer { retain(root) }
        let leaf = root.appendingPathComponent("existing.json")
        try Data("old".utf8).write(to: leaf)
        try #require(chmod(leaf.path, 0o640) == 0)
        try setACL([ACL_EXECUTE], deny: true, at: leaf)
        let before = try aclText(leaf)
        let bytes = Data("Synthetic replacement body".utf8)
        try SensitiveFileIO.atomicWrite(bytes, to: leaf)
        #expect(try mode(leaf) == 0o640)
        #expect(try aclText(leaf) == before)
        #expect(try Data(contentsOf: leaf) == bytes)
    }

    @Test func R12NormalAdviceWithFailurePrefixIsUnchanged() {
        let advice = ["读取路径失败时，应检查课程目录和权限。", "报告保存失败后建议检查剩余空间。",
                      "复查报告读取失败的原因需要进一步分析。", "复查进度读取失败时可以稍后重试。"]
        let result = NotesExportDocument.reviewSection(advice.joined(separator: "\n"))
        for line in advice { #expect(result.contains(line)) }
    }

    @Test func R12ColonAdviceIsPreservedAndCompleteFailureWrappersAreRedacted() {
        let advice = ["读取路径失败：先检查课程目录和权限，再重试导出。",
                      "报告保存失败：建议检查剩余空间。", "复查报告读取失败：可以稍后再试。",
                      "读取路径失败：Check the course directory and try again."]
        let failures = ["复查报告读取失败，未导出：SYNTHETIC_PRIVATE_DIAGNOSTIC",
                        "读取复查报告目录失败，未导出：SYNTHETIC_PRIVATE_DIAGNOSTIC",
                        "局部复查报告读取失败，未导出：synthetic.md（请求失败）"]
        let result = NotesExportDocument.reviewSection((advice + failures).joined(separator: "\n"))
        for line in advice { #expect(result.contains(line)) }
        for line in failures { #expect(!result.contains(line)) }
        #expect(!result.contains("SYNTHETIC_PRIVATE_DIAGNOSTIC"))
        #expect(result.contains("本批复查未完成，原笔记已保留。"))
    }

    @Test func R05UnsupportedStorageCapabilitiesDoNotBlockNewOrReplacementWrites() throws {
        let root = try fixture(); defer { retain(root) }
        let operations: [Set<SensitiveFileIO.OptionalOperation>] = [
            [.setACL], [.readACL, .setACL, .mode, .owner], [.link, .swap],
            [.link, .exclusiveRename, .swap, .directorySync]
        ]
        for (index, unsupported) in operations.enumerated() {
            let leaf = root.appendingPathComponent("portable-\(index).json")
            try SensitiveFileIO.$unsupportedOperations.withValue(unsupported) {
                try SensitiveFileIO.atomicWrite(Data("new synthetic body".utf8), to: leaf)
                #expect(try Data(contentsOf: leaf) == Data("new synthetic body".utf8))
                try SensitiveFileIO.atomicWrite(Data("updated synthetic body".utf8), to: leaf)
                #expect(try Data(contentsOf: leaf) == Data("updated synthetic body".utf8))
            }
        }
    }

    @Test func R05FallbackStillRespectsExistingReadOnlyObject() throws {
        let root = try fixture(); defer { retain(root) }
        let leaf = root.appendingPathComponent("read-only.json")
        let original = Data("synthetic retained body".utf8)
        try original.write(to: leaf)
        try #require(chmod(leaf.path, 0o400) == 0)
        try SensitiveFileIO.$unsupportedOperations.withValue([.link, .swap, .exclusiveRename, .setACL]) { () throws -> Void in
            #expect(throws: (any Error).self) { try SensitiveFileIO.atomicWrite(Data("replacement".utf8), to: leaf) }
            #expect(try Data(contentsOf: leaf) == original)
            #expect(try mode(leaf) == 0o400)
        }
    }

    @Test func R05UnreadableACLMetadataDoesNotBlockWritableReplacement() throws {
        let root = try fixture(); defer { retain(root) }
        let leaf = root.appendingPathComponent("writable-with-unavailable-acl.json")
        try Data("previous synthetic body".utf8).write(to: leaf)
        try SensitiveFileIO.$aclReadError.withValue(EACCES) {
            try SensitiveFileIO.atomicWrite(Data("updated synthetic body".utf8), to: leaf)
            #expect(try Data(contentsOf: leaf) == Data("updated synthetic body".utf8))
        }
    }
}
