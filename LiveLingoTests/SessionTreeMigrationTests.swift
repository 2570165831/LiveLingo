import Foundation
import Darwin
import Testing
@testable import LiveLingo

struct SessionTreeMigrationTests {
    private enum Fault: Error { case injected }
    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        init() throws {
            guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Fault.injected }
            defer { free(resolved) }
            root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                .appendingPathComponent("LiveLingoMigrationTests-\(UUID().uuidString)", isDirectory: true)
            source = root.appendingPathComponent("source", isDirectory: true)
            destination = root.appendingPathComponent("saved lesson", isDirectory: true)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("nested/empty", isDirectory: true),
                                                    withIntermediateDirectories: true)
            for (path, text) in [("recording.wav", "synthetic audio"), ("bilingual.jsonl", "synthetic transcript"),
                                 ("summary-zh-Hans.md", "完整笔记"), ("nested/draft.json", "synthetic prefix"),
                                 (".session-store.lock", "")] {
                try Data(text.utf8).write(to: source.appendingPathComponent(path))
            }
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    @Test func verifiedCopyIncludesWholeTreeHiddenFilesAndEmptyDirectories() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let before = try SessionTreeMigration.manifest(of: fixture.source)
        let receipt = try SessionTreeMigration.copyVerified(from: fixture.source, to: fixture.destination)
        #expect(receipt.entries == before)
        #expect(receipt.fileCount == 5)
        #expect(receipt.preservedSourceDirectory == nil)
        #expect(try SessionTreeMigration.manifest(of: fixture.source) == before)
        #expect(try SessionTreeMigration.manifest(of: fixture.destination) == before)
        #expect(fixture.exists(fixture.destination.appendingPathComponent("nested/empty")))
        #expect(fixture.exists(fixture.destination.appendingPathComponent(".session-store.lock")))
    }

    @Test func promotionRetiresOnlyAfterVerificationAndRetainsExactRecoverableSource() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try SessionTreeMigration.manifest(of: fixture.source)
        let receipt = try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination)
        let retained = try #require(receipt.preservedSourceDirectory)
        #expect(!fixture.exists(fixture.source))
        #expect(try SessionTreeMigration.manifest(of: retained) == original)
        #expect(try SessionTreeMigration.manifest(of: fixture.destination) == original)
        #expect(retained.deletingLastPathComponent() == fixture.root)
    }

    @Test func copyFailurePreservesOriginalAndPartialDestination() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try SessionTreeMigration.manifest(of: fixture.source)
        var operations = SessionTreeMigration.Operations()
        operations.copyTree = { source, destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: source.appendingPathComponent("recording.wav"),
                                              to: destination.appendingPathComponent("recording.wav"))
            throw Fault.injected
        }
        #expect(throws: SessionMigrationError.self) {
            try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination, operations: operations)
        }
        #expect(try SessionTreeMigration.manifest(of: fixture.source) == original)
        #expect(fixture.exists(fixture.destination.appendingPathComponent("recording.wav")))
        #expect(!fixture.exists(fixture.destination.appendingPathComponent("summary-zh-Hans.md")))
    }

    @Test func sameLengthDestinationDamageIsDetectedByHash() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try SessionTreeMigration.manifest(of: fixture.source)
        var operations = SessionTreeMigration.Operations()
        operations.beforeVerification = {
            let recording = fixture.destination.appendingPathComponent("recording.wav")
            let count = try Data(contentsOf: recording).count
            try Data(repeating: 88, count: count).write(to: recording)
        }
        #expect(throws: SessionMigrationError.self) {
            try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination, operations: operations)
        }
        #expect(try SessionTreeMigration.manifest(of: fixture.source) == original)
        #expect(fixture.exists(fixture.destination))
        #expect(try SessionTreeMigration.manifest(of: fixture.destination) != original)
    }

    @Test func sourceChangesDuringCopyOrBeforeRetirementPreserveBothTrees() throws {
        for lateChange in [false, true] {
            let fixture = try Fixture(); defer { fixture.clean() }
            let original = try Data(contentsOf: fixture.source.appendingPathComponent("recording.wav"))
            let change = {
                try Data(repeating: 89, count: original.count)
                    .write(to: fixture.source.appendingPathComponent("recording.wav"))
            }
            var operations = SessionTreeMigration.Operations()
            if lateChange { operations.beforeRetirement = change }
            else { operations.beforeVerification = change }
            #expect(throws: SessionMigrationError.self) {
                try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination, operations: operations)
            }
            #expect(fixture.exists(fixture.source))
            #expect(try Data(contentsOf: fixture.source.appendingPathComponent("recording.wav")) != original)
            #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("recording.wav")) == original)
        }
    }

    @Test func destinationDamageAfterInitialVerificationRestoresTheSourceName() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try SessionTreeMigration.manifest(of: fixture.source)
        var operations = SessionTreeMigration.Operations()
        operations.beforeRetirement = {
            try Data("damaged copy".utf8).write(to: fixture.destination.appendingPathComponent("nested/draft.json"))
        }
        do {
            _ = try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination, operations: operations)
            Issue.record("A changed destination must fail migration")
        } catch SessionMigrationError.failed(let source, let destination, let preserved, _) {
            #expect(source == fixture.source)
            #expect(destination == fixture.destination)
            #expect(preserved == nil)
        }
        #expect(try SessionTreeMigration.manifest(of: fixture.source) == original)
        #expect(fixture.exists(fixture.destination))
        #expect(try SessionTreeMigration.manifest(of: fixture.destination) != original)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!names.contains(where: { $0.hasPrefix(".source.migrated-") }))
    }

    @Test func injectedVerificationErrorPreservesSourceAndCompletedCopy() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let original = try SessionTreeMigration.manifest(of: fixture.source)
        var operations = SessionTreeMigration.Operations()
        operations.beforeVerification = { throw Fault.injected }
        #expect(throws: SessionMigrationError.self) {
            try SessionTreeMigration.copyVerified(from: fixture.source, to: fixture.destination, operations: operations)
        }
        #expect(try SessionTreeMigration.manifest(of: fixture.source) == original)
        #expect(try SessionTreeMigration.manifest(of: fixture.destination) == original)
    }

    @Test func unexpectedDestinationEntryAndLateSourceEntryPreventRetirement() throws {
        for changeSource in [false, true] {
            let fixture = try Fixture(); defer { fixture.clean() }
            var operations = SessionTreeMigration.Operations()
            operations.beforeVerification = {
                let directory = changeSource ? fixture.source : fixture.destination
                try Data("keep this unexpected data".utf8).write(to: directory.appendingPathComponent("extra.txt"))
            }
            #expect(throws: SessionMigrationError.self) {
                try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination, operations: operations)
            }
            #expect(fixture.exists(fixture.source))
            #expect(fixture.exists(fixture.destination))
            #expect(fixture.exists((changeSource ? fixture.source : fixture.destination).appendingPathComponent("extra.txt")))
        }
    }

    @Test func collisionAndOverlapNeverOverwriteOrStartCopy() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        let marker = fixture.destination.appendingPathComponent("keep.txt")
        try Data("original neighbor".utf8).write(to: marker)
        #expect(throws: SessionMigrationError.self) {
            try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "original neighbor")
        #expect(throws: SessionMigrationError.self) {
            try SessionTreeMigration.copyVerified(from: fixture.source, to: fixture.source.appendingPathComponent("child"))
        }
        #expect(!fixture.exists(fixture.source.appendingPathComponent("child")))
    }

    @Test func symlinksAndSpecialEntriesAreRejectedBeforeCopy() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let external = fixture.root.appendingPathComponent("neighbor.txt")
        try Data("do not touch".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("external-link"),
                                                    withDestinationURL: external)
        #expect(throws: SessionMigrationError.self) {
            try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination)
        }
        #expect(!fixture.exists(fixture.destination))
        #expect(try String(contentsOf: external, encoding: .utf8) == "do not touch")
    }

    @Test func sourceRootSymlinkAndDanglingDestinationAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let alias = fixture.root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
        #expect(throws: SessionMigrationError.self) {
            try SessionTreeMigration.promote(from: alias, to: fixture.destination)
        }
        try FileManager.default.createSymbolicLink(at: fixture.destination,
                                                    withDestinationURL: fixture.root.appendingPathComponent("missing-neighbor"))
        #expect(throws: SessionMigrationError.self) {
            try SessionTreeMigration.promote(from: fixture.source, to: fixture.destination)
        }
        #expect(fixture.exists(fixture.source))
    }

    @Test func ordinaryParentAliasesResolveToTheSameSessionLocation() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let alias = fixture.root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let from = alias.appendingPathComponent("source", isDirectory: true)
        let to = alias.appendingPathComponent("saved lesson", isDirectory: true)
        let receipt = try SessionTreeMigration.copyVerified(from: from, to: to)
        #expect(receipt.sourceDirectory == fixture.source)
        #expect(receipt.destinationDirectory == fixture.destination)
        #expect(try SessionTreeMigration.manifest(of: fixture.source) == receipt.entries)
    }

    @Test func splitCopyAndRetirementRetainsTheVerifiedOriginal() throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let receipt = try SessionTreeMigration.copyVerified(from: fixture.source, to: fixture.destination)
        #expect(fixture.exists(fixture.source))
        let retired = try SessionTreeMigration.retireVerifiedCopy(receipt)
        let preserved = try #require(retired.preservedSourceDirectory)
        #expect(!fixture.exists(fixture.source))
        #expect(try SessionTreeMigration.manifest(of: preserved) == receipt.entries)
        #expect(try SessionTreeMigration.manifest(of: fixture.destination) == receipt.entries)
        #expect(throws: SessionMigrationError.self) { try SessionTreeMigration.retireVerifiedCopy(retired) }
    }

    @Test func changedTreeBetweenCopyAndRetirementKeepsBothLocations() throws {
        for alterSource in [true, false] {
            let fixture = try Fixture(); defer { fixture.clean() }
            let receipt = try SessionTreeMigration.copyVerified(from: fixture.source, to: fixture.destination)
            let changed = alterSource ? fixture.source : fixture.destination
            try Data("late journal update".utf8).write(to: changed.appendingPathComponent("late.json"))
            #expect(throws: SessionMigrationError.self) { try SessionTreeMigration.retireVerifiedCopy(receipt) }
            #expect(fixture.exists(fixture.source))
            #expect(fixture.exists(fixture.destination))
            #expect(fixture.exists(changed.appendingPathComponent("late.json")))
        }
    }
}
