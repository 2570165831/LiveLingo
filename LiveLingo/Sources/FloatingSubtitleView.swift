import AppKit
import SwiftUI

struct FloatingSubtitleView: View {
    @EnvironmentObject private var model: AppModel
    var windowController: FloatingSubtitleWindowController = .shared

    var body: some View {
        FloatingSubtitleContent(model: model, stream: model.captionStream, windowController: windowController)
    }
}

private struct FloatingSubtitleContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stream: LiveCaptionState
    @ObservedObject var windowController: FloatingSubtitleWindowController

    private var preferences = FloatingSubtitlePreferences()
    @AppStorage("transcriptTextSize") private var readingTextSize = 18.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var scale: Double { ReadingTypography.scale(textSize: readingTextSize, dynamicType: dynamicTypeSize) }
    @State private var sourceLineMetrics = FloatingSubtitleLineMetrics()
    @State private var translationLineMetrics = FloatingSubtitleLineMetrics()

    var body: some View {
        #if DEBUG
        let _ = SummaryRenderingDiagnostics.record(\.floatingBodies)
        #endif
        let presentation = model.floatingSubtitlePresentation(mode: preferences.displayMode)
        let palette = FloatingSubtitlePalette(backgroundOpacity: preferences.backgroundOpacity)
        let sourceSize = preferences.sourceTextSize * scale
        let translationSize = preferences.translationTextSize * scale
        let sourceMinimum = sourceLineMetrics.fontSize == sourceSize ? sourceLineMetrics.firstLineHeight
            : FloatingSubtitleLineMetrics(fontSize: sourceSize, weight: .regular, spacing: 5 * scale).firstLineHeight
        let translationMinimum = translationLineMetrics.fontSize == translationSize ? translationLineMetrics.firstLineHeight
            : FloatingSubtitleLineMetrics(fontSize: translationSize, weight: .medium, spacing: 5 * scale).firstLineHeight
        let sourceBudget = min(226 - translationMinimum, max(88, sourceMinimum))
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(model.isRecording ? ClassroomPalette.recording : .gray).frame(width: 8, height: 8)
                Text(model.floatingSubtitleHeader)
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(Color(white: palette.headerWhite))
                Spacer()
                if windowController.isLocked {
                    Label("已锁定", systemImage: "lock.fill")
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(Color(white: palette.headerWhite))
                        .allowsHitTesting(false)
                        .accessibilityLabel("字幕窗已锁定，点击穿透；可在主窗口或菜单解锁")
                } else {
                    Menu {
                        if preferences.sizePreset == nil {
                            Button("自定义") {}.disabled(true)
                        }
                        Picker("悬浮字幕字号", selection: preferences.sizePresetBinding) {
                            Text("标准").tag(Optional(24.0))
                            Text("大").tag(Optional(28.0))
                            Text("特大").tag(Optional(32.0))
                        }
                    }
                    label: { Image(systemName: "textformat.size").foregroundStyle(.white) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("悬浮字幕字号")
                    .accessibilityIdentifier("floating-size-menu")
                }
            }
            // Keep both scroll containers mounted across mode switches, including
            // source-only Chinese. Hidden bodies cannot be selected or accessed.
            subtitle(presentation.source?.text ?? "",
                     size: sourceSize, weight: .regular,
                     color: Color(white: palette.sourceWhite), height: model.captionTarget == .english && presentation.source == nil ? 0 : sourceBudget,
                     languageName: presentation.source?.languageName, languageWhite: palette.languageWhite,
                     visible: presentation.source != nil)
            subtitle(presentation.translation?.text ?? "", size: translationSize, weight: .medium,
                     color: .white, height: model.captionTarget == .english && presentation.translation == nil ? 0 : 226 - sourceBudget, languageName: presentation.translation?.languageName,
                     languageWhite: palette.languageWhite, visible: presentation.translation != nil,
                     rendersTranslation: true)
        }
        .padding(22)
        .frame(minWidth: 640, maxWidth: 640, alignment: .leading)
        .background(Color(white: FloatingSubtitlePalette.backgroundWhite).opacity(preferences.backgroundOpacity))
        .preferredColorScheme(.dark)
        .onChange(of: FloatingSubtitleWindowSettings(showsAcrossSpaces: preferences.showsAcrossSpaces,
                                                     backgroundOpacity: preferences.backgroundOpacity),
                  initial: true) { _, settings in
            windowController.updateSettings(showsAcrossSpaces: settings.showsAcrossSpaces,
                                            backgroundOpacity: settings.backgroundOpacity)
        }
    }

    private func subtitle(_ text: String, size: Double, weight: Font.Weight, color: Color, height: CGFloat,
                          languageName: String? = nil, languageWhite: Double, visible: Bool,
                          rendersTranslation: Bool = false) -> some View {
        let storedMetrics = rendersTranslation ? translationLineMetrics : sourceLineMetrics
        let metrics = storedMetrics.fontSize == size ? storedMetrics
            : FloatingSubtitleLineMetrics(fontSize: size, weight: rendersTranslation ? .medium : .regular,
                                          spacing: 5 * scale)
        let viewportHeight = metrics.viewportHeight(maximum: height)
        return ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 8 * scale) {
                if let languageName {
                    CaptionLanguageLabel(name: languageName, subtitleSize: size, color: Color(white: languageWhite), scale: scale)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        subtitleText(text, size: size, weight: weight, color: color, selectable: visible,
                                     rendersTranslation: rendersTranslation)
                        Color.clear.frame(height: 0).id("tail")
                    }
                }
                .scrollIndicators(.never)
                .frame(height: viewportHeight)
            }
            .accessibilityElement(children: .contain)
            .frame(height: height, alignment: .top)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
            .allowsHitTesting(visible)
            .onChange(of: text, initial: true) { proxy.scrollTo("tail", anchor: .bottom) }
            .onChange(of: languageName) { proxy.scrollTo("tail", anchor: .bottom) }
            .onChange(of: visible) { if visible { proxy.scrollTo("tail", anchor: .bottom) } }
            .onChange(of: size) { proxy.scrollTo("tail", anchor: .bottom) }
            .onChange(of: viewportHeight) { proxy.scrollTo("tail", anchor: .bottom) }
        }
        .background {
            VStack(spacing: 0) {
                ForEach(1...2, id: \.self) { lines in
                    Text(Array(repeating: "Ag国", count: lines).joined(separator: "\n"))
                        .font(.system(size: size, weight: weight))
                        .lineSpacing(5 * scale)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: FloatingSubtitleLineMeasureKey.self,
                                                   value: [lines: geometry.size.height])
                        })
                }
            }
            .hidden().accessibilityHidden(true)
        }
        .onPreferenceChange(FloatingSubtitleLineMeasureKey.self) { heights in
            guard let first = heights[1], let two = heights[2], first > 0, two > first else { return }
            let measured = FloatingSubtitleLineMetrics(fontSize: size, firstLineHeight: first, lineAdvance: two - first)
            if rendersTranslation {
                if translationLineMetrics != measured { translationLineMetrics = measured }
            } else if sourceLineMetrics != measured {
                sourceLineMetrics = measured
            }
        }
    }

    @ViewBuilder
    private func subtitleText(_ text: String, size: Double, weight: Font.Weight, color: Color,
                              selectable: Bool, rendersTranslation: Bool) -> some View {
        let body = Group {
            if rendersTranslation {
                LiveFormulaText(text: text, bodySize: size).equatable()
            } else {
                Text(text)
            }
        }
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineSpacing(5 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
        if selectable {
            body.textSelection(.enabled)
        } else {
            body.textSelection(.disabled)
        }
    }
}

