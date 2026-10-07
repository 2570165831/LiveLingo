import Darwin
import Foundation
import Testing
@testable import LiveLingo

/// Every payload and path is generated here. The runner owns TMPDIR; no app
/// container, saved lesson, preference suite, recording, or model is opened.
struct PrivacyStorageTests {
    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("LiveLingo-PrivacyStorage-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        func directory(_ name: String, mode: mode_t = 0o755) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            guard chmod(url.path, mode) == 0 else { throw POSIXError(.EACCES) }
            return url
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_mode & 0o777
    }

    private func seed(_ bytes: Data, at url: URL, mode: mode_t = 0o644) throws {
        try bytes.write(to: url)
        guard chmod(url.path, mode) == 0 else { throw POSIXError(.EACCES) }
    }

    private func link(_ url: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    private func record(_ sessionID: UUID) -> TranscriptionWorkRecord {
        var value = TranscriptionWorkRecord(id: UUID(), sessionID: sessionID, ordinal: 0,
            audioFile: "chunk.wav", startFrame: 0, endFrame: 16_000, sampleRate: 16_000,
            start: 0, end: 1, captureStart: nil, captureEnd: nil,
            modelKey: "synthetic", fallbackModelKey: nil, appleEvidence: "Synthetic evidence")
        value.candidateText = "Synthetic candidate body."
        return value
    }

    private func descriptor(_ sessionID: UUID) -> CaptureChunkDescriptor {
        CaptureChunkDescriptor(id: UUID(), sessionID: sessionID, ordinal: 1,
            audioFile: "next.wav", recordingFile: "recording.wav", startFrame: 16_000,
            sampleRate: 16_000, modelKey: "synthetic", fallbackModelKey: nil)
    }

    @Test func archiveAtomicWriteRemovesTemporaryFileAfterRenameFailure() throws {
        let f = try Fixture(); defer { f.clean() }
        let destination = f.root.appendingPathComponent("snapshot.json")
        let original = Data("Synthetic committed snapshot".utf8)
        try seed(original, at: destination, mode: 0o600)
        // An immutable destination forces rename to fail after the temporary
        // file has been written and synced, without process-global fault hooks.
        try #require(chflags(destination.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(destination.path, 0) }
        #expect(throws: SessionStoreError.self) {
            try SessionArchiveCoding.atomicWrite(Data("Synthetic replacement".utf8), destination)
        }
        #expect(try Data(contentsOf: destination) == original)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        #expect(names.filter { $0.hasPrefix(".session-write-") }.isEmpty)
    }

