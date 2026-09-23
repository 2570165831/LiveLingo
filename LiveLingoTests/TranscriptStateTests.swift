import XCTest
@testable import LiveLingo

final class TranscriptStateTests: XCTestCase {
    func testLegacyFailureRestoresExplicitStateAndSafeDisplay() throws {
        let data = Data(#"{"id":"EA655B70-3B10-4B24-B8F0-C36BCCBCBC82","startTime":0,"endTime":3,"english":"Heat moves.","chinese":"[翻译失败：budget exhausted]"}"#.utf8)
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertEqual(segment.translationState, .failed)
        XCTAssertEqual(segment.translationError, "budget exhausted")
        XCTAssertFalse(segment.hasUsableTranslation)
        XCTAssertEqual(segment.displayChinese, "（本段翻译未完成，可对照英文）")
    }

    func testFailureRoundTripDoesNotPutDiagnosticsInChineseBody() throws {
        var segment = TranscriptSegment(startTime: 2, endTime: 4, english: "Work is energy transfer.")
        segment.beginTranslation()
        XCTAssertEqual(segment.translationState, .translating)
        segment.failTranslation("worker exited")
        XCTAssertTrue(segment.chinese.isEmpty)
        let restored = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(segment))
        XCTAssertEqual(restored, segment)
        XCTAssertFalse(restored.displayChinese.contains("worker exited"))
    }

    func testSuccessfulRetryRetainsIdentityAndClearsFailure() throws {
        let sessionID = UUID()
        var segment = TranscriptSegment(startTime: 2, endTime: 4, english: "Work is energy transfer.",
                                        sessionID: sessionID, inputRevision: 3)
        let id = segment.id
        segment.failTranslation("timeout")
        segment.beginTranslation()
        segment.completeTranslation("功是能量的传递。")
        XCTAssertEqual(segment.id, id)
        XCTAssertEqual(segment.sessionID, sessionID)
        XCTAssertEqual(segment.inputRevision, 3)
        XCTAssertTrue(segment.hasUsableTranslation)
        XCTAssertNil(segment.translationError)
        XCTAssertEqual(segment.displayChinese, "功是能量的传递。")
    }

    func testInterruptedTranslationCanReturnToPendingWithoutLosingEnglish() {
        var segment = TranscriptSegment(startTime: 0, endTime: 2, english: "The speed is constant.")
        segment.beginTranslation()
        segment.deferTranslation()
        XCTAssertEqual(segment.translationState, .pending)
        XCTAssertEqual(segment.english, "The speed is constant.")
    }

    func testMalformedSavedTimesAreRejected() {
        let data = Data(#"{"id":"EA655B70-3B10-4B24-B8F0-C36BCCBCBC82","startTime":4,"endTime":2,"english":"text","chinese":"文字"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TranscriptSegment.self, from: data))
    }
}
