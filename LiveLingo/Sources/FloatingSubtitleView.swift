import SwiftUI

struct FloatingSubtitleView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        FloatingSubtitleContent(model: model, stream: model.captionStream)
    }
}

private struct FloatingSubtitleContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stream: LiveCaptionState

    private var preferences = FloatingSubtitlePreferences()

    var body: some View {
        #if DEBUG
        let _ = SummaryRenderingDiagnostics.record(\.floatingBodies)
        #endif
        let presentation = FloatingSubtitlePresentation(sourceText: model.previewEnglishDisplay,
                                                        translatedText: model.previewChineseDisplay,
                                                        caption: model.nonEnglishPreviewPresentation,
                                                        mode: preferences.displayMode)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(model.isRecording ? ClassroomPalette.recording : .gray).frame(width: 8, height: 8)
                Text(model.isRecording ? "实时字幕 · 初译" : model.phaseLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(white: 0.8))
                Spacer()
                Menu {
                    Picker("悬浮字幕字号", selection: Binding(get: { preferences.sizePreset },
                                                        set: { preferences.sizePreset = $0 })) {
                        Text("标准").tag(24.0)
                        Text("大").tag(28.0)
                        Text("特大").tag(32.0)
                    }
                } label: { Image(systemName: "textformat.size").foregroundStyle(.white) }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("悬浮字幕字号")
            }
            // Keep both scroll containers mounted across mode switches, including
            // source-only Chinese. Hidden bodies cannot be selected or accessed.
            subtitle(presentation.source?.text ?? (model.nonEnglishPreviewPresentation?.isSourceOnly == true
                        ? model.previewChineseDisplay : model.previewEnglishDisplay),
                     size: preferences.sourceTextSize, weight: .regular, color: Color(white: 0.9), height: 88,
                     languageName: model.nonEnglishPreviewPresentation?.languageName,
                     visible: presentation.source != nil)
            subtitle(model.previewChineseDisplay, size: preferences.translationTextSize, weight: .medium,
                     color: .white, height: 138, languageName: presentation.translation?.languageName,
                     visible: presentation.translation != nil)
        }
        .padding(22)
        .frame(minWidth: 640, maxWidth: 640, alignment: .leading)
        .background(Color(white: 0.08).opacity(preferences.backgroundOpacity))
        .preferredColorScheme(.dark)
        .background(FloatingWindowLevel(backgroundOpacity: preferences.backgroundOpacity))
    }

    private func subtitle(_ text: String, size: Double, weight: Font.Weight, color: Color, height: CGFloat,
                          languageName: String? = nil, visible: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let languageName {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            CaptionLanguageLabel(name: languageName, subtitleSize: size, color: Color(white: 0.6))
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
    private var confirmedNonEnglishCaption: TranscriptSegment? {
        guard volatileEnglish.isEmpty, let caption = segments.last,
              caption.sourceLanguage != nil, caption.sourceLanguage != "en" else { return nil }
        return caption
    }

    var nonEnglishPreviewPresentation: CaptionPresentation? {
        confirmedNonEnglishCaption.map { CaptionPresentation($0) }
    }

    var previewEnglishDisplay: String {
        if let caption = confirmedNonEnglishCaption { return caption.english }
        return previewTranslationSource.isEmpty ? "等待英文语音…" : previewTranslationSource
    }

    var previewChineseDisplay: String {
        if let caption = confirmedNonEnglishCaption {
            let target = CaptionTranslationTarget.current
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

private struct FloatingWindowLevel: NSViewRepresentable {
    let backgroundOpacity: Double

    final class View: NSView {
        var backgroundOpacity = 1.0
        private weak var configuredWindow: NSWindow?
        private var originalIsOpaque = true
        private var originalBackgroundColor: NSColor?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if configuredWindow !== newWindow { restoreBackground() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            if configuredWindow !== window {
                configuredWindow = window
                originalIsOpaque = window.isOpaque
                originalBackgroundColor = window.backgroundColor
            }
            window.level = .floating
            if backgroundOpacity < 1 {
                window.isOpaque = false
                window.backgroundColor = .clear
            } else {
                restoreBackground()
            }
        }

        private func restoreBackground() {
            configuredWindow?.isOpaque = originalIsOpaque
            if let originalBackgroundColor { configuredWindow?.backgroundColor = originalBackgroundColor }
        }
    }
    func makeNSView(context: Context) -> View {
        let view = View()
        view.backgroundOpacity = backgroundOpacity
        return view
    }
    func updateNSView(_ nsView: View, context: Context) {
        nsView.backgroundOpacity = backgroundOpacity
        nsView.configureWindow()
    }
}
