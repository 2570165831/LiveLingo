import AVFoundation
import Foundation
import Testing
@testable import LiveLingo

struct SessionExporterTests {
    @Test func stableCaptionsKeepContextWhileEnglishPreviewStreamsSeparately() {
        #expect(SpeechPipeline.stableChunkDuration == 10)
    }

    @Test func waveformMetersExistingPCMAtTenHertz() {
        #expect(SpeechPipeline.waveformUpdateInterval == 0.1)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let minusThirtyDecibels = Float(pow(10.0, -30.0 / 20.0))
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = minusThirtyDecibels
        }

        #expect(abs(SpeechPipeline.normalizedAudioLevel(from: buffer) - 0.5) < 0.01)
        #expect(SpeechPipeline.normalizedAudioLevel(rms: 0) == 0)
        #expect(SpeechPipeline.normalizedAudioLevel(rms: 1) == 1)
    }

    @Test func rejectedFallbackSkipsSilenceButKeepsUsablePrimaryText() {
        #expect(
            SpeechPipeline.preferredTranscript(
                primary: "Okay.",
                fallback: "是。我也想要。"
            ) == "Okay."
        )
        #expect(
            SpeechPipeline.preferredTranscript(
                primary: "",
                fallback: "是。我也想要。"
            ).isEmpty
        )
    }

    @Test func pausedPhaseKeepsSessionBusy() {
        #expect(AppPhase.paused.isBusy)
    }

    @Test func physicsTermsUseContextWithoutChangingOrdinaryWords() {
  let context = "Use the equations for initial velocity and acceleration to resolve components with trigonometry."
  let cases: [(String,String,String)] = [
   ("Alright, 30 signs 60.", context, "Alright, 30 times sine 60."),
   ("Sine or cause. So it's thirty times sine sixty.",context,"sine or cosine. So it's thirty times sine sixty."),
   ("Generation.",context,"Equation."),
   ("S equals ut plus half at squared, and we are looking at the y direction.",context,"s = ut + ½at², and we are looking at the y direction."),
   ("Generation.","Solar panels produce power.","Generation."),
   ("The next generation shows signs of progress.",context,"The next generation shows signs of progress."),
   ("There are 30 signs 60 metres apart.","Road safety.","There are 30 signs 60 metres apart."),
   ("The cause is unknown. Meet at half past four.",context,"The cause is unknown. Meet at half past four."),
   ("Does this cause two collisions?",context,"Does this cause two collisions?"),
   ("There are 30 signs 60 metres apart.",context,"There are 30 signs 60 metres apart."),
   ("s = ut + 0.5at²",context,"s = ut + 0.5at²")
  ]
  for (source, recent, expected) in cases {
   #expect(AcademicInputNormalizer.normalize(source, recentContext: recent) == expected)
  }
    }

    @Test func lecturerRepetitionDoesNotDropFollowingSentences() {
        let opening = "Equals, equals, equals, equals. And of course, we have time, t, which is shared for both. Tell me, what do we know? What is the first thing we know?"
        #expect(ASRQualityGate.fallbackReason(for: opening, audioDuration: 10.1) == nil)
        #expect(SpeechPipeline.preferredTranscript(primary: opening, fallback: opening, audioDuration: 10.1) == opening)
        let repeatedPhrase = "We know we know we know the initial velocity and can resolve its horizontal and vertical components."
        #expect(ASRQualityGate.fallbackReason(for: repeatedPhrase, audioDuration: 10) == nil)
        let loop = "We know we know we know we know we know we know the velocity."
        #expect(ASRQualityGate.fallbackReason(for: loop, audioDuration: 10) == .repeatedLoop)
    }

    @Test func repeatedFallbackCannotReachTranslationOrReviveBadPrimary() {
        let loop = "Suppose, I went, " + String(repeating: "a pilot, ", count: 60)
        let normal = "A pilot controls the aircraft using these instruments."
        #expect(SpeechPipeline.preferredTranscript(primary: nil, fallback: loop).isEmpty)
        #expect(SpeechPipeline.preferredTranscript(primary: loop, fallback: loop).isEmpty)
        #expect(SpeechPipeline.preferredTranscript(primary: loop, fallback: "是。我也想要。").isEmpty)
        #expect(SpeechPipeline.preferredTranscript(primary: normal, fallback: loop) == normal)
        #expect(SpeechPipeline.preferredTranscript(primary: loop, fallback: normal) == normal)
        #expect(SpeechPipeline.preferredTranscript(primary: "damaged \u{FFFD} text", fallback: "").isEmpty)
    }

    @Test func finalTranscriptGateUsesChunkDurationWithoutRemovingNormalEmphasis() {
        let fast = (0..<45).map { "word\($0)" }.joined(separator: " ")
        #expect(SpeechPipeline.preferredTranscript(primary: nil, fallback: fast, audioDuration: 2).isEmpty)
        #expect(SpeechPipeline.preferredTranscript(primary: nil, fallback: fast, audioDuration: 10) == fast)
        let emphasis = "No, no, a pilot controls the aircraft."
        #expect(SpeechPipeline.preferredTranscript(primary: emphasis, fallback: "") == emphasis)
        #expect(SpeechPipeline.preferredTranscript(primary: nil, fallback: "Okay.") == "Okay.")
    }

    @Test func liveOnlyModeUsesTemporaryRecordingAndClearsOnlyWhenStopped() {
        #expect(SessionStorageMode.saveSession.persistsSession)
        #expect(!SessionStorageMode.saveSession.clearsHistoryWhenStopped)
        #expect(!SessionStorageMode.liveOnly.persistsSession)
        #expect(SessionStorageMode.liveOnly.clearsHistoryWhenStopped)
        #expect(SessionStorageMode.liveOnly.usesTemporaryRecording)
        #expect(!SessionStorageMode.liveOnly.requiresOutputDirectoryBeforeStart)
        #expect(SessionStorageMode.saveSession.requiresOutputDirectoryBeforeStart)
        #expect(!AppPhase.liveEnded.isBusy)
    }

    @Test func liveWorkspaceCanBeDiscardedWithoutTouchingOtherTemporaryFiles() throws {
        let workspace = try SessionWorkspace.makeTemporarySessionDirectory()
        let recording = workspace.appendingPathComponent(SessionWorkspace.recordingFileName)
        try Data("temporary audio".utf8).write(to: recording)
        let neighbor = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoTests-neighbor-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: neighbor)
        defer { try? FileManager.default.removeItem(at: neighbor) }

        try SessionWorkspace.discardTemporarySession(workspace)

        #expect(!FileManager.default.fileExists(atPath: workspace.path))
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
    }

    @Test func temporaryRecordingPromotesToUniqueSessionWithoutOverwrite() throws {
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoTests-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let existing = outputRoot.appendingPathComponent("LiveLingo lesson", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("existing.txt")
        try Data("do not overwrite".utf8).write(to: marker)

        let workspace = try SessionWorkspace.makeTemporarySessionDirectory()
        let recording = workspace.appendingPathComponent(SessionWorkspace.recordingFileName)
        let expected = Data("captured audio".utf8)
        try expected.write(to: recording)

        let promoted = try SessionWorkspace.promoteTemporarySession(
            from: workspace,
            to: outputRoot,
            preferredName: "LiveLingo lesson"
        )

        #expect(promoted.lastPathComponent == "LiveLingo lesson 2")
        #expect(try Data(contentsOf: promoted.appendingPathComponent("recording.wav")) == expected)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "do not overwrite")
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }

    @Test func audioInputModesKeepMicrophoneAndSystemAudioDistinct() {
        #expect(AudioInputMode.microphone.title == "麦克风")
        #expect(AudioInputMode.systemAudio.title == "系统音频（内录）")
        #expect(AudioInputMode.microphone.statusIcon == "mic.fill")
        #expect(AudioInputMode.systemAudio.statusIcon == "speaker.wave.2.fill")
    }

    @Test func systemAudioCaptureRequestsAudioAndExcludesThisApp() {
        let configuration = SpeechPipeline.systemAudioConfiguration()

        #expect(configuration.capturesAudio)
        #expect(configuration.excludesCurrentProcessAudio)
        #expect(configuration.sampleRate == 48_000)
        #expect(configuration.channelCount == 2)
    }

    @Test func microphoneWatchdogDetectsOnlyAnActiveStalledCapture() {
        let timeout = SpeechPipeline.microphoneStallTimeout

        #expect(
            !SpeechPipeline.microphoneCaptureIsStalled(
                lastCallbackUptime: 10,
                now: 10 + timeout - 0.01,
                isPaused: false,
                isStopping: false
            )
        )
        #expect(
            SpeechPipeline.microphoneCaptureIsStalled(
                lastCallbackUptime: 10,
                now: 10 + timeout,
                isPaused: false,
                isStopping: false
            )
        )
        #expect(
            !SpeechPipeline.microphoneCaptureIsStalled(
                lastCallbackUptime: 10,
                now: 10 + timeout,
                isPaused: true,
                isStopping: false
            )
        )
        #expect(
            !SpeechPipeline.microphoneCaptureIsStalled(
                lastCallbackUptime: 10,
                now: 10 + timeout,
                isPaused: false,
                isStopping: true
            )
        )
        #expect(
            !SpeechPipeline.microphoneCaptureIsStalled(
                lastCallbackUptime: nil,
                now: 10 + timeout,
                isPaused: false,
                isStopping: false
            )
        )
        #expect(SpeechPipeline.maximumMicrophoneRecoveryAttempts == 3)
    }

    @Test func srtTimestampRoundsMilliseconds() {
        #expect(SessionExporter.srtTimestamp(3_661.2346) == "01:01:01,235")
        #expect(SessionExporter.srtTimestamp(-1) == "00:00:00,000")
    }

    @Test func exportWritesAllTextFormats() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let segments = [
            TranscriptSegment(startTime: 0.2, endTime: 1.7, english: "Good morning.", chinese: "早上好。"),
            TranscriptSegment(startTime: 2, endTime: 4.25, english: "Welcome home.", chinese: "欢迎回家。")
        ]
        try SessionExporter.export(
            segments: segments,
            sessionDirectory: root,
            summary: "## 本段主题\n课堂问候。"
        )

        let english = try String(contentsOf: root.appendingPathComponent("transcript-en.txt"), encoding: .utf8)
        let chinese = try String(contentsOf: root.appendingPathComponent("transcript-zh-Hans.txt"), encoding: .utf8)
        let srt = try String(contentsOf: root.appendingPathComponent("bilingual.srt"), encoding: .utf8)
        let jsonl = try String(contentsOf: root.appendingPathComponent("bilingual.jsonl"), encoding: .utf8)
        let summary = try String(contentsOf: root.appendingPathComponent("summary-zh-Hans.md"), encoding: .utf8)

        #expect(english == "Good morning.\nWelcome home.\n")
        #expect(chinese == "早上好。\n欢迎回家。\n")
        #expect(srt.contains("00:00:00,200 --> 00:00:01,700"))
        #expect(srt.contains("Good morning.\n早上好。"))
        #expect(jsonl.split(separator: "\n").count == 2)
        #expect(summary == "## 本段主题\n课堂问候。\n")
    }

    @Test func lectureSummaryInputKeepsChronologyAndOnlyCompletedTranslations() {
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 10, english: "First idea.", chinese: "第一个观点。"),
            TranscriptSegment(startTime: 10, endTime: 20, english: "Still translating."),
            TranscriptSegment(startTime: 20, endTime: 30, english: "Second idea.", chinese: "第二个观点。"),
            TranscriptSegment(
                startTime: 30,
                endTime: 40,
                english: "Failed translation.",
                chinese: "[翻译失败：offline]"
            ),
        ]

        let input = LectureSummaryInput.make(from: segments)

        #expect(input.contains("[00:00]"))
        #expect(input.contains("[00:20]"))
        #expect(input.hasPrefix("[00:00]"))
        #expect(!input.contains("Still translating."))
        #expect(!input.contains("Failed translation."))
        #expect(QwenTranslationClient.summarySystemPrompt.contains("Simplified Chinese"))
    }

    @Test func chemistryTranslationProtectsFormulasUnitsAndInstrumentNames() {
        let source = "Dissolve 5.0 mmol of NaCl in 10 mL H2O at pH 7.4, then analyze by LC-MS."
        let prepared = ChemistryTranslationProtector.prepare(source)

        #expect(!prepared.text.contains("NaCl"))
        #expect(!prepared.text.contains("10 mL"))
        #expect(!prepared.text.contains("H2O"))
        #expect(!prepared.text.contains("pH 7.4"))
        #expect(!prepared.text.contains("LC-MS"))
        #expect(prepared.restore(in: "译文：\(prepared.text)") == "译文：\(source)")
    }

    @Test func chemistryTranslationLeavesOrdinaryEnglishUntouched() {
        let source = "The catalyst improves selectivity."
        let prepared = ChemistryTranslationProtector.prepare(source)

        #expect(prepared.text == source)
        #expect(prepared.restore(in: "催化剂提高了选择性。") == "催化剂提高了选择性。")
    }

    @Test func chemistryTranslationDoesNotTreatBiologyAcronymsAsFormulas() {
        let source = "NADH donates electrons while ATP synthase uses the gradient, and NaCl remains a formula."
        let prepared = ChemistryTranslationProtector.prepare(source)

        #expect(prepared.text.contains("NADH"))
        #expect(prepared.text.contains("ATP"))
        #expect(!prepared.text.contains("NaCl"))
        #expect(prepared.restore(in: prepared.text) == source)
    }

    @Test func translatedChineseIsNormalizedToSimplifiedWithoutChangingChemistry() {
        let translated = "我們把鈣鐵加入 10 mL H2O，並記錄實驗結果。"

        #expect(
            SimplifiedChineseNormalizer.normalize(translated)
                == "我们把钙铁加入 10 mL H2O，并记录实验结果。"
        )
    }

    @Test func auxiliaryHintsAreStrictlyLimitedToValidatedAcademicTokens() {
        let accepted = AuxiliaryTranslationHintExtractor.extract(
            from: "The ions are S C N minus and PO4 3 negative, while DNA moves 400 meters.",
            primary: "The ions are sign and phosphate, while the sequence moves four hundred metres."
        )
        let values = Set(accepted.map(\.value))

        #expect(values.contains("SCN-"))
        #expect(values.contains("PO4^3-"))
        #expect(values.contains("DNA"))
        #expect(values.contains("400 meters"))

        let rejected = AuxiliaryTranslationHintExtractor.extract(
            from: "KL minus PM minus 400",
            primary: "kay ell minus pee em minus four hundred"
        )
        #expect(rejected.isEmpty)
    }

    @Test func auxiliaryEvidenceMustBeAlmostEntirelyInsideTheStableChunk() {
        let observations = [
            AuxiliaryTranscriptObservation(text: "SCN minus", start: 1, end: 2),
            AuxiliaryTranscriptObservation(text: "crossing sentence", start: 5, end: 15),
            AuxiliaryTranscriptObservation(text: "400 meters", start: 11, end: 12),
        ]

        #expect(
            AuxiliaryTranslationHintExtractor.timeAlignedText(
                observations: observations,
                start: 0,
                end: 10
            ) == "SCN minus"
        )
        #expect(
            AuxiliaryTranslationHintExtractor.timeAlignedText(
                observations: observations,
                start: 10,
                end: 20
            ) == "400 meters"
        )
    }

    @Test func onlyNineBReceivesAuxiliaryTokenHints() {
        let hints = [AuxiliaryTranslationHint(kind: .formula, value: "SCN-")]
        let primary = "The ion is sign."
        let highQuality = QwenTranslationClient.translationInput(
            text: primary,
            modelName: QwenModelProfile.highQuality.translationModel,
            hints: hints
        )
        let energySaver = QwenTranslationClient.translationInput(
            text: primary,
            modelName: QwenModelProfile.energySaver.translationModel,
            hints: hints
        )

        #expect(highQuality.contains("Primary ASR transcript:"))
        #expect(highQuality.contains("formula: SCN-"))
        #expect(energySaver == primary)
    }

    @Test func automaticModeUsesBatteryAndPluggedInProfiles() {
        #expect(ModelMode.automatic.resolvedProfile(isOnBattery: true) == .energySaver)
        #expect(ModelMode.automatic.resolvedProfile(isOnBattery: false) == .highQuality)
        #expect(ModelMode.energySaver.resolvedProfile(isOnBattery: false) == .energySaver)
        #expect(ModelMode.highQuality.resolvedProfile(isOnBattery: true) == .highQuality)
        #expect(QwenModelProfile.energySaver.asrKey == "parakeet")
        #expect(QwenModelProfile.highQuality.asrKey == "parakeet")
        #expect(QwenModelProfile.energySaver.fallbackASRKey == "1.7b")
        #expect(QwenModelProfile.highQuality.fallbackASRKey == "1.7b")
        #expect(QwenModelProfile.energySaver.translationModel == "qwen3.5-4b-mlx")
        #expect(QwenModelProfile.highQuality.translationModel == "qwen/qwen3.5-9b")
    }

    @Test func downloadedTranslationModelIsReadyBeforeJITLoading() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "models": [
                [
                    "key": "qwen3.5-4b-mlx",
                    "loaded_instances": [],
                ],
            ],
        ])

        #expect(try QwenTranslationClient.modelIsAvailable("qwen3.5-4b-mlx", in: payload))
        #expect(!(try QwenTranslationClient.modelIsAvailable("qwen/qwen3.5-9b", in: payload)))
    }

    @Test func asrQualityGateKeepsNormalAcademicEnglish() {
        let text = "The atomic radius decreases from left to right across a period."

        #expect(ASRQualityGate.fallbackReason(for: text, audioDuration: 10) == nil)
        #expect(
            ASRQualityGate.fallbackReason(for: "", audioDuration: 10)
                == .emptyTranscript
        )
    }

    @Test func asrQualityGateCatchesShortAndRepeatedAnomalies() {
        #expect(
            ASRQualityGate.fallbackReason(for: "Okay.", audioDuration: 9)
                == .implausiblyShort
        )
        #expect(
            ASRQualityGate.fallbackReason(
                for: "the answer is the answer is the answer is",
                audioDuration: 10
            ) == .repeatedLoop
        )
        #expect(
            ASRQualityGate.fallbackReason(for: "damaged \u{FFFD} text", audioDuration: 4)
                == .invalidText
        )
    }

    @Test func englishTranscriptGateRejectsCJKDominantFallbackOutput() {
        #expect(EnglishTranscriptGate.accepts("We have Abdul Razak."))
        #expect(EnglishTranscriptGate.accepts("The Fe³⁺ concentration is 0.10 mol/L."))
        #expect(EnglishTranscriptGate.accepts("English explanation，附注。"))
        #expect(!EnglishTranscriptGate.accepts("是。我也想要。是。"))
        #expect(EnglishTranscriptGate.accepts(""))
    }

    @Test func academicInputNormalizerFixesKnownChemistryASRAndComplexNotation() {
        let source = "Fe³⁺ reacts with thiosyanate SCN⁻ to form FeSCN²⁺ in an S N two example."

        #expect(
            AcademicInputNormalizer.normalize(source)
                == "Fe³⁺ reacts with thiocyanate SCN⁻ to form [FeSCN]²⁺ in an SN2 example."
        )
    }

    @Test func academicInputNormalizerRepairsBellmanFordComplexityFromLetterASR() {
        let source = "Bellman Ford detects a negative weight cycle. Its time complexity is O of V times Z."

        #expect(
            AcademicInputNormalizer.normalize(source)
                == "Bellman-Ford detects a negative weight cycle. Its time complexity is O(VE)."
        )
    }

    @Test func academicInputNormalizerRepairsSpokenBiologyTerms() {
        let source = "N A D H donates electrons to complex one during oxidative phosphorylation, while A T P synthase uses the gradient."

        #expect(
            AcademicInputNormalizer.normalize(source)
                == "NADH donates electrons to Complex I during oxidative phosphorylation, while ATP synthase uses the gradient."
        )
    }

    @Test func academicInputNormalizerRepairsSpacedChemistryNotation() {
        let source = "Ferrous ions Fe 3 + react with thiosilane ions SCN - to form Fe SCN 2 + in an SN 2 reaction."

        #expect(
            AcademicInputNormalizer.normalize(source)
                == "Ferric ions Fe³⁺ react with thiocyanate ions SCN⁻ to form [FeSCN]²⁺ in an SN2 reaction."
        )
    }

    @Test func academicInputNormalizerUsesLectureContextForNamedTerms() {
        let source = "Lagrange's principle predicts how an equilibrium responds to stress. Faraday's law says magnetic flux induces an electromagnetic force."

        #expect(
            AcademicInputNormalizer.normalize(source)
                == "Le Chatelier's principle predicts how an equilibrium responds to stress. Faraday's law says magnetic flux induces an electromotive force."
        )
    }
}

