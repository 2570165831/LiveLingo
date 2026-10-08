import Foundation
import Darwin
import XCTest
@testable import LiveLingo

enum DataSafetyFixtures {
    static func make(_ label: String) throws -> URL {
        let designated = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("work/dd-safety/tmp", isDirectory: true)
        guard SessionDirectoryLocation.canonical(FileManager.default.temporaryDirectory)
            == SessionDirectoryLocation.canonical(designated) else {
            throw NSError(domain: "DataSafetyFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tests require the designated temporary directory"])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Safety-\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func preserve(_ root: URL) {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("work/dd-safety/fixtures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: destination.appendingPathComponent(root.lastPathComponent))
        } catch { XCTFail("Could not preserve synthetic fixture: \(error)") }
    }
}

final class DataSafetyStorageTests: XCTestCase {
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
