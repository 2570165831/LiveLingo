import CryptoKit
import Foundation
import XCTest
@testable import LiveLingo

final class LanguageCompatibilityTests: XCTestCase, @unchecked Sendable {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let han = "\u{4E00}\u{4E01}"

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func record() -> TranscriptionWorkRecord {
        var value = TranscriptionWorkRecord(id: id, sessionID: session, ordinal: 0, audioFile: "chunk.wav",
            startFrame: 0, endFrame: 16000, sampleRate: 16000, start: 0, end: 1,
            captureStart: nil, captureEnd: nil, modelKey: "parakeet", fallbackModelKey: "1.7b", appleEvidence: "")
        value.status = .completed; value.text = "x"
        return value
    }
    private func segment(_ language: String? = nil, text: String = "x", chinese: String = "") -> TranscriptSegment {
        TranscriptSegment(id: id, startTime: 0, endTime: 1, english: text, chinese: chinese,
                          sessionID: session, sourceLanguage: language)
    }

    func testEnglishBytesMatchTheMeasuredEE06Baseline() throws {
        // Measured from the ee06eb2 declarations and CLI code with these exact
        // synthetic UUIDs, times and "x"; only hashes are retained as fixtures.
        let recordBytes = try encode(record()), segmentBytes = try encode(segment())
        XCTAssertEqual(digest(recordBytes), "8e477f56b0156f131738de64c199468c01957dc667395ceb01d136ca20e9b9ed")
        XCTAssertEqual(digest(segmentBytes), "185a776b856fdeb9ac1b134251347cc7a70189402d73981087dcd93edcecee35")
        XCTAssertEqual(try encode(JSONDecoder().decode(Legacy020.TranscriptionWorkRecord.self, from: recordBytes)), recordBytes)
        XCTAssertEqual(try encode(JSONDecoder().decode(Legacy020.TranscriptSegment.self, from: segmentBytes)), segmentBytes)
    }

    func testNewLanguagesRemainReadableByTheExact020Declarations() throws {
        for code in SpokenLanguage.all.map(\.code).filter({ $0 != "en" }) {
            var value = record(); value.textLanguage = code
            value.candidateText = "y"; value.candidateLanguage = code
            let bytes = try encode(value)
            let old = try JSONDecoder().decode(Legacy020.TranscriptionWorkRecord.self, from: bytes)
            XCTAssertEqual(old.status, .completed)
            XCTAssertEqual(old.text, value.text)
            XCTAssertEqual(old.candidateText, value.candidateText)
            XCTAssertEqual(try JSONDecoder().decode(TranscriptionWorkRecord.self, from: bytes), value)
            let caption = segment(code)
            let captionBytes = try encode(caption)
            let oldCaption = try JSONDecoder().decode(Legacy020.TranscriptSegment.self, from: captionBytes)
            XCTAssertEqual(oldCaption.english, caption.english)
            XCTAssertEqual(try JSONDecoder().decode(TranscriptSegment.self, from: captionBytes), caption)
        }
    }

