import Foundation

#if QUALITY_PROBE_TESTS
/// Runs the actual quality CLI with injected generation and offline preparation.
/// No AppModel, model weights, runtime process, or GPU is invoked by this main.
@main
struct LearningQualityTargetCLITests {
    enum Failure: Error { case assertion(String) }
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard value() else { throw Failure.assertion(message) }
    }
    static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        else { throw Failure.assertion("JSON object") }
        return value
    }
    struct FrozenProducer: Encodable {
        let executableSHA256: String
        let promptSHA256: String
        let sourceRepresentation: String
        let sourcePolicy: String
        let batchCharacters: Int
        let displayContract: String
        let generationOrigin: String
        let buildManifestSHA256: String?
    }
    @MainActor static func main() async {
        do { try await run() }
        catch {
            fputs("Target quality CLI regression failed: \(error)\n", stderr)
            exit(1)
        }
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("new output directory argument") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw Failure.assertion("new output directory") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let frozen = FrozenProducer(executableSHA256: String(repeating: "a", count: 64),
            promptSHA256: String(repeating: "b", count: 64), sourceRepresentation: "revisioned",
            sourcePolicy: "fixture-uuid-v1/12s-start/10s-duration/revision-0/session-none",
            batchCharacters: 1200, displayContract: "production-point-and-rendered-membership-v1",
            generationOrigin: "synthetic-regression", buildManifestSHA256: nil)
        let current = LearningQualityCLI.Producer(executableSHA256: frozen.executableSHA256,
            promptSHA256: frozen.promptSHA256, sourceRepresentation: frozen.sourceRepresentation,
            sourcePolicy: frozen.sourcePolicy, batchCharacters: frozen.batchCharacters,
            displayContract: frozen.displayContract, generationOrigin: frozen.generationOrigin,
            buildManifestSHA256: frozen.buildManifestSHA256, targetLocale: nil)
        let frozenBytes = try encoder.encode(frozen)
        let currentBytes = try encoder.encode(current)
        try check(frozenBytes == currentBytes, "default producer encoded bytes remain frozen")
        let parsed = try LearningQualityCLI.options(["--input", "fixture.json", "--output", "results"])
        try check(parsed.target == .simplifiedChinese && !parsed.dryRun, "default option")
        for invalid in [
            ["--input", "fixture.json", "--output", "results", "--target", "de"],
            ["--input", "fixture.json", "--output", "results", "--dry-run", "--dry-run"],
            ["--input", "fixture.json", "--input", "other.json", "--output", "results"]
        ] {
            var rejected = false
            do { _ = try LearningQualityCLI.options(invalid) } catch { rejected = true }
            try check(rejected, "reject invalid flags")
        }

        let english = CaptionTranslationTarget(rawValue: "en")
        let englishPromptsReady = english.map {
            $0.learningNotePrompt != CaptionTranslationTarget.simplifiedChinese.learningNotePrompt
                && $0.learningReviewPrompt != CaptionTranslationTarget.simplifiedChinese.learningReviewPrompt
        } ?? false
        var targets: [CaptionTranslationTarget] = [.simplifiedChinese]
        if let english { targets.append(english) }
        var injectionCalls = 0

        if let english {
            let kindCases: [(String, String)] = [
                ("核心结论", "- A pointer stores an address."),
                ("概念关系", "- **Concept relationship**: A pointer stores an address."),
                ("例子", "- **Example**: A pointer stores an address."),
                ("易错点", "- **Common pitfall**: A pointer stores an address."),
                ("补充理解", "- **Background**: A pointer stores an address."),
                ("待确认", "- **Needs clarification**: A pointer stores an address.")
            ]
            for (kind, expected) in kindCases {
                let point = LearningPoint(kind: kind, text: "A pointer stores an address.")
                try check(point.markdown(target: english) == expected, "actual English kind formatter: " + kind)
            }
            let openExample = LearningPoint(kind: "例子", text: "A pointer stores an address.",
                needsContext: "Which object does this address identify?", sourceIDs: ["en0s0"])
            try check(openExample.markdown(target: english) ==
                "- **Example (Needs clarification)**: A pointer stores an address.", "actual English pending formatter")
            let stateCases: [(LearningFollowUp.State, String)] = [
                (.missing, "Missing information"), (.supplemented, "Later clarification"),
                (.conflict, "Conflicting accounts"), (.unclear, "Relationship unclear")
            ]
            for (state, expected) in stateCases {
                try check(state.label(target: english) == expected, "actual English state formatter")
            }
            try check(ClassroomFixedText.replayHeading.text(targetCode: english.rawValue) == "需要回听",
                "classroom replay wrapper defaults to Chinese")
            try check(ClassroomFixedText.sourceCheckHeading.text(targetCode: english.rawValue) == "来源检查",
                "classroom source-check wrapper defaults to Chinese")
            try check(ClassroomFixedText.sourceText.text(targetCode: english.rawValue) == "原文",
                "classroom source wrapper defaults to Chinese")
            let source = TranscriptSegment(startTime: 0, endTime: 10,
                english: "A pointer stores an address.", chinese: "A pointer stores an address.")
            let sourceLanguages: [String?] = [nil, "en"]
            for language in sourceLanguages {
                let stale = TranscriptSegment(startTime: 0, endTime: 10,
                    english: "A pointer stores an address.", chinese: "指针存储地址。", sourceLanguage: language)
                try check(stale.hasUsableTranslation, "stale Chinese counterpart remains usable")
                let units = LearningSourceUnit.make([stale], target: english)
                try check(units.map(\.language) == ["en"], "English source has one evidence group")
                try check(units.map(\.text) == [stale.english], "English source ignores stale Chinese counterpart")
            }
            var notebook = LearningNotebook(target: english)
            try check(notebook.target == english, "notebook owns English target")
            try check(ClassroomFixedText.sourceLine.noteFormat(["A pointer stores an address."], target: english)
                == "原文：A pointer stores an address.", "Chinese source wrapper preserves inserted English quote")
            try notebook.append(evidence: [source], note: LearningNote(topic: "Pointers",
                points: [openExample], sourceVersion: 2, noNewKnowledge: false))
            let markdown = notebook.markdown()
            try check(markdown.contains("## 需要回听"), "notebook uses Chinese replay heading in English mode")
            let shown = try LearningQualityCLI.displayPoints(notebook: notebook, markdown: markdown,
                latestMarkdown: notebook.markdown(covering: notebook.latestEvidenceIDs), target: english)
            try check(shown.first?.fullDisposition == "replay", "actual English line belongs to replay")
            try check(!LearningQualityCLI.renderedContains(openExample.markdown(target: english),
                in: "body", markdown: markdown, target: english), "replay cannot substitute for English body")
            let closed = LearningPoint(kind: "例子", text: "A pointer stores an address.").markdown(target: english)
            for heading in ["来源检查", "课程安排与待办"] {
                try check(!LearningQualityCLI.renderedContains(closed, in: "body",
                    markdown: "## " + heading + "\n" + closed, target: english),
                    "Chinese advisory wrapper cannot substitute for English body")
                try check(LearningQualityCLI.renderedContains(closed, in: "advisory",
                    markdown: "## " + heading + "\n" + closed, target: english),
                    "English point is recognized within Chinese advisory section")
            }
        }
        for target in targets {
            let text = "A pointer stores an address."
            let row = LearningQualityCLI.Row(english: text,
                chinese: "指针存储地址。")
            let fixture = LearningQualityCLI.Fixture(id: "target-test", stages: [[row]])
            let input = root.appendingPathComponent("fixture-\(target.rawValue).json")
            try encoder.encode(fixture).write(to: input, options: .atomic)
            let output = root.appendingPathComponent("dry-\(target.rawValue)", isDirectory: true)
            try await LearningQualityCLI.run(arguments: ["--input", input.path, "--output", output.path,
                "--target", target.rawValue, "--dry-run"], generate: { _, _ in
                    injectionCalls += 1
                    throw Failure.assertion("dry-run must not invoke generation")
                })
            let plan = try object(output.appendingPathComponent("dry-run.json"))
            try check(plan["modelInvoked"] as? Bool == false, "offline mode")
            try check(plan["generationOrigin"] as? String == "offline-preparation", "offline evidence label")
            try check(plan["targetLocale"] as? String == target.rawValue, "offline target")
            try check(!FileManager.default.fileExists(atPath: output.appendingPathComponent("result.json").path),
                      "no model result in dry-run")
            let prompt = try Data(contentsOf: output.appendingPathComponent("generation-prompt.txt"))
            let reviewPrompt = try Data(contentsOf: output.appendingPathComponent("review-prompt.txt"))
            try check(prompt == Data(target.learningNotePrompt.utf8), "passed generation target")
            try check(reviewPrompt == Data(target.learningReviewPrompt.utf8), "passed review target")
            let prepared = try object(output.appendingPathComponent("input-1.json"))
            let sample = try LearningQualityCLI.segment(row, fixtureID: fixture.id, stage: 0, index: 0, ordinal: 0)
            let expectedInput = try LearningPrompts.input(evidence: [sample], topics: [], target: target)
            let actualInput = try Data(contentsOf: output.appendingPathComponent("input-1.json"))
            try check(actualInput == Data(expectedInput.utf8), "actual production preparation bytes")
            let units = prepared["evidence"] as? [[String: Any]] ?? []
            let languages = units.compactMap { $0["language"] as? String }
            if target.rawValue == "en" {
                try check(languages == ["en"], "English evidence is one group")
                try check(units.compactMap { $0["text"] as? String } == [text],
                    "English preparation ignores old Chinese translation")
                let review = try object(output.appendingPathComponent("review-input-1.json"))
                let evidence = review["evidence"] as? [[String: Any]] ?? []
                let quoteIDs = evidence.flatMap { ($0["quotes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
                try check(quoteIDs == ["e0.en.0"], "review English evidence is one group")
            } else {
                try check(languages == ["en", "zh"], "default bilingual groups")
            }

            let generated = root.appendingPathComponent("injected-\(target.rawValue)", isDirectory: true)
            try await LearningQualityCLI.run(arguments: ["--input", input.path, "--output", generated.path,
                "--target", target.rawValue], generate: { prepared, _ in
                    injectionCalls += 1
                    let obj = try JSONSerialization.jsonObject(with: Data(prepared.utf8)) as? [String: Any]
                    let units = obj?["evidence"] as? [[String: Any]] ?? []
                    let language = target == .simplifiedChinese ? "zh" : "en"
                    let points = units.filter { $0["language"] as? String == language }.map { unit in
                        ["kind": "核心结论", "text": unit["text"] as! String,
                         "sourceIDs": [unit["id"] as! String]] as [String: Any]
                    }
                    let note: [String: Any] = ["sourceVersion": 2, "topic": "Pointers",
                        "points": points, "noNewKnowledge": false]
                    return String(decoding: try JSONSerialization.data(withJSONObject: note, options: .sortedKeys), as: UTF8.self)
                })
            let result = try object(generated.appendingPathComponent("result.json"))
            let producer = result["producer"] as? [String: Any] ?? [:]
            try check(producer["generationOrigin"] as? String == "synthetic-regression", "injected is never model evidence")
            try check((producer["targetLocale"] as? String) == (target == .simplifiedChinese ? nil : target.rawValue),
                      "target omitted only for default")
            try check(result["successfulRequests"] as? Int == 1, "actual decoder and target binder committed")
            let stages = result["stages"] as? [[String: Any]] ?? []
            let shown = stages.first?["displayPoints"] as? [[String: Any]] ?? []
            try check(shown.first?["fullDisposition"] as? String == "body", "production renderer body membership")
        }
        let expectedCalls = targets.count
        try check(injectionCalls == expectedCalls, "only explicit injected generations were invoked")
        let status = englishPromptsReady ? "passed" : "binding-display-passed-generation-prompt-dependency-pending"
        let receipt: [String: Any] = ["status": status,
            "assertions": assertions, "realModelsInvoked": false,
            "englishTargetAvailable": english != nil, "englishPromptsReady": englishPromptsReady,
            "defaultProducerBytesFrozen": true]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("target-test-results.json"), options: .atomic)
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys), as: UTF8.self))
    }
}
#endif
