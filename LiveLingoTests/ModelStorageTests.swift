import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LiveLingo

/// All bytes, receipts, links and locks belong to UUID-named synthetic fixtures.
/// Leave fixtures in the test runner's temporary directory for inspection; never
/// launch a runtime, use an application container, or delete fixture evidence.
@MainActor
final class ModelStorageTests: XCTestCase {
    private static let algorithm = "first-middle-last-64KiB-v1"
    private static let smallContents: [(String, Data)] = [
        ("config.json", Data("{\"synthetic\":true}".utf8)),
        ("weights/model.bin", Data((0..<4096).map { UInt8($0 % 251) })),
        ("weights/empty.bin", Data())
    ]

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Calculate the published sampling format independently of verifyFile.
    private static func sampleHash(_ data: Data) -> String {
        if data.count <= 1 << 20 { return hash(data) }
        let window = 64 << 10
        let offsets = [0, (data.count - window) / 2, data.count - window]
        var sampled = Data()
        for offset in offsets { sampled.append(data.subdata(in: offset..<(offset + window))) }
        return hash(sampled)
    }

    private static func entry(_ path: String, _ data: Data) -> ModelStorageManifest.File {
        .init(path: path, size: Int64(data.count), sha256: hash(data), sampleSHA256: sampleHash(data))
    }

    private static func inventory(_ models: [ModelStorageManifest.Model], schema: Int = 1,
                                  algorithm: String = ModelStorageTests.algorithm, limit: Int = 1 << 20) -> ModelStorageManifest {
        .init(schemaVersion: schema, sampleAlgorithm: algorithm, fullHashMaxBytes: limit, models: models)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let bundled: URL
        let source: URL
        let destination: URL
        let model: ModelStorageManifest.Model
        let manifestDigest: String
        let contents: [(String, Data)]

        init(_ label: String, contents: [(String, Data)] = ModelStorageTests.smallContents,
             omitting: Set<String> = []) throws {
            // Resolving the test runner's temporary root avoids system aliases
            // while retaining FileManager.temporaryDirectory isolation.
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ModelStorageTests-\(label)-\(UUID().uuidString)", isDirectory: true)
            bundled = root.appendingPathComponent("BundledModels", isDirectory: true)
            source = bundled.appendingPathComponent("tiny-source", isDirectory: true)
            destination = root.appendingPathComponent("DestinationModels", isDirectory: true)
            self.contents = contents
            let files = contents.map { ModelStorageTests.entry($0.0, $0.1) }
            let identity = files.map { "\($0.path):\($0.size):\($0.sha256)" }.joined(separator: "\n")
            model = .init(name: "TinyModel", version: "sha256-" + ModelStorageTests.hash(Data(identity.utf8)),
                          sourceRelativePath: "tiny-source", files: files)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            manifestDigest = ModelStorageTests.hash(try encoder.encode(ModelStorageTests.inventory([model])))
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            for (path, bytes) in contents where !omitting.contains(path) {
                let url = source.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try bytes.write(to: url)
            }
        }

        var parent: URL { destination.appendingPathComponent(model.name, isDirectory: true) }
        var committed: URL { parent.appendingPathComponent(model.version, isDirectory: true) }
        var receipt: ModelStorage.Receipt {
            .init(schemaVersion: 1, model: model.name, version: model.version,
                  manifestSHA256: manifestDigest, verification: .sampledPrecloneV1)
        }

        func preclone(operations: ModelStorage.Operations = .init()) throws -> ModelStorage.Outcome {
            try ModelStorage.preclone(model, manifestSHA256: manifestDigest,
                                      bundledModels: bundled, destinationModels: destination, operations: operations)
        }

        func requireAPFS() throws {
            var info = statfs()
            let directory = try ModelStorage.Directory.open(root, owned: true)
            guard fstatfs(directory.fd, &info) == 0 else { throw ModelStorage.Failure.system(errno) }
            let capacity = MemoryLayout.size(ofValue: info.f_fstypename)
            let type = withUnsafePointer(to: &info.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            guard type == "apfs" else { throw XCTSkip("Real clone fixture requires APFS; temporary root uses \(type)") }
        }

        func names(_ prefix: String) throws -> [URL] {
            guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.path < $1.path }
        }

        func partials() throws -> [URL] { try names(".partial-" + model.version + "-") }
        func retained() throws -> [URL] { try names(".retained-" + model.version + "-") }

        @discardableResult
        func seedPartial(marker: Data?, suffix: String = UUID().uuidString,
                         version: String? = nil, bytes: Data = Data("uncommitted synthetic evidence".utf8)) throws -> URL {
            let partial = parent.appendingPathComponent(".partial-\(version ?? model.version)-\(suffix)", isDirectory: true)
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            if let marker { try marker.write(to: partial.appendingPathComponent(ModelStorage.receiptName)) }
            try bytes.write(to: partial.appendingPathComponent("orphan.bin"))
            return partial
        }
    }

    private func changedModel(_ model: ModelStorageManifest.Model, name: String? = nil,
                              version: String? = nil, source: String? = nil,
                              files: [ModelStorageManifest.File]? = nil) -> ModelStorageManifest.Model {
        .init(name: name ?? model.name, version: version ?? model.version,
              sourceRelativePath: source ?? model.sourceRelativePath, files: files ?? model.files)
    }

