import Foundation

enum SessionWorkspaceError: LocalizedError {
    case invalidTemporarySession
    case recordingMissing
    case promotionFailed(source: URL, destination: URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidTemporarySession:
            return "临时录音目录不属于 LiveLingo，已停止文件操作。"
        case .recordingMissing:
            return "临时录音文件不存在。"
        case let .promotionFailed(source, destination, reason):
            return "录音迁移失败；临时录音仍保留在 \(source.path)，目标为 \(destination.path)。\(reason)"
        }
    }
}

enum SessionWorkspace {
    static let temporaryPrefix = "LiveLingo-Live-"
    static let recordingFileName = "recording.wav"

    static func makeTemporarySessionDirectory(
        fileManager: FileManager = .default,
        identifier: UUID = UUID()
    ) throws -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            temporaryPrefix + identifier.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    static func uniqueFinalDirectory(
        in outputRoot: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) -> URL {
        var candidate = outputRoot.appendingPathComponent(preferredName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = outputRoot.appendingPathComponent("\(preferredName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    static func promoteTemporarySession(
        from temporaryDirectory: URL,
        to outputRoot: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try validateTemporarySession(temporaryDirectory, fileManager: fileManager)
        let sourceRecording = temporaryDirectory.appendingPathComponent(recordingFileName)
        guard fileManager.fileExists(atPath: sourceRecording.path) else {
            throw SessionWorkspaceError.recordingMissing
        }

        let destination = uniqueFinalDirectory(
            in: outputRoot,
            preferredName: preferredName,
            fileManager: fileManager
        )

        let receipt = try SessionTreeMigration.promote(from: temporaryDirectory, to: destination,
            operations: .init(copyTree: { try fileManager.copyItem(at: $0, to: $1) }))
        // Preserve the exact recovery location after full-tree verification.
        if let preserved = receipt.preservedSourceDirectory {
            let recovery = ["source": preserved.path, "destination": destination.path]
            let bytes = try JSONSerialization.data(withJSONObject: recovery, options: [.sortedKeys])
            try bytes.write(to: destination.appendingPathComponent("migration-recovery.json"), options: .atomic)
        }
        return receipt.destinationDirectory
    }

    static func discardTemporarySession(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try validateTemporarySession(directory, fileManager: fileManager)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    static func copyTemporarySession(from temporaryDirectory: URL, to outputRoot: URL,
                                     preferredName: String) throws -> SessionMigrationReceipt {
        try validateTemporarySession(temporaryDirectory, fileManager: .default)
        guard FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent(recordingFileName).path) else {
            throw SessionWorkspaceError.recordingMissing
        }
        let destination = uniqueFinalDirectory(in: outputRoot, preferredName: preferredName, fileManager: .default)
        return try SessionTreeMigration.copyVerified(from: temporaryDirectory, to: destination)
    }

    private static func validateTemporarySession(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedDirectory.deletingLastPathComponent() == resolvedRoot,
              resolvedDirectory.lastPathComponent.hasPrefix(temporaryPrefix)
        else {
            throw SessionWorkspaceError.invalidTemporarySession
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> UInt64 {
        let values = try fileManager.attributesOfItem(atPath: url.path)
        return (values[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

enum SessionExporter {
    struct Manifest: Codable, Equatable {
        let createdAt: Date
        let sourceLocale: String
        let targetLocale: String
        let recordingFile: String
        let segmentCount: Int
    }

    static func export(
        segments: [TranscriptSegment],
        sessionDirectory: URL,
        recordingFileName: String = "recording.wav",
        summary: String = "",
        createdAt: Date = Date()
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let english = segments.map(\.english).joined(separator: "\n")
        let chinese = segments.map { Self.humanReadableChinese($0.chinese) }.joined(separator: "\n")
        try english.appending("\n").write(
            to: sessionDirectory.appendingPathComponent("transcript-en.txt"),
            atomically: true,
            encoding: .utf8
        )
        try chinese.appending("\n").write(
            to: sessionDirectory.appendingPathComponent("transcript-zh-Hans.txt"),
            atomically: true,
            encoding: .utf8
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let jsonl = try segments.map { segment -> String in
            let data = try encoder.encode(segment)
            guard let line = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return line
        }.joined(separator: "\n") + "\n"
        try jsonl.write(
            to: sessionDirectory.appendingPathComponent("bilingual.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let srt = segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))
            \(segment.english)
            \(Self.humanReadableChinese(segment.chinese))
            """
        }.joined(separator: "\n\n") + "\n"
        try srt.write(
            to: sessionDirectory.appendingPathComponent("bilingual.srt"),
            atomically: true,
            encoding: .utf8
        )

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            try (trimmedSummary + "\n").write(
                to: sessionDirectory.appendingPathComponent("summary-zh-Hans.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let manifest = Manifest(
            createdAt: createdAt,
            sourceLocale: "en-US",
            targetLocale: "zh-Hans",
            recordingFile: recordingFileName,
            segmentCount: segments.count
        )
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: sessionDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    /// 2026-09-18：给人看的出口（字幕/转写/笔记导出）不该出现 `[翻译失败：…]` 这种英文错误串 ✗。
    /// 内存里的占位符原样保留 ✓（它是应用的重试信号 ✓，5 处 `hasPrefix("[翻译失败：")` 依赖它 ✓），
    /// 只在**渲染**时换成中性中文 ✓ —— 与既有的"（本段暂无译文）"同一风格 ✓。
    static func humanReadableChinese(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "（本段暂无译文）" }
        if trimmed.hasPrefix("[翻译失败：") { return "（本段翻译未完成，可对照英文）" }
        return raw
    }

    static func srtTimestamp(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, Int((interval * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }
}

// MARK: - 摘要导出（Markdown / 纯文本 / PDF）

import AppKit
import UniformTypeIdentifiers

enum NotesExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown
    case plainText
    case word
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "纯文本"
        case .word: return "Word"
        case .pdf: return "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .word: return "docx"
        case .pdf: return "pdf"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .plainText: return .plainText
        case .word: return UTType("org.openxmlformats.wordprocessingml.document")
                ?? UTType(filenameExtension: "docx") ?? .data
        case .pdf: return .pdf
        }
    }
}

enum NotesExportScope: String, CaseIterable, Identifiable, Sendable {
    case latest
    case wholeLesson

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest: return "最近更新"
        case .wholeLesson: return "整课笔记"
        }
    }

    /// Used in the default file name and inside the document header.
    var fileLabel: String {
        switch self {
        case .latest: return "最近更新"
        case .wholeLesson: return "整课笔记"
        }
    }
}

/// Everything the exporter needs, snapshotted on the main actor before the save
/// panel opens. Building a document never calls a model and never reads or
/// writes the recording.
///
/// 复查意见从 2026-09-19 起只以**整篇 Markdown**（`reviewMarkdown`）进入快照 ✓：
/// 四种格式渲染同一个章节 ✓，不再各自编号拼装 ✓，也就不可能出现"复查批次 1"这类
/// 与报告正文重复、又可能对不上号的标题 ✓。
struct NotesExportSnapshot: Equatable, Sendable {
    let className: String
    let sessionName: String?
    let scope: NotesExportScope
    let scopeDetail: String
    let coverageLine: String
    let notesMarkdown: String
    /// 复查报告全文（含顶层进度标题与批次小节）；没有复查意见时为 nil。
    let reviewMarkdown: String?
    let transcript: [TranscriptSegment]
    let generatedAt: Date
    let includesReviewAdvice: Bool
    let includesTranscript: Bool

    var classDate: String { NotesExportDocument.classDate(of: self) }
}

enum NotesExportError: LocalizedError {
    case emptyNotes
    case pdfContextUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyNotes: return "所选范围还没有可导出的笔记内容。"
        case .pdfContextUnavailable: return "无法创建 PDF 输出上下文。"
        case .writeFailed(let detail): return "写入文件失败：\(detail)"
        }
    }
}

enum NotesExportDocument {
    static let notesHeading = "学习笔记"
    static let reviewHeading = "9B 复查意见（仅供核对，未合并进笔记正文）"
    static let transcriptHeading = "双语字幕（含时间戳）"
    static let disclaimer = "本文件由本机模型生成，未经人工逐句核对；正文按主题整理，“需要回听”和“来源检查”两节列出的内容仍需自行核对。"

    static func classDate(of snapshot: NotesExportSnapshot) -> String {
        // Prefer the date inside the recording folder name (the class date).
        if let name = snapshot.sessionName, let range = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(name[range])
        }
        return dateFormatter.string(from: snapshot.generatedAt)
    }

    static func defaultFileName(_ snapshot: NotesExportSnapshot, format: NotesExportFormat) -> String {
        "\(snapshot.className) \(classDate(of: snapshot)) \(snapshot.scope.fileLabel).\(format.fileExtension)"
    }

    static func timestamp(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total / 60) % 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    static func header(_ snapshot: NotesExportSnapshot, markdown: Bool) -> [String] {
        var lines: [String] = []
        let title = "\(snapshot.className) · \(snapshot.scope.fileLabel) · \(classDate(of: snapshot))"
        lines.append(markdown ? "# \(title)" : title)
        lines.append("")
        lines.append("- 内容范围：\(snapshot.scope.title)（\(snapshot.scopeDetail)）")
        lines.append("- 整理进度：\(snapshot.coverageLine)")
        // 「最近更新」只限制笔记正文的范围；复查意见是**整场录音**的。
        if snapshot.includesReviewAdvice, snapshot.reviewMarkdown != nil, snapshot.scope == .latest {
            lines.append("- 复查范围：本录音所有已完成的复查批次（不受“最近更新”笔记范围限制）")
        }
        if let session = snapshot.sessionName {
            lines.append("- 来源录音：\(session)")
        }
        lines.append("- 导出时间：\(timestampFormatter.string(from: snapshot.generatedAt))")
        lines.append("- 说明：\(disclaimer)")
        lines.append("")
        return lines
    }

    /// 复查章节正文（四种格式共用 ✓）。
    ///
    /// - 顶层报告标题（`# …`）转成一行"复查进度"文字 ✓（不再和章节标题抢层级 ✓）；
    /// - 批次标题（`## 第 N 批 …`）降为子级（`### …`）✓，保留原有的批号与主题 ✓；
    /// - 其余正文**原样保留** ✓（不认识的内容只搬不删 ✓）；
    /// - 不再另加"复查批次 1/2/3"编号 ✓（报告里已经有批号，重复编号会对不上 ✓）。
    static func reviewSection(_ markdown: String) -> String {
        var output: [String] = []
        var progressTaken = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# "), !progressTaken {
                progressTaken = true
                output.append("- 复查进度：" + trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("## ") {
                output.append("### " + trimmed.dropFirst(3))
                continue
            }
            output.append(text)
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 有复查意见时才存在的章节正文（层级已转换）；没有就是 nil。
    static func reviewBody(_ snapshot: NotesExportSnapshot) -> String? {
        guard snapshot.includesReviewAdvice, let review = snapshot.reviewMarkdown,
              !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let body = reviewSection(review)
        return body.isEmpty ? nil : body
    }

    /// 有复查意见时才存在的章节（Markdown / 纯文本两种渲染）。
    private static func reviewBlock(_ snapshot: NotesExportSnapshot, markdown: Bool) -> String? {
        guard let body = reviewBody(snapshot) else { return nil }
        return markdown ? "## \(reviewHeading)\n\n" + body : reviewHeading + "\n\n" + strippingMarkdown(body)
    }

    static func markdown(_ snapshot: NotesExportSnapshot) -> String {
        var sections: [String] = [header(snapshot, markdown: true).joined(separator: "\n")]
        let notes = snapshot.notesMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("## \(notesHeading)\n\n" + (notes.isEmpty ? "（所选范围暂无笔记）" : notes))
        if let review = reviewBlock(snapshot, markdown: true) {
            sections.append(review)
        }
        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            let lines = snapshot.transcript.map { segment -> String in
                let stamp = "\(timestamp(segment.startTime))–\(timestamp(segment.endTime))"
                let chinese = SessionExporter.humanReadableChinese(segment.chinese)
                return "[\(stamp)] \(segment.english)\n\(chinese)"
            }
            sections.append("## \(transcriptHeading)\n\n" + lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func plainText(_ snapshot: NotesExportSnapshot) -> String {
        var sections: [String] = []
        sections.append(header(snapshot, markdown: true)
            .map { $0.hasPrefix("- ") ? "  " + String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n"))
        let notes = strippingMarkdown(snapshot.notesMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(notesHeading + "\n\n" + (notes.isEmpty ? "（所选范围暂无笔记）" : notes))
        if let review = reviewBlock(snapshot, markdown: false) {
            sections.append(review)
        }
        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            let lines = snapshot.transcript.map { segment -> String in
                let stamp = "\(timestamp(segment.startTime))–\(timestamp(segment.endTime))"
                let chinese = SessionExporter.humanReadableChinese(segment.chinese)
                return "[\(stamp)] \(segment.english)\n\(chinese)"
            }
            sections.append(transcriptHeading + "\n\n" + lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n\n") + "\n"
    }

    static func data(_ snapshot: NotesExportSnapshot, format: NotesExportFormat) throws -> Data {
        switch format {
        case .markdown: return Data(markdown(snapshot).utf8)
        case .plainText: return Data(plainText(snapshot).utf8)
        case .word: return try wordData(snapshot)
        case .pdf: return try PDFNotesWriter.data(snapshot)
        }
    }

    /// `.docx` through the same attributed content the PDF uses: AppKit writes a
    /// real OOXML package, so Word opens it as an editable document with the
    /// headings, bold labels and sub/superscript formulas intact.
    static func wordData(_ snapshot: NotesExportSnapshot) throws -> Data {
        let attributed = PDFNotesWriter.attributedDocument(snapshot)
        do {
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
        } catch {
            throw NotesExportError.writeFailed(error.localizedDescription)
        }
    }

    static func write(_ snapshot: NotesExportSnapshot, format: NotesExportFormat, to url: URL) throws {
        let payload = try data(snapshot, format: format)
        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            throw NotesExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Drops Markdown syntax while keeping headings, paragraphs, formulas,
    /// timestamps and the “待核对/待确认” markers readable in plain text.
    static func strippingMarkdown(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var text = String(line)
            if let range = text.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
            text = text.replacingOccurrences(of: "**", with: "")
            text = text.replacingOccurrences(of: "__", with: "")
            if text.hasPrefix("> ") { text = String(text.dropFirst(2)) }
            return text
        }.joined(separator: "\n")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// PDF output through AppKit's text system: it paginates and wraps CJK text and
/// keeps sub/superscript formulas readable, without adding a PDF library.
enum PDFNotesWriter {
    static let pageSize = CGSize(width: 595, height: 842) // A4 in points
    static let margin: CGFloat = 48
    static let bodySize: CGFloat = 11

    static func data(_ snapshot: NotesExportSnapshot) throws -> Data {
        let attributed = attributedDocument(snapshot)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw NotesExportError.pdfContextUnavailable
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NotesExportError.pdfContextUnavailable
        }

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        // Each container consumes the glyphs it lays out, so the loop keeps
        // adding pages until every glyph has been drawn.
        while true {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphRange = layoutManager.glyphRange(for: container)
            context.beginPDFPage(nil)
            // TextKit 按"y 向下"排布行位置；PDF 上下文默认是"y 向上"。
            // 不翻转的话，每段文字的行序会上下颠倒（标题落到条目下方、文档标题跑到页尾），
            // 视觉与文本层都能看出来。这里把每页的坐标系翻成 y 向下再绘制。
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.current = nil
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            if NSMaxRange(glyphRange) >= layoutManager.numberOfGlyphs || glyphRange.length == 0 { break }
        }
        context.closePDF()
        return output as Data
    }

    static func attributedDocument(_ snapshot: NotesExportSnapshot) -> NSAttributedString {
        let output = NSMutableAttributedString()
        func append(_ text: String, style: Style) {
            output.append(line(text, style: style))
        }

        append("\(snapshot.className) · \(snapshot.scope.fileLabel) · \(snapshot.classDate)", style: .title)
        append("内容范围：\(snapshot.scope.title)（\(snapshot.scopeDetail)）", style: .meta)
        append("整理进度：\(snapshot.coverageLine)", style: .meta)
        if snapshot.includesReviewAdvice, snapshot.reviewMarkdown != nil, snapshot.scope == .latest {
            append("复查范围：本录音所有已完成的复查批次（不受“最近更新”笔记范围限制）", style: .meta)
        }
        if let session = snapshot.sessionName { append("来源录音：\(session)", style: .meta) }
        append("导出时间：\(NotesExportDocument.timestampFormatter.string(from: snapshot.generatedAt))", style: .meta)
        append(NotesExportDocument.disclaimer, style: .meta)

        append(NotesExportDocument.notesHeading, style: .heading)
        let notes = snapshot.notesMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty {
            append("（所选范围暂无笔记）", style: .body)
        } else {
            for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
                append(String(line), style: Style.markdown(String(line)))
            }
        }

        if let review = NotesExportDocument.reviewBody(snapshot) {
            append(NotesExportDocument.reviewHeading, style: .heading)
            for line in review.split(separator: "\n", omittingEmptySubsequences: false) {
                append(String(line), style: Style.markdown(String(line)))
            }
        }

        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            append(NotesExportDocument.transcriptHeading, style: .heading)
            for segment in snapshot.transcript {
                let stamp = "\(NotesExportDocument.timestamp(segment.startTime))–\(NotesExportDocument.timestamp(segment.endTime))"
                append("[\(stamp)] \(segment.english)", style: .body)
                append(SessionExporter.humanReadableChinese(segment.chinese), style: .translation)
            }
        }
        return output
    }

    enum Style {
        case title, heading, subheading, body, translation, bullet(Int), meta

        static func markdown(_ line: String) -> Style {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .meta }
            if trimmed.hasPrefix("### ") { return .subheading }
            if trimmed.hasPrefix("## ") { return .heading }
            if trimmed.hasPrefix("# ") { return .heading }
            let indentation = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return .bullet(indentation / 2) }
            return .body
        }
    }

    static func text(of style: Style, line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        switch style {
        case .heading, .subheading, .title:
            for prefix in ["### ", "## ", "# "] where trimmed.hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count))
                break
            }
        case .bullet:
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { trimmed = String(trimmed.dropFirst(2)) }
        default:
            break
        }
        return trimmed
    }

    static func line(_ source: String, style: Style) -> NSAttributedString {
        let text = text(of: style, line: source)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2.5
        paragraph.paragraphSpacing = 3
        switch style {
        case .title:
            paragraph.paragraphSpacing = 8
        case .heading:
            paragraph.paragraphSpacingBefore = 12
            paragraph.paragraphSpacing = 6
        case .subheading:
            paragraph.paragraphSpacingBefore = 8
        case .bullet(let depth):
            paragraph.firstLineHeadIndent = CGFloat(depth) * 16
            paragraph.headIndent = CGFloat(16 * (depth + 1))
        default:
            break
        }

        let size: CGFloat
        switch style {
        case .title: size = 18
        case .heading: size = 14
        case .subheading: size = 12
        case .meta: size = 9
        default: size = bodySize
        }
        let bold: Bool
        switch style {
        case .title, .heading, .subheading: bold = true
        default: bold = false
        }

        let result = NSMutableAttributedString()
        for run in inlineRuns(text, size: size, bold: bold) {
            result.append(run)
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        if case .meta = style {
            result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: result.length))
        }
        // A blank line still needs a paragraph so it keeps its vertical space.
        if result.length == 0 { result.append(NSAttributedString(string: " ")) }
        result.append(NSAttributedString(string: "\n"))
        return result
    }

    /// Inline runs: `**bold**` plus `$…$` / `\(…)` formulas, which are rendered
    /// with real sub/superscript baselines instead of raw LaTeX-ish markers.
    static func inlineRuns(_ source: String, size: CGFloat, bold: Bool) -> [NSAttributedString] {
        var runs: [NSAttributedString] = []
        let pattern = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
        let ns = source as NSString
        var cursor = 0

        func appendPlain(_ piece: String, strong: Bool) {
            guard !piece.isEmpty else { return }
            for run in FormulaDisplay.runs(piece) {
                let fontSize = run.script == 0 ? size : size * 0.72
                let font = font(size: fontSize, bold: strong || (run.math && !run.text.isEmpty))
                var attributes: [NSAttributedString.Key: Any] = [.font: font]
                if run.script != 0 {
                    attributes[.baselineOffset] = run.script > 0 ? size * 0.34 : -size * 0.16
                }
                if run.math {
                    attributes[.foregroundColor] = NSColor.labelColor
                }
                runs.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }

        if let pattern {
            for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > cursor {
                    appendPlain(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), strong: bold)
                }
                appendPlain(ns.substring(with: match.range(at: 1)), strong: true)
                cursor = NSMaxRange(match.range)
            }
        }
        if cursor < ns.length {
            appendPlain(ns.substring(from: cursor), strong: bold)
        }
        if runs.isEmpty { runs.append(NSAttributedString(string: source, attributes: [.font: font(size: size, bold: bold)])) }
        return runs
    }

    /// PDF 的文字层必须能被搜索和复制。实测（2026-09-18）：用 AppKit 排版嵌入后，
    /// PingFang SC 与 STHeiti SC 会把 149 个汉字写成**康熙部首码点**
    /// （「一」→U+2F00、「水」→U+2F54、「而」→U+2F7D、「氏」→U+2F52…），共 33 种；
    /// 人眼看不出差别，但从 PDF 搜索、复制、朗读全部失效。Hiragino Sans GB 不受影响，
    /// 因此把它提到首选（原先它是第二备选）。docx 路径不受此影响（写的是 Unicode 文本）。
    static func font(size: CGFloat, bold: Bool) -> NSFont {
        let candidates = bold
            ? ["HiraginoSansGB-W6", "PingFangSC-Semibold", "STHeitiSC-Medium"]
            : ["HiraginoSansGB-W3", "PingFangSC-Regular", "STHeitiSC-Light"]
        for name in candidates {
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
}
