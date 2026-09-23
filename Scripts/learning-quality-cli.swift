import Foundation
import CryptoKit

/// Internal synthetic-source probe. Gold answers are never read by this process.
/// Protocol 2 does not certify older results retroactively.
#if !QUALITY_PROBE_TESTS
@main
#endif
struct LearningQualityCLI {
    struct Row: Codable { let english: String; let chinese: String }
    struct Fixture: Codable { let id: String; let stages: [[Row]] }
    struct Producer: Codable {
        let executableSHA256: String
        let promptSHA256: String
        let sourceRepresentation: String
        let sourcePolicy: String
        let batchCharacters: Int
        let displayContract: String
        let generationOrigin: String
        let buildManifestSHA256: String?
    }
    struct DisplayPoint: Codable {
        let reference: String
        let hasOpenQuestion: Bool
        let fullDisposition: String
        let latestDisposition: String
        let renderedLine: String
        let resolvedClarifies: String?
    }
    struct Stage: Codable {
        let number: Int
        let elapsedSeconds: Double
        let batches: [LearningNoteBatch]
        let markdown: String
        let latestMarkdown: String
        let coveredSourceIDs: [UUID]
        let displayPoints: [DisplayPoint]
        let requestedRequests: Int
        let successfulRequests: Int
    }
    struct Request: Encodable {
        let number: Int
        let stage: Int
        let evidence: [TranscriptSegment]
        let sourceUnits: [LearningSourceUnit]
        let pendingTargets: [String]
        let inputFile: String
        let inputSHA256: String
        var responseFile: String?
        var responseSHA256: String?
        var normalizedNote: LearningNote?
        var batchID: UUID?
        var outcome = "requested"
        var error: String?
    }
    struct Result: Encodable {
        let probeVersion = 2
        let fixtureID: String
        let fixtureSHA256: String
        let model: String
        let producer: Producer
        let stages: [Stage]
        let requests: [Request]
        let requestedRequests: Int
        let successfulRequests: Int
        let error: String?
    }
    enum Failure: Error { case arguments, invalidFixture, exists, noProgress, renderMismatch }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func segment(_ row: Row, fixtureID: String, stage: Int, index: Int,
                        ordinal: Int) throws -> TranscriptSegment {
        let hex = Array(sha(Data("\(fixtureID)/\(stage)/\(index)".utf8)).prefix(32))
        let raw = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-"
            + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
        guard let id = UUID(uuidString: raw) else { throw Failure.invalidFixture }
        let start = Double(ordinal * 12)
        // Common constructor: the baseline omits revision/state; the candidate
        // initializes revision 0. Producer metadata makes the difference explicit.
        return TranscriptSegment(id: id, startTime: start, endTime: start + 10,
                                 english: row.english, chinese: row.chinese)
    }

    /// Check the production property AND membership in the production renderer.
    /// Resolving a follow-up alias only identifies its target; it does not settle
    /// the factual question. Linked groups retain the renderer's question state.
    static func displayPoints(notebook: LearningNotebook, markdown: String,
                              latestMarkdown: String) throws -> [DisplayPoint] {
        let all = notebook.batches.flatMap { batch in
            batch.note.points.enumerated().map {
                (reference: LearningNotebook.reference(batch, $0.offset), point: $0.element, batch: batch.id)
            }
        }
        let originals = Dictionary(uniqueKeysWithValues: all.map { ($0.reference, $0.point) })
        let retired = LearningNotebook.retiredQuestions(in: notebook.batches)
        func dispositions(visibleBatches: Set<UUID>, rendered: String) throws -> [String: String] {
            let visible = all.filter { visibleBatches.contains($0.batch) }
            let ids = Set(visible.map(\.reference))
            let children = Dictionary(grouping: visible.filter { $0.point.clarifies != nil },
                                      by: { $0.point.clarifies! })
            func containsQuestion(_ reference: String, visited: Set<String> = []) throws -> Bool {
                guard !visited.contains(reference), let point = originals[reference] else { throw Failure.renderMismatch }
                var next = visited; next.insert(reference)
                if retired.contains(reference) { return false }
                if point.hasOpenQuestion { return true }
                if let parent = point.clarifies {
                    if retired.contains(parent) { return false }
                    if originals[parent]?.hasOpenQuestion == true { return true }
                }
                for child in children[reference] ?? [] {
                    if try containsQuestion(child.reference, visited: next) { return true }
                }
                return false
            }
            var result: [String: String] = [:]
            for item in visible {
                var root = item.reference
                var seen = Set<String>()
                while let parent = originals[root]?.clarifies, ids.contains(parent) {
                    guard seen.insert(root).inserted else { throw Failure.renderMismatch }
                    root = parent
                }
                let placement = try containsQuestion(root) ? "replay" : "body"
                guard renderedContains(item.point.markdown, in: placement, markdown: rendered) else {
                    throw Failure.renderMismatch
                }
                result[item.reference] = placement
            }
            return result
        }
        let full = try dispositions(visibleBatches: Set(notebook.batches.map(\.id)), rendered: markdown)
        let latest = try dispositions(visibleBatches: Set(notebook.batches.suffix(1).map(\.id)), rendered: latestMarkdown)
        return all.map { item in
            DisplayPoint(reference: item.reference, hasOpenQuestion: item.point.hasOpenQuestion,
                fullDisposition: full[item.reference] ?? "hidden", latestDisposition: latest[item.reference] ?? "hidden",
                renderedLine: item.point.markdown, resolvedClarifies: item.point.clarifies)
        }
    }