/// The viewport shows whole measured lines while the window keeps its reading budget.
struct FloatingSubtitleLineMetrics: Equatable {
    var fontSize: Double = 0
    var firstLineHeight: CGFloat = 0
    var lineAdvance: CGFloat = 0

    init() {}
    init(fontSize: Double, firstLineHeight: CGFloat, lineAdvance: CGFloat) {
        self.fontSize = fontSize
        self.firstLineHeight = firstLineHeight
        self.lineAdvance = lineAdvance
    }
    init(fontSize: Double, weight: NSFont.Weight, spacing: CGFloat) {
        self.fontSize = fontSize
        firstLineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize, weight: weight))
        lineAdvance = firstLineHeight + spacing
    }
    func viewportHeight(maximum: CGFloat) -> CGFloat {
        guard firstLineHeight > 0, lineAdvance > 0, maximum >= firstLineHeight else { return 0 }
        return firstLineHeight + floor((maximum - firstLineHeight) / lineAdvance) * lineAdvance
    }
}

private struct FloatingSubtitleLineMeasureKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Preview wording shared by the classroom window and floating captions.
extension AppModel {
    /// "初译" names the live preview translation, so it is shown only while that
    /// preview can actually run; otherwise the Chinese line is the formal translation.
    var floatingSubtitleHeader: String {
        guard isRecording else { return phaseLabel }
        return previewTranslationEnabled && supportsPreviewTranslation ? "实时字幕 · 初译" : "实时字幕"
    }

