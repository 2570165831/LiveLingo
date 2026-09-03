import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.075),
                    Color(nsColor: .windowBackgroundColor),
                    Color.cyan.opacity(0.035),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if let error = model.errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                workspace
                statusBar
            }
        }
        .frame(minWidth: 980, minHeight: 700)
    }

    private var header: some View {
        VStack(spacing: 13) {
            HStack(spacing: 16) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .frame(width: 40, height: 40)
                        Image(systemName: "captions.bubble.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("实时课堂")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                        HStack(spacing: 6) {
                            Circle()
                                .fill(phaseColor)
                                .frame(width: 7, height: 7)
                            Text(model.phaseLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 12)
                settingsControls
            }

            recordingDeck
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var settingsControls: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label("质量模式", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("质量模式", selection: $model.selectedMode) {
                    ForEach(ModelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 218)
            }
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(2)
            .disabled(model.phase.isBusy)
            .help("自动：电池使用 4B，接电使用 9B；也可固定为省电或高质量")

            VStack(alignment: .leading, spacing: 4) {
                Label("音源", systemImage: "waveform")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("音源", selection: $model.selectedInputMode) {
                    Text("麦克风").tag(AudioInputMode.microphone)
                    Text("内录").tag(AudioInputMode.systemAudio)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 154)
            }
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(2)
            .disabled(model.phase.isBusy)
            .help("麦克风：收录环境声音；内录：捕获本机播放声音")

            VStack(alignment: .leading, spacing: 4) {
                Label("记录方式", systemImage: "record.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("记录方式", selection: $model.selectedStorageMode) {
                    Text("实时").tag(SessionStorageMode.liveOnly)
                    Text("录音").tag(SessionStorageMode.saveSession)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 142)
            }
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(2)
            .disabled(model.phase.isBusy)
            .help("实时：临时录音并显示历史，停止时删除录音并清空；录音：选择目录并保存录音、字幕与课堂总结")
        }
        .layoutPriority(1)
    }

    private var recordingDeck: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(model.hasActiveSession ? Color.red.opacity(0.14) : Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Circle()
                    .fill(model.hasActiveSession ? Color.red : Color.accentColor)
                    .frame(width: 20, height: 20)
                    .overlay {
                        if model.hasActiveSession {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white)
                                .frame(width: 8, height: 8)
                        } else {
                            Circle()
                                .stroke(.white, lineWidth: 2)
                                .frame(width: 10, height: 10)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.duration(model.elapsedSeconds))
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                Text(recordingSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RecordingWaveform(samples: model.waveformSamples, active: model.isRecording)
                .frame(width: 150, height: 30)

            Spacer(minLength: 10)

            Button {
                openWindow(id: "subtitles")
            } label: {
                Label("浮动字幕", systemImage: "pip")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if model.isLiveOnly && model.hasActiveSession {
                Button {
                    model.convertCurrentSessionToRecording()
                } label: {
                    Label("转为录音", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("选择目录；当前录音会继续，结束后再移动到所选目录")
            }

            Button {
                model.isPaused ? model.resume() : model.pause()
            } label: {
                Label(
                    model.isPaused ? "继续" : "暂停",
                    systemImage: model.isPaused ? "play.fill" : "pause.fill"
                )
                .frame(minWidth: 64)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!model.hasActiveSession)

            Button {
                model.hasActiveSession ? model.stop() : model.start()
            } label: {
                Label(
                    model.hasActiveSession ? stopTitle : "开始记录",
                    systemImage: model.hasActiveSession ? "stop.circle.fill" : "record.circle"
                )
                .frame(minWidth: 94)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.hasActiveSession ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!model.hasActiveSession && (!model.canStart || model.phase.isBusy))
        }
        .padding(13)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.88),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075))
        }
        .shadow(color: .black.opacity(0.045), radius: 14, y: 5)
    }

    private var workspace: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 1_000 {
                    HStack(spacing: 14) {
                        transcriptPanel
                            .frame(maxWidth: .infinity)
                        summaryPanel
                            .frame(width: min(460, max(370, geometry.size.width * 0.38)))
                    }
                } else {
                    VStack(spacing: 14) {
                        transcriptPanel
                            .frame(maxHeight: .infinity)
                        summaryPanel
                            .frame(height: 250)
                    }
                }
            }
            .padding(16)
        }
    }

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("双语转写")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("最新内容在顶部")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                LanguageBadge(flag: "🇺🇸", text: "英语")
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                LanguageBadge(flag: "🇨🇳", text: "简体中文")
            }
            .padding(16)

            Divider()

            if !model.volatileEnglish.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在识别")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(model.volatileEnglish)
                            .font(.body.weight(.medium))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.075))
                Divider()
            }

            if model.segments.isEmpty {
                ContentUnavailableView(
                    "等待第一段课堂内容",
                    systemImage: model.currentInputMode.statusIcon,
                    description: Text(englishPlaceholder)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.segments.reversed()) { segment in
                                segmentRow(segment)
                                    .id(segment.id)
                                Divider()
                                    .padding(.leading, 84)
                            }
                        }
                    }
                    .onChange(of: model.segments.count) {
                        if let latest = model.segments.last {
                            withAnimation(.easeOut(duration: 0.22)) {
                                proxy.scrollTo(latest.id, anchor: .top)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRecording ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(model.isRecording ? "正在持续识别…" : model.phaseLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.segments.count) 段")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .panelSurface(accent: .blue)
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(Self.clock(segment.startTime))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 7) {
                Text(segment.english)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if segment.chinese.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("等待翻译…")
                    }
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                } else {
                    Text(segment.chinese)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var summaryPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.cyan.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.cyan)
                        .font(.system(size: 16, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("课堂摘要")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(model.summaryStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("本机生成")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.1), in: Capsule())
            }
            .padding(16)

            Divider()

            if model.lectureSummary.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "text.badge.star")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.cyan.opacity(0.72))
                    Text("实时总结会在这里出现")
                        .font(.headline)
                    Text("完成两段双语字幕后开始整理；之后每三段增量更新，字幕翻译始终优先。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 290)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    SummaryMarkdownView(text: model.lectureSummary)
                        .padding(18)
                }
            }

            Divider()
            HStack {
                Label(model.effectiveProfile.shortLabel, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.requestSummaryRefresh()
                } label: {
                    Label("更新摘要", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.segments.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .panelSurface(accent: .cyan)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            StatusToken(icon: model.currentInputMode.statusIcon, text: model.audioInputStatus)
            StatusToken(icon: "waveform", text: model.speechStatus)
            StatusToken(icon: "character.book.closed.fill", text: model.translationStatus)

            Spacer(minLength: 12)

            if model.isLiveOnly {
                Label("实时暂存 · 停止后删除并清空", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    model.chooseOutputDirectory()
                } label: {
                    Label("保存目录", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(model.phase.isBusy)

                Text(model.outputDirectory?.lastPathComponent ?? "未选择")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if case .saved = model.phase {
                    Button("在访达中显示") { model.revealSavedSession() }
                        .buttonStyle(.borderless)
                }
            }

            if !model.translationReady {
                Button("重新检查模型") { model.retryRuntimePreparation() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(11)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.orange.opacity(0.22))
        }
    }

    private var phaseColor: Color {
        if model.isRecording { return .red }
        if model.isPaused { return .orange }
        if model.errorMessage != nil { return .orange }
        return model.translationReady ? .green : .secondary
    }

    private var recordingSubtitle: String {
        if model.isPaused { return "计时已暂停" }
        if model.isRecording { return model.currentInputMode.activeTitle }
        return model.translationReady ? "本机模型已就绪" : "正在检查本机模型"
    }

    private var stopTitle: String {
        model.isLiveOnly ? "结束记录" : "结束并保存"
    }

    private var englishPlaceholder: String {
        switch model.currentInputMode {
        case .microphone:
            return "开始后，麦克风英语会逐词预览，约 10 秒形成一段稳定双语字幕。"
        case .systemAudio:
            return "开始后，播放声会逐词预览，约 10 秒形成一段稳定双语字幕。"
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(
            format: "%02d:%02d:%02d",
            total / 3_600,
            (total / 60) % 60,
            total % 60
        )
    }
}

private struct SettingChip: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
            Text("\(title) · \(value)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.052), in: RoundedRectangle(cornerRadius: 9))
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct LanguageBadge: View {
    let flag: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(flag)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

private struct StatusToken: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct RecordingWaveform: View {
    let samples: [Float]
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(samples.indices, id: \.self) { index in
                let level = active ? min(1, max(0, samples[index])) : 0
                Capsule()
                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.38))
                    .frame(width: 3, height: 4 + CGFloat(level) * 24)
            }
        }
        .animation(.linear(duration: SpeechPipeline.waveformUpdateInterval), value: samples)
        .accessibilityHidden(true)
    }
}

private struct SummaryMarkdownView: View {
    let text: String

    private var lines: [String] {
        text.components(separatedBy: .newlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(String(line.dropFirst(3)))
                        .font(.headline)
                        .padding(.top, 5)
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 7)
                        Text(markdown: String(line.dropFirst(2)))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(markdown: line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }
}

private extension Text {
    init(markdown source: String) {
        if let attributed = try? AttributedString(markdown: source) {
            self.init(attributed)
        } else {
            self.init(source)
        }
    }
}

private extension View {
    func panelSurface(accent: Color) -> some View {
        background(
            Color(nsColor: .textBackgroundColor).opacity(0.96),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(accent.opacity(0.13))
            }
            .shadow(color: .black.opacity(0.055), radius: 18, y: 7)
    }
}
