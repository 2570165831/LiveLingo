import Foundation
import XCTest
@testable import LiveLingo

final class TargetDefaultingTests: XCTestCase, @unchecked Sendable {
    func testOnlySimplifiedChineseIsReleased() {
        XCTAssertEqual(OutputLanguage.released, [.simplifiedChinese])
        XCTAssertEqual(OutputLanguage.simplifiedChinese.generationTarget, .simplifiedChinese)
        XCTAssertNil(OutputLanguage.simplifiedChinese.persistedLocale)
        XCTAssertEqual(OutputLanguage.simplifiedChinese.autonym, "简体中文")
        XCTAssertNil(OutputLanguage.releasedLanguage("en"))
        XCTAssertNil(OutputLanguage.releasedLanguage("unknown"))
    }

    func testPresentationAndSourceDefaultsMatchExplicitTarget() throws {
        for code in [nil, "zh", "yue", "ja", "es"] as [String?] {
            let segment = TranscriptSegment(startTime: 0, endTime: 2,
                english: code == "zh" ? "這片葉子長大了。" : "The leaf grows.", chinese: "叶子长大了。",
                sourceLanguage: code)
            XCTAssertEqual(CaptionPresentation(segment), CaptionPresentation(segment, target: .simplifiedChinese))
            XCTAssertEqual(SessionExporter.targetLine(segment), SessionExporter.targetLine(segment, target: .simplifiedChinese))
            XCTAssertEqual(SessionExporter.captionLines(segment), SessionExporter.captionLines(segment, target: .simplifiedChinese))
            XCTAssertEqual(SessionExporter.srtCue(segment, index: 0), SessionExporter.srtCue(segment, index: 0, target: .simplifiedChinese))
            XCTAssertEqual(LearningSourceUnit.make([segment]), LearningSourceUnit.make([segment], target: .simplifiedChinese))
            XCTAssertEqual(LectureSummaryInput.entryCharacters(for: segment),
                LectureSummaryInput.entryCharacters(for: segment, target: .simplifiedChinese))
            XCTAssertEqual(LectureSummaryInput.make(from: [segment]),
                LectureSummaryInput.make(from: [segment], target: .simplifiedChinese))
        }
        for language in SpokenLanguage.all {
            XCTAssertEqual(language.avoidsTranslation, language.avoidsTranslation(target: .simplifiedChinese))
        }
    }

    private actor Requests {
        var values: [String] = []
        func reply(_ input: String, prompt: String, budget: Int) -> String {
            values.append(input + "\n" + prompt + "\n" + String(budget))
            return "热量增加。"
        }
        func recorded() -> [String] { values }
    }

    func testRequestAndAcceptanceDefaultsMatchExplicitTarget() async throws {
        let requests = Requests()
        let request: QwenTranslationClient.AdjacentRequest = { input, prompt, budget in
            await requests.reply(input, prompt: prompt, budget: budget)
        }
        let implicit = try await QwenTranslationClient.translate("El calor aumenta.",
            modelName: QwenModelProfile.energySaver.translationModel, sourceLanguage: "es", request: request)
        let explicit = try await QwenTranslationClient.translate("El calor aumenta.",
            modelName: QwenModelProfile.energySaver.translationModel, sourceLanguage: "es",
            target: .simplifiedChinese, request: request)
        XCTAssertEqual(implicit, explicit)
        let calls = await requests.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first, calls.last)
        XCTAssertEqual(try TranslationAcceptance.validatedCaption(implicit, source: "El calor aumenta.", sourceLanguage: "es"),
            try TranslationAcceptance.validatedCaption(implicit, source: "El calor aumenta.", sourceLanguage: "es", target: .simplifiedChinese))
    }

    @MainActor
    func testExplicitTargetAdapterRetainsEnglishAndUnknownFallback() async throws {
        var adapter = CaptionTranslationDependencies.unavailable
        var sources: [String?] = []
        adapter.translateTarget = { _, _, source, target, _, _, _ in
            sources.append(source)
            XCTAssertEqual(target, .simplifiedChinese)
            return "热量增加。"
        }
        for source in [nil, "en", "unknown", "es"] as [String?] {
            _ = try await adapter.translateCaption("The heat increases.", "synthetic", [], .standard, nil,
                sourceLanguage: source, target: .simplifiedChinese)
        }
        XCTAssertEqual(sources, [nil, nil, nil, "es"])
    }

    func testExportDefaultMatchesExplicitTargetBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TargetDefaulting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let implicit = root.appendingPathComponent("implicit")
        let explicit = root.appendingPathComponent("explicit")
        let segment = TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startTime: 0, endTime: 2, english: "The leaf grows.", chinese: "叶子长大了。")
        let date = Date(timeIntervalSince1970: 1_000)
        try SessionExporter.export(segments: [segment], sessionDirectory: implicit, summary: "叶子", createdAt: date)
        try SessionExporter.export(segments: [segment], sessionDirectory: explicit, summary: "叶子", createdAt: date,
            target: .simplifiedChinese)
        let names = try FileManager.default.contentsOfDirectory(atPath: implicit.path).sorted()
        XCTAssertEqual(names, try FileManager.default.contentsOfDirectory(atPath: explicit.path).sorted())
        for name in names {
            XCTAssertEqual(try Data(contentsOf: implicit.appendingPathComponent(name)),
                try Data(contentsOf: explicit.appendingPathComponent(name)), name)
        }
    }
}