    func floatingSubtitlePresentation(mode: FloatingSubtitleDisplayMode) -> FloatingSubtitlePresentation {
        var translatedText = floatingTranslationWithoutPreview ?? previewChineseDisplay
        var hasTranslation = true
        if mode == .translationOnly {
            if let caption = confirmedNonEnglishCaption {
                hasTranslation = captionTarget.keepsSourceAsCaption(language: caption.sourceLanguage)
                    || caption.hasUsableTranslation
            } else if previewTranslationEnabled && supportsPreviewTranslation
                        && !previewChinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasTranslation = true
            } else if volatileEnglish.isEmpty, let caption = segments.last, caption.hasUsableTranslation {
                translatedText = captionDisplayLanguage.renderForDisplay(caption.chinese, converter: chineseScriptConverter)
            } else {
                hasTranslation = false
            }
        }
        return FloatingSubtitlePresentation(sourceText: previewEnglishDisplay, translatedText: translatedText,
                                            caption: nonEnglishPreviewPresentation, mode: mode,
                                            hasUsableTranslation: hasTranslation)
    }

    /// Without live preview (turned off, or macOS 14) the floating window shows
    /// the formal translation of the sentence on the source line, which only
    /// happens at a pause. New speech gets a hint, never the older Chinese.
    /// The main-window preview keeps previewChineseDisplay.
    private var floatingTranslationWithoutPreview: String? {
        guard !(previewTranslationEnabled && supportsPreviewTranslation), confirmedNonEnglishCaption == nil,
              captionTarget.sourcePolicy(for: nil).usesEnglishTranslationPipeline else { return nil }
        if volatileEnglish.isEmpty, let caption = segments.last,
           captionTarget.sourcePolicy(for: caption.sourceLanguage).usesEnglishTranslationPipeline {
            if caption.hasUsableTranslation {
                return captionDisplayLanguage.renderForDisplay(caption.chinese, converter: chineseScriptConverter)
            }
            return caption.translationState == .failed ? "本段翻译未完成" : "等待正式译文…"
        }
        return previewTranslationEnabled ? "当前系统不支持初译；停顿时显示正式译文" : "初译已关闭；停顿时显示正式译文"
    }

    private var confirmedNonEnglishCaption: TranscriptSegment? {
        guard volatileEnglish.isEmpty, let caption = segments.last,
              (caption.sourceLanguage != nil && caption.sourceLanguage != "en")
                || (captionTarget == .english && captionTarget.keepsSourceAsCaption(language: caption.sourceLanguage)) else { return nil }
        return caption
    }

    var nonEnglishPreviewPresentation: CaptionPresentation? {
        if captionTarget == .english, !volatileEnglish.isEmpty { return CaptionPresentation(sourceOnlyText: volatileEnglish) }
        return confirmedNonEnglishCaption.map {
            CaptionPresentation($0, outputLanguage: captionDisplayLanguage, converter: chineseScriptConverter)
        }
    }

    var previewEnglishDisplay: String {
        if let caption = confirmedNonEnglishCaption { return caption.english }
        if captionTarget == .english, !volatileEnglish.isEmpty { return volatileEnglish }
        return previewTranslationSource.isEmpty ? "等待英文语音…" : previewTranslationSource
    }

    var previewChineseDisplay: String {
        if captionTarget == .english, !volatileEnglish.isEmpty { return volatileEnglish }
        if let caption = confirmedNonEnglishCaption {
            let target = captionTarget
            if target.keepsSourceAsCaption(language: caption.sourceLanguage) {
                return captionDisplayLanguage.renderForDisplay(target.renderPassThrough(caption.english), converter: chineseScriptConverter)
            }
            if caption.hasUsableTranslation {
                return captionDisplayLanguage.renderForDisplay(caption.chinese, converter: chineseScriptConverter)
            }
            return caption.translationState == .failed ? "本段翻译未完成" : "等待正式译文…"
        }
        guard previewTranslationEnabled else { return "初译已关闭" }
        guard supportsPreviewTranslation else { return "当前系统不支持初译；正式译文随后显示" }
        if !previewChinese.isEmpty {
            return "初译 · \(captionDisplayLanguage.renderForDisplay(previewChinese, converter: chineseScriptConverter))"
        }
        return previewTranslationSource.isEmpty ? "等待语音…" : "等待初译…"
    }
}
