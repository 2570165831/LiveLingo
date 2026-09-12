import Foundation
import SwiftUI
@preconcurrency import Translation

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("transcriptTextSize") private var transcriptTextSize = 18.0
    @State private var typedPanelHeight: CGFloat = 330
    @State private var wholeLessonNotes = false

    init(showWholeLessonNotes: Bool = false) {
        _wholeLessonNotes = State(initialValue: showWholeLessonNotes)
    }

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
        .modifier(ApplePreviewTranslationHost())
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

            RecordingWaveform(samples: model.waveformSamples, active: model.isRecording, lastUpdate: model.lastAudioLevelAt)
                .frame(width: 150, height: 30)

            Spacer(minLength: 10)

            Menu {
                Picker("字幕字号", selection: $transcriptTextSize) {
                    Text("标准").tag(18.0)
                    Text("大").tag(21.0)
                    Text("特大").tag(24.0)
                }
            } label: { Image(systemName: "textformat.size") }
            .help("主窗口字幕字号")

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
                        summaryAndTranslation(height: max(0, geometry.size.height - 32))
                            .frame(width: min(460, max(370, geometry.size.width * 0.38)))
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            transcriptPanel.frame(height: 400)
                            summaryPanel.frame(height: 380)
                            TypedTranslationView().panelSurface(accent: .blue)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func summaryAndTranslation(height: CGFloat) -> some View {
        // Allocate finite heights directly: a ScrollView cannot distribute spare
        // vertical space to its children, even when its content has a minHeight.
        let noteHeight = min(380, height * 0.65)
        let translationHeight = min(typedPanelHeight, max(0, height - noteHeight - 14))
        return VStack(spacing: 14) {
            summaryPanel
                .frame(height: max(0, height - translationHeight - 14))
            ScrollView {
                TypedTranslationView()
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { measured in
                            Color.clear.preference(key: TypedPanelHeightKey.self, value: measured.size.height)
                        }
                    }
            }
            .frame(height: translationHeight)
            .panelSurface(accent: .blue)
        }
        .frame(height: height, alignment: .top)
        .onPreferenceChange(TypedPanelHeightKey.self) { measured in
            if measured > 0, abs(typedPanelHeight - measured) > 0.5 {
                typedPanelHeight = measured
            }
        }
    }

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("双语转写")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(model.previewTranslationEnabled && model.supportsPreviewTranslation
                         ? model.previewTranslationStatus : "最新内容在顶部")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("同步初译", isOn: $model.previewTranslationEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.supportsPreviewTranslation)
                    .help("苹果传统模型提供临时中文；正式字幕仍由 Qwen 翻译。需要 macOS 15 或更新版本。")
                LanguageBadge(flag: "🇺🇸", text: "英语")
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                LanguageBadge(flag: "🇨🇳", text: "简体中文")
            }
            .padding(16)

            Divider()

            if model.hasActiveSession || model.phase == .stopping || !model.volatileEnglish.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .opacity(model.volatileEnglish.isEmpty ? 0 : 1)
                        Text(model.volatileEnglish.isEmpty ? "等待下一句" : "正在识别")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    previewReadingSlot(
                        model.volatileEnglish.isEmpty ? "等待英文语音…" : model.volatileEnglish,
                        size: transcriptTextSize - 2, weight: .regular)
                    previewReadingSlot(
                        !model.previewTranslationEnabled ? "初译已关闭" :
                            model.volatileEnglish.isEmpty || model.previewChinese.isEmpty
                                ? "等待初译…" : "初译 · \(model.previewChinese)",
                        size: transcriptTextSize, weight: .medium)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private func previewReadingSlot(_ text: String, size: Double, weight: Font.Weight) -> some View {
        // Let SwiftUI measure three lines with the same font and spacing as the captions.
        Text("Ag国\nAg国\nAg国")
            .font(.system(size: size, weight: weight))
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(text)
                                .font(.system(size: size, weight: weight))
                                .lineSpacing(5)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("preview-tail")
                        }
                    }
                    .onChange(of: text) { proxy.scrollTo("preview-tail", anchor: .bottom) }
                }
            }
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(Self.clock(segment.startTime))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                Text(segment.english)
                    .font(.system(size: transcriptTextSize - 2))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if segment.chinese.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(model.translatingSegmentID == segment.id ? "翻译中…" : "等待翻译…")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if model.translatingSegmentID == segment.id, !model.streamingChinese.isEmpty {
                            Text(model.streamingChinese)
                                .font(.system(size: transcriptTextSize, weight: .medium))
                                .lineSpacing(5)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Text(markdown: segment.chinese)
                        .font(.system(size: transcriptTextSize, weight: .medium))
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
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
                    Text("学习笔记")
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

            Picker("笔记范围", selection: $wholeLessonNotes) {
                Text("最近更新").tag(false)
                Text("整课笔记").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            LearningReviewControls(queue: model.noteReviewQueue)

            if model.lectureSummary.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "text.badge.star")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.cyan.opacity(0.72))
                    Text("实时总结会在这里出现")
                        .font(.headline)
                    Text(model.summaryConcurrencyAllowed
                        ? "完成两段后开始整理，之后每三分钟增量更新；当前内存允许字幕与摘要并行，积压时字幕优先。"
                        : "完成两段后开始整理，之后每三分钟尝试增量更新；等待内存与翻译空隙。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 290)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(wholeLessonNotes ? model.summaryCoverageStatus : model.latestSummaryScope)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !wholeLessonNotes && model.latestSummaryUpdate.isEmpty {
                            Text("这一批没有新增学习要点，先前内容保留在整课笔记中。")
                                .foregroundStyle(.secondary)
                        } else {
                            SummaryMarkdownView(text: wholeLessonNotes ? model.lectureSummary : model.latestSummaryUpdate)
                        }
                        if !model.reviewAdvice.isEmpty {
                            Divider()
                            DisclosureGroup("9B 复查意见（仅供核对）") {
                                SummaryMarkdownView(text: model.reviewAdvice)
                            }
                        }
                    }
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

