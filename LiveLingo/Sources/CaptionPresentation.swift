import Foundation
import SwiftUI

/// UI names belong here, separately from ASR labels and persisted source text.
/// Other interface locales use Foundation's language names instead of autonyms.
enum CaptionLanguageNames {
    static let interfaceLocale = Locale(identifier: "zh-Hans")

    private static let simplifiedChinese: [String: String] = [
        "zh": "中文", "yue": "粤语", "ar": "阿拉伯语", "de": "德语",
        "fr": "法语", "es": "西班牙语", "pt": "葡萄牙语", "id": "印度尼西亚语",
        "it": "意大利语", "ko": "韩语", "ru": "俄语", "th": "泰语",
        "ja": "日语", "vi": "越南语", "tr": "土耳其语", "hi": "印地语",
        "ms": "马来语", "nl": "荷兰语", "sv": "瑞典语", "da": "丹麦语",
        "fi": "芬兰语", "pl": "波兰语", "cs": "捷克语", "fil": "菲律宾语",
        "ro": "罗马尼亚语", "hu": "匈牙利语", "el": "希腊语", "fa": "波斯语",
        "mk": "马其顿语",
    ]

    static func name(for code: String?, locale: Locale = interfaceLocale) -> String? {
        guard let code, SpokenLanguage.find(code) != nil else { return nil }
        if locale.identifier.replacingOccurrences(of: "_", with: "-").hasPrefix("zh-Hans"),
           let name = simplifiedChinese[code] {
            return name
        }
        return locale.localizedString(forLanguageCode: code)
    }

    static func accessibilityLabel(for name: String) -> String { "语种：\(name)" }
}

/// The row's primary text is separate from its nonselectable language metadata.
/// Translation status and streamed text retain their existing dedicated views.
struct CaptionPresentation: Equatable {
    let languageName: String?
    let sourceLanguage: String?
    let isSourceOnly: Bool
    let primaryText: String

    init(sourceOnlyText: String) {
        languageName = nil
        sourceLanguage = nil
        isSourceOnly = true
        primaryText = sourceOnlyText
    }

    init(_ segment: TranscriptSegment, locale: Locale = CaptionLanguageNames.interfaceLocale,
         target: CaptionTranslationTarget = .simplifiedChinese) {
        if segment.isChineseOriginal {
            languageName = "中文原文"
            sourceLanguage = "zh"
            isSourceOnly = true
            primaryText = segment.english
            return
        }
        languageName = CaptionLanguageNames.name(for: SpokenLanguage.nonEnglishCode(segment.sourceLanguage), locale: locale)
        sourceLanguage = segment.sourceLanguage
        isSourceOnly = target.keepsSourceAsCaption(language: segment.sourceLanguage)
        if isSourceOnly {
            primaryText = segment.hasUsableTranslation
                ? segment.chinese : target.renderPassThrough(segment.english)
        } else {
            primaryText = segment.english
        }
    }

    init(_ segment: TranscriptSegment, outputLanguage: OutputLanguage,
         locale: Locale = CaptionLanguageNames.interfaceLocale,
         converter: ChineseScriptConverter = .shared) {
        if segment.isChineseOriginal {
            languageName = "中文原文"
            sourceLanguage = "zh"
            isSourceOnly = true
            primaryText = segment.english
            return
        }
        languageName = CaptionLanguageNames.name(for: SpokenLanguage.nonEnglishCode(segment.sourceLanguage), locale: locale)
        sourceLanguage = segment.sourceLanguage
        isSourceOnly = outputLanguage.keepsSourceAsCaption(language: segment.sourceLanguage)
        primaryText = isSourceOnly
            ? outputLanguage.renderForDisplay(SessionExporter.targetLine(segment, outputLanguage: outputLanguage), converter: converter)
            : segment.english
    }

    /// Determine failures/placeholders on the stored draft before converting.
    /// The default row keeps its existing displayChinese wording exactly.
    static func translationText(_ segment: TranscriptSegment, outputLanguage: OutputLanguage,
                                converter: ChineseScriptConverter = .shared) -> String {
        if outputLanguage == .simplifiedChinese { return segment.displayChinese }
        let failureMarker = segment.chinese.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("[翻译失败：")
        let text: String
        if outputLanguage.profile.renderer != .identity {
            // The UI has a state-only failure wording that the legacy exporter
            // does not use. Keep that wording and hide old private diagnostics.
            text = failureMarker ? SessionExporter.humanReadableChinese(segment.chinese) : segment.displayChinese
        } else {
            text = SessionExporter.targetLine(segment, outputLanguage: outputLanguage)
        }
        let isFixedText = !segment.hasUsableTranslation
            || failureMarker
        return isFixedText
            ? outputLanguage.renderFixedTextForDisplay(text, converter: converter)
            : outputLanguage.renderForDisplay(text, converter: converter)
    }

