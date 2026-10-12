import Foundation
import Testing
@testable import LiveLingo

/// Synthetic metadata only. Never launches capture, a model, or an old reader.
@Suite(.isolatedStorage)
struct SessionArchiveTests {
    private let date = Date(timeIntervalSince1970: 1_791_474_600)

    @Test func captureOffsetAcceptsBothClosedEndpointsAndHalfHours() throws {
        for (offset, label) in [(-18 * 3_600, "UTC-18"), (-19_800, "UTC-5:30"),
                                (0, "UTC+0"), (19_800, "UTC+5:30"), (18 * 3_600, "UTC+18")] {
            let start = try #require(SessionCaptureStart(date: date, utcOffsetSeconds: offset))
            #expect(start.utcOffsetSeconds == offset)
            #expect(start.utcOffsetLabel == label)
            #expect(start.timeZone.secondsFromGMT(for: date) == offset)
        }
    }

    // Run against the fixed source only. The pre-fix Int.min/abs regression
    // is demonstrated by static interception, never by executing that path.
    @Test(arguments: [Int.min, Int.max, -64_801, 64_801, -64_799, 64_799, -61, -1, 1, 61])
    func invalidCaptureOffsetsAreIgnored(offset: Int) throws {
        #expect(SessionCaptureStart(date: date, utcOffsetSeconds: offset) == nil)
        var snapshot = SessionSnapshot(createdAt: date)
        snapshot.captureStartedAt = date
        snapshot.captureUTCOffsetSeconds = offset
        try snapshot.validate()
        #expect(snapshot.captureStart == nil)
        let bytes = try SessionArchiveCoding.encode(snapshot)
        let decoded = try SessionArchiveCoding.decode(SessionSnapshot.self, from: bytes)
        #expect(decoded.captureStart == nil)
        #expect(decoded.captureUTCOffsetSeconds == offset, "Ignoring display metadata must not overwrite the stored value")
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: bytes) == 3)
    }

    @Test func captureDateAcceptsBothClosedEndpoints() throws {
        for interval in [-62_135_596_800.0, 253_402_300_799.999] {
            let boundary = Date(timeIntervalSince1970: interval)
            let start = try #require(SessionCaptureStart(date: boundary, utcOffsetSeconds: 0))
            #expect(start.date == boundary)
        }
        let first = Date(timeIntervalSince1970: -62_135_596_800)
        let last = Date(timeIntervalSince1970: 253_402_300_799.999)
        #expect(SessionCaptureStart(date: first, utcOffsetSeconds: -60) == nil)
        #expect(SessionCaptureStart(date: last, utcOffsetSeconds: 60) == nil)
        #expect(SessionCaptureStart(date: first, utcOffsetSeconds: 60) != nil)
        #expect(SessionCaptureStart(date: last, utcOffsetSeconds: -60) != nil)
    }

    @Test func outOfRangeAndNonfiniteCaptureDatesAreIgnoredBeforeFormatting() {
        for interval in [Double.nan, Double.infinity, -Double.infinity,
                         -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
                         -62_135_596_801.0, 253_402_300_800.0] {
            let invalidDate = Date(timeIntervalSince1970: interval)
            #expect(SessionCaptureStart(date: invalidDate, utcOffsetSeconds: 0) == nil)
            var snapshot = SessionSnapshot(createdAt: date)
            snapshot.captureStartedAt = invalidDate
            snapshot.captureUTCOffsetSeconds = 0
            #expect(snapshot.captureStart == nil)
        }
    }

    @Test func partialCaptureMetadataIsIgnoredButStillRequiresVersion3() throws {
        var snapshot = SessionSnapshot(createdAt: date)
        let fingerprint = try snapshot.inputFingerprint()
        #expect(snapshot.captureStart == nil)
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: SessionArchiveCoding.encode(snapshot)) == 1)
        snapshot.captureStartedAt = date
        #expect(snapshot.captureStart == nil)
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: SessionArchiveCoding.encode(snapshot)) == 3)
        snapshot.captureStartedAt = nil
        snapshot.captureUTCOffsetSeconds = 0
        #expect(snapshot.captureStart == nil)
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: SessionArchiveCoding.encode(snapshot)) == 3)
        #expect(try snapshot.inputFingerprint() == fingerprint)
        snapshot.captureStart = nil
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: SessionArchiveCoding.encode(snapshot)) == 1)
    }

    @Test func readerGatesKeepExistingVersionsAndDetectNestedOrNullTimeKeys() throws {
        let payloads: [(String, Int)] = [
            (#"{"schemaVersion":1,"processing":{"phase":"idle"}}"#, 1),
            (#"{"targetLocale":"en"}"#, 2),
            (#"{"items":[{"captureStartedAt":1791474600000}]}"#, 3),
            (#"{"items":[{"captureUTCOffsetSeconds":null}]}"#, 3),
            (#"{"targetLocale":"en","captureUTCOffsetSeconds":0}"#, 3)
        ]
        for (json, version) in payloads {
            #expect(try SessionArchiveCoding.minimumReaderVersion(for: Data(json.utf8)) == version)
        }
        for key in ["targetLocale", "sourceLanguage", "captionAnnotation", "translationFailures",
                    "pendingCaptionRepairs", "lastErrorSource", "captureError", "retireGenerationCheckpoint"] {
            let bytes = try JSONSerialization.data(withJSONObject: ["items": [[key: "synthetic"]]])
            #expect(try SessionArchiveCoding.minimumReaderVersion(for: bytes) == 2)
        }
        for version in 1...3 {
            let bytes = Data("{\"schemaVersion\":\(version)}".utf8)
            try SessionArchiveCoding.checkSchema(bytes)
        }
        #expect(throws: SessionStoreError.unsupportedSchema(4)) {
            try SessionArchiveCoding.checkSchema(Data(#"{"schemaVersion":4}"#.utf8))
        }
    }

    /// Only the old envelope gate is exercised: 0.2.0 accepts 1, pre-change
    /// lab accepts 1...2. No old snapshot decoder or formatter is executed.
    private func frozenReaderGate(_ bytes: Data, maximum: Int) throws {
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let version = try #require(object["schemaVersion"] as? Int)
        guard (1...maximum).contains(version) else { throw SessionStoreError.unsupportedSchema(version) }
    }

    @Test func savedTimeMetadataGatesOldReadersAndSurvivesJournalAndCheckpoint() throws {
        let root = TestFixtureDirectory.root.appendingPathComponent("P2d-time-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(directory: root)
        var snapshot = SessionSnapshot(createdAt: date)
        let captureStart = try #require(SessionCaptureStart(date: date, utcOffsetSeconds: 19_800))
        snapshot.captureStart = captureStart
        var saved = try store.save(snapshot)
        let file = root.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: file)
        for maximum in [1, 2] {
            #expect(throws: SessionStoreError.unsupportedSchema(3)) { try frozenReaderGate(bytes, maximum: maximum) }
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try store.load()?.captureStart == snapshot.captureStart)
        saved = try store.append(.processing(saved.processing), expectedRevision: saved.storageRevision)
        #expect(try store.load()?.captureStart == snapshot.captureStart)
        saved = try store.save(saved)
        #expect(saved.captureStart == snapshot.captureStart)
        let checkpointBytes = try Data(contentsOf: file)
        #expect(throws: SessionStoreError.unsupportedSchema(3)) { try frozenReaderGate(checkpointBytes, maximum: 2) }
    }

    @Test func snapshotsWithoutTimeKeepTheirLegacyEnvelopeVersions() throws {
        for (locale, version) in [(nil as String?, 1), ("en", 2)] {
            let root = TestFixtureDirectory.root.appendingPathComponent("P2d-legacy-\(UUID().uuidString)", isDirectory: true)
            let store = SessionStore(directory: root)
            let saved = try store.save(SessionSnapshot(createdAt: date, targetLocale: locale))
            let bytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(object["schemaVersion"] as? Int == version)
            try frozenReaderGate(bytes, maximum: 2)
            #expect(try store.load() == saved)
        }
    }
}