private struct TypedPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TypedTranslationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文本翻译").font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Text(model.effectiveProfile.shortLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text("英文 → 简体中文 · 使用当前质量模式 · 不加入录音历史")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("输入内容")
                Spacer()
                Text("\(model.manualTranslationInput.count) / 2000 字符").font(.caption)
                PasteButton(payloadType: String.self) { values in
                    model.manualTranslationInput = values.joined(separator: "\n")
                }.disabled(model.isManualTranslating)
            }
            TranslationTextEditor(
                text: $model.manualTranslationInput,
                isEnabled: !model.isManualTranslating,
                onSubmit: { precise in model.translateTypedText(thinking: precise) },
                onCancel: { model.cancelTypedTranslation() },
                onCancelAndClear: {
                    model.cancelTypedTranslation()
                    model.manualTranslationInput = ""
                }
            )
                .frame(height: 90)
                .border(Color.secondary.opacity(0.25))
            Text("Enter 翻译 · Shift+Enter 换行 · ⌘Enter 提交多行文本")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("⇧⌘Enter 精确翻译 · ⌘Delete 取消 · ⇧Delete 清空输入 · ⇧⌘Delete 取消并清空")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Text(model.manualTranslationStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isManualTranslating {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancelTypedTranslation() }
                        .keyboardShortcut(.delete, modifiers: .command)
                } else {
                    Button("精确翻译") { model.translateTypedText(thinking: true) }
                        .disabled(model.manualTranslationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.manualTranslationInput.count > 2000)
                    Button("翻译") { model.translateTypedText() }
                        .disabled(model.manualTranslationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.manualTranslationInput.count > 2000)
                }
            }
            Divider()
            HStack {
                Text("翻译结果")
                Spacer()
                Button("复制译文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.manualTranslationOutput, forType: .string)
                }.disabled(model.manualTranslationOutput.isEmpty)
            }
            if model.manualTranslationOutput.isEmpty {
                Text("译文会显示在这里")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .vertical) {
                    translationResultText
                    ScrollView {
                        translationResultText
                    }
                    .frame(height: 180)
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(16)
    }

    private var translationResultText: some View {
        Text(markdown: model.manualTranslationOutput)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct TranslationTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let onSubmit: (Bool) -> Void
    let onCancel: () -> Void
    let onCancelAndClear: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let editor = TranslationInputTextView(frame: scrollView.bounds)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .preferredFont(forTextStyle: .body)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 4, height: 5)
        editor.setAccessibilityLabel("待翻译英文")
        editor.delegate = context.coordinator
        scrollView.documentView = editor
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scrollView.documentView as? TranslationInputTextView else { return }
        editor.isEditable = isEnabled
        editor.onSubmit = onSubmit
        editor.onCancel = onCancel
        editor.onCancelAndClear = onCancelAndClear
        if editor.string != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranslationTextEditor
        init(_ parent: TranslationTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

private final class TranslationInputTextView: NSTextView {
    var onSubmit: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onCancelAndClear: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if handleDeleteShortcut(event) { return }
        if let precise = submissionMode(for: event) {
            if isEditable, !event.isARepeat { onSubmit?(precise) }
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleDeleteShortcut(event) { return true }
        if window?.firstResponder === self,
           event.modifierFlags.contains(.command), let precise = submissionMode(for: event) {
            if isEditable, !event.isARepeat { onSubmit?(precise) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleDeleteShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == 51 else { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if modifiers == [.shift, .command] {
            if !event.isARepeat { onCancelAndClear?() }
            return true
        }
        if modifiers == .command {
            if !isEditable, !event.isARepeat { onCancel?() }
            return true
        }
        if modifiers == .shift {
            if isEditable, !event.isARepeat {
                // Use the normal editing path so bindings and undo stay in sync.
                insertText("", replacementRange: NSRange(location: 0, length: (string as NSString).length))
            }
            return true
        }
        return false
    }

    private func submissionMode(for event: NSEvent) -> Bool? {
        guard (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() else { return nil }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if modifiers == [.shift, .command] { return true }
        return modifiers.isEmpty || modifiers == .command ? false : nil
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
    let lastUpdate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let receiving = active && lastUpdate.map { timeline.date.timeIntervalSince($0) < 0.6 } == true
            HStack(spacing: 3) {
                ForEach(samples.indices, id: \.self) { index in
                    let level = receiving ? min(1, max(0, samples[index])) : 0
                    Capsule()
                        .fill(receiving ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(width: 3, height: 3 + CGFloat(level) * 25)
                }
            }
            .animation(reduceMotion ? nil : .linear(duration: SpeechPipeline.waveformUpdateInterval), value: samples)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(!active ? "音量显示已暂停" : receiving ? "正在接收音频" : "等待音频输入")
            .help(!active ? "音量显示已暂停" : receiving ? "实际输入音量：平均强度与短时峰值" : "暂未收到音频输入")
        }
    }
}

private struct LearningReviewControls: View {
    @ObservedObject var queue: LearningReviewQueue

    var body: some View {
        if !queue.status.isEmpty {
            HStack(spacing: 8) {
                Text(queue.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if queue.hasWork {
                    Button(queue.actionTitle) { queue.togglePause() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

private struct SummaryMarkdownView: View {
    let text: String

    private var lines: [String] {
        text.components(separatedBy: .newlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let content = line.trimmingCharacters(in: .whitespaces)
                let indentation = min(4, line.prefix(while: { $0 == " " }).count / 2)
                if content.hasPrefix("- **原笔记 · 要点 "), index + 1 < lines.count,
                   lines[index + 1].hasPrefix("- **9B 建议（待核对）**：") {
                    ReviewChangeView(original: content.components(separatedBy: "**：").dropFirst().joined(separator: "**："),
                                     proposed: String(lines[index + 1].dropFirst("- **9B 建议（待核对）**：".count)))
                } else if content.hasPrefix("- **9B 建议（待核对）**："), index > 0,
                          lines[index - 1].hasPrefix("- **原笔记 · 要点 ") {
                    EmptyView()
                } else if line.hasPrefix("## ") {
                    Text(String(line.dropFirst(3)))
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.top, 5)
                } else if indentation > 0 && (content.hasPrefix("- 原文：") || content.hasPrefix("- 先前原文：")) {
                    DisclosureGroup(content.hasPrefix("- 先前原文：") ? "先前原文依据" : "后文原文依据") {
                        Text(markdown: String(content.dropFirst(2)))
                            .font(.system(size: 15))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 14))
                    .padding(.leading, CGFloat(indentation) * 14)
                } else if content.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .padding(.top, 7)
                        Text(markdown: String(content.dropFirst(2)))
                            .font(.system(size: 16))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(indentation) * 14)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(markdown: line)
                        .font(.system(size: 16))
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct ReviewChangeView: View {
    let original: String
    let proposed: String

    private func marked(_ value: String, against other: String, removed: Bool) -> Text {
        func tokens(_ text: String) -> [String] {
            let expression = try! NSRegularExpression(pattern: #"[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[A-Za-z]+|\X"#)
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
        let characters = tokens(value)
        let otherCharacters = tokens(other)
        // Bound comparison work for imported or unexpectedly long reports.
        guard characters.count <= 2_000, otherCharacters.count <= 2_000 else {
            return Text(verbatim: value)
        }
        let changed = Set(characters.difference(from: otherCharacters).compactMap { change -> Int? in
            if case let .insert(offset, _, _) = change { return offset }
            return nil
        })
        return characters.enumerated().reduce(Text("")) { result, item in
            let part = Text(verbatim: item.element)
            return result + (changed.contains(item.offset)
                ? part.bold().foregroundColor(removed ? .red : .teal).strikethrough(removed)
                : part)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("原笔记").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            marked(original, against: proposed, removed: true)
            Text("9B 建议 · 待核对").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            marked(proposed, against: original, removed: false)
        }
        .font(.system(size: 16))
        .lineSpacing(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension Text {
    init(markdown source: String) {
        self = FormulaDisplay.runs(source).reduce(Text("")) { result, run in
            let part: Text
            if run.script != 0 {
                part = Text(verbatim: run.text).font(.system(size: 10)).baselineOffset(run.script < 0 ? -3 : 5)
            } else if run.math {
                part = Text(verbatim: run.text)
            } else if let attributed = try? AttributedString(markdown: run.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                part = Text(attributed)
            } else { part = Text(verbatim: run.text) }
            return result + part
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

private struct ApplePreviewTranslationHost: ViewModifier {
    @EnvironmentObject private var model: AppModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.translationTask(model.previewTranslationEnabled ? configuration : nil) { session in
                await model.runPreviewTranslation(session: session)
            }
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private var configuration: TranslationSession.Configuration {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "zh-Hans")
        if #available(macOS 26.4, *) {
            return .init(source: source, target: target, preferredStrategy: .lowLatency)
        }
        return .init(source: source, target: target)
    }
}