    private func assertFailure(_ expected: ModelStorage.Failure, file: StaticString = #filePath,
                               line: UInt = #line, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? ModelStorage.Failure, expected, file: file, line: line)
        }
    }

    private func assertOriginal(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, bytes) in fixture.contents {
            XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent(path)), bytes, path, file: file, line: line)
        }
    }

    private func assertCommitted(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, bytes) in fixture.contents {
            let target = fixture.committed.appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: target), bytes, path, file: file, line: line)
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, file: file, line: line)
        }
        let marker = try JSONDecoder().decode(ModelStorage.Receipt.self,
            from: Data(contentsOf: fixture.committed.appendingPathComponent(ModelStorage.receiptName)))
        XCTAssertEqual(marker, fixture.receipt, file: file, line: line)
    }

    private func assertNoCommit(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        var info = stat()
        XCTAssertEqual(lstat(fixture.committed.path, &info), -1, file: file, line: line)
        XCTAssertEqual(errno, ENOENT, file: file, line: line)
    }

    private func verifyFile(_ url: URL, entry: ModelStorageManifest.File,
                            mode: ModelStorage.Verification, checkpoint: () throws -> Void = {}) throws {
        let parent = try ModelStorage.Directory.open(url.deletingLastPathComponent(), owned: true)
        let fd = try parent.file(url.lastPathComponent)
        defer { _ = Darwin.close(fd) }
        try ModelStorage.verifyFile(entry, fd: fd, verification: mode, checkpoint: checkpoint)
    }

    private func assertLink(_ url: URL, target: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0, file: file, line: line)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK, file: file, line: line)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path, file: file, line: line)
    }

    func testValidManifestRoundTripsNestedAndEmptySyntheticFiles() throws {
        let fixture = try Fixture("valid-manifest")
        let manifest = Self.inventory([fixture.model])
        let decoded = try ModelStorageManifest.decode(JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.models, [fixture.model])
        XCTAssertEqual(decoded.sampleAlgorithm, Self.algorithm)
        XCTAssertEqual(decoded.fullHashMaxBytes, 1 << 20)
    }

    func testManifestRejectsIllegalSchemaAlgorithmLimitAndEmptyInventory() throws {
        let fixture = try Fixture("schema")
        let manifests = [Self.inventory([fixture.model], schema: 0), Self.inventory([fixture.model], schema: 2),
                         Self.inventory([fixture.model], algorithm: "other"), Self.inventory([fixture.model], limit: 0),
                         Self.inventory([])]
        for manifest in manifests {
            assertFailure(.manifest) { _ = try ModelStorageManifest.decode(JSONEncoder().encode(manifest)) }
        }
    }

    func testManifestRejectsUnsafeModelNamesVersionsAndSourcePaths() throws {
        let fixture = try Fixture("model-paths")
        for name in ["", ".", "..", "../escape", "a/b", "a\\b", "with space", "模型", String(repeating: "a", count: 181)] {
            let model = changedModel(fixture.model, name: name)
            assertFailure(.manifest) { try Self.inventory([model]).validate() }
        }
        for version in ["", "sha256-", "v1", "sha256-" + String(repeating: "A", count: 64), "sha256-../escape"] {
            let model = changedModel(fixture.model, version: version)
            assertFailure(.manifest) { try Self.inventory([model]).validate() }
        }
        for path in ["", "/absolute", "../escape", "a/../b", "a//b", "a/", "./a", "a\\b", "a\u{0}b"] {
            let model = changedModel(fixture.model, source: path)
            assertFailure(.manifest) { try Self.inventory([model]).validate() }
        }
    }

    func testManifestRejectsUnsafeFilePathsAndReservedReceiptFile() throws {
        let fixture = try Fixture("file-paths")
        for path in ["", "/absolute", "../escape", "a/../b", "a//b", "a/", "./a", "a\\b", "a\u{0}b", ModelStorage.receiptName] {
            let model = changedModel(fixture.model, files: [Self.entry(path, Data("synthetic".utf8))])
            assertFailure(.manifest) { try Self.inventory([model]).validate() }
        }
    }

    func testManifestRejectsReceiptFileUsedAsDirectoryPrefix() throws {
        let fixture = try Fixture("receipt-prefix")
        let model = changedModel(fixture.model, files: [Self.entry(ModelStorage.receiptName + "/weights.bin", Data([1, 2, 3]))])
        // Regression: the receipt is a regular file written before model data.
        // Accepting it as a directory ancestor creates an unusable inventory.
        assertFailure(.manifest) { try Self.inventory([model]).validate() }
    }

    func testManifestRejectsMalformedDigestsNegativeSizeAndConflictingSmallHash() throws {
        let fixture = try Fixture("digest")
        let good = fixture.model.files[0]
        for digest in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                       String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            for file in [ModelStorageManifest.File(path: good.path, size: good.size, sha256: digest, sampleSHA256: good.sampleSHA256),
                         .init(path: good.path, size: good.size, sha256: good.sha256, sampleSHA256: digest)] {
                assertFailure(.manifest) { try Self.inventory([changedModel(fixture.model, files: [file])]).validate() }
            }
        }
        for file in [ModelStorageManifest.File(path: good.path, size: -1, sha256: good.sha256, sampleSHA256: good.sha256),
                     .init(path: good.path, size: good.size, sha256: good.sha256, sampleSHA256: Self.hash(Data("different".utf8)))] {
            assertFailure(.manifest) { try Self.inventory([changedModel(fixture.model, files: [file])]).validate() }
        }
    }

    func testManifestRejectsDuplicateModelsSourcesAndFiles() throws {
        let fixture = try Fixture("duplicates")
        for models in [[fixture.model, changedModel(fixture.model, source: "another-source")],
                       [fixture.model, changedModel(fixture.model, name: "AnotherModel")]] {
            assertFailure(.manifest) { try Self.inventory(models).validate() }
        }
        let duplicateFile = changedModel(fixture.model, files: [fixture.model.files[0], fixture.model.files[0]])
        assertFailure(.manifest) { try Self.inventory([duplicateFile]).validate() }
        assertFailure(.manifest) { try Self.inventory([changedModel(fixture.model, files: [])]).validate() }
    }

    func testManifestRejectsFileDirectoryPrefixCollisionInEitherOrder() throws {
        let fixture = try Fixture("prefix")
        let ancestor = Self.entry("weights", Data([1]))
        let child = Self.entry("weights/nested/data.bin", Data([2]))
        for files in [[ancestor, child], [child, ancestor]] {
            assertFailure(.manifest) { try Self.inventory([changedModel(fixture.model, files: files)]).validate() }
        }
        let distinct = [Self.entry("weights", Data([1])), Self.entry("weights-other/data.bin", Data([2]))]
        XCTAssertNoThrow(try Self.inventory([changedModel(fixture.model, files: distinct)]).validate())
    }

    func testPrecloneRejectsInvalidConstructedModelAndManifestDigestBeforeIO() throws {
        let fixture = try Fixture("invalid-before-io")
        var calls = 0
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in calls += 1; XCTFail("Invalid manifest must not clone") }
        operations.checkpoint = { XCTFail("Invalid manifest must fail before checkpoints") }
        for (model, digest) in [(changedModel(fixture.model, source: "../escape"), fixture.manifestDigest),
                                (fixture.model, "not-a-digest")] {
            assertFailure(.manifest) {
                _ = try ModelStorage.preclone(model, manifestSHA256: digest, bundledModels: fixture.bundled,
                    destinationModels: fixture.destination, operations: operations)
            }
        }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try assertOriginal(fixture)
    }

    func testRealAPFSCloneProducesByteIdenticalNestedModelAndReceipt() throws {
        let fixture = try Fixture("real-apfs")
        try fixture.requireAPFS()
        let native = ModelStorage.Operations().clone
        var clonedNames: [String] = []
        var operations = ModelStorage.Operations()
        operations.clone = { source, parent, name in
            clonedNames.append(name)
            try native(source, parent, name)
        }
        XCTAssertEqual(try fixture.preclone(operations: operations), .cloned)
        XCTAssertEqual(clonedNames, fixture.model.files.map { ($0.path as NSString).lastPathComponent })
        try assertOriginal(fixture)
        try assertCommitted(fixture)
        XCTAssertEqual(try fixture.partials(), [])
        XCTAssertEqual(try fixture.retained(), [])
        let directory = try ModelStorage.Directory.open(fixture.committed, owned: true)
        XCTAssertNoThrow(try ModelStorage.verify(fixture.model, at: directory, verification: .fullSHA256, checkpoint: {}))
    }

    func testRepeatLaunchVerifiesExistingModelWithoutAnotherClone() throws {
        let fixture = try Fixture("repeat")
        try fixture.requireAPFS()
        XCTAssertEqual(try fixture.preclone(), .cloned)
        var before = stat()
        XCTAssertEqual(lstat(fixture.committed.path, &before), 0)
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("An existing verified model must not clone again"); throw ModelStorage.Failure.system(EIO) }
        XCTAssertEqual(try fixture.preclone(operations: operations), .alreadyPresent)
        var after = stat()
        XCTAssertEqual(lstat(fixture.committed.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        try assertCommitted(fixture)
        try assertOriginal(fixture)
        XCTAssertEqual(try fixture.partials(), [])
    }

    func testChangedWholeManifestDigestReusesVersionAfterCurrentInventoryVerification() throws {
        let fixture = try Fixture("changed-whole-manifest")
        try fixture.requireAPFS()
        XCTAssertEqual(try fixture.preclone(), .cloned)
        let receiptURL = fixture.committed.appendingPathComponent(ModelStorage.receiptName)
        let originalReceipt = try Data(contentsOf: receiptURL)
        let added = changedModel(fixture.model, name: "AdditionalModel", source: "additional-source")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let currentDigest = Self.hash(try encoder.encode(Self.inventory([fixture.model, added])))
        XCTAssertNotEqual(currentDigest, fixture.manifestDigest)
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("Changing another model's inventory must not reclone this version") }
        XCTAssertEqual(try ModelStorage.preclone(fixture.model, manifestSHA256: currentDigest,
            bundledModels: fixture.bundled, destinationModels: fixture.destination, operations: operations), .alreadyPresent)
        XCTAssertEqual(try Data(contentsOf: receiptURL), originalReceipt)
        try assertCommitted(fixture)
        // A compatible old receipt is insufficient: every file must still be
        // checked against the CURRENT inventory rather than trusted by version.
        let first = fixture.model.files[0]
        let different = Data(repeating: 0xff, count: Int(first.size))
        let changedFile = Self.entry(first.path, different)
        let changedFiles = [changedFile] + Array(fixture.model.files.dropFirst())
        let incompatible = changedModel(fixture.model, files: changedFiles)
        let incompatibleDigest = Self.hash(try encoder.encode(Self.inventory([incompatible, added])))
        assertFailure(.mismatch) {
            _ = try ModelStorage.preclone(incompatible, manifestSHA256: incompatibleDigest,
                bundledModels: fixture.bundled, destinationModels: fixture.destination, operations: operations)
        }
        XCTAssertEqual(try Data(contentsOf: receiptURL), originalReceipt)
        try assertCommitted(fixture)
        try assertOriginal(fixture)
    }

    private func cloneFailure(_ code: Int32, label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try Fixture(label)
        var calls = 0
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in calls += 1; throw ModelStorage.Failure.system(code) }
        assertFailure(.system(code), file: file, line: line) { _ = try fixture.preclone(operations: operations) }
        XCTAssertEqual(calls, 1, "A failed clone must neither retry nor fall back to copying", file: file, line: line)
        assertNoCommit(fixture, file: file, line: line)
        let partial = try XCTUnwrap(try fixture.partials().only, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partial.path), [ModelStorage.receiptName], file: file, line: line)
        XCTAssertEqual(try JSONDecoder().decode(ModelStorage.Receipt.self,
            from: Data(contentsOf: partial.appendingPathComponent(ModelStorage.receiptName))), fixture.receipt, file: file, line: line)
        XCTAssertEqual(try fixture.retained(), [], file: file, line: line)
        try assertOriginal(fixture, file: file, line: line)
        let lock = Darwin.open(fixture.parent.appendingPathComponent(".preclone-lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw ModelStorage.Failure.system(errno) }
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0, "Failure must release the model lock", file: file, line: line)
    }

    func testCloneEXDEVNeverCopiesOrPublishes() throws { try cloneFailure(EXDEV, label: "exdev") }
    func testCloneENOSPCNeverCopiesOrPublishes() throws { try cloneFailure(ENOSPC, label: "enospc") }
    func testCloneEIONeverCopiesOrPublishes() throws { try cloneFailure(EIO, label: "eio") }

    func testInitialCheckpointCancellationDoesNotCreateDestination() throws {
        let fixture = try Fixture("cancel-before-io")
        var operations = ModelStorage.Operations()
        operations.checkpoint = { throw CancellationError() }
        operations.clone = { _, _, _ in XCTFail("Cancelled staging must not clone") }
        XCTAssertThrowsError(try fixture.preclone(operations: operations)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        try assertOriginal(fixture)
    }

    func testInterruptedCheckpointRetainsPartialAndNextLaunchQuarantinesIt() throws {
        let fixture = try Fixture("interrupt-and-relaunch")
        try fixture.requireAPFS()
        let native = ModelStorage.Operations().clone
        var count = 0
        var operations = ModelStorage.Operations()
        operations.clone = { source, parent, name in try native(source, parent, name); count += 1 }
        operations.checkpoint = { if count == 1 { throw ModelStorage.Failure.deferred } }
        assertFailure(.deferred) { _ = try fixture.preclone(operations: operations) }
        XCTAssertEqual(count, 1)
        assertNoCommit(fixture)
        let abandoned = try XCTUnwrap(try fixture.partials().only)
        let first = fixture.contents[0]
        let marker = try Data(contentsOf: abandoned.appendingPathComponent(ModelStorage.receiptName))
        XCTAssertEqual(try Data(contentsOf: abandoned.appendingPathComponent(first.0)), first.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.appendingPathComponent(fixture.contents[1].0).path))
        var originalIdentity = stat()
        XCTAssertEqual(lstat(abandoned.path, &originalIdentity), 0)
        XCTAssertEqual(try fixture.preclone(), .cloned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        let retained = try XCTUnwrap(try fixture.retained().only)
        var retainedIdentity = stat()
        XCTAssertEqual(lstat(retained.path, &retainedIdentity), 0)
        XCTAssertEqual(originalIdentity.st_ino, retainedIdentity.st_ino)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(ModelStorage.receiptName)), marker)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(first.0)), first.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.appendingPathComponent(fixture.contents[1].0).path))
        XCTAssertEqual(try fixture.partials(), [])
        try assertCommitted(fixture)
        try assertOriginal(fixture)
    }

    func testRecoveryMovesOnlyPartialWithValidOwnedReceipt() throws {
        let fixture = try Fixture("receipt-recovery")
        try fixture.requireAPFS()
        let marker = try JSONEncoder().encode(fixture.receipt)
        let valid = try fixture.seedPartial(marker: marker)
        var original = stat()
        XCTAssertEqual(lstat(valid.path, &original), 0)
        let foreignReceipts: [ModelStorage.Receipt] = [
            .init(schemaVersion: 2, model: fixture.model.name, version: fixture.model.version, manifestSHA256: fixture.manifestDigest, verification: .sampledPrecloneV1),
            .init(schemaVersion: 1, model: "OtherModel", version: fixture.model.version, manifestSHA256: fixture.manifestDigest, verification: .sampledPrecloneV1),
            .init(schemaVersion: 1, model: fixture.model.name, version: "sha256-" + Self.hash(Data("other-version".utf8)), manifestSHA256: fixture.manifestDigest, verification: .sampledPrecloneV1),
            .init(schemaVersion: 1, model: fixture.model.name, version: fixture.model.version, manifestSHA256: "invalid-digest", verification: .sampledPrecloneV1),
            .init(schemaVersion: 1, model: fixture.model.name, version: fixture.model.version, manifestSHA256: fixture.manifestDigest, verification: .fullSHA256)
        ]
        var unknown: [URL] = []
        for receipt in foreignReceipts { unknown.append(try fixture.seedPartial(marker: JSONEncoder().encode(receipt))) }
        unknown.append(try fixture.seedPartial(marker: nil))
        unknown.append(try fixture.seedPartial(marker: Data("not JSON".utf8)))
        unknown.append(try fixture.seedPartial(marker: marker, suffix: "not-a-UUID"))
        unknown.append(try fixture.seedPartial(marker: marker, version: "sha256-" + Self.hash(Data("older-version".utf8))))
        let before = try unknown.map { try Data(contentsOf: $0.appendingPathComponent("orphan.bin")) }
        XCTAssertEqual(try fixture.preclone(), .cloned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
        let retained = try XCTUnwrap(try fixture.retained().only)
        var after = stat()
        XCTAssertEqual(lstat(retained.path, &after), 0)
        XCTAssertEqual(original.st_ino, after.st_ino)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(ModelStorage.receiptName)), marker)
        for (index, url) in unknown.enumerated() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("orphan.bin")), before[index])
        }
        try assertCommitted(fixture)
    }

    func testRecoveryRetainsOwnedPartialFromDifferentWholeManifestDigest() throws {
        let fixture = try Fixture("partial-prior-manifest")
        try fixture.requireAPFS()
        let prior = ModelStorage.Receipt(schemaVersion: 1, model: fixture.model.name, version: fixture.model.version,
                                        manifestSHA256: Self.hash(Data("prior synthetic inventory".utf8)), verification: .sampledPrecloneV1)
        XCTAssertNotEqual(prior.manifestSHA256, fixture.manifestDigest)
        let marker = try JSONEncoder().encode(prior)
        let partial = try fixture.seedPartial(marker: marker)
        let bytes = try Data(contentsOf: partial.appendingPathComponent("orphan.bin"))
        XCTAssertEqual(try fixture.preclone(), .cloned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let retained = try XCTUnwrap(try fixture.retained().only)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(ModelStorage.receiptName)), marker)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("orphan.bin")), bytes)
        try assertCommitted(fixture)
    }

    func testRecoveryLeavesPartialSymlinksReceiptSymlinksAndRegularFilesUntouched() throws {
        let fixture = try Fixture("unknown-links")
        try fixture.requireAPFS()
        try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: true)
        let external = fixture.root.appendingPathComponent("SyntheticNeighbor", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let marker = try JSONEncoder().encode(fixture.receipt)
        let externalMarker = external.appendingPathComponent(ModelStorage.receiptName)
        try marker.write(to: externalMarker)
        let canary = Data("synthetic neighbor must remain untouched".utf8)
        try canary.write(to: external.appendingPathComponent("canary.bin"))
        let prefix = ".partial-" + fixture.model.version + "-"
        let directoryLink = fixture.parent.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: external)
        let danglingLink = fixture.parent.appendingPathComponent(prefix + UUID().uuidString)
        let missing = fixture.root.appendingPathComponent("missing-synthetic-neighbor")
        try FileManager.default.createSymbolicLink(at: danglingLink, withDestinationURL: missing)
        let receiptLinkPartial = try fixture.seedPartial(marker: nil)
        let receiptLink = receiptLinkPartial.appendingPathComponent(ModelStorage.receiptName)
        try FileManager.default.createSymbolicLink(at: receiptLink, withDestinationURL: externalMarker)
        let regular = fixture.parent.appendingPathComponent(prefix + UUID().uuidString)
        try canary.write(to: regular)
        XCTAssertEqual(try fixture.preclone(), .cloned)
        try assertLink(directoryLink, target: external)
        try assertLink(danglingLink, target: missing)
        try assertLink(receiptLink, target: externalMarker)
        XCTAssertEqual(try Data(contentsOf: regular), canary)
        XCTAssertEqual(try Data(contentsOf: externalMarker), marker)
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("canary.bin")), canary)
        XCTAssertEqual(try fixture.retained(), [])
        try assertCommitted(fixture)
    }

    func testExistingModelRecoveryStillRetainsOwnedPartialWithoutRecloning() throws {
        let fixture = try Fixture("existing-recovery")
        try fixture.requireAPFS()
        XCTAssertEqual(try fixture.preclone(), .cloned)
        let partial = try fixture.seedPartial(marker: JSONEncoder().encode(fixture.receipt))
        let bytes = try Data(contentsOf: partial.appendingPathComponent("orphan.bin"))
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("Recovery beside a committed model must not clone") }
        XCTAssertEqual(try fixture.preclone(operations: operations), .alreadyPresent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let retained = try XCTUnwrap(try fixture.retained().only)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("orphan.bin")), bytes)
        try assertCommitted(fixture)
    }

    func testLargeFileSampleAndFullSHA256BothMatchIndependentDigests() throws {
        let bytes = Data((0..<((2 << 20) + 17)).map { UInt8($0 % 251) })
        let fixture = try Fixture("large-pristine", contents: [("weights.bin", bytes)])
        let file = fixture.model.files[0]
        XCTAssertNotEqual(file.sha256, file.sampleSHA256)
        try verifyFile(fixture.source.appendingPathComponent(file.path), entry: file, mode: .sampledPrecloneV1)
        try verifyFile(fixture.source.appendingPathComponent(file.path), entry: file, mode: .fullSHA256)
    }

    func testFullSHA256DetectsUnsampledSameLengthDamageThatPrecloneSamplingAllows() throws {
        let bytes = Data(repeating: 0x5a, count: (2 << 20) + 17)
        let fixture = try Fixture("unsampled-damage", contents: [("weights.bin", bytes)])
        try fixture.requireAPFS()
        var damaged = bytes
        damaged[128 << 10] ^= 0xff // Outside all three 64 KiB sample windows.
        XCTAssertEqual(Self.sampleHash(damaged), Self.sampleHash(bytes))
        XCTAssertNotEqual(Self.hash(damaged), Self.hash(bytes))
        try damaged.write(to: fixture.source.appendingPathComponent("weights.bin"))
        XCTAssertEqual(try fixture.preclone(), .cloned)
        let committed = try ModelStorage.Directory.open(fixture.committed, owned: true)
        XCTAssertNoThrow(try ModelStorage.verify(fixture.model, at: committed, verification: .sampledPrecloneV1, checkpoint: {}))
        assertFailure(.mismatch) { try ModelStorage.verify(fixture.model, at: committed, verification: .fullSHA256, checkpoint: {}) }
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("Repeat launch must not clone a sample-verified model") }
        XCTAssertEqual(try fixture.preclone(operations: operations), .alreadyPresent)
        XCTAssertEqual(try Data(contentsOf: fixture.committed.appendingPathComponent("weights.bin")), damaged)
    }

    func testSamplingDetectsDamageInEachWindow() throws {
        let bytes = Data(repeating: 0x37, count: (2 << 20) + 17)
        let window = 64 << 10
        for offset in [0, (bytes.count - window) / 2, bytes.count - window] {
            let fixture = try Fixture("sample-window-\(offset)", contents: [("weights.bin", bytes)])
            var damaged = bytes
            damaged[offset] ^= 0xff
            try damaged.write(to: fixture.source.appendingPathComponent("weights.bin"))
            assertFailure(.mismatch) {
                try verifyFile(fixture.source.appendingPathComponent("weights.bin"), entry: fixture.model.files[0], mode: .sampledPrecloneV1)
            }
        }
    }

    func testSmallFileSamplingUsesCompleteHashAndDetectsInteriorDamage() throws {
        let bytes = Data(repeating: 0x33, count: 1 << 20)
        let fixture = try Fixture("small-full-hash", contents: [("weights.bin", bytes)])
        var damaged = bytes
        damaged[128 << 10] ^= 0xff
        try damaged.write(to: fixture.source.appendingPathComponent("weights.bin"))
        XCTAssertEqual(fixture.model.files[0].sha256, fixture.model.files[0].sampleSHA256)
        assertFailure(.mismatch) {
            try verifyFile(fixture.source.appendingPathComponent("weights.bin"), entry: fixture.model.files[0], mode: .sampledPrecloneV1)
        }
    }

    func testFullHashHonorsCheckpointCancellationBetweenReadChunks() throws {
        let bytes = Data(repeating: 0x44, count: (2 << 20) + 17)
        let fixture = try Fixture("hash-cancel", contents: [("weights.bin", bytes)])
        var checkpoints = 0
        XCTAssertThrowsError(try verifyFile(fixture.source.appendingPathComponent("weights.bin"),
            entry: fixture.model.files[0], mode: .fullSHA256, checkpoint: {
                checkpoints += 1
                if checkpoints == 2 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checkpoints, 2)
        try assertOriginal(fixture)
    }

    func testSourceSizeMismatchFailsBeforeCloneAndPreservesReceiptOnlyPartial() throws {
        for bytes in [Data(), Data("too-long-synthetic-model-data".utf8)] {
            let fixture = try Fixture("source-size", contents: [("weights.bin", Data([1, 2, 3]))])
            try bytes.write(to: fixture.source.appendingPathComponent("weights.bin"))
            var operations = ModelStorage.Operations()
            operations.clone = { _, _, _ in XCTFail("Wrong source size must fail before clone") }
            assertFailure(.mismatch) { _ = try fixture.preclone(operations: operations) }
            assertNoCommit(fixture)
            let partial = try XCTUnwrap(try fixture.partials().only)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partial.path), [ModelStorage.receiptName])
            XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("weights.bin")), bytes)
        }
    }

    func testSourceSameLengthHashMismatchNeverPublishes() throws {
        let fixture = try Fixture("source-hash", contents: [("weights.bin", Data([1, 2, 3]))])
        try fixture.requireAPFS()
        let changed = Data([1, 9, 3])
        try changed.write(to: fixture.source.appendingPathComponent("weights.bin"))
        assertFailure(.mismatch) { _ = try fixture.preclone() }
        assertNoCommit(fixture)
        let partial = try XCTUnwrap(try fixture.partials().only)
        XCTAssertEqual(try Data(contentsOf: partial.appendingPathComponent("weights.bin")), changed)
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("weights.bin")), changed)
    }

    func testClonedSizeAndHashDamageNeverPublishesOrChangesSource() throws {
        for truncate in [true, false] {
            let fixture = try Fixture("target-damage", contents: [("weights.bin", Data([1, 2, 3]))])
            try fixture.requireAPFS()
            let native = ModelStorage.Operations().clone
            var operations = ModelStorage.Operations()
            operations.clone = { source, parent, name in
                try native(source, parent, name)
                let fd = openat(parent, name, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ModelStorage.Failure.system(errno) }
                defer { _ = Darwin.close(fd) }
                if truncate {
                    guard ftruncate(fd, 2) == 0 else { throw ModelStorage.Failure.system(errno) }
                } else {
                    var byte: UInt8 = 0xff
                    guard pwrite(fd, &byte, 1, 1) == 1 else { throw ModelStorage.Failure.system(errno) }
                }
            }
            assertFailure(.mismatch) { _ = try fixture.preclone(operations: operations) }
            assertNoCommit(fixture)
            XCTAssertEqual(try fixture.partials().count, 1)
            try assertOriginal(fixture)
        }
    }

    func testVerifyRejectsFirstFileReplacementAfterHashBeforeSecondFile() throws {
        let firstBytes = Data([1, 2, 3, 4])
        let secondBytes = Data([5, 6, 7, 8])
        let damagedBytes = Data([1, 0, 3, 4])
        let fixture = try Fixture("verified-file-replaced", contents: [
            ("first.bin", firstBytes), ("second.bin", secondBytes)
        ])
        try fixture.requireAPFS()
        XCTAssertEqual(try fixture.preclone(), .cloned)
        try assertCommitted(fixture)
        let directory = try ModelStorage.Directory.open(fixture.committed, owned: true)
        let firstURL = fixture.committed.appendingPathComponent("first.bin")
        let preserved = fixture.root.appendingPathComponent("preserved-verified-first.bin")
        var before = stat()
        XCTAssertEqual(lstat(firstURL.path, &before), 0)
        XCTAssertEqual(damagedBytes.count, firstBytes.count)
        XCTAssertNotEqual(damagedBytes, firstBytes)
        var checkpoints = 0
        var injected = false
        XCTAssertThrowsError(try ModelStorage.verify(fixture.model, at: directory, verification: .fullSHA256,
            checkpoint: {
                checkpoints += 1
                // 1: first file boundary; 2: its data read; 3: its EOF read;
                // 4: second file boundary, after the first hash was accepted.
                if checkpoints == 4 {
                    try FileManager.default.moveItem(at: firstURL, to: preserved)
                    try damagedBytes.write(to: firstURL)
                    injected = true
                }
            })) { error in
                let failure = error as? ModelStorage.Failure
                XCTAssertTrue(failure == .mismatch || failure == .unsafePath,
                              "Reject changed file identity or its changed directory snapshot: \(error)")
            }
        XCTAssertTrue(injected, "The replacement must occur after accepting the first file's hash")
        XCTAssertGreaterThanOrEqual(checkpoints, 4)
        var kept = stat(), replaced = stat()
        XCTAssertEqual(lstat(preserved.path, &kept), 0)
        XCTAssertEqual(lstat(firstURL.path, &replaced), 0)
        XCTAssertEqual(kept.st_dev, before.st_dev)
        XCTAssertEqual(kept.st_ino, before.st_ino)
        XCTAssertNotEqual(replaced.st_ino, before.st_ino)
        XCTAssertEqual(kept.st_size, replaced.st_size)
        XCTAssertEqual(try Data(contentsOf: preserved), firstBytes)
        XCTAssertEqual(try Data(contentsOf: firstURL), damagedBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.committed.appendingPathComponent("second.bin")), secondBytes)
        try assertOriginal(fixture)
    }

    func testExistingDamagedFileOrUnexpectedEntryFailsWithoutReclone() throws {
        for unexpected in [false, true] {
            let fixture = try Fixture("existing-damage")
            try fixture.requireAPFS()
            XCTAssertEqual(try fixture.preclone(), .cloned)
            let url = fixture.committed.appendingPathComponent(unexpected ? "unexpected.bin" : fixture.contents[0].0)
            let bytes = unexpected ? Data("preserve unexpected synthetic evidence".utf8)
                : Data(repeating: 0xff, count: fixture.contents[0].1.count)
            try bytes.write(to: url)
            var operations = ModelStorage.Operations()
            operations.clone = { _, _, _ in XCTFail("An invalid existing version must not be replaced") }
            assertFailure(.mismatch) { _ = try fixture.preclone(operations: operations) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try fixture.partials(), [])
            try assertOriginal(fixture)
        }
    }

    func testExistingReceiptMismatchFailsWithoutOverwritingModel() throws {
        let fixture = try Fixture("existing-receipt")
        try fixture.requireAPFS()
        XCTAssertEqual(try fixture.preclone(), .cloned)
        let wrong = ModelStorage.Receipt(schemaVersion: 1, model: fixture.model.name, version: fixture.model.version,
                                        manifestSHA256: "invalid-digest", verification: .sampledPrecloneV1)
        let bytes = try JSONEncoder().encode(wrong)
        let receiptURL = fixture.committed.appendingPathComponent(ModelStorage.receiptName)
        try bytes.write(to: receiptURL)
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("Receipt mismatch must not replace a version") }
        assertFailure(.mismatch) { _ = try fixture.preclone(operations: operations) }
        XCTAssertEqual(try Data(contentsOf: receiptURL), bytes)
        for (path, original) in fixture.contents { XCTAssertEqual(try Data(contentsOf: fixture.committed.appendingPathComponent(path)), original) }
        XCTAssertEqual(try fixture.partials(), [])
    }

    func testSourceRootAndModelDirectorySymlinksAreRejectedBeforeClone() throws {
        for rootLink in [true, false] {
            let fixture = try Fixture("source-directory-link")
            let link = fixture.root.appendingPathComponent("source-alias")
            let target = rootLink ? fixture.bundled : fixture.source
            let alias = rootLink ? link : fixture.bundled.appendingPathComponent("linked-model")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            let model = rootLink ? fixture.model : changedModel(fixture.model, source: "linked-model")
            var operations = ModelStorage.Operations()
            operations.clone = { _, _, _ in XCTFail("Source directory symlinks must not reach clone") }
            XCTAssertThrowsError(try ModelStorage.preclone(model, manifestSHA256: fixture.manifestDigest,
                bundledModels: rootLink ? alias : fixture.bundled, destinationModels: fixture.destination, operations: operations))
            try assertLink(alias, target: target)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            try assertOriginal(fixture)
        }
    }

    func testSourceFileSymlinkIsRejectedAndSyntheticNeighborIsUnchanged() throws {
        let fixture = try Fixture("source-file-link", contents: [("weights.bin", Data([1, 2, 3]))], omitting: ["weights.bin"])
        let neighbor = fixture.root.appendingPathComponent("neighbor.bin")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: neighbor)
        let link = fixture.source.appendingPathComponent("weights.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: neighbor)
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("Source file symlinks must not reach clone") }
        XCTAssertThrowsError(try fixture.preclone(operations: operations))
        assertNoCommit(fixture)
        try assertLink(link, target: neighbor)
        XCTAssertEqual(try Data(contentsOf: neighbor), bytes)
        let partial = try XCTUnwrap(try fixture.partials().only)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.appendingPathComponent("weights.bin").path))
    }

    func testSourceNestedDirectorySymlinkIsRejected() throws {
        let fixture = try Fixture("source-nested-link", contents: [("weights/model.bin", Data([4, 5, 6]))], omitting: ["weights/model.bin"])
        let neighbor = fixture.root.appendingPathComponent("neighbor", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: false)
        let bytes = Data([4, 5, 6])
        try bytes.write(to: neighbor.appendingPathComponent("model.bin"))
        let link = fixture.source.appendingPathComponent("weights")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: neighbor)
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("Nested source links must not reach clone") }
        XCTAssertThrowsError(try fixture.preclone(operations: operations))
        assertNoCommit(fixture)
        try assertLink(link, target: neighbor)
        XCTAssertEqual(try Data(contentsOf: neighbor.appendingPathComponent("model.bin")), bytes)
    }

    func testSourceHardlinkIsRejectedWithoutCloning() throws {
        let fixture = try Fixture("source-hardlink", contents: [("weights.bin", Data([1, 2, 3]))])
        let alias = fixture.root.appendingPathComponent("hardlink-neighbor.bin")
        try FileManager.default.linkItem(at: fixture.source.appendingPathComponent("weights.bin"), to: alias)
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("A hardlinked source must not clone") }
        assertFailure(.unsafePath) { _ = try fixture.preclone(operations: operations) }
        assertNoCommit(fixture)
        XCTAssertEqual(try Data(contentsOf: alias), fixture.contents[0].1)
        try assertOriginal(fixture)
    }

    func testDestinationRootAndModelParentSymlinksAreRejectedWithoutNeighborWrites() throws {
        for rootLink in [true, false] {
            let fixture = try Fixture("destination-directory-link")
            let neighbor = fixture.root.appendingPathComponent("neighbor", isDirectory: true)
            try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let bytes = Data("synthetic protected neighbor".utf8)
            try bytes.write(to: neighbor.appendingPathComponent("canary.bin"))
            if !rootLink { try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false) }
            let alias = rootLink ? fixture.destination : fixture.parent
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: neighbor)
            var operations = ModelStorage.Operations()
            operations.clone = { _, _, _ in XCTFail("Destination symlinks must not reach clone") }
            XCTAssertThrowsError(try fixture.preclone(operations: operations))
            try assertLink(alias, target: neighbor)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: neighbor.path), ["canary.bin"])
            XCTAssertEqual(try Data(contentsOf: neighbor.appendingPathComponent("canary.bin")), bytes)
            try assertOriginal(fixture)
        }
    }

    func testCommittedVersionSymlinkIsRejectedWithoutFollowingIt() throws {
        let fixture = try Fixture("version-link")
        try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: true)
        let neighbor = fixture.root.appendingPathComponent("neighbor", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: false)
        let marker = try JSONEncoder().encode(fixture.receipt)
        try marker.write(to: neighbor.appendingPathComponent(ModelStorage.receiptName))
        try FileManager.default.createSymbolicLink(at: fixture.committed, withDestinationURL: neighbor)
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("An existing version symlink must not be followed or replaced") }
        XCTAssertThrowsError(try fixture.preclone(operations: operations))
        try assertLink(fixture.committed, target: neighbor)
        XCTAssertEqual(try Data(contentsOf: neighbor.appendingPathComponent(ModelStorage.receiptName)), marker)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: neighbor.path), [ModelStorage.receiptName])
        XCTAssertEqual(try fixture.partials(), [])
    }

    func testLockSymlinkIsRejectedWithoutTouchingNeighbor() throws {
        let fixture = try Fixture("lock-link")
        try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: true)
        let neighbor = fixture.root.appendingPathComponent("neighbor-lock.bin")
        let bytes = Data("synthetic neighbor lock".utf8)
        try bytes.write(to: neighbor)
        let link = fixture.parent.appendingPathComponent(".preclone-lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: neighbor)
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("Unsafe lock must fail before clone") }
        XCTAssertThrowsError(try fixture.preclone(operations: operations))
        try assertLink(link, target: neighbor)
        XCTAssertEqual(try Data(contentsOf: neighbor), bytes)
        XCTAssertEqual(try fixture.partials(), [])
        assertNoCommit(fixture)
    }

    func testCloneInjectedTargetFileSymlinkCannotModifyNeighborPermissionsOrBytes() throws {
        let fixture = try Fixture("target-file-link", contents: [("weights.bin", Data([1, 2, 3]))])
        let neighbor = fixture.root.appendingPathComponent("neighbor.bin")
        let bytes = Data("synthetic neighbor bytes".utf8)
        try bytes.write(to: neighbor)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: neighbor.path)
        let before = try FileManager.default.attributesOfItem(atPath: neighbor.path)[.posixPermissions] as? NSNumber
        var operations = ModelStorage.Operations()
        operations.clone = { _, parent, name in
            guard symlinkat(neighbor.path, parent, name) == 0 else { throw ModelStorage.Failure.system(errno) }
        }
        XCTAssertThrowsError(try fixture.preclone(operations: operations))
        assertNoCommit(fixture)
        let partial = try XCTUnwrap(try fixture.partials().only)
        try assertLink(partial.appendingPathComponent("weights.bin"), target: neighbor)
        XCTAssertEqual(try Data(contentsOf: neighbor), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: neighbor.path)[.posixPermissions] as? NSNumber, before)
        try assertOriginal(fixture)
    }

    func testCheckpointInjectedTargetNestedSymlinkCannotWriteOutsideStaging() throws {
        let fixture = try Fixture("target-nested-link", contents: [("weights/model.bin", Data([1, 2, 3]))])
        let neighbor = fixture.root.appendingPathComponent("neighbor", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: false)
        let bytes = Data("synthetic neighbor canary".utf8)
        try bytes.write(to: neighbor.appendingPathComponent("canary.bin"))
        var injected: URL?
        var operations = ModelStorage.Operations()
        operations.clone = { _, _, _ in XCTFail("A redirected nested target must not clone") }
        operations.checkpoint = {
            if injected == nil, let partial = try fixture.partials().only,
               FileManager.default.fileExists(atPath: partial.appendingPathComponent(ModelStorage.receiptName).path) {
                let link = partial.appendingPathComponent("weights")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: neighbor)
                injected = link
            }
        }
        XCTAssertThrowsError(try fixture.preclone(operations: operations))
        assertNoCommit(fixture)
        try assertLink(XCTUnwrap(injected), target: neighbor)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: neighbor.path), ["canary.bin"])
        XCTAssertEqual(try Data(contentsOf: neighbor.appendingPathComponent("canary.bin")), bytes)
        try assertOriginal(fixture)
    }

    func testReplacedStagingDirectoryCannotBePublished() throws {
        let fixture = try Fixture("staging-replaced", contents: [("weights.bin", Data([1, 2, 3]))])
        try fixture.requireAPFS()
        let neighbor = fixture.root.appendingPathComponent("neighbor", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: false)
        let bytes = Data("synthetic untouched neighbor".utf8)
        try bytes.write(to: neighbor.appendingPathComponent("canary.bin"))
        let preserved = fixture.parent.appendingPathComponent("synthetic-replaced-staging", isDirectory: true)
        var oldName: URL?
        let native = ModelStorage.Operations().clone
        var operations = ModelStorage.Operations()
        operations.clone = { source, parent, name in
            let partial = try XCTUnwrap(try fixture.partials().only)
            try FileManager.default.moveItem(at: partial, to: preserved)
            try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: neighbor)
            oldName = partial
            try native(source, parent, name) // Open descriptor still names the preserved synthetic directory.
        }
        assertFailure(.unsafePath) { _ = try fixture.preclone(operations: operations) }
        assertNoCommit(fixture)
        try assertLink(XCTUnwrap(oldName), target: neighbor)
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("weights.bin")), fixture.contents[0].1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: neighbor.path), ["canary.bin"])
        XCTAssertEqual(try Data(contentsOf: neighbor.appendingPathComponent("canary.bin")), bytes)
        try assertOriginal(fixture)
    }

    func testCloneTimeModelParentReplacementCannotReportCloned() throws {
        let fixture = try Fixture("model-parent-replaced", contents: [("weights.bin", Data([1, 2, 3]))])
        try fixture.requireAPFS()
        let preservedParent = fixture.destination.appendingPathComponent("synthetic-original-model-parent", isDirectory: true)
        let canary = Data("synthetic replacement directory must remain untouched".utf8)
        let native = ModelStorage.Operations().clone
        var stagedName: String?
        var operations = ModelStorage.Operations()
        operations.clone = { source, parent, name in
            stagedName = try XCTUnwrap(try fixture.partials().only).lastPathComponent
            try FileManager.default.moveItem(at: fixture.parent, to: preservedParent)
            try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: false)
            try canary.write(to: fixture.parent.appendingPathComponent("canary.bin"))
            try native(source, parent, name)
        }
        assertFailure(.unsafePath) { _ = try fixture.preclone(operations: operations) }
        assertNoCommit(fixture)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path), ["canary.bin"])
        XCTAssertEqual(try Data(contentsOf: fixture.parent.appendingPathComponent("canary.bin")), canary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preservedParent.appendingPathComponent(fixture.model.version).path))
        let preservedStage = preservedParent.appendingPathComponent(try XCTUnwrap(stagedName), isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: preservedStage.appendingPathComponent("weights.bin")), fixture.contents[0].1)
        XCTAssertEqual(try JSONDecoder().decode(ModelStorage.Receipt.self,
            from: Data(contentsOf: preservedStage.appendingPathComponent(ModelStorage.receiptName))), fixture.receipt)
        try assertOriginal(fixture)
    }

    func testPostPublicationModelParentReplacementCannotReportCloned() throws {
        let fixture = try Fixture("published-parent-replaced", contents: [("weights.bin", Data([1, 2, 3]))])
        try fixture.requireAPFS()
        let preservedParent = fixture.destination.appendingPathComponent("preserved-published-model-parent", isDirectory: true)
        let canary = Data("synthetic replacement parent must remain untouched".utf8)
        var injected = false
        var publishedIdentity: stat?
        var operations = ModelStorage.Operations()
        operations.checkpoint = {
            if !injected, FileManager.default.fileExists(atPath: fixture.committed.path) {
                var info = stat()
                guard lstat(fixture.committed.path, &info) == 0 else { throw ModelStorage.Failure.system(errno) }
                publishedIdentity = info
                try FileManager.default.moveItem(at: fixture.parent, to: preservedParent)
                try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: false)
                try canary.write(to: fixture.parent.appendingPathComponent("canary.bin"))
                injected = true
            }
        }
        assertFailure(.unsafePath) { _ = try fixture.preclone(operations: operations) }
        XCTAssertTrue(injected, "The checkpoint must run after the formal version directory first appears")
        assertNoCommit(fixture)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path), ["canary.bin"])
        XCTAssertEqual(try Data(contentsOf: fixture.parent.appendingPathComponent("canary.bin")), canary)
        let preservedVersion = preservedParent.appendingPathComponent(fixture.model.version, isDirectory: true)
        var retainedIdentity = stat()
        XCTAssertEqual(lstat(preservedVersion.path, &retainedIdentity), 0)
        let originalIdentity = try XCTUnwrap(publishedIdentity)
        XCTAssertEqual(retainedIdentity.st_dev, originalIdentity.st_dev)
        XCTAssertEqual(retainedIdentity.st_ino, originalIdentity.st_ino)
        XCTAssertEqual(try Data(contentsOf: preservedVersion.appendingPathComponent("weights.bin")), fixture.contents[0].1)
        XCTAssertEqual(try JSONDecoder().decode(ModelStorage.Receipt.self,
            from: Data(contentsOf: preservedVersion.appendingPathComponent(ModelStorage.receiptName))), fixture.receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedParent.appendingPathComponent(".preclone-lock").path))
        try assertOriginal(fixture)
    }

    func testPhaseGateAllowsIdleSavedFailedAndDefersCapturePhases() {
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-saved-phase")
        for phase in [AppPhase.idle, .saved(saved), .liveEnded, .failed("synthetic failure")] {
            XCTAssertFalse(ModelPrecloneController.blocksPreclone(phase), String(describing: phase))
        }
        for phase in [AppPhase.preparing, .recording, .paused, .stopping] {
            XCTAssertTrue(ModelPrecloneController.blocksPreclone(phase), String(describing: phase))
        }
    }

    func testInitiallyBlockedGateDefersBeforeCreatingDestination() throws {
        let fixture = try Fixture("initial-gate")
        let gate = ModelPrecloneGate()
        var operations = ModelStorage.Operations()
        operations.checkpoint = { try gate.checkpoint() }
        operations.clone = { _, _, _ in XCTFail("Blocked preclone must not clone") }
        assertFailure(.deferred) { _ = try fixture.preclone(operations: operations) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        gate.setBlocked(false)
        XCTAssertNoThrow(try gate.checkpoint())
        gate.setBlocked(true)
        assertFailure(.deferred) { try gate.checkpoint() }
    }

    func testRecordingGateDefersInFlightCloneAndIdleRetryPreservesPartial() throws {
        let fixture = try Fixture("recording-gate")
        try fixture.requireAPFS()
        let gate = ModelPrecloneGate()
        gate.setBlocked(ModelPrecloneController.blocksPreclone(.idle))
        let native = ModelStorage.Operations().clone
        var calls = 0
        var operations = ModelStorage.Operations()
        operations.checkpoint = { try gate.checkpoint() }
        operations.clone = { source, parent, name in
            try native(source, parent, name)
            calls += 1
            gate.setBlocked(ModelPrecloneController.blocksPreclone(.recording))
        }
        assertFailure(.deferred) { _ = try fixture.preclone(operations: operations) }
        XCTAssertEqual(calls, 1)
        assertNoCommit(fixture)
        let partial = try XCTUnwrap(try fixture.partials().only)
        let original = try Data(contentsOf: partial.appendingPathComponent(fixture.contents[0].0))
        gate.setBlocked(ModelPrecloneController.blocksPreclone(.idle))
        operations.clone = native
        XCTAssertEqual(try fixture.preclone(operations: operations), .cloned)
        let retained = try XCTUnwrap(try fixture.retained().only)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(fixture.contents[0].0)), original)
        try assertCommitted(fixture)
        try assertOriginal(fixture)
    }

    func testDistinctVersionsCoexistWithoutChangingOlderModelOrPartial() throws {
        let first = try Fixture("version-one", contents: [("weights.bin", Data([1, 2, 3]))])
        let second = try Fixture("version-two", contents: [("weights.bin", Data([4, 5, 6]))])
        try first.requireAPFS()
        try second.requireAPFS()
        XCTAssertNotEqual(first.model.version, second.model.version)
        XCTAssertEqual(try first.preclone(), .cloned)
        let oldMarker = try Data(contentsOf: first.committed.appendingPathComponent(ModelStorage.receiptName))
        let oldPartial = try first.seedPartial(marker: JSONEncoder().encode(first.receipt))
        let partialBytes = try Data(contentsOf: oldPartial.appendingPathComponent("orphan.bin"))
        XCTAssertEqual(try ModelStorage.preclone(second.model, manifestSHA256: second.manifestDigest,
            bundledModels: second.bundled, destinationModels: first.destination), .cloned)
        try assertCommitted(first)
        XCTAssertEqual(try Data(contentsOf: first.committed.appendingPathComponent(ModelStorage.receiptName)), oldMarker)
        XCTAssertEqual(try Data(contentsOf: oldPartial.appendingPathComponent("orphan.bin")), partialBytes)
        let secondVersion = first.parent.appendingPathComponent(second.model.version, isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: secondVersion.appendingPathComponent("weights.bin")), second.contents[0].1)
        XCTAssertEqual(try JSONDecoder().decode(ModelStorage.Receipt.self,
            from: Data(contentsOf: secondVersion.appendingPathComponent(ModelStorage.receiptName))), second.receipt)
        XCTAssertEqual(try first.retained(), [])
        try assertOriginal(first)
        try assertOriginal(second)
    }

    func testIndependentLockDescriptorsAndSecondInstanceCannotCloneSameModel() throws {
        let fixture = try Fixture("multi-instance-lock", contents: [("weights.bin", Data([1, 2, 3]))])
        try fixture.requireAPFS()
        let otherVersion = changedModel(fixture.model, version: "sha256-" + Self.hash(Data("competing version".utf8)))
        let native = ModelStorage.Operations().clone
        var competed = false
        var operations = ModelStorage.Operations()
        operations.clone = { source, parent, name in
            let lockURL = fixture.parent.appendingPathComponent(".preclone-lock")
            let competing = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard competing >= 0 else { throw ModelStorage.Failure.system(errno) }
            defer { _ = Darwin.close(competing) }
            XCTAssertEqual(flock(competing, LOCK_EX | LOCK_NB), -1)
            let lockError = errno
            XCTAssertTrue(lockError == EWOULDBLOCK || lockError == EAGAIN)
            let partialsBefore = try fixture.partials()
            let markerBefore = try Data(contentsOf: XCTUnwrap(partialsBefore.only).appendingPathComponent(ModelStorage.receiptName))
            var rejectedOperations = ModelStorage.Operations()
            rejectedOperations.clone = { _, _, _ in XCTFail("A competing instance must never clone") }
            for model in [fixture.model, otherVersion] {
                self.assertFailure(.busy) {
                    _ = try ModelStorage.preclone(model, manifestSHA256: fixture.manifestDigest,
                        bundledModels: fixture.bundled, destinationModels: fixture.destination, operations: rejectedOperations)
                }
            }
            XCTAssertEqual(try fixture.partials(), partialsBefore)
            XCTAssertEqual(try fixture.retained(), [])
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(partialsBefore.only).appendingPathComponent(ModelStorage.receiptName)), markerBefore)
            competed = true
            try native(source, parent, name)
        }
        XCTAssertEqual(try fixture.preclone(operations: operations), .cloned)
        XCTAssertTrue(competed)
        try assertCommitted(fixture)
        let lock = Darwin.open(fixture.parent.appendingPathComponent(".preclone-lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw ModelStorage.Failure.system(errno) }
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0, "Successful publication must release the instance lock")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
