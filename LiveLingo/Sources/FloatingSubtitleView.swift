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

    var body: some View {
        #if DEBUG
        let _ = SummaryRenderingDiagnostics.record(\.floatingBodies)
        #endif
        let presentation = model.floatingSubtitlePresentation(mode: preferences.displayMode)
        let palette = FloatingSubtitlePalette(backgroundOpacity: preferences.backgroundOpacity)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(model.isRecording ? ClassroomPalette.recording : .gray).frame(width: 8, height: 8)
                Text(model.isRecording ? "实时字幕 · 初译" : model.phaseLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(white: palette.headerWhite))
                Spacer()
                Menu {
                    if preferences.sizePreset == nil {
                        Button("自定义") {}.disabled(true)
                    }
                    Picker("悬浮字幕字号", selection: preferences.sizePresetBinding) {
                        Text("标准").tag(Optional(24.0))
                        Text("大").tag(Optional(28.0))
                        Text("特大").tag(Optional(32.0))
                    }
                } label: { Image(systemName: "textformat.size").foregroundStyle(.white) }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("悬浮字幕字号")
            }
            // Keep both scroll containers mounted across mode switches, including
            // source-only Chinese. Hidden bodies cannot be selected or accessed.
            subtitle(presentation.source?.text ?? "",
                     size: preferences.sourceTextSize, weight: .regular,
                     color: Color(white: palette.sourceWhite), height: model.captionTarget == .english && presentation.source == nil ? 0 : 88,
                     languageName: presentation.source?.languageName, languageWhite: palette.languageWhite,
                     visible: presentation.source != nil)
            subtitle(presentation.translation?.text ?? "", size: preferences.translationTextSize, weight: .medium,
                     color: .white, height: model.captionTarget == .english && presentation.translation == nil ? 0 : 138, languageName: presentation.translation?.languageName,
                     languageWhite: palette.languageWhite, visible: presentation.translation != nil)
        }
        .padding(22)
        .frame(minWidth: 640, maxWidth: 640, alignment: .leading)
        .background(Color(white: FloatingSubtitlePalette.backgroundWhite).opacity(preferences.backgroundOpacity))
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            if windowController.isLocked {
                Label("已锁定", systemImage: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: palette.headerWhite))
                    .padding(.top, 4).padding(.trailing, 8)
                    .allowsHitTesting(false)
                    .accessibilityLabel("字幕窗已锁定，点击穿透；可在主窗口或菜单解锁")
            }
        }
        .onChange(of: FloatingSubtitleWindowSettings(showsAcrossSpaces: preferences.showsAcrossSpaces,
                                                     backgroundOpacity: preferences.backgroundOpacity),
                  initial: true) { _, settings in
            windowController.updateSettings(showsAcrossSpaces: settings.showsAcrossSpaces,
                                            backgroundOpacity: settings.backgroundOpacity)
        }
    }

    private func subtitle(_ text: String, size: Double, weight: Font.Weight, color: Color, height: CGFloat,
                          languageName: String? = nil, languageWhite: Double, visible: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let languageName {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            CaptionLanguageLabel(name: languageName, subtitleSize: size, color: Color(white: languageWhite))
                            subtitleText(text, size: size, weight: weight, color: color, selectable: visible)
                        }
                        .accessibilityElement(children: .contain)
                    } else {
                        subtitleText(text, size: size, weight: weight, color: color, selectable: visible)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
            }
            .frame(height: height)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(!visible)
            .allowsHitTesting(visible)
            .onChange(of: text) { proxy.scrollTo("tail", anchor: .bottom) }
            .onChange(of: languageName) { proxy.scrollTo("tail", anchor: .bottom) }
            .onChange(of: visible) { if visible { proxy.scrollTo("tail", anchor: .bottom) } }
            .onChange(of: size) { proxy.scrollTo("tail", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func subtitleText(_ text: String, size: Double, weight: Font.Weight, color: Color,
                              selectable: Bool) -> some View {
        let body = Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        if selectable {
            body.textSelection(.enabled)
        } else {
            body.textSelection(.disabled)
        }
    }
}

/// Preview wording shared by the classroom window and floating captions.
extension AppModel {
    func floatingSubtitlePresentation(mode: FloatingSubtitleDisplayMode) -> FloatingSubtitlePresentation {
        var translatedText = previewChineseDisplay
        var hasTranslation = true
        if mode == .translationOnly {
            if let caption = confirmedNonEnglishCaption {
                hasTranslation = captionTarget.keepsSourceAsCaption(language: caption.sourceLanguage)
                    || caption.hasUsableTranslation
            } else if previewTranslationEnabled && supportsPreviewTranslation
                        && !previewChinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasTranslation = true
            } else if volatileEnglish.isEmpty, let caption = segments.last, caption.hasUsableTranslation {
                translatedText = caption.chinese
            } else {
                hasTranslation = false
            }
        }
        return FloatingSubtitlePresentation(sourceText: previewEnglishDisplay, translatedText: translatedText,
                                            caption: nonEnglishPreviewPresentation, mode: mode,
                                            hasUsableTranslation: hasTranslation)
    }

    private var confirmedNonEnglishCaption: TranscriptSegment? {
        guard volatileEnglish.isEmpty, let caption = segments.last,
              (caption.sourceLanguage != nil && caption.sourceLanguage != "en")
                || (captionTarget == .english && captionTarget.keepsSourceAsCaption(language: caption.sourceLanguage)) else { return nil }
        return caption
    }

    var nonEnglishPreviewPresentation: CaptionPresentation? {
        if captionTarget == .english, !volatileEnglish.isEmpty { return CaptionPresentation(sourceOnlyText: volatileEnglish) }
        return confirmedNonEnglishCaption.map { CaptionPresentation($0, target: captionTarget) }
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
            if target.keepsSourceAsCaption(language: caption.sourceLanguage) { return target.renderPassThrough(caption.english) }
            if caption.hasUsableTranslation { return caption.chinese }
            return caption.translationState == .failed ? "本段翻译未完成" : "等待正式译文…"
        }
        guard previewTranslationEnabled else { return "初译已关闭" }
        guard supportsPreviewTranslation else { return "当前系统不支持初译；正式译文随后显示" }
        if !previewChinese.isEmpty { return "初译 · \(previewChinese)" }
        return previewTranslationSource.isEmpty ? "等待语音…" : "等待初译…"
    }
}
