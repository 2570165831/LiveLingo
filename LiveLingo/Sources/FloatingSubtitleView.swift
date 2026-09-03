import SwiftUI

struct FloatingSubtitleView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(model.isRecording ? .red : .secondary)
                    .frame(width: 8, height: 8)
                Text(model.isRecording ? "LIVE" : model.phaseLabel.uppercased())
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(english)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(3)
            Text(chinese)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(3)
        }
        .padding(18)
        .frame(minWidth: 640, maxWidth: 640, minHeight: 130, alignment: .leading)
        .background(.black.opacity(0.86))
        .background(.ultraThinMaterial)
    }

    private var english: String {
        if !model.volatileEnglish.isEmpty { return model.volatileEnglish }
        return model.segments.last?.english ?? "等待英文语音…"
    }

    private var chinese: String {
        if !model.liveChinese.isEmpty { return model.liveChinese }
        return model.segments.last?.chinese ?? "稳定语段将在这里翻译"
    }
}
