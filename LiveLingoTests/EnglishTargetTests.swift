import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class EnglishTargetTests: XCTestCase {
    func testOptionalAnnotationsPreserveDefaultBytesAndRoundTripLatinMetadata() throws {
        var segment = TranscriptSegment(startTime: 0, endTime: 1, english: "An uncertain formula.")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let baseline = try encoder.encode(segment)
        segment.updateCaptionAnnotation(targetCode: "zh-Hans", formulaUncertain: true)
        XCTAssertEqual(try encoder.encode(segment), baseline)
        XCTAssertNil(segment.captionAnnotation)
        segment.completeTranslation("【公式待核对】公式。")
        XCTAssertEqual(segment.chinese, "【公式待核对】公式。")
        XCTAssertNil(segment.captionAnnotation)
        for target in ["en", "es", "fr"] {
            var marked = TranscriptSegment(startTime: 0, endTime: 1, english: "An uncertain formula.")
            marked.updateCaptionAnnotation(targetCode: target)
            XCTAssertEqual(marked.captionAnnotation, .translationPending)
            XCTAssertEqual(marked.chinese, "")
            marked.completeTranslation("【公式待核对】Formula.", targetCode: target)
            XCTAssertEqual(marked.chinese, "Formula.")
            XCTAssertEqual(marked.captionAnnotation, .formulaNeedsReview)
            XCTAssertEqual(marked.annotationText(targetCode: target), "【公式待核对】")
            XCTAssertEqual(try JSONDecoder().decode(TranscriptSegment.self, from: encoder.encode(marked)), marked)
            marked.recordTranslationFailure(.translationRejected)
            marked.finishFailedTranslation()
            marked.updateCaptionAnnotation(targetCode: target)
            XCTAssertEqual(marked.chinese, "")
            XCTAssertEqual(marked.captionAnnotation, .translationIncomplete)
        }
    }

    func testFixedTextDefaultsToInterfaceChineseWithoutEnteringCaptionBody() {
        XCTAssertFalse(ClassroomFixedText.usesTargetLanguage)
        XCTAssertEqual(ClassroomFixedText.pendingTranslation.text(targetCode: "en"), "（本段暂无译文）")
        XCTAssertEqual(ClassroomFixedText.pendingTranslation.text(targetCode: "en", useTargetLanguage: true), "(Translation pending)")
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "水很冷。", sourceLanguage: "zh")
        XCTAssertEqual(segment.chinese, "")
        XCTAssertEqual(SessionExporter.targetLine(segment, outputLanguage: .english), "（本段暂无译文）")
    }
}