    func testOptionalFieldsOnlyPersistSupportedNonEnglishCodes() throws {
        for code in [nil, "en", "xx", "zh-Hans", "ZH"] as [String?] {
            var value = record(); value.textLanguage = code; value.candidateLanguage = code
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(value)) as? [String: Any])
            XCTAssertNil(object["textLanguage"])
            XCTAssertNil(object["candidateLanguage"])
            let caption = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(segment(code))) as? [String: Any])
            XCTAssertNil(caption["sourceLanguage"])
        }
    }

    func testRecordLanguageInferenceRequiresCompletedHanContentAndNoMarker() throws {
        for status in [TranscriptionWorkRecord.Status.completed, .failed, .pending, .otherLanguage] {
            for text in [han, "x", ""] {
                var value = record(); value.status = status; value.text = text
                let decoded = try JSONDecoder().decode(TranscriptionWorkRecord.self, from: encode(value))
                XCTAssertEqual(decoded.textLanguage, status == .completed && text == han ? "zh" : nil)
                XCTAssertNil(decoded.candidateLanguage)
            }
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(record())) as? [String: Any])
        object["text"] = han
        object["textLanguage"] = "xx"; object["candidateLanguage"] = "xx"
        let unknown = try JSONDecoder().decode(TranscriptionWorkRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(unknown.textLanguage)
        XCTAssertNil(unknown.candidateLanguage)
        object["textLanguage"] = "yue"
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionWorkRecord.self,
            from: JSONSerialization.data(withJSONObject: object)).textLanguage, "yue")
    }

    func testSegmentInferenceRequiresCompletedIdenticalHanText() throws {
        for (text, translation, expected) in [(han, han, "zh" as String?), (han, "", nil),
                                             (han, "\u{4E02}\u{4E03}", nil), ("x", "x", nil)] {
            let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: encode(segment(text: text, chinese: translation)))
            XCTAssertEqual(decoded.sourceLanguage, expected)
        }
        var pending = segment(text: han, chinese: han)
        pending.beginTranslation()
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.self, from: encode(pending)).sourceLanguage)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(segment(text: han, chinese: han))) as? [String: Any])
        object["sourceLanguage"] = "xx"
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.self,
            from: JSONSerialization.data(withJSONObject: object)).sourceLanguage)
    }

    func testSameContentIgnoresOnlyMissingLanguageAndKeepsContentChecks() throws {
        let legacy = segment(), spanish = segment("es"), french = segment("fr")
        XCTAssertTrue(legacy.sameContent(as: spanish))
        XCTAssertTrue(spanish.sameContent(as: legacy))
        XCTAssertFalse(spanish.sameContent(as: french))
        XCTAssertFalse(legacy.sameContent(as: segment("es", text: "y")))
        var revised = legacy; revised.inputRevision += 1
        XCTAssertFalse(legacy.sameContent(as: revised))
        var translated = legacy; translated.completeTranslation(han)
        XCTAssertFalse(legacy.sameContent(as: translated))
        let cantonese = segment("yue", text: han, chinese: han)
        let old = try JSONDecoder().decode(Legacy020.TranscriptSegment.self, from: encode(cantonese))
        let inferred = try JSONDecoder().decode(TranscriptSegment.self, from: encode(old))
        XCTAssertEqual(inferred.sourceLanguage, "zh")
        XCTAssertTrue(cantonese.sameContent(as: inferred))
        XCTAssertTrue(inferred.sameContent(as: cantonese))
        let inferredWire = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(inferred)) as? [String: Any])
        XCTAssertNil(inferredWire["sourceLanguage"])
        XCTAssertNil(inferredWire["sourceLanguageWasInferred"])
        XCTAssertFalse(cantonese.sameContent(as: segment("zh", text: han, chinese: han)))
        let markedZh = segment("zh", text: han, chinese: han)
        XCTAssertEqual(inferred, markedZh) // decoding provenance is not content
    }

    func testOldInputRevisionReplaysAndRestoresChineseMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LanguageRevision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(directory: root)
        let original = segment("yue", text: han, chinese: han)
        let saved = try store.save(SessionSnapshot(sessionID: session, segments: [original]))
        let old = try JSONDecoder().decode(Legacy020.TranscriptSegment.self, from: encode(original))
        let predecessor = try JSONDecoder().decode(TranscriptSegment.self, from: encode(old))
        var replacement = predecessor; replacement.inputRevision = 1
        let change = SessionInputRevision(fromRevision: 0, toRevision: 1,
            previousSegment: predecessor, replacementSegment: replacement, reason: "synthetic")
        // Strip inferred metadata again so this event has the actual old shape on disk.
        var event = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(SessionJournalEvent.inputRevision(change))) as? [String: Any])
        var outer = try XCTUnwrap(event["inputRevision"] as? [String: Any])
        var payload = try XCTUnwrap(outer["_0"] as? [String: Any])
        for key in ["previousSegment", "replacementSegment"] {
            var caption = try XCTUnwrap(payload[key] as? [String: Any]); caption.removeValue(forKey: "sourceLanguage")
            payload[key] = caption
        }
        outer["_0"] = payload; event["inputRevision"] = outer
        let oldShape = try JSONDecoder().decode(SessionJournalEvent.self, from: JSONSerialization.data(withJSONObject: event))
        let appended = try store.append(oldShape)
        XCTAssertEqual(appended.inputRevision, saved.inputRevision + 1)
        let reopened = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(reopened.inputRevision, 1)
        XCTAssertEqual(reopened.segments[0].sourceLanguage, "zh")
        XCTAssertEqual(reopened.revisionHistory.count, 1)
    }

    func testWriterKeepsTheMarkedPredecessorWhenAnOldRevisionOmitsLanguage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LanguageWriter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = segment("es", chinese: han)
        let store = SessionStore(directory: root)
        let saved = try store.save(SessionSnapshot(sessionID: session, segments: [original]))
        let old = try JSONDecoder().decode(Legacy020.TranscriptSegment.self, from: encode(original))
        let previous = try JSONDecoder().decode(TranscriptSegment.self, from: encode(old))
        var replacement = previous; replacement.inputRevision = 1
        let change = SessionInputRevision(fromRevision: 0, toRevision: 1,
            previousSegment: previous, replacementSegment: replacement, reason: "synthetic")
        var desired = saved
        desired.inputRevision = 1; desired.segments = [replacement]; desired.revisionHistory = [change]
        let result = try await SessionArchiveWriter(directory: root, restored: saved).commit(desired)
        XCTAssertEqual(result.lastJournalSequence, saved.lastJournalSequence + 1)
        XCTAssertEqual(try store.load(), result)
    }
}

