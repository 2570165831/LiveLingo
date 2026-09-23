import Foundation

/// Actual production decoder/binder/renderer tests with an injected generator.
/// This executable never constructs AppModel or calls the model runtime.
@main
struct LearningQualityCLITests {
    enum TestFailure: Error { case assertion(String), expectedFailure }
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        assertions += 1
        guard condition() else { throw TestFailure.assertion(label) }
    }
    static func source(_ text: String, at time: Double = 0) -> TranscriptSegment {
        TranscriptSegment(startTime: time, endTime: time + 10,
            english: "A synthetic source for renderer testing.", chinese: text)
    }
    static func note(_ text: String, kind: String = "核心结论", needs: String? = nil,
                     clarifies: String? = nil) -> LearningNote {
        LearningNote(topic: "测试主题", points: [LearningPoint(kind: kind, text: text,
            needsContext: needs, clarifies: clarifies, sourceIDs: ["zh0s0"])],
            sourceVersion: 2, noNewKnowledge: false)
    }
    static func display(_ notebook: LearningNotebook) throws -> [LearningQualityCLI.DisplayPoint] {
        try LearningQualityCLI.displayPoints(notebook: notebook, markdown: notebook.markdown(),
            latestMarkdown: notebook.markdown(covering: notebook.latestEvidenceIDs))
    }
    static func read(_ directory: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("result.json"))) as? [String: Any]
            else { throw TestFailure.assertion("result object") }
        return value
    }
    @MainActor static func main() async {
        do { try await run() }
        catch {
            fputs("Synthetic CLI regression failed: \(error)\n", stderr)
            exit(1)
        }
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw TestFailure.assertion("output and corpus arguments") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let corpus = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw TestFailure.assertion("new test output") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try check(!LearningPoint(kind: "核心结论", text: "说明", needsContext: "   ").hasOpenQuestion, "whitespace question")
        try check(!LearningPoint(kind: "核心结论", text: "说明", needsContext: LearningPoint.numericCheckContext).hasOpenQuestion, "numeric advisory")
        try check(LearningPoint(kind: "核心结论", text: "说明", needsContext: "属于谁？", referenceState: .numericDifference).hasOpenQuestion, "real question wins over state")
        try check(LearningPoint(kind: "待确认", text: "说明").hasOpenQuestion, "pending kind")

        var ordinary = LearningNotebook()
        try ordinary.append(evidence: [source("电表读数为3伏特。")], note: note("电表读数为3伏特。"))
        var shown = try display(ordinary)
        try check(shown.count == 1 && shown[0].fullDisposition == "body" && shown[0].latestDisposition == "body", "ordinary render")
        try ordinary.append(evidence: [source("另一台电表读数为7伏特。", at: 12)], note: note("另一台电表读数为7伏特。"))
        shown = try display(ordinary)
        try check(shown[0].latestDisposition == "hidden" && shown[1].latestDisposition == "body", "latest-only filtering")
        do {
            _ = try LearningQualityCLI.displayPoints(notebook: ordinary, markdown: "", latestMarkdown: ordinary.markdown())
            throw TestFailure.expectedFailure
        } catch LearningQualityCLI.Failure.renderMismatch {
            assertions += 1
        }
        try check(!LearningQualityCLI.renderedContains("- 电表读数为3伏特。", in: "body", markdown: "## 来源检查\n- 电表读数为3伏特。"), "advisory cannot substitute body")
        try check(!LearningQualityCLI.renderedContains("- 电表读数为3伏特。", in: "body", markdown: "## 电表读数为3伏特。\n- 尚未说明。"), "title cannot substitute point")

        var followup = LearningNotebook()
        try followup.append(evidence: [source("它的温度为20摄氏度。")],
            note: note("温度为20摄氏度，所属样品尚未明确。", kind: "待确认", needs: "温度属于哪个样品？"))
        let later = [source("这项20摄氏度属于样品甲。", at: 12)]
        let pending = followup.selectPendingPoints(for: later)
        try check(!pending.isEmpty, "actual pending selection")
        let clarified = LearningPrompts.resolvingFollowUps(note("样品甲温度为20摄氏度。", clarifies: "q0"), targets: pending.map(\.id))
        try followup.append(evidence: later, note: clarified)
        shown = try display(followup)
        try check(shown.count == 2 && shown.allSatisfy { $0.fullDisposition == "replay" }, "linked group retains open question")
        try check(!shown[1].hasOpenQuestion && shown[1].latestDisposition == "replay", "later point question propagation")
        try check(shown[1].resolvedClarifies == shown[0].reference, "resolved alias is exact old reference")

        var resolvedNotebook = LearningNotebook()
        try resolvedNotebook.append(evidence: [source("它的温度为20摄氏度。")],
            note: note("温度为20摄氏度，所属样品尚未明确。", kind: "待确认", needs: "温度属于哪个样品？"))
        let resolvedEvidence = [source("样品甲的温度为20摄氏度。", at: 12)]
        let unresolved = resolvedNotebook.selectPendingPoints(for: resolvedEvidence)
        try check(unresolved.count == 1, "frozen follow-up target")
        let supplement = LearningNote(topic: "测试主题",
            points: [LearningPoint(kind: "核心结论", text: "样品甲的温度为20摄氏度。", sourceIDs: ["zh0s0"])],
            sourceVersion: 2, noNewKnowledge: false,
            followUps: [LearningFollowUp(alias: "q0", state: .supplemented,
                                         sourceIDs: ["zh0s0"], detail: "后文明确指出了所属样品。")])
        try resolvedNotebook.append(evidence: resolvedEvidence,
            note: LearningPrompts.resolvingFollowUps(supplement, targets: unresolved.map(\.id)))
        shown = try display(resolvedNotebook)
        try check(shown.count == 2 && shown.allSatisfy { $0.fullDisposition == "body" },
                  "supplemented question moves to body")
        try check(shown[0].hasOpenQuestion && shown[0].latestDisposition == "hidden"
                  && shown[1].latestDisposition == "body", "latest placement after supplement")

        var numeric = LearningNotebook()
        try numeric.append(evidence: [source("这个量可以进行单位换算。")], note: note("换算结果为1000千克每立方米。"))
        shown = try display(numeric)
        try check(numeric.batches[0].note.points[0].referenceState == .numericDifference, "numeric binding metadata")
        try check(!shown[0].hasOpenQuestion && shown[0].fullDisposition == "body", "numeric advisory does not erase body")
        var empty = LearningNotebook()
        try empty.append(evidence: [source("谢谢。")], note: LearningNote(topic: "无新增学习知识", points: [], sourceVersion: 2, noNewKnowledge: true))
        let noPoints = try display(empty)
        try check(noPoints.isEmpty, "legitimate empty note")

        let input = corpus.appendingPathComponent("constant-acceleration.json")
        let bad = root.appendingPathComponent("malformed-final", isDirectory: true)
        let badResponse = "{\"sourceVersion\":2,\"topic\":\"unfinished"
        var receivedFailure = false
        do {
            try await LearningQualityCLI.run(arguments: ["--input", input.path, "--output", bad.path], generate: { _, _ in badResponse })
        } catch { receivedFailure = true }
        try check(receivedFailure, "malformed model response must fail")
        let savedResponse = try String(contentsOf: bad.appendingPathComponent("response-1.txt"), encoding: .utf8)
        try check(savedResponse == badResponse, "malformed raw final saved verbatim")
        let failed = try read(bad)
        try check(failed["requestedRequests"] as? Int == 1 && failed["successfulRequests"] as? Int == 0, "failure counters")
        let failedRequests = failed["requests"] as? [[String: Any]] ?? []
        try check(failedRequests.first?["outcome"] as? String == "failed" && failed["error"] is String, "failure receipt")
        let producer = failed["producer"] as? [String: Any]
        try check(producer?["generationOrigin"] as? String == "synthetic-regression", "synthetic provenance")

        let fixtures = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "gold.json" && $0.lastPathComponent != "manifest.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let outputs = root.appendingPathComponent("synthetic-results", isDirectory: true)
        for fixture in fixtures {
            let destination = outputs.appendingPathComponent(fixture.deletingPathExtension().lastPathComponent, isDirectory: true)
            try await LearningQualityCLI.run(arguments: ["--input", fixture.path, "--output", destination.path], generate: { prepared, _ in
                guard let data = prepared.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let units = object["evidence"] as? [[String: Any]] else { throw TestFailure.assertion("prepared input") }
                let points = units.filter { $0["language"] as? String == "zh" }.compactMap { unit -> [String: Any]? in
                    guard let text = unit["text"] as? String, let id = unit["id"] as? String else { return nil }
                    return ["kind": "核心结论", "text": text, "sourceIDs": [id], "needsContext": NSNull(), "clarifies": NSNull()]
                }
                // Production limits apply; combine adjacent sentences from one source only.
                var bounded = points
                while bounded.count > 24 {
                    let adjacent = bounded.indices.dropLast().first { index in
                        guard let left = bounded[index]["sourceIDs"] as? [String], left.count == 1,
                              let right = bounded[index + 1]["sourceIDs"] as? [String], right.count == 1 else { return false }
                        return left[0].split(separator: "s").first == right[0].split(separator: "s").first
                    }
                    guard let index = adjacent,
                          let left = bounded[index]["sourceIDs"] as? [String],
                          let right = bounded[index + 1]["sourceIDs"] as? [String] else { throw TestFailure.assertion("synthetic point bound") }
                    let next = bounded.remove(at: index + 1)
                    bounded[index]["text"] = (bounded[index]["text"] as? String ?? "") + (next["text"] as? String ?? "")
                    bounded[index]["sourceIDs"] = left + right
                }
                let note: [String: Any] = ["sourceVersion": 2, "topic": "合成回归", "points": bounded, "noNewKnowledge": bounded.isEmpty]
                return String(decoding: try JSONSerialization.data(withJSONObject: note, options: .sortedKeys), as: UTF8.self)
            })
            let result = try read(destination)
            try check((result["stages"] as? [Any])?.isEmpty == false && result["error"] == nil, "successful injected course")
            try check((result["requestedRequests"] as? Int) == (result["successfulRequests"] as? Int), "successful request counts")
        }
        let summary: [String: Any] = ["assertions": assertions, "fixtureCount": fixtures.count,
            "generationOrigin": "synthetic-regression", "realModelsInvoked": false, "status": "passed"]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("swift-test-results.json"), options: .atomic)
        print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: .sortedKeys), as: UTF8.self))
    }
}
