import Foundation

/// An offline probe for an explicitly supplied synthetic volume. No services,
/// preferences, audio inputs, model weights or network transports are started.
@main
struct PortableStorageProbe {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("synthetic-portable-" + UUID().uuidString, isDirectory: true)
        var results: [String: Bool] = [:]
        func run(_ name: String, _ action: () throws -> Void) {
            do { try action(); results[name] = true }
            catch { results[name] = false }
        }
        let segment = TranscriptSegment(startTime: 0, endTime: 1,
            english: "Synthetic lesson", chinese: "合成课堂")
        let course = root.appendingPathComponent("course", isDirectory: true)
        let store = SessionStore(directory: course)
        var saved: SessionSnapshot?
        run("course-create") {
            saved = try store.save(SessionSnapshot(segments: [segment]))
            guard try store.load()?.segments == [segment] else { throw CocoaError(.fileReadCorruptFile) }
        }
        run("course-overwrite") {
            guard var desired = saved else { throw CocoaError(.fileReadCorruptFile) }
            desired.legacyMarkdown = "合成笔记已更新。"
            saved = try store.save(desired)
            guard try store.load()?.legacyMarkdown == desired.legacyMarkdown else { throw CocoaError(.fileReadCorruptFile) }
        }
        for name in ["export-create", "export-overwrite"] {
            run(name) {
                try SessionExporter.export(segments: [segment], sessionDirectory: course, summary: name)
                let summary = course.appendingPathComponent("summary-zh-Hans.md")
                guard try String(contentsOf: summary, encoding: .utf8) == name + "\n" else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        let notes = NotesExportSnapshot(className: "Synthetic class", sessionName: nil,
            scope: .wholeLesson, scopeDetail: "合成范围", coverageLine: "合成覆盖",
            notesMarkdown: "合成笔记。", reviewMarkdown: nil, transcript: [],
            generatedAt: Date(timeIntervalSince1970: 0), includesReviewAdvice: false, includesTranscript: false)
        for format in [NotesExportFormat.markdown, .plainText, .word, .pdf] {
            let output = root.appendingPathComponent("notes." + format.fileExtension)
            for stage in ["create", "overwrite"] {
                run("notes-" + format.fileExtension + "-" + stage) {
                    try NotesExportDocument.write(notes, format: format, to: output)
                    guard try !Data(contentsOf: output).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                }
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(results.values.allSatisfy { $0 } ? 0 : 1)
    }
}