// The two structs below are copied verbatim from git show v0.2.0:, enclosed
// only in a namespace so their type names and decoding behavior stay intact.
private enum Legacy020 {
struct TranscriptionWorkRecord: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        case pending, active, retryWaiting, manualPending, completed, silent, failed
    }
    enum Attempt: String, Codable, Sendable { case initial, automaticRetry, manual }
    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    /// Relative to the journal directory, so moving a complete session is safe.
    let audioFile: String
    let startFrame: Int64
    let endFrame: Int64
    let sampleRate: Double
    let start: TimeInterval
    let end: TimeInterval
    let captureStart: TimeInterval?
    let captureEnd: TimeInterval?
    let modelKey: String
    let fallbackModelKey: String?
    let appleEvidence: String
    var recordingFile: String? = nil
    /// Only true after exact PCM comparison against the sealed session WAV.
    /// The original range can then be materialized for an explicit later retry.
    var audioRetired: Bool? = nil
    var status: Status = .pending
    var attempt: Attempt = .initial
    var automaticRetryCount = 0
    var manualRetryCount = 0
    var text: String?
    var candidateText: String?
    var candidateOrigin: String?
    var failure: String?
    var duration: TimeInterval { max(0, end - start) }
    var needsWork: Bool { [.pending, .active, .retryWaiting, .manualPending].contains(status) }
}


struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    enum TranslationState: String, Codable, Sendable {
        case pending, translating, completed, failed
    }

    let id: UUID
    let sessionID: UUID?
    var inputRevision: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let english: String
    var chinese: String {
        didSet { reconcileLegacyTranslation() }
    }
    private(set) var translationState: TranslationState
    private(set) var translationError: String?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        english: String,
        chinese: String = "",
        sessionID: UUID? = nil,
        inputRevision: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.inputRevision = max(0, inputRevision)
        self.startTime = max(0, startTime)
        self.endTime = max(startTime, endTime)
        self.english = english
        self.chinese = chinese
        self.translationState = .pending
        self.translationError = nil
        reconcileLegacyTranslation()
    }

    var hasUsableTranslation: Bool {
        translationState == .completed && !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One rendering rule for saved transcripts, the classroom and all exports.
    /// The floating window continues to use its separate initial translation.
    var displayChinese: String {
        switch translationState {
        case .completed: return chinese
        case .failed: return "（本段翻译未完成，可对照英文）"
        case .pending, .translating: return "（本段暂无译文）"
        }
    }

    mutating func beginTranslation() {
        translationState = .translating
        translationError = nil
    }

    mutating func completeTranslation(_ text: String) {
        chinese = text
    }

    mutating func failTranslation(_ error: String) {
        chinese = ""
        translationState = .failed
        translationError = error
    }

    mutating func deferTranslation() {
        guard translationState == .translating else { return }
        translationState = .pending
    }

    // This is the only compatibility boundary that interprets the old marker.
    // New failures store diagnostics separately from translated content.
    private mutating func reconcileLegacyTranslation() {
        let text = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[翻译失败：") {
            translationState = .failed
            translationError = String(text.dropFirst("[翻译失败：".count).dropLast(text.hasSuffix("]") ? 1 : 0))
        } else {
            translationState = text.isEmpty ? .pending : .completed
            translationError = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, inputRevision, startTime, endTime, english, chinese, translationState, translationError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID)
        inputRevision = try values.decodeIfPresent(Int.self, forKey: .inputRevision) ?? 0
        startTime = try values.decode(TimeInterval.self, forKey: .startTime)
        endTime = try values.decode(TimeInterval.self, forKey: .endTime)
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime >= startTime, inputRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .startTime, in: values,
                                                   debugDescription: "Invalid transcript time range or revision")
        }
        english = try values.decode(String.self, forKey: .english)
        chinese = try values.decodeIfPresent(String.self, forKey: .chinese) ?? ""
        translationState = .pending
        translationError = nil
        reconcileLegacyTranslation()
        if let storedState = try values.decodeIfPresent(TranslationState.self, forKey: .translationState) {
            guard storedState != .completed || hasUsableTranslation else {
                throw DecodingError.dataCorruptedError(forKey: .translationState, in: values,
                                                       debugDescription: "Completed translation has no usable content")
            }
            translationState = storedState
            translationError = try values.decodeIfPresent(String.self, forKey: .translationError)
        }
    }
}

}