    static func translationStatus(isTranslating: Bool) -> String {
        isTranslating ? "翻译中…" : "等待翻译…"
    }
}

/// Per-row action state is separate from the immutable caption and its stream.
struct ChineseRecognitionRowPresentation {
    static let actionTitle = "按中文重新识别"
    static let undoTitle = "撤销中文重识别"
    static let cancelTitle = "取消"
    static let cancelActionTitle = "取消中文重识别"
    static let waitingStatusText = "已排队：课堂结束并完成实时转写后按中文重新识别"

    let isRecognizing: Bool
    let isBusy: Bool
    let canCancel: Bool
    let canRecognize: Bool
    let showsUndo: Bool
    let canUndo: Bool
    let unavailableReason: String?
    let undoUnavailableReason: String?
    let statusText: String?
    let isFailure: Bool

    var statusAccessibilityLabel: String? {
        guard let statusText else { return nil }
        guard canCancel else { return statusText }
        let announcement = statusText.hasSuffix("…") ? String(statusText.dropLast()) : statusText
        return "\(announcement)，可取消中文重识别。"
    }

    var cancelAccessibilityLabel: String {
        canCancel && !isRecognizing ? "取消等待中的中文重识别" : Self.cancelActionTitle
    }

    var actionsAccessibilityLabel: String {
        if isBusy { return "字幕操作：\(statusAccessibilityLabel ?? "")" }
        if let reason = undoUnavailableReason {
            return "字幕操作：暂不可重新识别或撤销，\(reason)"
        }
        if let reason = unavailableReason {
            return "字幕操作：暂不可重新识别，\(reason)"
        }
        return "字幕操作：按中文重新识别或撤销"
    }

    var recognizeAccessibilityLabel: String {
        guard let unavailableReason else { return Self.actionTitle }
        return "\(Self.actionTitle)，暂不可重新识别：\(unavailableReason)"
    }

    var undoAccessibilityLabel: String {
        guard let undoUnavailableReason else { return Self.undoTitle }
        return "\(Self.undoTitle)，暂不可撤销：\(undoUnavailableReason)"
    }

    init(status: ChineseRecognitionStatus?, availability: ChineseRecognitionAvailability,
         canUndo: Bool, courseActionsAvailability: ChineseRecognitionAvailability = .available) {
        if case .recognizing? = status {
            isRecognizing = true
        } else {
            isRecognizing = false
        }
        let busyReason: String?
        switch status {
        case .pending?:
            isBusy = false
            canCancel = true
            statusText = "待重新识别：可按中文重新识别，或取消排队请求。"
            busyReason = nil
            isFailure = false
        case .waitingForRealtime?:
            isBusy = true
            canCancel = true
            statusText = Self.waitingStatusText
            busyReason = Self.waitingStatusText + "；暂不能重新识别或撤销，可取消本次请求。"
            isFailure = false
        case .recognizing?:
            isBusy = true
            canCancel = true
            statusText = "正在按中文重新识别…"
            busyReason = "正在按中文重新识别，暂不能再次识别或撤销；可取消本次请求。"
            isFailure = false
        case .saving?:
            isBusy = true
            canCancel = false
            statusText = "中文已识别，正在保存，暂不可撤销。"
            busyReason = "正在保存中文识别结果，保存结束后才能重新识别或撤销，暂不可取消。"
            isFailure = false
        case .cancelled?:
            isBusy = false
            canCancel = false
            statusText = "已取消中文重识别，原句已保留。"
            busyReason = nil
            isFailure = false
        case .failed(let reason)?:
            isBusy = false
            canCancel = false
            // Saving can fail after the Chinese source has already replaced
            // the caption. Keep that notice instead of claiming it was unchanged.
            statusText = canUndo && reason.contains("中文原文已保留") ? reason
                : "按中文重新识别失败：\(reason)；原句已保留。"
            busyReason = nil
            isFailure = true
        case .completed?, nil:
            isBusy = false
            canCancel = false
            statusText = nil
            busyReason = nil
            isFailure = false
        }
        let courseReason = courseActionsAvailability.isAvailable ? nil
            : courseActionsAvailability.reason ?? "课程当前不可操作，请稍后重试。"
        canRecognize = availability.isAvailable && courseActionsAvailability.isAvailable && !isBusy
        showsUndo = canUndo
        self.canUndo = canUndo && !isBusy && status != .pending && courseActionsAvailability.isAvailable
        unavailableReason = busyReason ?? courseReason ?? (availability.isAvailable ? nil
            : availability.reason ?? "此句的录音已不可用，无法按中文重新识别。")
        undoUnavailableReason = canUndo ? busyReason ?? courseReason
            ?? (status == .pending ? "本句仍有待重新识别请求；请先执行或取消请求，再撤销。" : nil) : nil
    }
}

/// Text selection is explicitly disabled for every native copy/select-all path.
/// VoiceOver encounters this label separately from the selectable caption text.
struct CaptionLanguageLabel: View {
    let name: String
    let subtitleSize: Double
    var color: Color = ReadingAccessibility.secondaryText
    var scale: Double = 1

