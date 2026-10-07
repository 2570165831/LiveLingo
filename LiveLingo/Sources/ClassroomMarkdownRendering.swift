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
        return try lines.indices.map {
            try line(lines, at: $0, language: language, scheduleEvidence: scheduleEvidence, converter: converter)
        }.joined(separator: "\n")
    }

    static func line(_ lines: [String], at index: Int, language: OutputLanguage,
                     scheduleEvidence: [TranscriptSegment] = [],
                     converter: ChineseScriptConverter = .shared) throws -> String {
        let raw = lines[index]
        guard language.profile.renderer != .identity else { return raw }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // Evidence quotes are source text, even when they contain Han characters.
        for prefix in ["- 先前原文：", "- 原文："] where trimmed.hasPrefix(prefix) {
            guard let range = raw.range(of: prefix) else { continue }
            let label = ChineseOutputDefaults.fixedTextFollowsDisplayLanguage
                ? try language.render(prefix, converter: converter) : prefix
            return String(raw[..<range.lowerBound]) + label + raw[range.upperBound...]
        }
        let heading = lines.prefix(index + 1).last { $0.hasPrefix("## ") }
        if heading?.trimmingCharacters(in: .newlines) == "## 课程安排与待办", trimmed.hasPrefix("- ["),
           let separator = raw.range(of: " — ", options: .backwards) {
            // The authoring format allows the separator inside either field.
            // Frozen evidence identifies the actual source/translation boundary.
            for segment in scheduleEvidence {
                let source = segment.english.trimmingCharacters(in: .whitespacesAndNewlines)
                let target = segment.chinese.trimmingCharacters(in: .whitespacesAndNewlines)
                let total = max(0, Int(segment.startTime))
                let prefix = "- [\(String(format: "%02d:%02d", total / 60, total % 60))] \(source) — "
                let content = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                if !source.isEmpty, !target.isEmpty, content == prefix + target {
                    return prefix + (try language.render(target, converter: converter)) + (raw.hasSuffix("\r") ? "\r" : "")
                }
            }
            // Historical text without provenance uses the last separator so
            // no source quotation is converted merely for containing Han text.
            return String(raw[..<separator.upperBound])
                + (try language.render(String(raw[separator.upperBound...]), converter: converter))
        }
        return try language.render(raw, converter: converter)
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
                          converter: ChineseScriptConverter = .shared) -> Self {
        let raw = classify(lines, at: index)
        guard language.profile.renderer != .identity, !isLegacyRendered else { return raw }
        func text(_ value: String) -> String { (try? language.render(value, converter: converter)) ?? value }
        switch raw {
        case let .reviewChange(original, proposed):
            return .reviewChange(original: text(original), proposed: text(proposed))
        case .hidden, .blank: return raw
        case let .heading(value): return .heading(text(value))
        case let .sourceEvidence(label, _, indentation):
            let converted = (try? ClassroomMarkdownRendering.line(lines, at: index, language: language,
                scheduleEvidence: scheduleEvidence, converter: converter)) ?? lines[index]
            let content = converted.trimmingCharacters(in: .whitespaces)
            return .sourceEvidence(label: label, text: String(content.dropFirst(2)), indentation: indentation)
        case let .bullet(_, indentation):
            let converted = (try? ClassroomMarkdownRendering.line(lines, at: index, language: language,
                scheduleEvidence: scheduleEvidence, converter: converter))
                ?? lines[index]
            let content = converted.trimmingCharacters(in: .whitespaces)
            return .bullet(text: String(content.dropFirst(2)), indentation: indentation)
        case let .paragraph(value): return .paragraph(text(value))
        }
    }
}
