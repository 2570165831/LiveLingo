import SwiftUI

struct FloatingSubtitleView: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage("floatingTextSize") private var textSize = 24.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(model.isRecording ? .red : .gray).frame(width: 8, height: 8)
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
            subtitle(english, size: textSize - 3, weight: .regular, color: Color(white: 0.9), height: 88)
            subtitle(chinese, size: textSize, weight: .medium, color: .white, height: 138)
        }
        .padding(22)
        .frame(minWidth: 640, maxWidth: 640, alignment: .leading)
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
        .background(FloatingWindowLevel())
    }

    private func subtitle(_ text: String, size: Double, weight: Font.Weight, color: Color, height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(color)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("tail")
                }
            }
            .frame(height: height)
            .onChange(of: text) { proxy.scrollTo("tail", anchor: .bottom) }
        }
    }

    private var english: String {
        model.previewTranslationSource.isEmpty ? "等待英文语音…" : model.previewTranslationSource
    }

    private var chinese: String {
        guard model.previewTranslationEnabled else { return "初译已关闭" }
        guard model.supportsPreviewTranslation else { return "此系统不支持苹果初译" }
        if !model.previewChinese.isEmpty { return "初译 · \(model.previewChinese)" }
        return model.previewTranslationSource.isEmpty ? "等待语音…" : "等待初译…"
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
