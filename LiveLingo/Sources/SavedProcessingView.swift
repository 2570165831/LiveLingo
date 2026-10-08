import SwiftUI

/// Controls are bound to the displayed course. Opening this view never starts
/// recording, playback, model generation or review by itself.
struct SavedProcessingView: View {
    @ObservedObject var model: AppModel

    private var actionable: [TranscriptionWorkRecord] {
        model.savedTranscriptionWork.filter {
            $0.needsWork || $0.status == .failed || $0.status == .otherLanguage || $0.candidateText != nil
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.savedProcessingStatus ?? "录音已保存，采集已停止。")
                        .font(.headline)
                        .accessibilityIdentifier("saved-processing-status")
                    if let label = model.savedOutputLanguageLabel {
                        Text(label).font(.callout).foregroundStyle(ReadingAccessibility.secondaryText)
                            .accessibilityIdentifier("saved-course-output-language")
                    }
                    if model.showsChineseReadingSelector {
                        Picker("阅读文字", selection: Binding(get: { model.chineseReadingLanguage },
                                                            set: { model.setChineseDisplayLanguage($0) })) {
                            ForEach(model.chineseReadingChoices) { language in
                                Text(language.profile.autonym).tag(language)
                            }
                        }
                        .accessibilityIdentifier("saved-course-reading-language")
                        Text("切换阅读文字无需重新翻译；保存和导出仍使用课程原来的语言。")
                            .font(.caption).foregroundStyle(ReadingAccessibility.secondaryText)
                    }
                    if let state = model.transcriptionProcessing {
                        Text(SavedProcessingPresentation.workSummary(state, segments: model.segments))
                            .font(.callout).foregroundStyle(ReadingAccessibility.secondaryText)
                    } else if let summary = SavedProcessingPresentation.languageSummary(segments: model.segments) {
                        Text(summary)
                            .font(.callout).foregroundStyle(ReadingAccessibility.secondaryText)
                    }
                    HStack {
                        Button(model.savedProcessingIsPaused ? "继续处理" : "暂停处理") {
                            if model.savedProcessingIsPaused { model.resumeSavedProcessing() }
                            else { model.pauseSavedProcessing() }
                        }
                        .disabled(model.legacyProvenanceUnavailable)
                        .accessibilityIdentifier("saved-processing-pause-resume")
                        Button("显示录音文件夹") { model.revealSavedSession() }
                            .accessibilityIdentifier("saved-processing-reveal")
                    }
                }

                if model.legacyProvenanceUnavailable {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这份旧课程保留了原字幕和笔记，缺少来源批次。重建会根据现有字幕重新整理，原笔记仍保留在存档中。")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("从现有字幕重建笔记") { model.rebuildSavedNotes() }
                            .accessibilityIdentifier("saved-processing-rebuild-notes")
                    }
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }

                if let error = model.archiveError {
                    Label {
                        Text(error).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ClassroomPalette.failure)
                    }
                    .accessibilityIdentifier("saved-processing-error")
                    Button("重试保存课程进度") { model.retrySavedSessionWrite() }
                        .disabled(model.archiveLoading)
                        .accessibilityIdentifier("saved-processing-retry-save")
                }

                if !model.transcriptionCandidates.isEmpty {
                    Text("待确认文字").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    ForEach(model.transcriptionCandidates, id: \.id) { candidate in
                        TranscriptionCandidateEditor(model: model, candidate: candidate,
                            revision: model.candidateInputRevision(candidate.id))
                            .id(CandidateEditorIdentity(id: candidate.id, sessionID: candidate.sessionID))
                    }
                }

                if !actionable.isEmpty {
                    Text("转写任务").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    ForEach(actionable) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(LearningTimeLabel.stamp(record.start))–\(LearningTimeLabel.stamp(record.end))")
                                    .monospacedDigit()
                                Text(SavedProcessingPresentation.recordLabel(record.status)).foregroundStyle(ReadingAccessibility.secondaryText)
                                Spacer(minLength: 8)
                                if record.status == .failed || record.status == .otherLanguage {
                                    Button("重试这段") { model.resumeSavedProcessing(retryID: record.id) }
                                        .disabled(model.legacyProvenanceUnavailable)
                                        .accessibilityLabel("重试 \(LearningTimeLabel.stamp(record.start)) 至 \(LearningTimeLabel.stamp(record.end)) 的转写")
                                        .accessibilityIdentifier("transcription-retry-\(record.id)")
                                }
                            }
                            Text("自动补转 \(record.automaticRetryCount)/2 次 · 手动重试 \(record.manualRetryCount) 次")
                                .font(.caption).foregroundStyle(ReadingAccessibility.secondaryText)
                            if let failure = record.failure, !failure.isEmpty {
                                Text(failure).font(.callout).textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                } else if model.transcriptionCandidates.isEmpty {
                    Text("当前没有待补转片段。已保存的字幕和笔记可在课堂主窗口阅读或导出。")
                        .foregroundStyle(ReadingAccessibility.secondaryText)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("saved-processing-panel")
        .onDisappear { model.stopCandidatePlayback() }
    }

}