private final class ASREventCollector: @unchecked Sendable {
    let lock = NSLock()
    private var values: [SpeechPipeline.Event] = []
    func append(_ event: SpeechPipeline.Event) { lock.withLock { values.append(event) } }
    var events: [SpeechPipeline.Event] { lock.withLock { values } }
}

struct ASRRecoveryTests {
    @Test func numericAndShortRepeatedCaptionsSurviveButRunawayDoesNot() {
        for text in ["123", "2 + 2 = 4", "No, no, no, that's wrong.", "Vector equation vector, vector, vector."] {
            #expect(SpeechPipeline.preferredTranscript(primary: text, fallback: "", audioDuration: 8) == text)
        }
        #expect(ASRQualityGate.isShortRepetition("Vector equation vector, vector, vector."))
        #expect(!ASRQualityGate.isShortRepetition("The vector points upwards."))
        #expect(SpeechPipeline.preferredTranscript(primary: "", fallback: String(repeating: "oh ", count: 100), audioDuration: 10).isEmpty)
        #expect(SpeechPipeline.preferredTranscript(primary: "", fallback: "这是中文", audioDuration: 8).isEmpty)
    }

    private func audio(in directory: URL, name: String, seconds: Double = 1) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.1 }
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            if #available(macOS 15, *) { file.close() }
        }
        return url
    }

    @Test func failedChunkKeepsNextCaptionAndWritesFailurePosition() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = try audio(in: dir, name: "recording.wav")
        let bad = try audio(in: dir, name: "bad.wav")
        let good = try audio(in: dir, name: "good.wav")
        let queue = SpeechPipeline.TranscriptionQueue { url, _, _ in
            if url.lastPathComponent == "bad.wav" { throw URLError(.timedOut) }
            return "The next sentence is still available."
        }
        let collector = ASREventCollector()
        for (index, url) in [bad, good].enumerated() {
            await queue.submit(.init(audioURL: url, modelKey: "primary", fallbackModelKey: "fallback",
                start: Double(index), end: Double(index + 1), appleEvidence: "", recordingURL: recording), handler: collector.append)
        }
        await queue.finish()
        #expect(!collector.events.contains { if case .failure = $0 { return true }; return false })
        #expect(collector.events.contains { if case .transcriptionIssue(start: 0, end: 1, message: _) = $0 { return true }; return false })
        #expect(collector.events.contains { if case .final(text: "The next sentence is still available.", start: _, end: _, hints: _) = $0 { return true }; return false })
        let journal = try String(contentsOf: dir.appendingPathComponent("transcription-issues.jsonl"), encoding: .utf8)
        #expect(journal.contains("transcription_missing"))
        #expect(FileManager.default.fileExists(atPath: recording.path))
    }

    @Test func languageMismatchActuallyRequestsFallback() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try audio(in: dir, name: "chunk.wav")
        let queue = SpeechPipeline.TranscriptionQueue { _, model, _ in
            model == "primary" ? "这是中文" : "This is an English caption."
        }
        let collector = ASREventCollector()
        await queue.submit(.init(audioURL: url, modelKey: "primary", fallbackModelKey: "fallback",
            start: 0, end: 1, appleEvidence: "", recordingURL: nil), handler: collector.append)
        await queue.finish()
        #expect(collector.events.contains { if case .final(text: "This is an English caption.", start: _, end: _, hints: _) = $0 { return true }; return false })
    }

    @Test func idleContextRetryIsRecordedWithoutDuplicatingCaptions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = try audio(in: dir, name: "recording.wav", seconds: 4)
        let chunk = try audio(in: dir, name: "chunk.wav")
        let queue = SpeechPipeline.TranscriptionQueue { url, _, _ in
            url.lastPathComponent.hasPrefix("LiveLingo-retry-") ? "A recovered sentence with surrounding context." : ""
        }
        let collector = ASREventCollector()
        await queue.submit(.init(audioURL: chunk, modelKey: "primary", fallbackModelKey: "fallback",
            start: 1, end: 2, appleEvidence: "", recordingURL: recording), handler: collector.append)
        for _ in 0..<60 {
            if collector.events.contains(where: { if case let .transcriptionIssue(_, _, message) = $0 { return message.contains("待核对") }; return false }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await queue.finish()
        let journal = try String(contentsOf: dir.appendingPathComponent("transcription-issues.jsonl"), encoding: .utf8)
        #expect(journal.contains("transcription_retry"))
        #expect(journal.contains("A recovered sentence"))
        #expect(!collector.events.contains { if case .final = $0 { return true }; return false })
    }

    @Test func newCaptionCancelsOptionalRetry() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = try audio(in: dir, name: "recording.wav", seconds: 4)
        let bad = try audio(in: dir, name: "bad.wav")
        let good = try audio(in: dir, name: "good.wav")
        let collector = ASREventCollector()
        let queue = SpeechPipeline.TranscriptionQueue { url, _, _ in
            if url.lastPathComponent.hasPrefix("LiveLingo-retry-") {
                collector.append(.transcriptionIssue(start: -1, end: -1, message: "retryStarted"))
                do { try await Task.sleep(for: .seconds(15)) }
                catch {
                    collector.append(.transcriptionIssue(start: -1, end: -1, message: "retryCancelled"))
                    throw error
                }
            }
            return url.lastPathComponent == "good.wav" ? "The next caption wins." : ""
        }
        await queue.submit(.init(audioURL: bad, modelKey: "primary", fallbackModelKey: "fallback",
            start: 0, end: 1, appleEvidence: "", recordingURL: recording), handler: collector.append)
        for _ in 0..<60 {
            if collector.events.contains(where: { if case .transcriptionIssue(start: -1, end: -1, message: "retryStarted") = $0 { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await queue.submit(.init(audioURL: good, modelKey: "primary", fallbackModelKey: "fallback",
            start: 1, end: 2, appleEvidence: "", recordingURL: recording), handler: collector.append)
        await queue.finish()
        #expect(collector.events.contains { if case .transcriptionIssue(start: -1, end: -1, message: "retryCancelled") = $0 { return true }; return false })
        #expect(collector.events.contains { if case .final(text: "The next caption wins.", start: _, end: _, hints: _) = $0 { return true }; return false })
    }

    @Test func contextRetryReadsOnlyBoundedNeighbourAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = try audio(in: dir, name: "recording.wav", seconds: 4)
        let retry = try RecordingDiagnostics.contextAudio(recordingURL: recording, start: 1, end: 2)
        defer { try? FileManager.default.removeItem(at: retry) }
        let file = try AVAudioFile(forReading: retry)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2.5) < 0.001)
    }
}
