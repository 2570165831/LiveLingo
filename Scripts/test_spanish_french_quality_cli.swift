import Foundation

#if QUALITY_PROBE_TESTS
/// Production quality preparation, decoder, binder and display with injected text.
@main @MainActor
struct SpanishFrenchQualityCLITests {
    enum Failure: Error { case assertion(String) }
    static var assertions = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        assertions += 1
        guard try value() else { throw Failure.assertion(name) }
    }
    static func object(_ file: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        else { throw Failure.assertion("JSON object") }
        return value
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.assertion("new output and fixture root") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try check(!FileManager.default.fileExists(atPath: root.path), "new output")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var calls = 0
        for target in [CaptionTranslationTarget.spanish, .french] {
            for name in ["decimal-mass", "ownership-context", "algorithm-conditions"] {
                let input = fixtures.appendingPathComponent("learning-quality-public-" + target.rawValue)
                    .appendingPathComponent(name + ".json")
                let dry = root.appendingPathComponent("dry-" + target.rawValue + "-" + name)
                try await LearningQualityCLI.run(arguments: ["--input", input.path, "--output", dry.path,
                    "--target", target.rawValue, "--dry-run", "--include-content"], generate: { _, _ in
                        throw Failure.assertion("dry run must not generate")
                    })
                try check(try object(dry.appendingPathComponent("dry-run.json"))["modelInvoked"] as? Bool == false, "offline preparation")
                let generatePrompt = try String(contentsOf: dry.appendingPathComponent("generation-prompt.txt"), encoding: .utf8)
                try check(generatePrompt == target.learningNotePrompt, "production target prompt")
                let output = root.appendingPathComponent("generated-" + target.rawValue + "-" + name)
                try await LearningQualityCLI.run(arguments: ["--input", input.path, "--output", output.path,
                    "--target", target.rawValue, "--include-content"], generate: { input, model in
                        calls += 1
                        try check(model == QwenModelProfile.energySaver.translationModel, "injected generation model")
                        let parsed = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
                        let evidence = parsed["evidence"] as! [[String: Any]]
                        let points = evidence.filter { $0["language"] as? String == target.rawValue }.map {
                            ["kind": "例子", "text": $0["text"] as! String,
                             "sourceIDs": [$0["id"] as! String], "needsContext": NSNull()] as [String: Any]
                        }
                        let pending = parsed["pendingPoints"] as? [[String: Any]] ?? []
                        var followUps: [String: Any] = [:]
                        for point in pending {
                            followUps[point["id"] as! String] = ["state": "缺信息", "sourceIDs": [],
                                "detail": target == .spanish ? "Falta información explícita." : "Il manque des informations explicites."]
                        }
                        return String(decoding: try JSONSerialization.data(withJSONObject: ["sourceVersion": 2,
                            "topic": name, "points": points, "followUps": followUps, "noNewKnowledge": false],
                            options: .sortedKeys), as: UTF8.self)
                    })
                let result = try object(output.appendingPathComponent("result.json"))
                let producer = result["producer"] as! [String: Any]
                try check(producer["targetLocale"] as? String == target.rawValue, "producer target")
                try check(producer["generationOrigin"] as? String == "synthetic-regression", "honest injected evidence")
                try check(result["successfulRequests"] as? Int == 2, "incremental production requests")
                let stages = result["stages"] as! [[String: Any]]
                try check(stages.count == 2, "both stages retained")
            }
        }
        try check(calls == 12, "one generation per stage")
        let receipt: [String: Any] = ["status": "passed", "assertions": assertions,
            "generationCalls": calls, "realModelsInvoked": false]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("test-results.json"), options: .atomic)
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys), as: UTF8.self))
    }
}
#endif
