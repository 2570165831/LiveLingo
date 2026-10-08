import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class TraditionalCLIRoutingTests: XCTestCase {
    private func fixture() throws -> (AppModel, ChineseScriptConverter, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraditionalCLI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "LiveLingo-Test-" + UUID().uuidString
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Rejected CLI runs must not start a model")
                throw CancellationError()
            }
        let missing = ChineseScriptConverter(resourceDirectory: nil)
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults,
            chineseScriptConverter: missing)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove()
            try FileManager.default.removeItem(at: root)
        }
        return (model, missing, root)
    }

    func testTraditionalCLIOptInPreflightsMissingDictionaryBeforeChangingSessionOrPreparingModels() throws {
        let (model, converter, root) = try fixture()
        XCTAssertEqual(OutputLanguage.cliGenerationLanguages, [.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
        for target in [OutputLanguage.traditionalChineseTaiwan, .traditionalChineseHongKong] {
            let directory = root.appendingPathComponent(target.rawValue)
            let phase = model.phase
            do {
                try model.preflightCLIGeneration(target: target)
                XCTFail("CLI must reject missing dictionaries")
            } catch ChineseScriptConverter.Failure.resourcesMissing {
                XCTAssertEqual(model.phase, phase)
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            }
            XCTAssertTrue(target.isReleased)
            XCTAssertEqual(model.outputLanguage, .simplifiedChinese)
        }
        XCTAssertEqual(converter.debugLoadCount, 1)
    }

    func testLatinCLIReleaseGuardRemainsUnchangedWithoutLoadingChineseResources() throws {
        let (model, converter, _) = try fixture()
        for target in [OutputLanguage.english, .spanish, .french] {
            do {
                try model.preflightCLIGeneration(target: target)
                XCTFail("Unreleased target was accepted")
            } catch SessionStoreError.invalidState(let message) {
                XCTAssertEqual(message, "输出语言尚未开放")
            }
        }
        XCTAssertEqual(converter.debugLoadCount, 0)
        XCTAssertEqual(model.outputLanguage, .simplifiedChinese)
    }
}
