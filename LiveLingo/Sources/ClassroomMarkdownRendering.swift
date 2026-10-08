import Foundation

/// The generator and saved notebook retain Simplified Chinese. Render only
/// after structural classification, keeping source evidence and schedule
/// quotations separate from generated text.
enum ClassroomMarkdownRendering {
    static func render(_ markdown: String, language: OutputLanguage,
                       isLegacyRendered: Bool = false,
                       scheduleEvidence: [TranscriptSegment] = [],
                       converter: ChineseScriptConverter = .shared) throws -> String {
        guard language.profile.renderer != .identity, !isLegacyRendered else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        let document = ChineseScriptConverter.RenderText(markdown)
        var offset = 0
        return try lines.indices.map { index in
            let count = lines[index].utf8.count
            let protected = document.slice(offset..<(offset + count))
            offset += count + 1
            return try line(lines, at: index, language: language, scheduleEvidence: scheduleEvidence,
                            converter: converter, protected: protected, document: document)
        }.joined(separator: "\n")
    }

    static func line(_ lines: [String], at index: Int, language: OutputLanguage,
                     scheduleEvidence: [TranscriptSegment] = [],
                     converter: ChineseScriptConverter = .shared) throws -> String {
        let raw = lines[index]
        guard language.profile.renderer != .identity else { return raw }
        let document = ChineseScriptConverter.RenderText(lines.joined(separator: "\n"))
        return try line(lines, at: index, language: language, scheduleEvidence: scheduleEvidence,
                        converter: converter, protected: protectedLine(lines, at: index, document: document), document: document)
    }

    fileprivate static func protectedLine(_ lines: [String], at index: Int,
                                          document: ChineseScriptConverter.RenderText? = nil) -> ChineseScriptConverter.RenderText {
        let document = document ?? ChineseScriptConverter.RenderText(lines.joined(separator: "\n"))
        let offset = lines.prefix(index).reduce(0) { $0 + $1.utf8.count + 1 }
        return document.slice(offset..<(offset + lines[index].utf8.count))
    }

    private static func sectionHeading(_ lines: [String], at index: Int,
                                       document: ChineseScriptConverter.RenderText) -> String? {
        var offset = lines.prefix(index).reduce(0) { $0 + $1.utf8.count + 1 }
        for position in (0...index).reversed() {
            let raw = lines[position]
            if raw.hasPrefix("## "), !document.slice(offset..<(offset + raw.utf8.count)).isFullyProtected { return raw }
            if position > 0 { offset -= lines[position - 1].utf8.count + 1 }
        }
        return nil
    }

    /// Exact archived evidence, including the original source/target boundary.
    /// Kept separate so legacy identity checks can detect ambiguous fallbacks.
    static func scheduleFields(_ raw: String, evidence: [TranscriptSegment]) -> (prefix: String, target: String, suffix: String)? {
        let suffix = raw.hasSuffix("\r") ? "\r" : ""
        let content = suffix.isEmpty ? raw : String(raw.dropLast())
        for segment in evidence {
            let source = segment.english.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = segment.chinese.trimmingCharacters(in: .whitespacesAndNewlines)
            let total = max(0, Int(segment.startTime))
            let prefix = "- [\(String(format: "%02d:%02d", total / 60, total % 60))] \(source) — "
            // String equality permits canonically equivalent Unicode with
            // different UTF-8 lengths. Byte slices need the exact archive bytes.
            if !source.isEmpty, !target.isEmpty, content.utf8.elementsEqual((prefix + target).utf8) {
                return (prefix, target, suffix)
            }
        }
        return nil
    }

    static func hasUnresolvedScheduleBoundary(_ markdown: String, evidence: [TranscriptSegment]) -> Bool {
        let lines = markdown.components(separatedBy: "\n")
        let document = ChineseScriptConverter.RenderText(markdown)
        var heading: String?
        for index in lines.indices {
            let raw = lines[index]
            if protectedLine(lines, at: index, document: document).isFullyProtected { continue }
            if raw.hasPrefix("## ") { heading = raw.trimmingCharacters(in: .newlines) }
            if heading == "## 课程安排与待办", raw.trimmingCharacters(in: .whitespaces).hasPrefix("- ["),
               raw.components(separatedBy: " — ").count > 2, scheduleFields(raw, evidence: evidence) == nil {
                return true
            }
        }
        return false
    }

