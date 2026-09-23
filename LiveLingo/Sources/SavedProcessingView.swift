import SwiftUI

/// Controls are bound to the displayed course. Opening this view never starts
/// recording, playback, model generation or review by itself.
struct SavedProcessingView: View {
    @ObservedObject var model: AppModel

    private var actionable: [TranscriptionWorkRecord] {
        model.savedTranscriptionWork.filter { $0.needsWork || $0.status == .failed || $0.candidateText != nil }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.savedProcessingStatus ?? "录音已保存，采集已停止。")
                        .font(.headline)
                        .accessibilityIdentifier("saved-processing-status")
                    if let state = model.transcriptionProcessing {
                        Text("等待转写 \(state.pendingCount) 段 · 待确认或失败 \(state.unresolvedCount) 段")
                            .font(.callout).foregroundStyle(.secondary)
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
                    Text(error)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("saved-processing-error")
                    Button("重试保存课程进度") { model.retrySavedSessionWrite() }
                        .disabled(model.archiveLoading)
                        .accessibilityIdentifier("saved-processing-retry-save")
                }

                if !model.transcriptionCandidates.isEmpty {
                    Text("待确认文字").font(.title3.weight(.semibold))
                    ForEach(model.transcriptionCandidates, id: \.id) { candidate in
                        TranscriptionCandidateEditor(model: model, candidate: candidate,
                            revision: model.candidateInputRevision(candidate.id))
                            .id(CandidateEditorIdentity(id: candidate.id, text: candidate.text,
                                original: candidate.originalText,
                                revision: model.candidateInputRevision(candidate.id)))
                    }
                }

                if !actionable.isEmpty {
                    Text("转写任务").font(.title3.weight(.semibold))
                    ForEach(actionable) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(LearningTimeLabel.stamp(record.start))–\(LearningTimeLabel.stamp(record.end))")
                                    .monospacedDigit()
                                Text(Self.label(record.status)).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                if record.status == .failed {
                                    Button("重试这段") { model.resumeSavedProcessing(retryID: record.id) }
                                        .disabled(model.legacyProvenanceUnavailable)
                                        .accessibilityLabel("重试 \(LearningTimeLabel.stamp(record.start)) 至 \(LearningTimeLabel.stamp(record.end)) 的转写")
                                        .accessibilityIdentifier("transcription-retry-\(record.id)")
                                }
                            }
                            Text("自动补转 \(record.automaticRetryCount)/2 次 · 手动重试 \(record.manualRetryCount) 次")
                                .font(.caption).foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("saved-processing-panel")
        .onDisappear { model.stopCandidatePlayback() }
    }

    private static func label(_ status: TranscriptionWorkRecord.Status) -> String {
        switch status {
        case .pending: return "等待转写"
        case .active: return "正在转写"
        case .retryWaiting: return "等待自动补转"
        case .manualPending: return "等待手动重试"
        case .completed: return "已转写"
        case .silent: return "已确认无讲话"
        case .failed: return "转写失败"
        }
    }
}

private struct CandidateEditorIdentity: Hashable {
    let id: UUID
    let text: String
    let original: String
    let revision: Int
}

private struct TranscriptionCandidateEditor: View {
    @ObservedObject var model: AppModel
    let candidate: TranscriptionCandidate
    let revision: Int
    @State private var proposed: String

    init(model: AppModel, candidate: TranscriptionCandidate, revision: Int) {
        self.model = model
        self.candidate = candidate
        self.revision = revision
        _proposed = State(initialValue: candidate.text)
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
                .accessibilityIdentifier("candidate-play-\(candidate.id)")
            }
            if candidate.origin == "context" {
                Text("候选使用了相邻语句，尚未确认与本段的对应范围。请先回听，再编辑确认。")
                    .font(.callout).foregroundStyle(.secondary)
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
                    TextEditor(text: $proposed)
                        .font(.body)
                        .frame(minHeight: 100)
                        .accessibilityLabel("\(LearningTimeLabel.stamp(candidate.start)) 的候选文字")
                        .accessibilityIdentifier("candidate-editor-\(candidate.id)")
                }
            }
            Text("确认后重做这段的译文和相关笔记；旧正文、笔记及复查意见继续保留。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保留原文") {
                    model.dismissTranscriptionCandidate(candidate.id, expectedCandidate: candidate.text)
                }
                Spacer()
                Button("确认采用编辑后的文字") {
                    model.acceptTranscriptionCandidate(candidate.id, editedText: proposed,
                        expectedOriginal: candidate.originalText, expectedRevision: revision,
                        expectedCandidate: candidate.text, expectedSession: candidate.sessionID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("candidate-accept-\(candidate.id)")
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .disabled(model.candidateConfirmationInFlight || model.archiveLoading)
    }
}
