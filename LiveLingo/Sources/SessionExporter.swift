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

    static func temporaryRoot(fileManager: FileManager = .default) throws -> URL {
        #if LIVELINGO_PREVIEW
        let root = try PreviewDataIsolation.dataURL("Temporary")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
        #else
        return fileManager.temporaryDirectory
        #endif
    }

    static func makeTemporarySessionDirectory(
        fileManager: FileManager = .default,
        identifier: UUID = UUID()
    ) throws -> URL {
        let directory = try temporaryRoot(fileManager: fileManager).appendingPathComponent(
            temporaryPrefix + identifier.uuidString,
            isDirectory: true
        )
        let root = try SensitiveFileIO.Directory.open(at: fileManager.temporaryDirectory, create: false, tighten: false)
        _ = try root.subdirectory(named: directory.lastPathComponent)
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
            try SensitiveFileIO.atomicWrite(bytes, to: destination.appendingPathComponent("migration-recovery.json"))
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
        let resolvedRoot = try temporaryRoot(fileManager: fileManager).standardizedFileURL.resolvingSymlinksInPath()
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
        var sourceLanguages: [String]? = nil
        var converterVersion: String? = nil
    }

    static var targetTranscriptFileName: String { targetTranscriptFileName(for: CaptionTranslationTarget.simplifiedChinese.rawValue) }
    static var targetSummaryFileName: String { targetSummaryFileName(for: CaptionTranslationTarget.simplifiedChinese.rawValue) }

    static func targetTranscriptFileName(for locale: String) -> String {
        // The legacy source transcript must remain distinct from English output.
        locale == "en" ? "transcript-target-en.txt" : "transcript-\(locale).txt"
    }

    static func targetSummaryFileName(for locale: String) -> String { "summary-\(locale).md" }

    static func isValidTargetLocale(_ locale: String) -> Bool {
        locale.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil
    }

    /// Saved courses keep the target recorded at export time. Pre-manifest
    /// courses retain their legacy summary name and identity fingerprint.
    static func savedSummaryURL(in directory: URL) -> URL {
        // This convenience entry point is for callers outside SessionStore's
        // lock. Store readers must use the explicit-target overload below.
        let snapshotURL = directory.appendingPathComponent(SessionStore.snapshotFileName)
        let snapshot = FileManager.default.fileExists(atPath: snapshotURL.path)
            ? try? SessionStore(directory: directory).load() : nil
        return savedSummaryURL(in: directory, targetLocale: snapshot?.targetLocale)
    }

    /// Does not acquire a SessionStore lock or read a snapshot. The caller
    /// supplies its already known target (nil for a legacy import).
    static func savedSummaryURL(in directory: URL, targetLocale: String?) -> URL {
        struct TargetMetadata: Decodable { let targetLocale: String }
        var names: [String] = []
        if let locale = targetLocale, isValidTargetLocale(locale) {
            names.append(targetSummaryFileName(for: locale))
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let metadata = try? JSONDecoder().decode(TargetMetadata.self, from: data),
           isValidTargetLocale(metadata.targetLocale) {
            names.append(targetSummaryFileName(for: metadata.targetLocale))
        }
        for name in ["summary-zh-Hans.md"] where !names.contains(name) {
            names.append(name)
        }
        return names.map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            ?? directory.appendingPathComponent(names[0])
    }

    /// Language labels are UI metadata, never part of copied/exported text.
    static func sourceLine(_ segment: TranscriptSegment) -> String { segment.english }

    static func targetLine(_ segment: TranscriptSegment, target: CaptionTranslationTarget = .simplifiedChinese) -> String {
        if target.keepsSourceAsCaption(language: segment.sourceLanguage) {
            return segment.hasUsableTranslation ? segment.chinese : target.renderPassThrough(segment.english)
        }
        if target != .simplifiedChinese {
            if segment.translationState == .failed { return ClassroomFixedText.failedAgainstSource.text(targetCode: target.rawValue) }
            return segment.hasUsableTranslation ? segment.chinese : ClassroomFixedText.pendingTranslation.text(targetCode: target.rawValue)
        }
        if segment.sourceLanguage != nil, segment.translationState == .failed {
            return "（本段翻译未完成，可对照原文）"
        }
        return humanReadableChinese(segment.chinese)
    }

    static func captionLines(_ segment: TranscriptSegment, target: CaptionTranslationTarget = .simplifiedChinese) -> [String] {
        target.keepsSourceAsCaption(language: segment.sourceLanguage)
            ? [targetLine(segment, target: target)] : [sourceLine(segment), targetLine(segment, target: target)]
    }

    static func sourceLanguages(in segments: [TranscriptSegment]) -> [String]? {
        let codes = Set(segments.compactMap(\.sourceLanguage)).sorted()
        return codes.isEmpty ? nil : codes
    }

    static func srtCue(_ segment: TranscriptSegment, index: Int, target: CaptionTranslationTarget = .simplifiedChinese) -> String {
        return "\(index + 1)\n\(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))\n"
            + captionLines(segment, target: target).joined(separator: "\n")
    }

    /// Saved text can be verified before its language is released for generation.
    static func targetLine(_ segment: TranscriptSegment, outputLanguage: OutputLanguage) -> String {
        if let generated = outputLanguage.generationTarget {
            return targetLine(segment, target: generated)
        }
        if outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage) {
            return segment.hasUsableTranslation ? segment.chinese : segment.english
        }
        if segment.translationState == .failed {
            return ClassroomFixedText.failedAgainstSource.text(targetCode: outputLanguage.rawValue)
        }
        if !segment.hasUsableTranslation {
            return ClassroomFixedText.pendingTranslation.text(targetCode: outputLanguage.rawValue)
        }
        return segment.chinese
    }

    static func captionLines(_ segment: TranscriptSegment, outputLanguage: OutputLanguage) -> [String] {
        let translated = targetLine(segment, outputLanguage: outputLanguage)
        if outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage) {
            return [translated]
        }
        return [sourceLine(segment), translated]
    }

    static func srtCue(_ segment: TranscriptSegment, index: Int, outputLanguage: OutputLanguage) -> String {
        "\(index + 1)\n\(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))\n"
            + captionLines(segment, outputLanguage: outputLanguage).joined(separator: "\n")
    }

    /// The existing targetLine/captionLines/srtCue APIs remain generation text
    /// for UI callers. Export and saved-output verification render exactly once.
    static func renderedTargetLine(_ segment: TranscriptSegment, outputLanguage: OutputLanguage,
                                   converter: ChineseScriptConverter = .shared) throws -> String {
        var draft = targetLine(segment, outputLanguage: outputLanguage)
        let sourceOnly = outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage)
        if outputLanguage.profile.renderer != .identity, !sourceOnly, segment.translationState == .failed {
            draft = (segment.sourceLanguage == nil ? ClassroomFixedText.failedAgainstEnglish : .failedAgainstSource)
                .text(targetCode: "zh-Hans")
        }
        return !sourceOnly && !segment.hasUsableTranslation
            ? try outputLanguage.renderFixedText(draft, converter: converter)
            : try outputLanguage.render(draft, converter: converter)
    }

    static func renderedCaptionLines(_ segment: TranscriptSegment, outputLanguage: OutputLanguage,
                                    converter: ChineseScriptConverter = .shared) throws -> [String] {
        let translated = try renderedTargetLine(segment, outputLanguage: outputLanguage, converter: converter)
        return outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage)
            ? [translated] : [sourceLine(segment), translated]
    }

    static func renderedSRTCue(_ segment: TranscriptSegment, index: Int, outputLanguage: OutputLanguage,
                               converter: ChineseScriptConverter = .shared) throws -> String {
        "\(index + 1)\n\(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))\n"
            + (try renderedCaptionLines(segment, outputLanguage: outputLanguage, converter: converter))
                .joined(separator: "\n")
    }

    static func export(
        segments: [TranscriptSegment],
        sessionDirectory: URL,
        recordingFileName: String = "recording.wav",
        summary: String = "",
        createdAt: Date = Date(),
        target: OutputLanguage = .simplifiedChinese,
        summaryIsLegacyRendered: Bool = false,
        summaryEvidence: [TranscriptSegment] = [],
        converter: ChineseScriptConverter = .shared
    ) throws {
        // Check the actual dictionary, including empty/legacy-only exports.
        // Release metadata does not determine whether saved text can render.
        if target.profile.renderer != .identity {
            try converter.prepare()
        }
        let english = segments.map(sourceLine).joined(separator: "\n")
        let chinese = try segments.map { try renderedTargetLine($0, outputLanguage: target, converter: converter) }.joined(separator: "\n")
        let srt = try segments.enumerated().map { index, segment in
            try renderedSRTCue(segment, index: index, outputLanguage: target, converter: converter)
        }.joined(separator: "\n\n") + "\n"
        let trimmedSummary = try ClassroomMarkdownRendering.render(summary, language: target,
            isLegacyRendered: summaryIsLegacyRendered,
            scheduleEvidence: summaryEvidence.isEmpty ? segments : summaryEvidence,
            converter: converter).trimmingCharacters(in: .whitespacesAndNewlines)
        try SensitiveFileIO.prepareDirectory(sessionDirectory)
        try SensitiveFileIO.atomicWrite(Data(english.appending("\n").utf8),
            to: sessionDirectory.appendingPathComponent("transcript-en.txt"))
        try SensitiveFileIO.atomicWrite(Data(chinese.appending("\n").utf8),
            to: sessionDirectory.appendingPathComponent(targetTranscriptFileName(for: target.rawValue)))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let jsonl = try segments.map { segment -> String in
            let data = try ChineseOutputDefaults.encodeBilingualDraft(segment, using: encoder)
            guard let line = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return line
        }.joined(separator: "\n") + "\n"
        try SensitiveFileIO.atomicWrite(Data(jsonl.utf8), to: sessionDirectory.appendingPathComponent("bilingual.jsonl"))

        try SensitiveFileIO.atomicWrite(Data(srt.utf8), to: sessionDirectory.appendingPathComponent("bilingual.srt"))

        if !trimmedSummary.isEmpty {
            try SensitiveFileIO.atomicWrite(Data((trimmedSummary + "\n").utf8),
                to: sessionDirectory.appendingPathComponent(targetSummaryFileName(for: target.rawValue)))
        }

        let manifest = Manifest(
            createdAt: createdAt,
            sourceLocale: "en-US",
            targetLocale: target.rawValue,
            recordingFile: recordingFileName,
            segmentCount: segments.count,
            sourceLanguages: sourceLanguages(in: segments),
            converterVersion: target.profile.renderer == .identity ? nil : ChineseScriptConverter.version
        )
        let manifestData = try encoder.encode(manifest)
        try SensitiveFileIO.atomicWrite(manifestData, to: sessionDirectory.appendingPathComponent("manifest.json"))
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
    var target: OutputLanguage = .simplifiedChinese
    /// Legacy summaries are already rendered; review advice still uses its
    /// independently stored generation text.
    var notesAreLegacyRendered: Bool = false
    /// Evidence remains available even when the user omits the transcript.
    var scheduleEvidence: [TranscriptSegment] = []

    var classDate: String { NotesExportDocument.classDate(of: self) }
}

