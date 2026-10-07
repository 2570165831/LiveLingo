import Foundation
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
            .appendingPathComponent("superseded/fixtures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: destination.appendingPathComponent(root.lastPathComponent))
        } catch { XCTFail("Could not preserve synthetic fixture: \(error)") }
    }
}

final class DataSafetyStorageTests: XCTestCase {
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