    static func renderedContains(_ pointLine: String, in placement: String, markdown: String) -> Bool {
        var current = "body"
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                let title = String(line.dropFirst(3))
                current = title == LearningNotebook.replayHeading ? "replay"
                    : (title == LearningNotebook.sourceCheckHeading || title == "课程安排与待办" ? "advisory" : "body")
                lines.append("")
            } else {
                lines.append(current == placement ? line.trimmingCharacters(in: .whitespaces) : "")
            }
        }
        let wanted = pointLine.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !wanted.isEmpty, lines.count >= wanted.count else { return false }
        return (0...(lines.count - wanted.count)).contains { Array(lines[$0..<($0 + wanted.count)]) == wanted }
    }

    @MainActor static func main() async {
        do { try await run() }
        catch {
            await shutdown()
            fputs("Quality probe failed; inspect the isolated result and response files.\n", stderr)
            exit(1)
        }
        await shutdown()
    }

    @MainActor static func shutdown() async {
        await MLXRuntime.shared.unload(QwenModelProfile.energySaver.translationModel)
        await MLXRuntime.shared.unload(QwenModelProfile.highQuality.translationModel)
    }

    @MainActor static func run(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        generate: (@MainActor (String, String) async throws -> String)? = nil
    ) async throws {
        let args = arguments
        guard args.count == 4, args[0] == "--input", args[2] == "--output" else { throw Failure.arguments }
        let input = URL(fileURLWithPath: args[1])
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.exists }
        let bytes = try Data(contentsOf: input)
        let fixture = try JSONDecoder().decode(Fixture.self, from: bytes)
        guard !fixture.id.isEmpty, !fixture.stages.isEmpty,
              fixture.stages.allSatisfy({ !$0.isEmpty && $0.allSatisfy {
                  !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              } }) else { throw Failure.invalidFixture }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sample = try segment(fixture.stages[0][0], fixtureID: fixture.id, stage: 0, index: 0, ordinal: 0)
        let sourceObject = try JSONSerialization.jsonObject(with: encoder.encode(sample)) as? [String: Any]
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableSHA = sha(try Data(contentsOf: executable))
        let manifestURL = executable.deletingLastPathComponent().appendingPathComponent("quality-build-manifest.json")
        var buildManifest: Data?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard object?["executableSHA256"] as? String == executableSHA,
                  object?["sourcesUnchangedDuringBuild"] as? Bool == true else { throw Failure.invalidFixture }
            buildManifest = data
        }
        let producer = Producer(executableSHA256: executableSHA,
            promptSHA256: sha(Data(LearningPrompts.generate.utf8)),
            sourceRepresentation: sourceObject?["inputRevision"] == nil ? "legacy" : "revisioned",
            sourcePolicy: "fixture-uuid-v1/12s-start/10s-duration/revision-0/session-none",
            batchCharacters: SummaryRefreshPolicy.automaticBatchCharacters,
            displayContract: "production-point-and-rendered-membership-v1",
            generationOrigin: generate == nil ? "production-model" : "synthetic-regression",
            buildManifestSHA256: buildManifest.map(sha))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try bytes.write(to: output.appendingPathComponent("fixture.json"), options: .atomic)
        if let buildManifest {
            try buildManifest.write(to: output.appendingPathComponent("quality-build-manifest.json"), options: .atomic)
        }
        let model = QwenModelProfile.energySaver.translationModel
        var notebook = LearningNotebook()
        var evidence: [TranscriptSegment] = []
        var covered = Set<UUID>()
        var stages: [Stage] = []
        var requests: [Request] = []
        var successes = 0
        let started = ProcessInfo.processInfo.systemUptime
        func save(error: String? = nil) throws {
            let result = Result(fixtureID: fixture.id, fixtureSHA256: sha(bytes), model: model,
                producer: producer, stages: stages, requests: requests, requestedRequests: requests.count,
                successfulRequests: successes, error: error)
            try encoder.encode(result).write(to: output.appendingPathComponent("result.json"), options: .atomic)
        }
        try save()
        do {
            for (stageIndex, rows) in fixture.stages.enumerated() {
                for (index, row) in rows.enumerated() {
                    evidence.append(try segment(row, fixtureID: fixture.id, stage: stageIndex,
                                                index: index, ordinal: evidence.count))
                }
                let boundary = Set(evidence.map(\.id))
                while !boundary.isSubset(of: covered) {
                    let selected = LectureSummaryInput.incremental(from: evidence, coveredIDs: covered,
                        previousSummary: "", maximumCharacters: SummaryRefreshPolicy.automaticBatchCharacters).segmentIDs
                    guard !selected.isEmpty else { throw Failure.noProgress }
                    let current = evidence.filter { selected.contains($0.id) }
                    let pending = notebook.selectPendingPoints(for: current)
                    let prepared = try LearningPrompts.input(evidence: current, topics: notebook.topics, pending: pending)
                    let number = requests.count + 1
                    let inputFile = "input-\(number).json"
                    try Data(prepared.utf8).write(to: output.appendingPathComponent(inputFile), options: .atomic)
                    requests.append(Request(number: number, stage: stageIndex + 1, evidence: current,
                        sourceUnits: LearningSourceUnit.make(current), pendingTargets: Array(pending.prefix(4).map(\.id)),
                        inputFile: inputFile, inputSHA256: sha(Data(prepared.utf8))))
                    try save()
                    let requestStarted = ProcessInfo.processInfo.systemUptime
                    do {
                        let response: String
                        if let generate {
                            response = try await generate(prepared, model)
                        } else {
                            response = try await QwenTranslationClient.learningNote(input: prepared,
                                modelName: model, prefix: "", onUpdate: { _ in })
                        }
                        let responseFile = "response-\(number).txt"
                        // Persist the final response before attempting production decoding.
                        try Data(response.utf8).write(to: output.appendingPathComponent(responseFile), options: .atomic)
                        requests[number - 1].responseFile = responseFile
                        requests[number - 1].responseSHA256 = sha(Data(response.utf8))
                        requests[number - 1].outcome = "received"
                        try save()
                        var note = try LearningNote.decode(response)
                        note = LearningPrompts.resolvingFollowUps(note, targets: pending.map(\.id))
                        note.topic = SimplifiedChineseNormalizer.normalize(note.topic)
                        note.sourceVersion = 2
                        for index in note.points.indices {
                            note.points[index].text = SimplifiedChineseNormalizer.normalize(note.points[index].text)
                        }
                        requests[number - 1].normalizedNote = note
                        try notebook.append(evidence: current, note: note)
                        covered.formUnion(selected)
                        successes += 1
                        requests[number - 1].batchID = notebook.batches.last?.id
                        requests[number - 1].outcome = "committed"
                        try save()
                    } catch {
                        requests[number - 1].outcome = "failed"
                        requests[number - 1].error = String(describing: error)
                        throw error
                    }
                    let event: [String: Any] = ["event": "batch_completed", "stage": stageIndex + 1,
                        "requestedRequests": requests.count, "successfulRequests": successes,
                        "sourceCount": current.count, "seconds": ProcessInfo.processInfo.systemUptime - requestStarted]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: event, options: .sortedKeys), as: UTF8.self))
                    fflush(stdout)
                }
                let markdown = notebook.markdown()
                let latest = notebook.markdown(covering: notebook.latestEvidenceIDs)
                let stage = Stage(number: stageIndex + 1,
                    elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, batches: notebook.batches,
                    markdown: markdown, latestMarkdown: latest,
                    coveredSourceIDs: covered.sorted { $0.uuidString < $1.uuidString },
                    displayPoints: try displayPoints(notebook: notebook, markdown: markdown, latestMarkdown: latest),
                    requestedRequests: requests.count, successfulRequests: successes)
                stages.append(stage)
                try markdown.write(to: output.appendingPathComponent("notes-stage-\(stage.number).md"),
                                   atomically: true, encoding: .utf8)
                try save()
            }
            try save()
        } catch {
            try save(error: String(describing: error))
            throw error
        }
    }
}