    fileprivate static func line(_ lines: [String], at index: Int, language: OutputLanguage,
                                 scheduleEvidence: [TranscriptSegment], converter: ChineseScriptConverter,
                                 protected: ChineseScriptConverter.RenderText,
                                 document: ChineseScriptConverter.RenderText) throws -> String {
        let raw = lines[index]
        // Classification-like prefixes inside code are still technical bytes.
        guard !protected.isFullyProtected else { return raw }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Evidence quotes are source text, even when they contain Han characters.
        for prefix in ["- 先前原文：", "- 原文："] where trimmed.hasPrefix(prefix) {
            guard let range = raw.range(of: prefix) else { continue }
            let label = ChineseOutputDefaults.fixedTextFollowsDisplayLanguage
                ? try language.render(prefix, converter: converter) : prefix
            return String(raw[..<range.lowerBound]) + label + raw[range.upperBound...]
        }
        let heading = sectionHeading(lines, at: index, document: document)
        if heading?.trimmingCharacters(in: .newlines) == "## 课程安排与待办", trimmed.hasPrefix("- ["),
           let separator = raw.range(of: " — ", options: .backwards) {
            // The authoring format allows the separator inside either field.
            // Frozen evidence identifies the actual source/translation boundary.
            if let fields = scheduleFields(raw, evidence: scheduleEvidence) {
                let target = protected.slice(fields.prefix.utf8.count..<(fields.prefix.utf8.count + fields.target.utf8.count))
                return fields.prefix + (try language.render(target, converter: converter)) + fields.suffix
            }
            // Historical text without provenance uses the last separator so
            // no source quotation is converted merely for containing Han text.
            let prefix = String(raw[..<separator.upperBound])
            return prefix + (try language.render(protected.slice(prefix.utf8.count..<protected.byteCount), converter: converter))
        }
        return try language.render(protected, converter: converter)
    }
}

extension SummaryMarkdownLine {
    enum Role: Equatable { case reviewChange, hidden, heading, sourceEvidence, bullet, paragraph, blank }
    var role: Role {
        switch self {
        case .reviewChange: return .reviewChange
        case .hidden: return .hidden
        case .heading: return .heading
        case .sourceEvidence: return .sourceEvidence
        case .bullet: return .bullet
        case .paragraph: return .paragraph
        case .blank: return .blank
        }
    }

    /// Returns the same structural case as classify(). No converted prefix is
    /// used to decide folding, review pairing or indentation.
    static func displayed(_ lines: [String], at index: Int, language: OutputLanguage,
                          isLegacyRendered: Bool = false,
                          scheduleEvidence: [TranscriptSegment] = [],
                          converter: ChineseScriptConverter = .shared,
                          document: ChineseScriptConverter.RenderText? = nil) -> Self {
        let raw = classify(lines, at: index)
        guard language.profile.renderer != .identity, !isLegacyRendered else { return raw }
        let document = document ?? ChineseScriptConverter.RenderText(lines.joined(separator: "\n"))
        let protected = ClassroomMarkdownRendering.protectedLine(lines, at: index, document: document)
        guard !protected.isFullyProtected else { return raw }
        func text(_ value: String, at position: Int? = nil) -> String {
            let field = position.map { ClassroomMarkdownRendering.protectedLine(lines, at: $0, document: document) } ?? protected
            let line = lines[position ?? index]
            // classify() trims the original review line, but not its proposed
            // neighbor. Locate the exact field instead of assuming either is
            // a byte suffix; trailing whitespace must not shift into a scalar.
            guard let range = line.range(of: value, options: [.backwards, .literal]) else {
                return (try? language.render(value, converter: converter)) ?? value
            }
            let start = line[..<range.lowerBound].utf8.count
            let end = line[..<range.upperBound].utf8.count
            return (try? language.render(field.slice(start..<end), converter: converter)) ?? value
        }
        switch raw {
        case let .reviewChange(original, proposed):
            return .reviewChange(original: text(original), proposed: text(proposed, at: index + 1))
        case .hidden, .blank: return raw
        case let .heading(value): return .heading(text(value))
        case let .sourceEvidence(label, _, indentation):
            let converted = (try? ClassroomMarkdownRendering.line(lines, at: index, language: language,
                scheduleEvidence: scheduleEvidence, converter: converter, protected: protected, document: document)) ?? lines[index]
            let content = converted.trimmingCharacters(in: .whitespaces)
            return .sourceEvidence(label: label, text: String(content.dropFirst(2)), indentation: indentation)
        case let .bullet(_, indentation):
            let converted = (try? ClassroomMarkdownRendering.line(lines, at: index, language: language,
                scheduleEvidence: scheduleEvidence, converter: converter, protected: protected, document: document))
                ?? lines[index]
            let content = converted.trimmingCharacters(in: .whitespaces)
            return .bullet(text: String(content.dropFirst(2)), indentation: indentation)
        case let .paragraph(value): return .paragraph(text(value))
        }
    }
}