enum NotesExportError: LocalizedError {
    case emptyNotes
    case pdfContextUnavailable
    case rendererUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyNotes: return "所选范围还没有可导出的笔记内容。"
        case .pdfContextUnavailable: return "无法创建 PDF 输出上下文。"
        case .rendererUnavailable: return "课程输出语言的渲染器尚不可用，暂时无法导出笔记。"
        case .writeFailed(let detail): return "写入文件失败：\(detail)"
        }
    }
}

enum NotesExportDocument {
    /// Prepared fields are shared by all four formats. Source quotations,
    /// recording names and source caption lines are never a conversion input.
    struct RenderedFields {
        let className: String
        let scopeDetail: String
        let coverageLine: String
        let notesMarkdown: String
        var reviewBody: String?
        let labels: [ClassroomFixedText: String]
        let transcriptHeading: String
        let captionLines: [[String]]
    }

    static func prepare(_ snapshot: NotesExportSnapshot,
                        converter: ChineseScriptConverter = .shared) throws -> RenderedFields? {
        let target = snapshot.target
        guard target.profile.renderer != .identity else { return nil }
        do {
            // A supplied missing dictionary must fail even when no Han text is
            // present or the legacy notes themselves need no conversion.
            try converter.prepare()
            let keys: [ClassroomFixedText] = [.notesHeading, .exportReviewHeading, .exportDisclaimer,
                .latestScope, .wholeScope, .exportScopeLine, .exportCoverageLine, .exportReviewScope,
                .exportSessionLine, .exportTimeLine, .exportExplanationLine, .exportProgressLine, .emptyNotes]
            let labels = try Dictionary(uniqueKeysWithValues: keys.map {
                ($0, try target.renderFixedText($0.text(targetCode: target.rawValue), converter: converter))
            })
            var fields = RenderedFields(
                className: try target.render(snapshot.className, converter: converter),
                scopeDetail: try target.render(snapshot.scopeDetail, converter: converter),
                coverageLine: try target.render(snapshot.coverageLine, converter: converter),
                notesMarkdown: try ClassroomMarkdownRendering.render(snapshot.notesMarkdown, language: target,
                    isLegacyRendered: snapshot.notesAreLegacyRendered,
                    scheduleEvidence: snapshot.scheduleEvidence.isEmpty ? snapshot.transcript : snapshot.scheduleEvidence,
                    converter: converter),
                reviewBody: nil,
                labels: labels,
                transcriptHeading: try target.renderFixedText(transcriptHeading(for: target), converter: converter),
                captionLines: snapshot.includesTranscript ? try snapshot.transcript.map {
                    try SessionExporter.renderedCaptionLines($0, outputLanguage: target, converter: converter)
                } : []
            )
            if snapshot.includesReviewAdvice, let review = snapshot.reviewMarkdown,
               !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let renderedReview = try ClassroomMarkdownRendering.render(review, language: target,
                    scheduleEvidence: snapshot.scheduleEvidence, converter: converter)
                let body = reviewSection(renderedReview, target: target, rendered: fields)
                fields.reviewBody = body.isEmpty ? nil : body
            }
            return fields
        } catch {
            throw NotesExportError.rendererUnavailable
        }
    }

    static func fixed(_ key: ClassroomFixedText, target: OutputLanguage,
                      rendered: RenderedFields? = nil) -> String {
        rendered?.labels[key] ?? key.text(targetCode: target.rawValue)
    }
    static func fixed(_ key: ClassroomFixedText, _ args: [String], target: OutputLanguage,
                      rendered: RenderedFields? = nil) -> String {
        guard let rendered else { return key.format(args: args, targetCode: target.rawValue) }
        // Convert the template before inserting arguments. Searching/replacing
        // an assembled line could rewrite a quote or a recording folder name.
        let template = fixed(key, target: target, rendered: rendered)
        let regex = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        var result = ""
        var cursor = template.startIndex
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template),
                  let digits = Range(match.range(at: 1), in: template),
                  let index = Int(template[digits]), args.indices.contains(index) else { continue }
            result += template[cursor..<range.lowerBound]
            result += args[index]
            cursor = range.upperBound
        }
        return result + template[cursor...]
    }
    static func notesHeading(for target: OutputLanguage, rendered: RenderedFields? = nil) -> String {
        fixed(.notesHeading, target: target, rendered: rendered)
    }
    static func reviewHeading(for target: OutputLanguage, rendered: RenderedFields? = nil) -> String {
        fixed(.exportReviewHeading, target: target, rendered: rendered)
    }
    static func disclaimer(for target: OutputLanguage, rendered: RenderedFields? = nil) -> String {
        fixed(.exportDisclaimer, target: target, rendered: rendered)
    }
    static func scopeLabel(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) -> String {
        fixed(snapshot.scope == .latest ? .latestScope : .wholeScope, target: snapshot.target, rendered: rendered)
    }

    static let notesHeading = "学习笔记"
    static let reviewHeading = "9B 复查意见（仅供核对，未合并进笔记正文）"
    static let transcriptHeading = "双语字幕（含时间戳）"
    static func transcriptHeading(for target: OutputLanguage) -> String {
        target == .english ? ClassroomFixedText.transcriptHeading.text(targetCode: target.rawValue) : transcriptHeading
    }
    static let disclaimer = "本文件由本机模型生成，未经人工逐句核对；正文按主题整理，“需要回听”和“来源检查”两节列出的内容仍需自行核对。"

    static func classDate(of snapshot: NotesExportSnapshot) -> String {
        // Prefer the date inside the recording folder name (the class date).
        if let name = snapshot.sessionName, let range = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(name[range])
        }
        return dateFormatter.string(from: snapshot.generatedAt)
    }

    static func defaultFileName(_ snapshot: NotesExportSnapshot, format: NotesExportFormat) -> String {
        "\(snapshot.className) \(classDate(of: snapshot)) \(scopeLabel(snapshot)).\(format.fileExtension)"
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

    static func header(_ snapshot: NotesExportSnapshot, markdown: Bool, rendered: RenderedFields? = nil) -> [String] {
        var lines: [String] = []
        let title = "\(rendered?.className ?? snapshot.className) · \(scopeLabel(snapshot, rendered: rendered)) · \(classDate(of: snapshot))"
        lines.append(markdown ? "# \(title)" : title)
        lines.append("")
        lines.append("- " + fixed(.exportScopeLine, [scopeLabel(snapshot, rendered: rendered), rendered?.scopeDetail ?? snapshot.scopeDetail], target: snapshot.target, rendered: rendered))
        lines.append("- " + fixed(.exportCoverageLine, [rendered?.coverageLine ?? snapshot.coverageLine], target: snapshot.target, rendered: rendered))
        // 「最近更新」只限制笔记正文的范围；复查意见是**整场录音**的。
        if snapshot.includesReviewAdvice, snapshot.reviewMarkdown != nil, snapshot.scope == .latest {
            lines.append("- " + fixed(.exportReviewScope, target: snapshot.target, rendered: rendered))
        }
        if let session = snapshot.sessionName {
            lines.append("- " + fixed(.exportSessionLine, [session], target: snapshot.target, rendered: rendered))
        }
        lines.append("- " + fixed(.exportTimeLine, [timestampFormatter.string(from: snapshot.generatedAt)], target: snapshot.target, rendered: rendered))
        lines.append("- " + fixed(.exportExplanationLine, [disclaimer(for: snapshot.target, rendered: rendered)], target: snapshot.target, rendered: rendered))
        lines.append("")
        return lines
    }

    /// 复查章节正文（四种格式共用 ✓）。
    ///
    /// - 顶层报告标题（`# …`）转成一行"复查进度"文字 ✓（不再和章节标题抢层级 ✓）；
    /// - 批次标题（`## 第 N 批 …`）降为子级（`### …`）✓，保留原有的批号与主题 ✓；
    /// - 正常建议原样保留；旧机器失败行改为固定说明，不再次导出自由诊断；
    /// - 不再另加"复查批次 1/2/3"编号 ✓（报告里已经有批号，重复编号会对不上 ✓）。
    static func reviewSection(_ markdown: String, target: OutputLanguage = .simplifiedChinese,
                              rendered: RenderedFields? = nil) -> String {
        var output: [String] = []
        var progressTaken = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let failurePrefixes = ["本批复查失败，保留原笔记：", "读取路径失败", "复查进度读取失败",
                                   "复查报告读取失败", "报告保存失败", "复查报告保存失败"]
            if failurePrefixes.contains(where: trimmed.hasPrefix) {
                output.append("本批复查未完成，原笔记已保留。")
                continue
            }
            if trimmed.hasPrefix("# "), !progressTaken {
                progressTaken = true
                output.append("- " + fixed(.exportProgressLine, [trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)], target: target, rendered: rendered))
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
    static func reviewBody(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) -> String? {
        if let rendered { return rendered.reviewBody }
        guard snapshot.includesReviewAdvice, let review = snapshot.reviewMarkdown,
              !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let body = reviewSection(review, target: snapshot.target)
        return body.isEmpty ? nil : body
    }

    /// 有复查意见时才存在的章节（Markdown / 纯文本两种渲染）。
    private static func reviewBlock(_ snapshot: NotesExportSnapshot, markdown: Bool,
                                    rendered: RenderedFields? = nil) -> String? {
        guard let body = reviewBody(snapshot, rendered: rendered) else { return nil }
        let heading = reviewHeading(for: snapshot.target, rendered: rendered)
        return markdown ? "## \(heading)\n\n" + body : heading + "\n\n" + strippingMarkdown(body)
    }

    static func markdown(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) -> String {
        var sections: [String] = [header(snapshot, markdown: true, rendered: rendered).joined(separator: "\n")]
        let notes = (rendered?.notesMarkdown ?? snapshot.notesMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("## \(notesHeading(for: snapshot.target, rendered: rendered))\n\n" + (notes.isEmpty ? fixed(.emptyNotes, target: snapshot.target, rendered: rendered) : notes))
        if let review = reviewBlock(snapshot, markdown: true, rendered: rendered) {
            sections.append(review)
        }
        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            let lines = snapshot.transcript.enumerated().map { index, segment -> String in
                let stamp = "\(timestamp(segment.startTime))–\(timestamp(segment.endTime))"
                let captions = rendered?.captionLines[index] ?? SessionExporter.captionLines(segment, outputLanguage: snapshot.target)
                return "[\(stamp)] " + captions.joined(separator: "\n")
            }
            sections.append("## \(rendered?.transcriptHeading ?? transcriptHeading(for: snapshot.target))\n\n" + lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func plainText(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) -> String {
        var sections: [String] = []
        sections.append(header(snapshot, markdown: true, rendered: rendered)
            .map { $0.hasPrefix("- ") ? "  " + String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n"))
        let notes = strippingMarkdown(rendered?.notesMarkdown ?? snapshot.notesMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append(notesHeading(for: snapshot.target, rendered: rendered) + "\n\n" + (notes.isEmpty ? fixed(.emptyNotes, target: snapshot.target, rendered: rendered) : notes))
        if let review = reviewBlock(snapshot, markdown: false, rendered: rendered) {
            sections.append(review)
        }
        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            let lines = snapshot.transcript.enumerated().map { index, segment -> String in
                let stamp = "\(timestamp(segment.startTime))–\(timestamp(segment.endTime))"
                let captions = rendered?.captionLines[index] ?? SessionExporter.captionLines(segment, outputLanguage: snapshot.target)
                return "[\(stamp)] " + captions.joined(separator: "\n")
            }
            sections.append((rendered?.transcriptHeading ?? transcriptHeading(for: snapshot.target)) + "\n\n" + lines.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n\n") + "\n"
    }

    static func data(_ snapshot: NotesExportSnapshot, format: NotesExportFormat,
                     converter: ChineseScriptConverter = .shared) throws -> Data {
        let rendered = try prepare(snapshot, converter: converter)
        switch format {
        case .markdown: return Data(markdown(snapshot, rendered: rendered).utf8)
        case .plainText: return Data(plainText(snapshot, rendered: rendered).utf8)
        case .word: return try wordData(snapshot, rendered: rendered)
        case .pdf: return try PDFNotesWriter.data(snapshot, rendered: rendered)
        }
    }

    /// `.docx` through the same attributed content the PDF uses: AppKit writes a
    /// real OOXML package, so Word opens it as an editable document with the
    /// headings, bold labels and sub/superscript formulas intact.
    static func wordData(_ snapshot: NotesExportSnapshot, rendered: RenderedFields? = nil) throws -> Data {
        let attributed = PDFNotesWriter.attributedDocument(snapshot, rendered: rendered)
        do {
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
        } catch {
            throw NotesExportError.writeFailed(error.localizedDescription)
        }
    }

    static func write(_ snapshot: NotesExportSnapshot, format: NotesExportFormat, to url: URL,
                      converter: ChineseScriptConverter = .shared) throws {
        let payload = try data(snapshot, format: format, converter: converter)
        do {
            try SensitiveFileIO.atomicWrite(payload, to: url)
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

    static func data(_ snapshot: NotesExportSnapshot, rendered: NotesExportDocument.RenderedFields? = nil) throws -> Data {
        let attributed = attributedDocument(snapshot, rendered: rendered)
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

    static func attributedDocument(_ snapshot: NotesExportSnapshot,
                                   rendered: NotesExportDocument.RenderedFields? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString()
        func append(_ text: String, style: Style) {
            output.append(line(text, style: style))
        }

        append("\(rendered?.className ?? snapshot.className) · \(NotesExportDocument.scopeLabel(snapshot, rendered: rendered)) · \(snapshot.classDate)", style: .title)
        append(NotesExportDocument.fixed(.exportScopeLine, [NotesExportDocument.scopeLabel(snapshot, rendered: rendered), rendered?.scopeDetail ?? snapshot.scopeDetail], target: snapshot.target, rendered: rendered), style: .meta)
        append(NotesExportDocument.fixed(.exportCoverageLine, [rendered?.coverageLine ?? snapshot.coverageLine], target: snapshot.target, rendered: rendered), style: .meta)
        if snapshot.includesReviewAdvice, snapshot.reviewMarkdown != nil, snapshot.scope == .latest {
            append(NotesExportDocument.fixed(.exportReviewScope, [], target: snapshot.target, rendered: rendered), style: .meta)
        }
        if let session = snapshot.sessionName { append(NotesExportDocument.fixed(.exportSessionLine, [session], target: snapshot.target, rendered: rendered), style: .meta) }
        append(NotesExportDocument.fixed(.exportTimeLine, [NotesExportDocument.timestampFormatter.string(from: snapshot.generatedAt)], target: snapshot.target, rendered: rendered), style: .meta)
        append(NotesExportDocument.disclaimer(for: snapshot.target, rendered: rendered), style: .meta)

        append(NotesExportDocument.notesHeading(for: snapshot.target, rendered: rendered), style: .heading)
        let notes = (rendered?.notesMarkdown ?? snapshot.notesMarkdown).trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty {
            append(NotesExportDocument.fixed(.emptyNotes, target: snapshot.target, rendered: rendered), style: .body)
        } else {
            for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
                append(String(line), style: Style.markdown(String(line)))
            }
        }

        if let review = NotesExportDocument.reviewBody(snapshot, rendered: rendered) {
            append(NotesExportDocument.reviewHeading(for: snapshot.target, rendered: rendered), style: .heading)
            for line in review.split(separator: "\n", omittingEmptySubsequences: false) {
                append(String(line), style: Style.markdown(String(line)))
            }
        }

        if snapshot.includesTranscript, !snapshot.transcript.isEmpty {
            append(rendered?.transcriptHeading ?? NotesExportDocument.transcriptHeading(for: snapshot.target), style: .heading)
            for (index, segment) in snapshot.transcript.enumerated() {
                let stamp = "\(NotesExportDocument.timestamp(segment.startTime))–\(NotesExportDocument.timestamp(segment.endTime))"
                let lines = rendered?.captionLines[index] ?? SessionExporter.captionLines(segment, outputLanguage: snapshot.target)
                append("[\(stamp)] \(lines[0])", style: .body)
                for translation in lines.dropFirst() { append(translation, style: .translation) }
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
