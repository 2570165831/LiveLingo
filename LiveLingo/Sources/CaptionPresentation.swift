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
    let isSourceOnly: Bool
    let primaryText: String

    init(_ segment: TranscriptSegment, locale: Locale = CaptionLanguageNames.interfaceLocale) {
        let target = CaptionTranslationTarget.current
        languageName = CaptionLanguageNames.name(for: SpokenLanguage.nonEnglishCode(segment.sourceLanguage), locale: locale)
        isSourceOnly = target.keepsSourceAsCaption(language: segment.sourceLanguage)
        if isSourceOnly {
            primaryText = segment.hasUsableTranslation
                ? segment.chinese : target.renderPassThrough(segment.english)
        } else {
            primaryText = segment.english
        }
    }

    static func translationStatus(isTranslating: Bool) -> String {
        isTranslating ? "翻译中…" : "等待翻译…"
    }
}

/// Text selection is explicitly disabled for every native copy/select-all path.
/// VoiceOver encounters this label separately from the selectable caption text.
struct CaptionLanguageLabel: View {
    let name: String
    let subtitleSize: Double

    var body: some View {
        Text(verbatim: name)
            .font(.system(size: subtitleSize - 3))
            .foregroundStyle(.secondary)
            .fixedSize()
            .textSelection(.disabled)
            .accessibilityLabel(CaptionLanguageNames.accessibilityLabel(for: name))
    }
}

enum SavedProcessingPresentation {
    private static let nonEnglishSpeech = "非英语讲话"
    static let untranscribedSpeech = nonEnglishSpeech + "（未转写）"

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
        }
    }
}
