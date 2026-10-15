import AppKit
import Darwin
import Foundation
import PDFKit
import Testing
@testable import LiveLingo

/// Synthetic captions only; no capture, model, window or user course access.
@Suite(.isolatedStorage)
struct ChineseRecognitionStorageTests {
    private let date = Date(timeIntervalSince1970: 0)
    private let chinese = "这片叶子长大了。"

    private func source() -> TranscriptSegment {
        TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            startTime: 0, endTime: 1.25, english: "Ice is cold.", chinese: "冰很冷。")
    }

    private func directory(_ name: String) throws -> URL {
        let root = TestFixtureDirectory.root.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func batch(_ segment: TranscriptSegment) -> LearningNoteBatch {
        LearningNoteBatch(id: UUID(), evidence: [segment],
            note: LearningNote(topic: "叶子", points: [.init(kind: "核心结论", text: chinese,
                sources: [.init(index: 0, quote: chinese)])]))
    }

    @Test func applyReplacesBothTextFieldsWithoutChangingAudioIdentity() throws {
        var segment = source()
        let original = segment
        segment.applyChineseRecognition(" \n" + chinese + "\n ")
        #expect(segment.isChineseOriginal)
        #expect(segment.canUndoChineseRecognition)
        #expect(segment.english == chinese && segment.chinese == chinese)
        #expect(segment.sourceLanguage == "zh" && segment.hasExplicitSourceLanguage)
        #expect(segment.hasUsableTranslation && segment.translationState == .completed)
        #expect(segment.displayChinese == chinese)
        #expect(segment.id == original.id && segment.sessionID == original.sessionID)
        #expect(segment.startTime == original.startTime && segment.endTime == original.endTime)
        #expect(segment.inputRevision == original.inputRevision)
        #expect(segment.chineseRecognitionOriginal?.english == original.english)
        #expect(segment.chineseRecognitionOriginal?.chinese == original.chinese)
        #expect(!segment.sameContent(as: original))
    }

    @Test func emptyResultDoesNotChangeSourceAndRepeatedResultsKeepFirstUndo() throws {
        var segment = source()
        let before = try SessionArchiveCoding.encode(segment)
        segment.applyChineseRecognition(" \n\t ")
        #expect(try SessionArchiveCoding.encode(segment) == before)
        segment.applyChineseRecognition(chinese)
        let backup = segment.chineseRecognitionOriginal
        segment.applyChineseRecognition("水会流动。")
        segment.applyChineseRecognition(" ")
        #expect(segment.chineseRecognitionOriginal == backup)
        #expect(segment.english == "水会流动。")
        let undone = segment.undoChineseRecognition()
        #expect(undone)
        #expect(try SessionArchiveCoding.encode(segment) == before)
        let undoneAgain = segment.undoChineseRecognition()
        #expect(!undoneAgain)
        #expect(!segment.canUndoChineseRecognition)
    }

    @Test func undoRestoresEveryTranslationStateAndDiagnosticField() throws {
        var failed = source()
        failed.recordTranslationFailure(.translationRejected, rejection: .sourceEcho)
        failed.recordTranslationFailure(.requestTimedOut)
        failed.recordTranslationFailure(.translationRejected, rejection: .sourceEcho)
        failed.finishFailedTranslation()
        failed.updateCaptionAnnotation(targetCode: "en")
        failed.recordInitialTranslationFallback("冰很冷。", targetCode: "zh-Hans")
        var legacyFailure = source()
        legacyFailure.failTranslation("synthetic legacy failure")
        var pending = TranscriptSegment(startTime: 2, endTime: 3, english: "Water flows.")
        pending.updateCaptionAnnotation(targetCode: "en")
        var translating = pending
        translating.beginTranslation()
        var formula = source()
        formula.updateCaptionAnnotation(targetCode: "en", formulaUncertain: true)
        for original in [source(), pending, translating, failed, legacyFailure, formula] {
            var segment = original
            segment.applyChineseRecognition(chinese)
            #expect(segment.translationFailures.isEmpty && segment.translationError == nil)
            #expect(segment.captionAnnotation == nil && segment.initialTranslationFallback == nil)
            segment.inputRevision = 8
            let undone = segment.undoChineseRecognition()
            #expect(undone)
            var expected = original
            expected.inputRevision = 8
            #expect(segment == expected)
            #expect(try SessionArchiveCoding.encode(segment) == SessionArchiveCoding.encode(expected))
        }
    }

    @Test func legacyInferredLanguageRoundTripsThroughUndoWithoutBecomingExplicit() throws {
        let bytes = Data(#"{"id":"00000000-0000-0000-0000-000000000011","startTime":0,"endTime":1,"english":"热量传递。","chinese":"热量传递。","translationState":"completed"}"#.utf8)
        var legacy = try SessionArchiveCoding.decode(TranscriptSegment.self, from: bytes)
        #expect(legacy.sourceLanguage == "zh" && !legacy.hasExplicitSourceLanguage)
        let original = try SessionArchiveCoding.encode(legacy)
        legacy.applyChineseRecognition(chinese)
        var reloaded = try SessionArchiveCoding.decode(TranscriptSegment.self, from: SessionArchiveCoding.encode(legacy))
        let undone = reloaded.undoChineseRecognition()
        #expect(undone)
        #expect(!reloaded.hasExplicitSourceLanguage)
        #expect(try SessionArchiveCoding.encode(reloaded) == original)
    }

    @Test func queuedTranslationCannotOverwriteChineseOriginal() {
        var segment = source()
        segment.applyChineseRecognition(chinese)
        let corrected = segment
        segment.beginTranslation()
        segment.completeTranslation("The leaf grew.", targetCode: "en")
        segment.failTranslation("late failure")
        segment.recordTranslationFailure(.requestTimedOut)
        segment.finishFailedTranslation()
        segment.updateCaptionAnnotation(targetCode: "en", formulaUncertain: true)
        segment.chinese = "late output"
        #expect(segment == corrected)
    }

    @Test func ordinaryEnglishEncodingMatchesFrozenBytesAndNeedsReader1() throws {
        let expected = #"{"chinese":"冰很冷。","endTime":1.25,"english":"Ice is cold.","id":"00000000-0000-0000-0000-000000000011","inputRevision":0,"startTime":0,"translationState":"completed"}"#
        let bytes = try SessionArchiveCoding.encode(source())
        #expect(bytes == Data(expected.utf8))
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: bytes) == 1)
        #expect(SessionArchiveCoding.currentReaderVersion == 5)
        let decoded = try SessionArchiveCoding.decode(TranscriptSegment.self, from: bytes)
        #expect(!decoded.isChineseOriginal && decoded.chineseRecognitionOriginal == nil)
    }

    @Test func ordinaryEnglishSourceTargetSRTAndJSONLMatchFrozenStep6Bytes() throws {
        let segments = [source(),
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
                startTime: 1.25, endTime: 2.5, english: "Water flows.", inputRevision: 2),
            TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
                startTime: 2.5, endTime: 4, english: "Heat moves.", chinese: "[翻译失败：synthetic-failure]")]
        #expect(SessionExporter.sourceLine(segments[0]) == "Ice is cold.")
        #expect(SessionExporter.targetLine(segments[0]) == "冰很冷。")
        #expect(SessionExporter.srtCue(segments[0], index: 0)
            == "1\n00:00:00,000 --> 00:00:01,250\nIce is cold.\n冰很冷。")
        let root = try directory("frozen-english-export")
        try SessionExporter.export(segments: segments, sessionDirectory: root, summary: "\n# Lesson\n", createdAt: date)
        // The same pre-feature fixed literals as MultilingualSessionExporterTests.
        let expected = [
            "transcript-en.txt": "Ice is cold.\nWater flows.\nHeat moves.\n",
            "transcript-zh-Hans.txt": "冰很冷。\n（本段暂无译文）\n（本段翻译未完成，可对照英文）\n",
            "summary-zh-Hans.md": "# Lesson\n",
            "manifest.json": #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":3,"sourceLocale":"en-US","targetLocale":"zh-Hans"}"#,
            "bilingual.jsonl": #"""
            {"chinese":"冰很冷。","endTime":1.25,"english":"Ice is cold.","id":"00000000-0000-0000-0000-000000000011","inputRevision":0,"startTime":0,"translationState":"completed"}
            {"chinese":"","endTime":2.5,"english":"Water flows.","id":"00000000-0000-0000-0000-000000000012","inputRevision":2,"startTime":1.25,"translationState":"pending"}
            {"chinese":"[翻译失败：synthetic-failure]","endTime":4,"english":"Heat moves.","id":"00000000-0000-0000-0000-000000000013","inputRevision":0,"startTime":2.5,"translationError":"synthetic-failure","translationState":"failed"}
            """# + "\n",
            "bilingual.srt": """
            1
            00:00:00,000 --> 00:00:01,250
            Ice is cold.
            冰很冷。

            2
            00:00:01,250 --> 00:00:02,500
            Water flows.
            （本段暂无译文）

            3
            00:00:02,500 --> 00:00:04,000
            Heat moves.
            （本段翻译未完成，可对照英文）
            """ + "\n"
        ]
        for (name, bytes) in expected {
            #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data(bytes.utf8))
        }
        for segment in segments {
            let fields = try #require(JSONSerialization.jsonObject(with: SessionArchiveCoding.encode(segment)) as? [String: Any])
            #expect(fields["isChineseOriginal"] == nil && fields["chineseRecognitionOriginal"] == nil)
        }
    }

    @Test func ordinaryEnglishMarkdownMatchesFrozenStep6Bytes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let generatedAt = try #require(calendar.date(from:
            DateComponents(year: 2001, month: 1, day: 2, hour: 12, minute: 34)))
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 1, english: "Ice is cold.", chinese: "冰很冷。"),
            TranscriptSegment(startTime: 1, endTime: 2, english: "Water flows."),
            TranscriptSegment(startTime: 2, endTime: 3, english: "Heat moves.", chinese: "[翻译失败：synthetic-failure]")]
        let snapshot = NotesExportSnapshot(className: "Chemistry", sessionName: "Lesson 2001-01-02", scope: .wholeLesson,
            scopeDetail: "全部片段", coverageLine: "已整理", notesMarkdown: "冰很冷。", reviewMarkdown: nil,
            transcript: segments, generatedAt: generatedAt, includesReviewAdvice: false, includesTranscript: true,
            exportTimeZone: calendar.timeZone)
        let expected = "# Chemistry · 整课笔记 · 2001-01-02\n\n"
            + "- 内容范围：整课笔记（全部片段）\n- 整理进度：已整理\n- 来源录音：Lesson 2001-01-02\n"
            + "- 导出时间：2001-01-02 12:34\n"
            + "- 说明：本文件由本机模型生成，未经人工逐句核对；正文按主题整理，“需要回听”和“来源检查”两节列出的内容仍需自行核对。\n\n\n"
            + "## 学习笔记\n\n冰很冷。\n\n## 双语字幕（含时间戳）\n\n"
            + "[00:00–00:01] Ice is cold.  \n冰很冷。\n\n[00:01–00:02] Water flows.  \n（本段暂无译文）\n\n"
            + "[00:02–00:03] Heat moves.  \n（本段翻译未完成，可对照英文）\n"
        #expect(try NotesExportDocument.data(snapshot, format: .markdown) == Data(expected.utf8))
    }

    @Test func reader5GateDependsOnlyOnNewKeysNotTextOrOrdinaryLanguage() throws {
        for json in [#"{"isChineseOriginal":true}"#, #"{"chineseRecognitionOriginal":null}"#,
                     #"{"batches":[{"evidence":[{"isChineseOriginal":true}]}]}"#] {
            #expect(try SessionArchiveCoding.minimumReaderVersion(for: Data(json.utf8)) == 5)
        }
        #expect(try SessionArchiveCoding.minimumReaderVersion(for:
            Data(#"{"english":"isChineseOriginal chineseRecognitionOriginal"}"#.utf8)) == 1)
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: Data(#"{"sourceLanguage":"zh"}"#.utf8)) == 2)
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: Data(#"{"captureStartedAt":0}"#.utf8)) == 3)
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: Data(#"{"initialTranslationFallback":null}"#.utf8)) == 4)
    }

    @Test func snapshotAndJournalKeepUndoAndGateOldReaders() throws {
        for journalOnly in [false, true] {
            let root = try directory("chinese-storage")
            let store = SessionStore(directory: root)
            var segment = source()
            var saved = try store.save(SessionSnapshot(segments: [segment], createdAt: date))
            segment.applyChineseRecognition(chinese)
            segment.inputRevision = 1
            let correction = SessionInputRevision(fromRevision: 0, toRevision: 1,
                previousSegment: source(), replacementSegment: segment,
                reason: "按中文重新识别", confirmedAt: date)
            saved = try store.append(.inputRevision(correction), expectedRevision: saved.storageRevision)
            if !journalOnly { saved = try store.save(saved) }
            let file = root.appendingPathComponent(journalOnly ? SessionStore.journalFileName : SessionStore.snapshotFileName)
            let bytes = try Data(contentsOf: file)
            let rows = bytes.split(separator: 10).filter { !$0.isEmpty }
            let row = try #require(rows.last)
            let envelope = try #require(JSONSerialization.jsonObject(with: Data(row)) as? [String: Any])
            #expect((envelope["schemaVersion"] as? Int) == 5)
            // Frozen reader gate, without launching or mutating an older app.
            let version = try #require(envelope["schemaVersion"] as? Int)
            for maximum in 1...4 {
                #expect(throws: SessionStoreError.unsupportedSchema(5)) {
                    guard (1...maximum).contains(version) else { throw SessionStoreError.unsupportedSchema(version) }
                }
            }
            #expect(try Data(contentsOf: file) == bytes)
            let loaded = try #require(try store.load())
            #expect(loaded.segments == [segment])
            var restored = loaded.segments[0]
            let undone = restored.undoChineseRecognition()
            #expect(undone)
            var originalAtRevision1 = source()
            originalAtRevision1.inputRevision = 1
            #expect(restored == originalAtRevision1)
            restored.inputRevision = 2
            let undo = SessionInputRevision(fromRevision: 1, toRevision: 2,
                previousSegment: segment, replacementSegment: restored,
                reason: "撤销中文重新识别", confirmedAt: date)
            let reverted = try store.append(.inputRevision(undo), expectedRevision: loaded.storageRevision)
            _ = try store.save(reverted)
            #expect(try store.load()?.segments == [restored])
        }
    }

    @Test func learningEvidenceDropsUndoButKeepsChineseProvenanceAndStableDigest() throws {
        var segment = source()
        segment.applyChineseRecognition(chinese)
        let evidence = segment.withoutTranslationFailures
        #expect(evidence.isChineseOriginal && evidence.chineseRecognitionOriginal == nil)
        #expect(!evidence.canUndoChineseRecognition)
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: SessionArchiveCoding.encode(evidence)) == 5)
        let bytes = try SessionArchiveCoding.encode(batch(segment))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("Ice is cold."))
        #expect(try SessionArchiveCoding.decode(LearningNoteBatch.self, from: bytes).evidence == [evidence])
        var differentOriginal = TranscriptSegment(id: segment.id, startTime: segment.startTime,
            endTime: segment.endTime, english: "Different fluent English.")
        differentOriginal.applyChineseRecognition(chinese)
        #expect(segment != differentOriginal)
        #expect(!segment.sameContent(as: differentOriginal))
        #expect(segment.withoutTranslationFailures == differentOriginal.withoutTranslationFailures)
        let left = SessionSnapshot(segments: [segment], createdAt: date)
        var right = left
        right.segments = [differentOriginal]
        #expect(try left.inputFingerprint() == right.inputFingerprint())
    }

    @Test @MainActor func notesUseChineseSourcesForEveryGenerationTargetAndReview() throws {
        var segment = source()
        segment.applyChineseRecognition(chinese)
        for target in [CaptionTranslationTarget.simplifiedChinese, .english, .spanish, .french] {
            let units = LearningSourceUnit.make([segment], target: target)
            #expect(units == [.init(id: "zh0s0", index: 0, language: "zh", text: chinese)])
            #expect(LearningSourceUnit.bindingTexts(for: segment, target: target) == [chinese])
            let prompt = LearningPrompts.generationPrompt(target: target, evidence: [segment])
            #expect(prompt.hasSuffix(LearningPrompts.chineseOriginalEvidenceRule))
            let input = try LearningPrompts.input(evidence: [segment], topics: [], target: target)
            #expect(input.contains("zh0s0") && !input.contains("Ice is cold."))
            let prepared = try LearningReviewQueue.prepareInput(batch(segment), targetLocale: target.rawValue, allowUnreleased: true)
            #expect(prepared.input.catalog["e0.zh.0"]?.text == chinese)
            #expect(prepared.input.catalog["e0.en.0"] == nil)
            #expect(prepared.prompt.hasSuffix(LearningPrompts.chineseOriginalEvidenceRule))
            let job = try LearningReviewQueue.prepareJob(directory: directory("chinese-review"),
                batches: [batch(segment)], original: chinese, targetLocale: target.rawValue, allowUnreleased: true)
            #expect(try LearningReviewQueue.prepareInput(job, allowUnreleased: true).prompt == job.prompt)
            #expect(LearningPrompts.generationPrompt(target: target, evidence: [source()])
                == LearningPrompts.generationPrompt(target: target))
        }
    }

    @Test func everyCaptionExitKeepsChineseTextExactlyAndDoesNotRenderTargetScript() throws {
        var segment = source()
        segment.applyChineseRecognition(chinese)
        let missingConverter = ChineseScriptConverter(resourceDirectory: try directory("no-converter"))
        for target in OutputLanguage.allCases {
            #expect(SessionExporter.sourceLine(segment) == chinese)
            #expect(SessionExporter.targetLine(segment, outputLanguage: target) == chinese)
            #expect(SessionExporter.captionLines(segment, outputLanguage: target) == [chinese])
            #expect(try SessionExporter.renderedTargetLine(segment, outputLanguage: target, converter: missingConverter) == chinese)
            #expect(try SessionExporter.renderedCaptionLines(segment, outputLanguage: target, converter: missingConverter) == [chinese])
            #expect(try SessionExporter.renderedSRTCue(segment, index: 0, outputLanguage: target, converter: missingConverter)
                == "1\n00:00:00,000 --> 00:00:01,250\n" + chinese)
        }
    }

    @Test func chineseCheckpointRestoresNormalAndRecoveryPromptsForEveryOutputLanguage() throws {
        var segment = source()
        segment.applyChineseRecognition(chinese)
        for language in OutputLanguage.allCases {
            let target = try #require(language.generationTarget)
            for recovering in target == .simplifiedChinese ? [false] : [false, true] {
                var snapshot = SessionSnapshot(segments: [segment], createdAt: date, targetLocale: language.rawValue)
                let prompt = LearningPrompts.generationPrompt(target: target,
                    recoveringAfterOutputLimit: recovering, evidence: [segment])
                let input = try LearningPrompts.input(evidence: [segment], topics: [], target: target)
                let draft = LearningDraft(evidence: [segment], model: "proposal-stub", input: input, target: target,
                    systemPrompt: prompt, text: "Frozen unfinished JSON.", attempts: 2)
                let checkpoint = draft.checkpoint(sessionID: snapshot.sessionID,
                    inputRevision: snapshot.inputRevision, generation: snapshot.generation)
                snapshot.generationCheckpoints = [checkpoint]
                let reloaded = try SessionArchiveCoding.decode(SessionSnapshot.self, from: SessionArchiveCoding.encode(snapshot))
                let restored = try #require(LearningDraft(checkpoint: checkpoint, snapshot: reloaded, model: "proposal-stub"))
                #expect(restored.systemPrompt == prompt && restored.promptDigest == checkpoint.promptDigest)
                #expect(restored.evidence == [segment.withoutTranslationFailures])
                #expect(restored.text == draft.text && restored.attempts == draft.attempts)
                #expect(restored.checkpoint(sessionID: snapshot.sessionID,
                    inputRevision: snapshot.inputRevision, generation: snapshot.generation) == checkpoint)
                #expect(LearningDraft(checkpoint: checkpoint, snapshot: reloaded, model: "proposal-stub",
                    systemPrompt: target.learningNotePrompt) == nil)
                var unknown = checkpoint
                unknown.promptDigest = SessionArchiveCoding.digest(Data("Unknown custom prompt.".utf8))
                #expect(LearningDraft(checkpoint: unknown, snapshot: reloaded, model: "proposal-stub") == nil)
                var invalidated = checkpoint
                invalidated.invalidated = true
                #expect(LearningDraft(checkpoint: invalidated, snapshot: reloaded, model: "proposal-stub") == nil)
                var legacyBatchIDs = checkpoint
                legacyBatchIDs.batchEvidenceIDs = nil
                #expect(LearningDraft(checkpoint: legacyBatchIDs, snapshot: reloaded, model: "proposal-stub")?.systemPrompt == prompt)
            }
        }
    }

    @Test func checkpointPromptUsesOnlyItsBatchNotOtherChineseCaptionsOrPriorDependencies() throws {
        let english = source()
        var prior = TranscriptSegment(startTime: 2, endTime: 3, english: "A fluent mistaken source.")
        prior.applyChineseRecognition(chinese)
        for target in [CaptionTranslationTarget.simplifiedChinese, .english, .spanish, .french] {
            let snapshot = SessionSnapshot(segments: [prior, english], createdAt: date, targetLocale: target.rawValue)
            for includesPriorDependency in [false, true] {
                let dependencies = includesPriorDependency ? [prior.id, english.id] : [english.id]
                for recovering in target == .simplifiedChinese ? [false] : [false, true] {
                    let prompt = LearningPrompts.generationPrompt(target: target, recoveringAfterOutputLimit: recovering,
                        evidence: [english])
                    let input = try LearningPrompts.input(evidence: [english], topics: [], target: target)
                    let draft = LearningDraft(evidence: [english], model: "proposal-stub", input: input, target: target,
                        systemPrompt: prompt, text: "Frozen prefix", dependencyIDs: dependencies)
                    let checkpoint = draft.checkpoint(sessionID: snapshot.sessionID,
                        inputRevision: snapshot.inputRevision, generation: snapshot.generation)
                    let restored = try #require(LearningDraft(checkpoint: checkpoint, snapshot: snapshot, model: "proposal-stub"))
                    #expect(restored.systemPrompt == prompt && restored.evidence == [english])
                    #expect(!restored.systemPrompt.contains(LearningPrompts.chineseOriginalEvidenceRule))
                    #expect(restored.dependencyIDs == dependencies)
                    if includesPriorDependency {
                        var missingDependency = snapshot
                        missingDependency.segments = [english]
                        #expect(LearningDraft(checkpoint: checkpoint, snapshot: missingDependency, model: "proposal-stub") == nil)
                    }
                }
            }
        }
    }

    @Test func sessionExportsContainCorrectedSourceButNeverUndoEnglish() throws {
        var segment = source()
        segment.applyChineseRecognition(chinese)
        for target in OutputLanguage.allCases {
            let root = try directory("chinese-export")
            try SessionExporter.export(segments: [segment], sessionDirectory: root, createdAt: date, target: target)
            for name in ["transcript-en.txt", SessionExporter.targetTranscriptFileName(for: target.rawValue)] {
                #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data((chinese + "\n").utf8))
            }
            #expect(try String(contentsOf: root.appendingPathComponent("bilingual.srt"), encoding: .utf8)
                == "1\n00:00:00,000 --> 00:00:01,250\n" + chinese + "\n")
            let jsonl = try Data(contentsOf: root.appendingPathComponent("bilingual.jsonl"))
            #expect(!String(decoding: jsonl, as: UTF8.self).contains("Ice is cold."))
            let exported = try SessionArchiveCoding.decode(TranscriptSegment.self, from: jsonl)
            #expect(exported.isChineseOriginal && exported.chineseRecognitionOriginal == nil)
            #expect(exported.english == chinese && exported.chinese == chinese)
        }
    }

    @Test func manifestKeepsOrdinaryEnglishRevisionsFrozenAndStampsManualChinese() throws {
        let root = try directory("revision-zero-export")
        try SessionExporter.export(segments: [source()], sessionDirectory: root, createdAt: date)
        let frozen = #"{"createdAt":"1970-01-01T00:00:00Z","recordingFile":"recording.wav","segmentCount":1,"sourceLocale":"en-US","targetLocale":"zh-Hans"}"#
        #expect(try Data(contentsOf: root.appendingPathComponent("manifest.json")) == Data(frozen.utf8))
        let revisions = [TranscriptSegment(startTime: 0, endTime: 1, english: "Ice is cold.", inputRevision: 2),
            TranscriptSegment(startTime: 1, endTime: 2, english: "Water flows.", inputRevision: 4),
            TranscriptSegment(startTime: 2, endTime: 3, english: "Heat moves.", inputRevision: 3)]
        try SessionExporter.export(segments: revisions, sessionDirectory: root, createdAt: date)
        let ordinary = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any]
        #expect(ordinary?["sourceRevision"] == nil)
        var manual = revisions[1]
        manual.applyChineseRecognition(chinese)
        try SessionExporter.export(segments: [revisions[0], manual, revisions[2]], sessionDirectory: root, createdAt: date)
        let manifestBytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
        #expect((manifest["sourceRevision"] as? Int) == 4)
    }

    @Test func staleBodyExportsCannotReplaceChineseCorrectionOrUndo() throws {
        for portable in [false, true] {
            var operations = SessionExporter.PublicationOperations()
            if portable {
                operations.createSymbolicLink = { _, _ in
                    throw SessionStoreError.io(operation: "synthetic unsupported export link", code: ENOTSUP)
                }
            }
            let root = try directory("stale-source-export")
            let original = source()
            // Seed revision zero so correction publishes through the actual
            // shared pointer, with both normal and portable publication paths.
            try SessionExporter.export(segments: [original], sessionDirectory: root, summary: "# Original",
                createdAt: date, operations: operations)
            var corrected = original
            corrected.applyChineseRecognition(chinese)
            corrected.inputRevision = 1
            try SessionExporter.export(segments: [corrected], sessionDirectory: root, summary: "# Corrected",
                createdAt: date, operations: operations)
            let names = ["manifest.json", "transcript-en.txt", "transcript-zh-Hans.txt",
                "bilingual.jsonl", "bilingual.srt", "summary-zh-Hans.md"]
            let selected = try SessionExporter.currentExportDirectory(in: root)
            let before = try Dictionary(uniqueKeysWithValues: names.map { name in
                (name, try Data(contentsOf: root.appendingPathComponent(name)))
            })
            let versions = root.appendingPathComponent(".exports/versions", isDirectory: true)
            let priorVersions = try FileManager.default.contentsOfDirectory(atPath: versions.path).sorted()
            var mustSkip = operations
            mustSkip.beforeMemberPublication = { _ in
                throw SessionStoreError.invalidState("Stale export must not publish any member")
            }
            // A stale detached render is superseded, not a fake save failure.
            try SessionExporter.export(segments: [original], sessionDirectory: root, summary: "# Stale English",
                createdAt: date, operations: mustSkip)
            #expect(try SessionExporter.currentExportDirectory(in: root) == selected)
            #expect(try FileManager.default.contentsOfDirectory(atPath: versions.path).sorted() == priorVersions)
            for name in names {
                #expect(try Data(contentsOf: root.appendingPathComponent(name)) == before[name])
            }
            #expect(before["transcript-en.txt"] == Data((chinese + "\n").utf8))
            let correctionManifestBytes = try #require(before["manifest.json"])
            let correctionManifest = try #require(JSONSerialization.jsonObject(with: correctionManifestBytes) as? [String: Any])
            #expect((correctionManifest["sourceRevision"] as? Int) == 1)

            var undone = corrected
            let didUndo = undone.undoChineseRecognition()
            #expect(didUndo)
            undone.inputRevision = 2
            try SessionExporter.export(segments: [undone], sessionDirectory: root, summary: "# Undone",
                createdAt: date, operations: operations)
            let undoSelected = try SessionExporter.currentExportDirectory(in: root)
            let undoBytes = try Dictionary(uniqueKeysWithValues: names.map { name in
                (name, try Data(contentsOf: root.appendingPathComponent(name)))
            })
            let undoVersions = try FileManager.default.contentsOfDirectory(atPath: versions.path).sorted()
            try SessionExporter.export(segments: [corrected], sessionDirectory: root, summary: "# Stale Chinese",
                createdAt: date, operations: mustSkip)
            #expect(try SessionExporter.currentExportDirectory(in: root) == undoSelected)
            #expect(try FileManager.default.contentsOfDirectory(atPath: versions.path).sorted() == undoVersions)
            for name in names {
                #expect(try Data(contentsOf: root.appendingPathComponent(name)) == undoBytes[name])
            }
            #expect(undoBytes["transcript-en.txt"] == Data("Ice is cold.\n".utf8))
            let undoManifestBytes = try #require(undoBytes["manifest.json"])
            let undoManifest = try #require(JSONSerialization.jsonObject(with: undoManifestBytes) as? [String: Any])
            #expect((undoManifest["sourceRevision"] as? Int) == 2)
            let undoJSONL = try #require(undoBytes["bilingual.jsonl"])
            let undoFields = try #require(JSONSerialization.jsonObject(with: undoJSONL) as? [String: Any])
            #expect(undoFields["isChineseOriginal"] == nil && undoFields["chineseRecognitionOriginal"] == nil)
        }
    }

    @Test func staleExportAlsoCannotReplaceFirstUnversionedDirectoryPublication() throws {
        let root = try directory("stale-first-export")
        var corrected = source()
        corrected.applyChineseRecognition(chinese)
        corrected.inputRevision = 1
        try SessionExporter.export(segments: [corrected], sessionDirectory: root, createdAt: date)
        let manifestBytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        try SessionExporter.export(segments: [source()], sessionDirectory: root, createdAt: date)
        #expect(try Data(contentsOf: root.appendingPathComponent("manifest.json")) == manifestBytes)
        #expect(try String(contentsOf: root.appendingPathComponent("transcript-en.txt"), encoding: .utf8) == chinese + "\n")
    }

    @Test func sameBodyRevisionStillAllowsTranslationUpdates() throws {
        let root = try directory("same-source-export")
        var segment = source()
        try SessionExporter.export(segments: [segment], sessionDirectory: root, createdAt: date)
        segment.completeTranslation("冰确实很冷。")
        try SessionExporter.export(segments: [segment], sessionDirectory: root, createdAt: date)
        #expect(try String(contentsOf: root.appendingPathComponent("transcript-zh-Hans.txt"), encoding: .utf8) == "冰确实很冷。\n")
        let manifestBytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let fields = try #require(JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any])
        #expect(fields["sourceRevision"] == nil)
    }

    @Test @MainActor func notesExportsKeepChineseOriginalInTextWordAndPDF() throws {
        var segment = source()
        segment.applyChineseRecognition(chinese)
        for target in OutputLanguage.allCases {
            let snapshot = NotesExportSnapshot(className: "Synthetic lesson", sessionName: nil, scope: .wholeLesson,
                scopeDetail: "", coverageLine: "", notesMarkdown: "Study note.", reviewMarkdown: nil,
                transcript: [segment], generatedAt: date, includesReviewAdvice: false, includesTranscript: true,
                target: target, exportTimeZone: TimeZone(secondsFromGMT: 0))
            for format in [NotesExportFormat.markdown, .plainText] {
                let text = String(decoding: try NotesExportDocument.data(snapshot, format: format), as: UTF8.self)
                #expect(text.contains(chinese) && !text.contains("Ice is cold."))
            }
            let word = try NotesExportDocument.data(snapshot, format: .word)
            let attributed = try NSAttributedString(data: word,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
            #expect(attributed.string.contains(chinese) && !attributed.string.contains("Ice is cold."))
            let pdf = try #require(PDFDocument(data: NotesExportDocument.data(snapshot, format: .pdf)))
            let pdfText = try #require(pdf.string)
            #expect(pdfText.contains(chinese) && !pdfText.contains("Ice is cold."))
        }
    }
}
