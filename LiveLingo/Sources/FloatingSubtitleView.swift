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

    @AppStorage("floatingTextSize") private var textSize = 24.0

    var body: some View {
        #if DEBUG
        let _ = SummaryRenderingDiagnostics.record(\.floatingBodies)
        #endif
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(model.isRecording ? ClassroomPalette.recording : .gray).frame(width: 8, height: 8)
                Text(model.isRecording ? "实时字幕 · 初译" : model.phaseLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(white: 0.8))
                Spacer()
                Menu {
                    Picker("悬浮字幕字号", selection: $textSize) {
                        Text("标准").tag(24.0)
                        Text("大").tag(28.0)
                        Text("特大").tag(32.0)
                    }
                } label: { Image(systemName: "textformat.size").foregroundStyle(.white) }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("悬浮字幕字号")
            }
            if let caption = model.nonEnglishPreviewPresentation, caption.isChineseOnly {
                subtitle(caption.primaryText, size: textSize, weight: .medium, color: .white, height: 138,
                         languageName: caption.languageName)
            } else {
                subtitle(english, size: textSize - 3, weight: .regular, color: Color(white: 0.9), height: 88,
                         languageName: model.nonEnglishPreviewPresentation?.languageName)
                subtitle(chinese, size: textSize, weight: .medium, color: .white, height: 138)
            }
        }
        .padding(22)
        .frame(minWidth: 640, maxWidth: 640, alignment: .leading)
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
        .background(FloatingWindowLevel())
    }

    private func subtitle(_ text: String, size: Double, weight: Font.Weight, color: Color, height: CGFloat,
                          languageName: String? = nil) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let languageName {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            CaptionLanguageLabel(name: languageName, subtitleSize: size)
                            subtitleText(text, size: size, weight: weight, color: color)
                        }
                        .accessibilityElement(children: .contain)
                    } else {
                        subtitleText(text, size: size, weight: weight, color: color)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
            }
            .frame(height: height)
            .onChange(of: text) { proxy.scrollTo("tail", anchor: .bottom) }
        }
    }

    private func subtitleText(_ text: String, size: Double, weight: Font.Weight, color: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var english: String { model.previewEnglishDisplay }
    private var chinese: String { model.previewChineseDisplay }
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
            if target.keepsSourceAsCaption(language: caption.sourceLanguage) { return CaptionPresentation(caption).primaryText }
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
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.level = .floating
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) { nsView.window?.level = .floating }
}