private struct CandidateEditorIdentity: Hashable {
    let id: UUID
    let sessionID: UUID
}

/// The source binding and the user's draft have independent lifetimes. A
/// changed source cannot silently reset or adopt an unconfirmed edit.
struct CandidateEditSource: Equatable {
    let candidate: TranscriptionCandidate
    let revision: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.candidate.id == rhs.candidate.id
            && lhs.candidate.sessionID == rhs.candidate.sessionID
            && lhs.candidate.originalText == rhs.candidate.originalText
            && lhs.candidate.text == rhs.candidate.text
            && lhs.candidate.language == rhs.candidate.language
            && lhs.candidate.start == rhs.candidate.start && lhs.candidate.end == rhs.candidate.end
            && lhs.candidate.audioURL == rhs.candidate.audioURL && lhs.candidate.origin == rhs.candidate.origin
    }
}

struct CandidateEditDraft {
    private(set) var source: CandidateEditSource
    var text: String
    private(set) var hasConflict = false

    init(source: CandidateEditSource) {
        self.source = source
        text = source.candidate.text
    }

    mutating func receive(_ updated: CandidateEditSource) {
        guard source != updated else { hasConflict = false; return }
        if text == source.candidate.text && !hasConflict {
            source = updated
            text = updated.candidate.text
        } else {
            hasConflict = true
        }
    }

    mutating func acknowledge(_ updated: CandidateEditSource) {
        source = updated
        hasConflict = false
    }
}

struct TranscriptionCandidateEditor: View {
    @ObservedObject var model: AppModel
    let candidate: TranscriptionCandidate
    let revision: Int
    @State private var draft: CandidateEditDraft

    init(model: AppModel, candidate: TranscriptionCandidate, revision: Int) {
        self.model = model
        self.candidate = candidate
        self.revision = revision
        _draft = State(initialValue: CandidateEditDraft(source: CandidateEditSource(candidate: candidate, revision: revision)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(LearningTimeLabel.stamp(candidate.start))–\(LearningTimeLabel.stamp(candidate.end))")
                    .font(.headline.monospacedDigit())
                Spacer()
                Button(model.playingCandidateID == candidate.id ? "停止回听" : "回听这段") {
                    model.playTranscriptionCandidate(candidate.id)
                }
                .accessibilityLabel(ContextualActionName.candidate(model.playingCandidateID == candidate.id ? "停止回听" : "回听",
                    start: candidate.start, end: candidate.end))
                .accessibilityIdentifier("candidate-play-\(candidate.id)")
            }
            if candidate.origin == "context" {
                Text("候选使用了相邻语句，尚未确认与本段的对应范围。请先回听，再编辑确认。")
                    .font(.callout).foregroundStyle(ReadingAccessibility.secondaryText)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("保留的原文").font(.subheadline.weight(.semibold))
                    Text(candidate.originalText.isEmpty ? "本段暂无原文" : candidate.originalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("候选文字 · 可编辑").font(.subheadline.weight(.semibold))
                    TextEditor(text: $draft.text)
                        .font(.body)
                        .frame(minHeight: 100)
                        .accessibilityLabel("\(LearningTimeLabel.stamp(candidate.start)) 的候选文字")
                        .accessibilityIdentifier("candidate-editor-\(candidate.id)")
                }
            }
            Text("确认后重做这段的译文和相关笔记；旧正文、笔记及核对意见继续保留。")
                .font(.caption).foregroundStyle(ReadingAccessibility.secondaryText)
            if draft.hasConflict {
                Text("本段来源已更新；你的编辑已保留，请对照新原文重新核对后确认。")
                    .foregroundStyle(ReadingAccessibility.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("candidate-source-conflict-\(candidate.id)")
                Button("已核对更新，保留编辑") {
                    draft.acknowledge(CandidateEditSource(candidate: candidate, revision: revision))
                }
                .accessibilityLabel(ContextualActionName.candidate("已核对更新，保留编辑", start: candidate.start, end: candidate.end))
                .accessibilityIdentifier("candidate-acknowledge-\(candidate.id)")
            }
            HStack {
                Button("保留原文") {
                    model.dismissTranscriptionCandidate(candidate.id, expectedCandidate: candidate.text)
                }
                .accessibilityLabel(ContextualActionName.candidate("保留原文", start: candidate.start, end: candidate.end))
                Spacer()
                Button("确认采用编辑后的文字") {
                    guard !draft.hasConflict else { return }
                    let source = draft.source
                    model.acceptTranscriptionCandidate(candidate.id, editedText: draft.text,
                        expectedOriginal: source.candidate.originalText, expectedRevision: source.revision,
                        expectedCandidate: source.candidate.text, expectedSession: source.candidate.sessionID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.hasConflict || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(ContextualActionName.candidate("确认采用编辑后的文字", start: candidate.start, end: candidate.end))
                .accessibilityIdentifier("candidate-accept-\(candidate.id)")
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .disabled(model.candidateConfirmationInFlight || model.archiveLoading)
        .onChange(of: CandidateEditSource(candidate: candidate, revision: revision)) { _, updated in
            draft.receive(updated)
        }
    }
}