    @Test func exporterTightensExistingSensitiveFilesAndPreservesOtherContents() throws {
        let f = try Fixture(); defer { f.clean() }
        let directory = try f.directory("session")
        let sentinel = directory.appendingPathComponent("user-kept.bin")
        let kept = Data("Synthetic unrelated user file".utf8)
        try seed(kept, at: sentinel, mode: 0o640)
        let names = ["transcript-en.txt", "transcript-zh-Hans.txt", "bilingual.jsonl",
                     "bilingual.srt", "summary-zh-Hans.md", "manifest.json"]
        for name in names { try seed(Data("Synthetic prior body".utf8), at: directory.appendingPathComponent(name)) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1,
            english: "Water flows.", chinese: "水会流动。")
        try SessionExporter.export(segments: [segment], sessionDirectory: directory,
            summary: "合成笔记。", createdAt: Date(timeIntervalSince1970: 0))
        #expect(try mode(directory) == 0o700)
        for name in names { #expect(try mode(directory.appendingPathComponent(name)) == 0o600) }
        #expect(try Data(contentsOf: sentinel) == kept)
        #expect(try mode(sentinel) == 0o640)
        #expect(try Data(contentsOf: directory.appendingPathComponent("transcript-en.txt")) == Data("Water flows.\n".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("transcript-zh-Hans.txt")) == Data("水会流动。\n".utf8))
        #expect(try Data(contentsOf: directory.appendingPathComponent("summary-zh-Hans.md")) == Data("合成笔记。\n".utf8))
    }

    @Test func notesExportWritesPrivateFileWithUnchangedPayload() throws {
        let f = try Fixture(); defer { f.clean() }
        let snapshot = NotesExportSnapshot(className: "Synthetic class", sessionName: nil,
            scope: .wholeLesson, scopeDetail: "合成范围", coverageLine: "合成覆盖",
            notesMarkdown: "## 合成笔记\n\n水会流动。", reviewMarkdown: nil, transcript: [],
            generatedAt: Date(timeIntervalSince1970: 0), includesReviewAdvice: false, includesTranscript: false)
        for format in [NotesExportFormat.markdown, .plainText] {
            let destination = f.root.appendingPathComponent("notes." + format.fileExtension)
            try seed(Data("Synthetic previous export".utf8), at: destination)
            let expected = try NotesExportDocument.data(snapshot, format: format)
            try NotesExportDocument.write(snapshot, format: format, to: destination)
            #expect(try mode(destination) == 0o600)
            #expect(try Data(contentsOf: destination) == expected)
        }
    }

    @Test func temporarySessionDirectoryIsPrivate() throws {
        let directory = try SessionWorkspace.makeTemporarySessionDirectory()
        defer { try? SessionWorkspace.discardTemporarySession(directory) }
        #expect(try mode(directory) == 0o700)
    }

    @Test func permissionMigrationPreservesOwnerReadOnlyRestrictions() throws {
        let f = try Fixture(); defer {
            _ = chmod(f.root.path, 0o700)
            f.clean()
        }
        let leaf = f.root.appendingPathComponent("read-only.json")
        let original = Data("Synthetic read-only body".utf8)
        try seed(original, at: leaf, mode: 0o400)
        try #require(chmod(f.root.path, 0o500) == 0)
        for _ in 0..<2 {
            try SensitiveFileIO.prepareDirectory(f.root)
            try SensitiveFileIO.tightenFileIfPresent(leaf)
            #expect(try mode(f.root) == 0o500)
            #expect(try mode(leaf) == 0o400)
            #expect(try Data(contentsOf: leaf) == original)
        }
    }

    @Test func reviewReportFilesArePrivateAndHistoryRemainsReadable() throws {
        let f = try Fixture(); defer { f.clean() }
        let directory = try f.directory("reports")
        let sentinel = directory.appendingPathComponent("user-kept.bin")
        let kept = Data("Synthetic unrelated report attachment".utf8)
        try seed(kept, at: sentinel)
        var entry = ReviewReportEntry(jobID: UUID(), identity: nil, scope: .wholeLesson,
            inputDigest: nil, completed: 0, total: 0, supersededByRevision: nil,
            updatedAt: Date(timeIntervalSince1970: 0), fileName: LearningReviewScope.wholeLesson.reportFileName,
            markdown: "合成复查正文。")
        try ReviewReportCollection.save(entry, in: directory)
        for name in [ReviewReportCollection.manifestFileName, entry.fileName] {
            try #require(chmod(directory.appendingPathComponent(name).path, 0o644) == 0)
        }
        entry.markdown = "合成复查新正文。"
        try ReviewReportCollection.save(entry, in: directory)
        #expect(try mode(directory) == 0o700)
        for name in [ReviewReportCollection.manifestFileName, entry.fileName] {
            #expect(try mode(directory.appendingPathComponent(name)) == 0o600)
        }
        #expect(try ReviewReportCollection.read(in: directory).first?.markdown == entry.markdown)
        #expect(try Data(contentsOf: directory.appendingPathComponent(entry.fileName)) == Data((entry.markdown + "\n").utf8))
        #expect(try Data(contentsOf: sentinel) == kept)
    }

    @Test func journalTightensExistingDirectoriesFilesAndKeepsRecords() throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try f.directory("session")
        let work = session.appendingPathComponent(DurableTranscriptionJournal.directoryName)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        try #require(chmod(work.path, 0o755) == 0)
        let sentinel = work.appendingPathComponent("user-kept.bin")
        let kept = Data("Synthetic unrelated journal file".utf8)
        try seed(kept, at: sentinel)
        let id = UUID(), value = record(id)
        let journal = try DurableTranscriptionJournal(sessionDirectory: session, sessionID: id)
        try journal.put(value); try journal.checkpoint()
        let capture = descriptor(id)
        try DurableTranscriptionJournal.stageCapture(capture, directory: journal.directory)
        for name in ["work.jsonl", "snapshot.json"] { try #require(chmod(work.appendingPathComponent(name).path, 0o644) == 0) }
        let reopened = try DurableTranscriptionJournal(sessionDirectory: session, sessionID: id)
        #expect(try mode(session) == 0o700)
        #expect(try mode(work) == 0o700)
        for name in ["work.jsonl", "snapshot.json", "capture-" + capture.id.uuidString + ".json"] {
            #expect(try mode(work.appendingPathComponent(name)) == 0o600)
        }
        #expect(reopened.records == [value])
        #expect(try reopened.unfinishedCaptures().map(\.id) == [capture.id])
        #expect(try Data(contentsOf: sentinel) == kept)
    }

    @Test func journalTruncatedTailBackupIsPrivateAndPreservesExactBytes() throws {
        let f = try Fixture(); defer { f.clean() }
        let id = UUID(), value = record(id)
        let journal = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: id)
        try journal.put(value)
        let log = journal.directory.appendingPathComponent("work.jsonl")
        let original = try Data(contentsOf: log), tail = Data("{synthetic-incomplete".utf8)
        try seed(original + tail, at: log)
        let reopened = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: id)
        let files = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
        let saved = try #require(files.first { $0.lastPathComponent.hasPrefix("truncated-tail-") })
        #expect(reopened.recoveredTruncatedTail)
        #expect(reopened.records == [value])
        #expect(try mode(saved) == 0o600)
        #expect(try Data(contentsOf: saved) == tail)
        #expect(try Data(contentsOf: log) == original)
        #expect(try mode(log) == 0o600)
    }

    @Test func journalRejectsLinkedWorkingDirectoryWithoutChangingTarget() throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try f.directory("session"), outside = try f.directory("outside")
        try link(session.appendingPathComponent(DurableTranscriptionJournal.directoryName), to: outside)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) {
            _ = try DurableTranscriptionJournal(sessionDirectory: session, sessionID: UUID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try mode(outside) == 0o755)
    }

    @Test func journalRejectsLinkedSessionRoot() throws {
        let f = try Fixture(); defer { f.clean() }
        let target = try f.directory("target"), alias = f.root.appendingPathComponent("alias")
        try link(alias, to: target)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) {
            _ = try DurableTranscriptionJournal(sessionDirectory: alias, sessionID: UUID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(try mode(target) == 0o755)
    }

    @Test func journalRejectsLinkedIntermediatePath() throws {
        let f = try Fixture(); defer { f.clean() }
        let target = try f.directory("target"), alias = f.root.appendingPathComponent("alias")
        let actualSession = target.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: actualSession, withIntermediateDirectories: false)
        try link(alias, to: target)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) {
            _ = try DurableTranscriptionJournal(sessionDirectory: alias.appendingPathComponent("session"), sessionID: UUID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: actualSession.path).isEmpty)
    }

    @Test func journalRejectsLinkedLogOnReopen() throws {
        let f = try Fixture(); defer { f.clean() }
        let id = UUID()
        let journal = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: id)
        let log = journal.directory.appendingPathComponent("work.jsonl")
        let retained = f.root.appendingPathComponent("retained-log.jsonl")
        try FileManager.default.moveItem(at: log, to: retained)
        let original = try Data(contentsOf: retained)
        try link(log, to: retained)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) {
            _ = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: id)
        }
        #expect(try Data(contentsOf: retained) == original)
    }

    @Test func journalAppendRejectsLeafSymlinkAndKeepsState() throws {
        let f = try Fixture(); defer { f.clean() }
        let journal = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: UUID())
        let log = journal.directory.appendingPathComponent("work.jsonl")
        let retained = f.root.appendingPathComponent("retained-log.jsonl")
        try FileManager.default.moveItem(at: log, to: retained)
        let original = try Data(contentsOf: retained)
        try link(log, to: retained)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) { try journal.setPaused(true) }
        #expect(!journal.isPaused)
        #expect(try Data(contentsOf: retained) == original)
    }

    @Test func journalCheckpointRejectsLeafSymlinkWithoutReplacingIt() throws {
        let f = try Fixture(); defer { f.clean() }
        let journal = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: UUID())
        let retained = f.root.appendingPathComponent("retained-snapshot.json")
        let original = Data("Synthetic unrelated snapshot".utf8)
        try seed(original, at: retained)
        let snapshot = journal.directory.appendingPathComponent("snapshot.json")
        try link(snapshot, to: retained)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) { try journal.checkpoint() }
        #expect(try Data(contentsOf: retained) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: snapshot.path) == retained.path)
    }

    @Test func journalPinsOpenedDirectoryWhenWorkingPathIsReplaced() throws {
        let f = try Fixture(); defer { f.clean() }
        let journal = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: UUID())
        let retained = f.root.appendingPathComponent("retained-work")
        try FileManager.default.moveItem(at: journal.directory, to: retained)
        let retainedLog = retained.appendingPathComponent("work.jsonl")
        let priorLog = try Data(contentsOf: retainedLog)
        let outside = try f.directory("outside")
        let target = outside.appendingPathComponent("work.jsonl")
        let original = Data("Synthetic unrelated outside file".utf8)
        try seed(original, at: target)
        try link(journal.directory, to: outside)
        do {
            try journal.setPaused(true)
            #expect(journal.isPaused)
            let updatedLog = try Data(contentsOf: retainedLog)
            #expect(updatedLog.count > priorLog.count)
            #expect(updatedLog.starts(with: priorLog))
            try journal.checkpoint()
            #expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("snapshot.json").path))
        } catch is DurableTranscriptionJournal.JournalError {
            // Refusing a changed path is also safe; successful operations must
            // use the retained directory descriptor, never the symlink target.
        }
        #expect(try Data(contentsOf: target) == original)
        #expect(try mode(outside) == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: retained.path).contains("work.jsonl"))
    }

    @Test func captureStageRejectsLinkedWorkingDirectory() throws {
        let f = try Fixture(); defer { f.clean() }
        let target = try f.directory("target"), alias = f.root.appendingPathComponent("alias")
        try link(alias, to: target)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) {
            try DurableTranscriptionJournal.stageCapture(descriptor(UUID()), directory: alias)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func captureRecoveryRejectsLinkedMarker() throws {
        let f = try Fixture(); defer { f.clean() }
        let id = UUID(), capture = descriptor(id)
        let journal = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: id)
        try DurableTranscriptionJournal.stageCapture(capture, directory: journal.directory)
        let marker = journal.directory.appendingPathComponent("capture-" + capture.id.uuidString + ".json")
        let retained = f.root.appendingPathComponent("retained-marker.json")
        try FileManager.default.moveItem(at: marker, to: retained)
        let original = try Data(contentsOf: retained)
        try link(marker, to: retained)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) { _ = try journal.unfinishedCaptures() }
        #expect(try Data(contentsOf: retained) == original)
    }

    @Test func journalRejectsSameDirectoryAudioAndRecordingSymlinks() throws {
        let f = try Fixture(); defer { f.clean() }
        let id = UUID(), journal = try DurableTranscriptionJournal(sessionDirectory: f.root, sessionID: id)
        var value = record(id)
        let audio = journal.directory.appendingPathComponent("actual.wav")
        try seed(Data("Synthetic audio bytes".utf8), at: audio)
        try link(journal.directory.appendingPathComponent(value.audioFile), to: audio)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) { _ = try journal.audioURL(for: value) }
        value.recordingFile = "recording.wav"
        let recording = f.root.appendingPathComponent("actual-recording.wav")
        try seed(Data("Synthetic recording bytes".utf8), at: recording)
        try link(f.root.appendingPathComponent("recording.wav"), to: recording)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) { _ = try journal.recordingURL(for: value) }
    }

    @Test func P03LegacyReviewFailureExcludedFromNotesExport() throws {
        let marker = "SYNTHETIC_PRIVATE_DIAGNOSTIC"
        let advice = "正常建议：检查合成公式中的单位。"
        let review = "# 合成复查\n\n" + [
            "本批复查失败，保留原笔记：" + marker + " synthetic/private/lesson.txt",
            "读取路径失败：" + marker,
            "复查进度读取失败，已保留现场：" + marker,
            "复查报告读取失败：" + marker,
            "报告保存失败：" + marker,
            "复查报告保存失败：" + marker,
            advice
        ].joined(separator: "\n")
        let body = NotesExportDocument.reviewSection(review)
        #expect(!body.contains(marker))
        #expect(!body.contains("synthetic/private"))
        #expect(body.contains(advice))
        #expect(body.contains("本批复查未完成，原笔记已保留。"))
        let snapshot = NotesExportSnapshot(className: "Synthetic class", sessionName: nil,
            scope: .wholeLesson, scopeDetail: "合成范围", coverageLine: "合成覆盖",
            notesMarkdown: "合成笔记。", reviewMarkdown: review, transcript: [],
            generatedAt: Date(timeIntervalSince1970: 0), includesReviewAdvice: true, includesTranscript: false)
        for format in [NotesExportFormat.markdown, .plainText] {
            let payload = try NotesExportDocument.data(snapshot, format: format)
            let text = try #require(String(data: payload, encoding: .utf8))
            #expect(!text.contains(marker))
            #expect(text.contains(advice))
        }
        #expect(review.contains(marker)) // The stored historical input is unchanged.
    }

    @Test func inheritedAllowACLIsRemovedFromSensitiveObjectsOnly() throws {
        let f = try Fixture(); defer { f.clean() }
        let group = try #require(getgrnam("everyone"))
        // membership.h documents this synthesized GID UUID as valid for ACLs,
        // including groups that also have an assigned directory-service UUID.
        var principal = try #require(UUID(uuidString:
            String(format: "AAAABBBB-CCCC-DDDD-EEEE-FFFF%08X", group.pointee.gr_gid))).uuid
        var acl: acl_t? = acl_init(1)
        defer { if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) } }
        var rawEntry: acl_entry_t?
        try #require(acl_create_entry(&acl, &rawEntry) == 0)
        let entry = try #require(rawEntry)
        try #require(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0)
        try #require(withUnsafePointer(to: &principal) { acl_set_qualifier(entry, $0) } == 0)
        var rawPermissions: acl_permset_t?
        try #require(acl_get_permset(entry, &rawPermissions) == 0)
        let permissions = try #require(rawPermissions)
        for permission in [ACL_READ_DATA, ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_READ_SECURITY] {
            try #require(acl_add_perm(permissions, permission) == 0)
        }
        var rawFlags: acl_flagset_t?
        try #require(acl_get_flagset_np(UnsafeMutableRawPointer(entry), &rawFlags) == 0)
        let flags = try #require(rawFlags)
        try #require(acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 0)
        try #require(acl_add_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 0)
        try #require(acl_set_file(f.root.path, ACL_TYPE_EXTENDED, acl) == 0)

        func aclText(_ url: URL) throws -> String {
            guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
                if errno == ENOENT { return "" }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
            var first: acl_entry_t?
            errno = 0
            let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &first)
            if first == nil, result == 0 || errno == EINVAL { return "" }
            try #require(result == 0)
            var length: ssize_t = 0
            let text = try #require(acl_to_text(acl, &length))
            defer { _ = acl_free(UnsafeMutableRawPointer(text)) }
            return String(cString: text)
        }
        let ancestorACL = try aclText(f.root)
        #expect(ancestorACL.contains("allow"))
        let destination = f.root.appendingPathComponent("body.json")
        let original = Data("Synthetic body".utf8), suffix = Data("\nSynthetic appended body".utf8)
        try SensitiveFileIO.atomicWrite(original, to: destination)
        #expect(try mode(destination) == 0o600)
        #expect(try !aclText(destination).contains("allow"))
        // Reapply inheritance to the owned leaf and test the existing-file
        // append path as well as the new atomic-file path.
        try #require(acl_set_file(destination.path, ACL_TYPE_EXTENDED, acl) == 0)
        try SensitiveFileIO.append(suffix, to: destination)
        #expect(try !aclText(destination).contains("allow"))
        #expect(try Data(contentsOf: destination) == original + suffix)
        let directory = f.root.appendingPathComponent("private-work")
        try SensitiveFileIO.prepareDirectory(directory)
        #expect(try mode(directory) == 0o700)
        #expect(try !aclText(directory).contains("allow"))
        #expect(try aclText(f.root) == ancestorACL)
    }

    @Test func sessionStoreTightensExistingRootSnapshotAndAppendFile() throws {
        let f = try Fixture(); defer { f.clean() }
        let store = SessionStore(directory: f.root)
        let initial = try store.save(SessionSnapshot(createdAt: Date(timeIntervalSince1970: 0)))
        let segment = TranscriptSegment(startTime: 0, endTime: 1,
            english: "Synthetic preserved input.", chinese: "合成译文。", sessionID: initial.sessionID)
        _ = try store.append(.upsertSegment(segment))
        try #require(chmod(f.root.path, 0o755) == 0)
        for name in [SessionStore.snapshotFileName, SessionStore.journalFileName] {
            try #require(chmod(f.root.appendingPathComponent(name).path, 0o644) == 0)
        }
        let loadedSnapshot = try store.load()
        let loaded = try #require(loadedSnapshot)
        #expect(loaded.segments == [segment])
        #expect(try mode(f.root) == 0o700)
        for name in [SessionStore.snapshotFileName, SessionStore.journalFileName] {
            #expect(try mode(f.root.appendingPathComponent(name)) == 0o600)
        }
    }
}