    var body: some View {
        Text(verbatim: name)
            .font(.system(size: subtitleSize - 3 * scale))
            .foregroundStyle(color)
            .fixedSize()
            .textSelection(.disabled)
            .accessibilityLabel(CaptionLanguageNames.accessibilityLabel(for: name))
    }
}

enum SavedProcessingPresentation {
    private static let nonEnglishSpeech = "非英语讲话"
    static let untranscribedSpeech = nonEnglishSpeech + "（未转写）"

    static func showsTranscriptionTask(_ record: TranscriptionWorkRecord) -> Bool {
        record.needsWork || canRetryTranscription(record) || record.candidateText != nil
    }

    static func canRetryTranscription(_ record: TranscriptionWorkRecord) -> Bool {
        [.failed, .otherLanguage, .noSpeech].contains(record.status)
    }

    static func noSpeechSummary(count: Int) -> String? {
        count > 0 ? "未识别到讲话 \(count) 段" : nil
    }

    static func languageSummary(segments: [TranscriptSegment], untranscribedCount: Int = 0) -> String? {
        let chinese = segments.filter { $0.sourceLanguage == "zh" }.count
        let other = segments.filter {
            SpokenLanguage.nonEnglishCode($0.sourceLanguage) != nil && $0.sourceLanguage != "zh"
        }.count
        var parts: [String] = []
        if chinese > 0 { parts.append("中文发言 \(chinese) 段") }
        if other > 0 { parts.append("其他语言 \(other) 段") }
        if untranscribedCount > 0 { parts.append("\(untranscribedSpeech)\(untranscribedCount) 段") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func workSummary(_ state: TranscriptionProcessingState, segments: [TranscriptSegment]) -> String {
        let existing = "等待转写 \(state.pendingCount) 段 · 待确认或失败 \(state.unresolvedCount) 段"
            + (noSpeechSummary(count: state.noSpeechCount).map { " · " + $0 } ?? "")
        // English-gate rejections already had a shorter summary before language tags.
        // Keep that exact wording when no confirmed multilingual caption is present.
        guard segments.contains(where: { SpokenLanguage.nonEnglishCode($0.sourceLanguage) != nil }) else {
            return state.otherLanguageCount > 0
                ? existing + " · \(nonEnglishSpeech) \(state.otherLanguageCount) 段" : existing
        }
        guard let summary = languageSummary(segments: segments, untranscribedCount: state.otherLanguageCount) else {
            return existing
        }
        return existing + " · " + summary
    }

    static func recordLabel(_ status: TranscriptionWorkRecord.Status) -> String {
        switch status {
        case .pending: return "等待转写"
        case .active: return "正在转写"
        case .retryWaiting: return "等待自动补转"
        case .manualPending: return "等待手动重试"
        case .completed: return "已转写"
        case .silent: return "已确认无讲话"
        case .failed: return "转写失败"
        case .otherLanguage: return untranscribedSpeech
        case .noSpeech: return "未识别到讲话"
        }
    }
}

/// Classify stored Markdown before any display-language rendering. Branch order
/// and neighbor whitespace match the original SummaryMarkdownView exactly.
enum SummaryMarkdownLine: Equatable {
    case reviewChange(original: String, proposed: String)
    case hidden
    case heading(String)
    case sourceEvidence(label: String, text: String, indentation: Int)
    case bullet(text: String, indentation: Int)
    case paragraph(String)
    case blank

    static func classify(_ lines: [String], at index: Int) -> Self {
        let line = lines[index]
        let content = line.trimmingCharacters(in: .whitespaces)
        let indentation = min(4, line.prefix(while: { $0 == " " }).count / 2)
        if content.hasPrefix("- **原笔记 · 要点 "), index + 1 < lines.count,
           lines[index + 1].hasPrefix("- **9B 建议（待核对）**：") {
            return .reviewChange(original: content.components(separatedBy: "**：").dropFirst().joined(separator: "**："),
                                 proposed: String(lines[index + 1].dropFirst("- **9B 建议（待核对）**：".count)))
        } else if content.hasPrefix("- **9B 建议（待核对）**："), index > 0,
                  lines[index - 1].hasPrefix("- **原笔记 · 要点 ") {
            return .hidden
        } else if line.hasPrefix("## ") {
            return .heading(String(line.dropFirst(3)))
        } else if indentation > 0 && (content.hasPrefix("- 原文：") || content.hasPrefix("- 先前原文：")) {
            return .sourceEvidence(label: content.hasPrefix("- 先前原文：") ? "先前原文依据" : "后文原文依据",
                                   text: String(content.dropFirst(2)), indentation: indentation)
        } else if content.hasPrefix("- ") {
            return .bullet(text: String(content.dropFirst(2)), indentation: indentation)
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            return .paragraph(line)
        }
        return .blank
    }
}
