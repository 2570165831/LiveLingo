import Foundation
import SwiftUI
@preconcurrency import Translation

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("transcriptTextSize") private var transcriptTextSize = 18.0
    @State private var wholeLessonNotes = false
    @State private var showExportOptions = false
    @State private var activeSheet: ClassroomSheet?
    @State private var compactPane: ReadingPane = .subtitles
    @State private var followLatest = true
    @State private var captionAnchor: UUID?
    @State private var showStatusDetails = false
    @State private var showSummaryDetails = false
    @State private var sheetReturnFocus: ClassroomSheet?
    @FocusState private var focusedSheetButton: ClassroomSheet?

    enum ReadingPane: String, CaseIterable, Identifiable {
        case subtitles = "字幕"
        case notes = "笔记"
        var id: Self { self }
    }

    enum ClassroomSheet: String, Identifiable {
        case settings, translation, review, processing
        var id: Self { self }
        var title: String {
            switch self {
            case .settings: return "课堂设置"
            case .translation: return "文字翻译"
            case .review: return "核对笔记"
            case .processing: return "录音处理与补转"
            }
        }
    }

    init(showWholeLessonNotes: Bool = false) {
        _wholeLessonNotes = State(initialValue: showWholeLessonNotes)
        _compactPane = State(initialValue: showWholeLessonNotes ? .notes : .subtitles)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            workspace
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 820, minHeight: 700)
        .sheet(item: $activeSheet, onDismiss: {
            model.stopCandidatePlayback()
            focusedSheetButton = sheetReturnFocus
        }) { sheet in
            classroomSheet(sheet)
                .environmentObject(model)
        }
        .modifier(ApplePreviewTranslationHost())
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("实时课堂")
                    .font(.system(size: 20, weight: .semibold))
                Circle().fill(phaseColor).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.phaseLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { model.chooseSavedSession() } label: {
                    Label("打开课程…", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.phase.isBusy || model.archiveLoading || model.isImportingFile)
                .accessibilityIdentifier("classroom-open-session")
                Button { presentSheet(.translation) } label: {
                    Label(model.isManualTranslating ? "文字翻译中…" : "文字翻译", systemImage: "character.bubble")
                }
                .accessibilityIdentifier("classroom-typed-translation")
                .focused($focusedSheetButton, equals: .translation)
                Button { presentSheet(.settings) } label: {
                    Label("课堂设置…", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("classroom-settings")
                .focused($focusedSheetButton, equals: .settings)
            }
            .buttonStyle(.borderless)
            recordingDeck
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var settingsControls: some View {
        Form {
            Section("录音与保存") {
                Picker("音源", selection: $model.selectedInputMode) {
                    Text("麦克风").tag(AudioInputMode.microphone)
                    Text("系统内录").tag(AudioInputMode.systemAudio)
                }
                .disabled(model.phase.isBusy)
                Picker("记录方式", selection: $model.selectedStorageMode) {
                    Text("保存录音与笔记").tag(SessionStorageMode.saveSession)
                    Text("实时暂存").tag(SessionStorageMode.liveOnly)
                }
                .disabled(model.phase.isBusy)
                Text("实时暂存会在停止后删除临时录音并清空内容；录音期间可用“转为录音”保留这次课堂。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.isLiveOnly {
                    LabeledContent("保存位置", value: model.outputDirectory?.lastPathComponent ?? "尚未选择")
                    Button("选择保存位置…") { model.chooseOutputDirectory() }
                        .disabled(model.phase.isBusy)
                }
            }
            Section("字幕与处理") {
                Picker("质量模式", selection: $model.selectedMode) {
                    ForEach(ModelMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(model.phase.isBusy)
                Toggle("同步初译", isOn: $model.previewTranslationEnabled)
                    .disabled(!model.supportsPreviewTranslation)
                Text(model.supportsPreviewTranslation
                     ? "初译用于及时阅读；正式译文随后保存在字幕中。"
                     : "同步初译需要 macOS 15 或更新版本；正式翻译仍可使用。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("专注模式", isOn: $model.processingFocusEnabled)
                Text("优先处理录音与字幕，后台核对等待空闲。")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("录音期间防止空闲睡眠", isOn: $model.preventIdleSleepWhileRecording)
                DisclosureGroup("处理方式与模型详情") {
                    Text(model.modelModeStatus)
                    Text(model.focusExplanation)
                    Text("防止空闲睡眠是独立选项，停止录音或关闭开关后释放。")
                }
                .font(.callout)
            }
            Section("笔记整理") {
                Picker("每次整理的内容量", selection: $model.noteBatchCharacters) {
                    Text("较少 · 约 2500 字").tag(2_500)
                    Text("标准 · 约 4000 字").tag(4_000)
                    Text("较多 · 约 6000 字").tag(6_000)
                }
                Text("只影响之后的笔记。内容量较少时单次处理更短，但需要处理的批次更多。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func classroomSheet(_ sheet: ClassroomSheet) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") { activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("classroom-sheet-close")
            }
            .padding(20)
            Divider()
            switch sheet {
            case .settings:
                settingsControls
            case .translation:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        TypedTranslationView()
                        if model.isManualTranslating {
                            Text("关闭此窗口后翻译继续，可从“文字翻译中…”重新打开。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
            case .review:
                ScrollView {
                    LearningReviewControls(model: model)
                        .padding(.vertical, 16)
                }
            case .processing:
                SavedProcessingView(model: model)
            }
        }
        .frame(width: sheet == .processing ? 700 : 560, height: sheet == .review ? 360 : 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func presentSheet(_ sheet: ClassroomSheet) {
        sheetReturnFocus = sheet
        activeSheet = sheet
    }

    private var recordingDeck: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.duration(model.elapsedSeconds))
                    .font(.system(size: 17, weight: .medium).monospacedDigit())
                Text(recordingSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)

            RecordingWaveform(samples: model.waveformSamples, active: model.isRecording, lastUpdate: model.lastAudioLevelAt)
                .frame(width: 64, height: 24)

            Spacer(minLength: 10)

            Menu {
                Picker("字幕字号", selection: $transcriptTextSize) {
                    Text("标准").tag(18.0)
                    Text("大").tag(21.0)
                    Text("特大").tag(24.0)
                }
            } label: { Image(systemName: "textformat.size") }
            .help("主窗口字幕字号")
            .accessibilityLabel("字幕字号")
            .accessibilityIdentifier("classroom-caption-size")

            Button {
                openWindow(id: "subtitles")
            } label: {
                Image(systemName: "pip")
            }
            .buttonStyle(.bordered)
            .help("打开浮动字幕")
            .accessibilityLabel("打开浮动字幕")
            .accessibilityIdentifier("classroom-floating-subtitles")

            if model.isLiveOnly && model.hasActiveSession {
                Button {
                    model.convertCurrentSessionToRecording()
                } label: {
                    Label("转为录音", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
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
            .controlSize(.regular)
            .disabled(!model.hasActiveSession)
            .accessibilityIdentifier("classroom-pause-resume")

            if model.isImportingFile {
                Button {
                    model.cancelMediaImport()
                } label: {
                    Label("停止导入", systemImage: "stop.circle")
                        .frame(minWidth: 94)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.phase == .stopping)
                .help("停止导入；已经转出的部分会照常整理、导出并保存")
            } else {
                Button {
                    model.chooseAndImportMediaFile()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.phase.isBusy || !model.translationReady)
                .help("导入本地音频或视频文件…")
                .accessibilityLabel("导入本地音频或视频文件")
                .accessibilityIdentifier("classroom-import")
            }

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
            .controlSize(.regular)
            .disabled(!model.hasActiveSession && (!model.canStart || model.phase.isBusy))
            .accessibilityIdentifier("classroom-record-stop")
        }
        .frame(height: 42)
    }

    private var workspace: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 1_120 {
                    HStack(spacing: 14) {
                        transcriptPanel
                            .frame(maxWidth: .infinity)
                        summaryPanel
                            .frame(width: min(440, max(380, geometry.size.width * 0.34)))
                    }
                } else {
                    VStack(spacing: 12) {
                        Picker("阅读内容", selection: $compactPane) {
                            ForEach(ReadingPane.allCases) { pane in
                                Text(pane.rawValue).tag(pane)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("classroom-reading-pane")
                        if compactPane == .subtitles { transcriptPanel }
                        else { summaryPanel }
                    }
                }
            }
            .padding(16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("classroom-reading-workspace")
    }

    private var transcriptPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("双语转写")
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.previewTranslationEnabled && model.supportsPreviewTranslation
                         ? model.previewTranslationStatus : "最新内容在顶部")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.previewTranslationStatus)
                }
                Spacer()
                Toggle("跟随最新", isOn: $followLatest)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("关闭后可阅读先前字幕，新内容不会自动滚动到顶部")
                    .accessibilityIdentifier("classroom-follow-latest")
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
                    // 与浮动字幕同源：没有逐词预览（系统语音资源未安装）时回退到
                    // 最近一条定稿英文字幕，初译不再被流式英文是否为空卡住。
                    previewReadingSlot(
                        model.previewTranslationSource.isEmpty ? "等待英文语音…" : model.previewTranslationSource,
                        size: transcriptTextSize - 2, weight: .regular)
                    previewReadingSlot(
                        !model.previewTranslationEnabled ? "初译已关闭" :
                            !model.supportsPreviewTranslation ? "当前系统不支持初译；正式译文会在下方显示" :
                            model.previewChinese.isEmpty
                                ? "等待初译…" : "初译 · \(model.previewChinese)",
                        size: transcriptTextSize, weight: .medium)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
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
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $captionAnchor, anchor: .top)
                    .onChange(of: model.segments.count) {
                        if followLatest, let latest = model.segments.last {
                            proxy.scrollTo(latest.id, anchor: .top)
                        }
                    }
                    .onChange(of: followLatest) {
                        if followLatest, let latest = model.segments.last {
                            proxy.scrollTo(latest.id, anchor: .top)
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
        .panelSurface()
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
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                Text(segment.english)
                    .font(.system(size: transcriptTextSize - 2))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if segment.translationState == .pending || segment.translationState == .translating {
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
                    Text(markdown: segment.displayChinese)
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
        #if DEBUG
        .background {
            if AppRuntimeEnvironment.isUnitTesting {
                CaptionFrameProbe(segmentID: segment.id)
            }
        }
        #endif
    }

    private var summaryPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("学习笔记")
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.summaryStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.summaryStatus)
                }
                Spacer()
                Button { showSummaryDetails = true } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("查看笔记整理状态")
                .help("查看完整的整理进度与导出结果")
                .popover(isPresented: $showSummaryDetails) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("笔记状态").font(.headline)
                            Text(model.summaryStatus)
                            Text(model.summaryCoverageStatus)
                            if let status = model.exportStatus { Text(status) }
                        }
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 360, height: 220)
                }
            }
            .padding(16)

            Divider()

            HStack(spacing: 10) {
                Picker("笔记范围", selection: $wholeLessonNotes) {
                    Text("最近更新").tag(false)
                    Text("整课笔记").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if model.lectureSummary.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("实时总结会在这里出现")
                        .font(.headline)
                    Text("完成两段翻译后开始整理。新的课堂内容会逐步加入笔记。")
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
                            DisclosureGroup("核对意见 · 正文已保留") {
                                SummaryMarkdownView(text: model.reviewAdvice)
                            }
                        }
                    }
                    .padding(18)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ReviewEntryButton(queue: model.noteReviewQueue) { presentSheet(.review) }
                        .focused($focusedSheetButton, equals: .review)
                    Spacer()
                    Button {
                        model.exportScope = wholeLessonNotes ? .wholeLesson : .latest
                        showExportOptions.toggle()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.segments.isEmpty || model.isExporting)
                    .help("导出 Markdown、纯文本、Word 或 PDF")
                    .accessibilityIdentifier("classroom-export-notes")
                    .popover(isPresented: $showExportOptions, arrowEdge: .top) { exportOptionsPopover }

                    Button {
                        model.requestSummaryRefresh()
                    } label: {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.segments.isEmpty)
                    .accessibilityLabel("更新课堂笔记")
                    .accessibilityIdentifier("classroom-refresh-notes")
                }
                Text(model.exportStatus ?? "导出所选笔记；核对范围可另行选择")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 18, alignment: .leading)
                    .help(model.exportStatus ?? "核对意见独立保存，笔记正文保留")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .panelSurface()
    }

    private var exportOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出课堂笔记").font(.headline)

            Picker("格式", selection: $model.exportFormat) {
                ForEach(NotesExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Picker("范围", selection: $model.exportScope) {
                ForEach(NotesExportScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            Text(model.exportScope == .wholeLesson ? model.summaryCoverageStatus : model.latestSummaryScope)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("附带双语字幕与时间戳（按所选范围）", isOn: $model.exportIncludesTranscript)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("附带核对意见（独立章节）", isOn: $model.exportIncludesReviewAdvice)
                .toggleStyle(.switch)
                .controlSize(.small)

            Text("导出只读取当前笔记与复查记录，不调用模型、不改动录音或已保存文件；默认文件名包含课堂日期与内容范围。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("选择位置并导出…") {
                    showExportOptions = false
                    model.beginNotesExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isExporting)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.errorMessage == nil ? model.currentInputMode.statusIcon : "exclamationmark.triangle")
                    .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.orange)
                    .accessibilityHidden(true)
                Text(model.errorMessage ?? model.savedProcessingStatus ?? model.archiveNotice ?? model.translationStatus)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("classroom-status-message")
                Button("状态详情…") { showStatusDetails = true }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("classroom-status-details")
                    .popover(isPresented: $showStatusDetails, arrowEdge: .top) { statusDetails }
                Group {
                    if let notice = model.sessionNotice, notice == model.errorMessage {
                        Button(action: model.dismissSessionNotice) {
                            Image(systemName: "xmark").frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("关闭这条提示")
                        .accessibilityLabel("关闭这条提示")
                    } else {
                        Color.clear.accessibilityHidden(true)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .frame(height: 38)
            HStack(spacing: 12) {
                if model.isLiveOnly {
                    Text("实时暂存 · 停止后删除录音并清空")
                } else {
                    Button("保存位置…") { model.chooseOutputDirectory() }
                        .buttonStyle(.borderless)
                        .disabled(model.phase.isBusy)
                    Text(model.outputDirectory?.lastPathComponent ?? "尚未选择保存位置")
                        .lineLimit(1)
                    if case .saved = model.phase {
                        Button("录音处理…") { presentSheet(.processing) }
                            .buttonStyle(.borderless)
                            .focused($focusedSheetButton, equals: .processing)
                            .accessibilityIdentifier("classroom-saved-processing")
                        Button("在访达中显示") { model.revealSavedSession() }
                            .buttonStyle(.borderless)
                    }
                }
                Spacer(minLength: 8)
                if !model.translationReady {
                    Button("重新检查模型") { model.retryRuntimePreparation() }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 30)
        }
        .padding(.horizontal, 18)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("classroom-status-bar")
    }

    private var statusDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.errorMessage == nil ? "课堂状态" : "课堂提示")
                    .font(.headline)
                if let error = model.errorMessage {
                    Text(error)
                    Divider()
                }
                if let status = model.savedProcessingStatus { Text(status) }
                if let notice = model.archiveNotice { Text(notice) }
                Text("音源：\(model.audioInputStatus)")
                Text("识别：\(model.speechStatus)")
                Text("翻译：\(model.translationStatus)")
                Text(model.modelModeStatus)
                    .foregroundStyle(.secondary)
                Text(model.resourceStatusDescription)
                    .foregroundStyle(.secondary)
                if !model.translationReady {
                    Button("重新检查模型") { model.retryRuntimePreparation() }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(width: 440, height: 280)
    }

    private var phaseColor: Color {
        if model.isRecording { return .red }
        if model.isPaused { return .orange }
        if model.errorMessage != nil { return .orange }
        return .secondary
    }

    private var recordingSubtitle: String {
        if model.isImportingFile {
            return "正在导入本地文件 \(Int(model.importProgress * 100))%"
        }
        let input = model.currentInputMode == .microphone ? "麦克风" : "系统内录"
        if model.isPaused { return "\(input) · 计时已暂停" }
        if model.isRecording { return "\(input) · 录音中" }
        if case .saved = model.phase { return model.savedProcessingStatus ?? "录音已停止 · 课程已保存" }
        return model.translationReady ? "\(input) · 模型已就绪" : "\(input) · 正在检查模型"
    }

    private var stopTitle: String {
        model.isLiveOnly ? "结束记录" : "结束并保存"
    }

    private var englishPlaceholder: String {
        switch model.currentInputMode {
        case .microphone:
            return "开始后，麦克风内容会先显示英文，再补上中文译文。"
        case .systemAudio:
            return "开始后，本机播放的内容会先显示英文，再补上中文译文。"
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

#if DEBUG
/// Measures an actual rendered row in the isolated test host. Release builds
/// contain neither the probe nor synthetic presentation data.
private struct CaptionFrameProbe: NSViewRepresentable {
    let segmentID: UUID
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("classroom-caption-\(segmentID)")
    }
}
#endif

private struct ReviewEntryButton: View {
    @ObservedObject var queue: LearningReviewQueue
    let action: () -> Void

    private var needsAttention: Bool {
        queue.managementError != nil || queue.items.contains { $0.failure != nil }
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if needsAttention {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
                Text(needsAttention ? "核对需处理…" : queue.running ? "核对进行中…" : "核对笔记…")
            }
        }
        .buttonStyle(.borderless)
        .help("选择本课核对范围，或管理历史核对任务")
        .accessibilityIdentifier("classroom-review-notes")
    }
}

struct TypedTranslationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("英文 → 简体中文").font(.headline)
                Spacer()
                Text(model.effectiveProfile.shortLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text("使用当前质量模式 · 不加入录音历史")
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
        // 只在真的在收音时才挂 TimelineView：它每 0.1 秒唤醒一次布局，
        // 空闲时挂着会白烧约 16% 的 CPU（实测：主线程持续 NSDisplayCycleFlush → layoutIfNeeded）。
        if active {
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                bars(receiving: receiving(at: timeline.date))
            }
        } else {
            bars(receiving: false)
        }
    }

    private func receiving(at date: Date) -> Bool {
        lastUpdate.map { date.timeIntervalSince($0) < 0.6 } == true
    }

    private func bars(receiving: Bool) -> some View {
        GeometryReader { geometry in
            let gap: CGFloat = 1
            let count = max(1, samples.count)
            let width = max(1, (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: gap) {
                ForEach(samples.indices, id: \.self) { index in
                    let level = receiving ? min(1, max(0, samples[index])) : 0
                    Capsule()
                        .fill(receiving ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(width: width, height: 2 + CGFloat(level) * max(0, geometry.size.height - 2))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .linear(duration: SpeechPipeline.waveformUpdateInterval), value: samples)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(!active ? "音量显示已暂停" : receiving ? "正在接收音频" : "等待音频输入")
        .help(!active ? "音量显示已暂停" : receiving ? "实际输入音量：平均强度与短时峰值" : "暂未收到音频输入")
    }
}

private struct LearningReviewControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: LearningReviewQueue
    @State private var historyExpanded = false
    @State private var confirmingRemoval = false
    @State private var showingQueueManager = false
    @State private var pendingQueueRemoval: UUID?

    init(model: AppModel) {
        self.model = model
        self.queue = model.noteReviewQueue
    }

    private var currentDirectory: URL? { model.reviewDisplayDirectory }
    private var choices: [AppModel.ReviewBatchChoice] { model.reviewBatchChoices }
    private var hasReviewNotice: Bool {
        guard let notice = model.reviewQueueNotice else { return false }
        return !notice.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("复查队列")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !queue.status.isEmpty && !queue.belongsTo(currentDirectory) {
                    Text("历史录音")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 8)
                // Reviewing is manual: the entry stays reachable in every state,
                // also when there is nothing reviewable yet (then it is disabled).
                Menu {
                    Button("复查整课（全部 \(choices.count) 批）") {
                        model.startManualReview(.wholeLesson)
                    }
                    if let latest = choices.last {
                        Button("仅复查最新一批（第 \(latest.number) 批 · \(latest.topic)）") {
                            model.startManualReview(.batch(latest.number, id: latest.id))
                        }
                    }
                    Divider()
                    ForEach(choices) { choice in
                        Button("第 \(choice.number) 批 · \(choice.topic)（\(choice.pointCount) 条 · \(choice.timeRange)）") {
                            model.startManualReview(.batch(choice.number, id: choice.id))
                        }
                    }
                } label: {
                    Label("复查…", systemImage: "text.magnifyingglass")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.canManuallyReview)
                .help("选择复查范围：整课或某一批已完成笔记。9B 思考复查耗时随内容长度和设备变化（历史单机实测约 5 分钟/批，仅供参照），只给出核对意见。")
                // Queue management stays reachable in every state: it is never
                // hidden behind the history disclosure or tied to the current recording.
                Button("管理队列…") { showingQueueManager = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("查看复查任务、重试失败项、调整顺序或重新定位录音文件夹；任何操作都不会删除文件")
            }

            if !model.canManuallyReview {
                Text("课堂保存并生成笔记后，可选择整课或一批内容进行核对。历史任务仍可在“管理队列”中处理。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.canManuallyReview || hasReviewNotice {
                VStack(alignment: .leading, spacing: 3) {
                    Text("核对意见独立保存，原笔记保持不变。")
                        .font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("核对方式与耗时") {
                        Text("使用本机 9B 模型检查所选内容。耗时随设备和内容变化；状态中的历史耗时仅供参考。局部报告单独保存，整课报告保留。")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    if let notice = model.reviewQueueNotice, !notice.isEmpty {
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !queue.status.isEmpty {
                if queue.belongsTo(currentDirectory) {
                    details
                } else {
                    DisclosureGroup(isExpanded: $historyExpanded) {
                        details
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("历史录音复查 · \(queue.recordingName)")
                            Text("\(queue.running ? "后台处理中" : "已暂停或等待处理") · 与当前录音无关")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onChange(of: currentDirectory) { _, _ in historyExpanded = false }
        .sheet(isPresented: $showingQueueManager) { queueManagerSheet }
        .confirmationDialog("将这项任务移出复查队列？", isPresented: $confirmingRemoval) {
            Button("移出复查队列") { queue.removeFailedJob() }
        } message: {
            Text("只停止这项复查，不删除录音、原笔记或已保存的复查报告。")
        }
    }

    private var details: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(queue.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if queue.hasWork {
                  HStack {
                    Button(queue.userPaused ? "开始复查" : queue.actionTitle) { queue.performPrimaryAction() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    if queue.canRemoveFailedJob {
                        Button("移出复查队列") { confirmingRemoval = true }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                  }
                }
            }
    }

    // MARK: Queue management

    private var queueRemovalPrompt: Binding<Bool> {
        Binding(get: { pendingQueueRemoval != nil },
                set: { if !$0 { pendingQueueRemoval = nil } })
    }

    private func queueItemName(_ id: UUID) -> String {
        queue.items.first(where: { $0.id == id })?.name ?? "这项任务"
    }

    private func recordingDirectoryIsAvailable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private var queueManagerSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("复查队列管理")
                        .font(.headline)
                    Text("后台复查任务与当前录音无关；这里只调整复查队列，不会删除录音文件、原笔记或已保存的复查报告。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("关闭") { showingQueueManager = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            HStack(spacing: 12) {
                Text(queue.hasWork ? queue.status : "暂无待复查任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(!queue.hasWork || queue.userPaused ? "开始复查" : queue.actionTitle) {
                    queue.performPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!queue.hasWork)
                .help("开始或暂停整个复查队列；暂停时保留已完成结果和当前生成进度")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let managementError = queue.managementError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(managementError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            if queue.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("复查队列为空")
                        .font(.callout)
                    Text("保存课堂笔记后，关闭此窗口，在“核对笔记”中选择整课或一批内容开始。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(queue.items) { item in
                            queueRow(id: item.id,
                                     name: item.name,
                                     directory: item.directory,
                                     completed: item.completed,
                                     total: item.total,
                                     failure: item.failure,
                                     active: item.active,
                                     scope: item.scope,
                                     awaitingManualStart: queue.frontJobAwaitingManualStart
                                        && item.id == queue.items.first?.id)
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 360)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("共 \(queue.items.count) 项任务，按顺序处理；移动或移除正在运行的任务会先安全取消当前批次，已完成进度会保留。")
                Text("“重新定位文件夹…”只在录音文件夹被移动或改名时使用，LiveLingo 会核对原笔记是否一致。")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("将这项任务移出复查队列？",
                            isPresented: queueRemovalPrompt,
                            presenting: pendingQueueRemoval) { id in
            Button("移出复查队列", role: .destructive) {
                queue.removeJob(id)
                pendingQueueRemoval = nil
            }
        } message: { id in
            Text("只会把“\(queueItemName(id))”从复查队列中移除，不会删除录音文件、原笔记或已保存的复查报告。")
        }
    }

    private func queueRow(id: UUID, name: String, directory: URL,
                          completed: Int, total: Int, failure: String?, active: Bool,
                          scope: LearningReviewScope?, awaitingManualStart: Bool) -> some View {
        let available = recordingDirectoryIsAvailable(directory)
        let isLast = queue.items.last?.id == id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: active ? "waveform" : "clock")
                    .font(.caption)
                    .foregroundStyle(active ? Color.cyan : Color.secondary)
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if active {
                    Text("正在复查")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.cyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.12), in: Capsule())
                } else {
                    Text(failure == nil ? "等待处理" : "需要处理")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if total > 0 {
                    Text("已完成 \(completed)/\(total) 批")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("尚未开始")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(scope?.label ?? "整课复查")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if awaitingManualStart {
                    Text("等待手动开始（升级后不会自动运行）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if total > 0 {
                ProgressView(value: Double(min(max(completed, 0), total)), total: Double(total))
                    .controlSize(.small)
            }

            if let failure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(failure.isEmpty ? "复查已中断，等待重试。" : failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: available ? "folder" : "folder.badge.questionmark")
                    .font(.caption2)
                    .foregroundStyle(available ? Color.secondary : Color.orange)
                Text(available ? directory.path : "录音文件夹已移动或不可用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(directory.path)
            }

            HStack(spacing: 10) {
                if failure != nil {
                    Button("重试") { queue.retryJob(id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("重新处理这项复查；已经完成的批次不会重复。")
                }
                Button("移到最后") { queue.moveJobToEnd(id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(isLast)
                    .help(isLast ? "已经在队列末尾" : "调整复查顺序；正在运行的任务会先安全取消当前批次。")
                if !available {
                    Button("重新定位文件夹…") { relocateRecording(id: id, from: directory, name: name) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("选择录音文件夹的新位置；LiveLingo 会核对原笔记是否一致。")
                }
                Spacer(minLength: 8)
                Button("移出队列…") { pendingQueueRemoval = id }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help("只从复查队列移除这项任务，不会删除任何文件。")
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func relocateRecording(id: UUID, from directory: URL, name: String) {
        let panel = NSOpenPanel()
        panel.title = "重新定位录音文件夹"
        panel.message = "选择“\(name)”现在所在的文件夹。LiveLingo 会核对原笔记是否一致，不会移动或删除任何文件。"
        panel.prompt = "选择文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        let parent = directory.deletingLastPathComponent()
        if recordingDirectoryIsAvailable(parent) { panel.directoryURL = parent }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        queue.relocateJob(id, to: chosen)
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
    func panelSurface() -> some View {
        background(Color(nsColor: .textBackgroundColor),
                   in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

private struct ApplePreviewTranslationHost: ViewModifier {
    @EnvironmentObject private var model: AppModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), !AppRuntimeEnvironment.isUnitTesting {
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
