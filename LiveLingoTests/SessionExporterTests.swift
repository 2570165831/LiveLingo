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

    @Test func logisticsSectionExtractsDeadlinesFromEvidenceVerbatim() {
        var book = LearningNotebook()
        let segments = [
            TranscriptSegment(startTime: 40, endTime: 50,
                              english: "So you have three quizzes to complete before the week after.",
                              chinese: "所以你有三次测验要在下周之前完成。"),
            TranscriptSegment(startTime: 300, endTime: 310,
                              english: "The lecture today is about orbital shapes.",
                              chinese: "今天的课讲轨道形状。"),
        ]
        for segment in segments {
            try? book.append(evidence: [segment], note: LearningNote(topic: "测试主题", points: [
                .init(kind: "核心结论", text: "占位要点。")
            ]))
        }
        let markdown = book.markdown()
        #expect(markdown.contains("## 课程安排与待办"))
        #expect(markdown.contains("three quizzes to complete before the week after."))
        #expect(markdown.contains("00:40"))
        #expect(!markdown.contains("orbital shapes."))
    }

    /// 2026-09-19：裸 `close/closes` 撤掉了 ✗ —— 科学语境的 "close to zero" 不是课程安排 ✗；
    /// 同时**不能再截断到 6 条** ✗：真实的 7 条安排必须全部保留 ✓。
    @Test func logisticsIgnoresScientificCloseAndKeepsEveryScheduleItem() {
        var book = LearningNotebook()
        let science = [
            (10.0, "The measured value is close to zero at room temperature.", "测量值在室温下接近零。"),
            (20.0, "As the reaction proceeds it closes the gap between the curves.", "随着反应进行，两条曲线之间的差距缩小。"),
        ]
        let schedule = (1...7).map { index -> (Double, String, String) in
            (Double(100 + index * 10), "Assignment \(index) is due on Friday of week \(index).",
             "第 \(index) 次作业在第 \(index) 周周五截止。")
        }
        for (start, english, chinese) in science + schedule {
            try? book.append(evidence: [TranscriptSegment(startTime: start, endTime: start + 8,
                                                          english: english, chinese: chinese)],
                             note: LearningNote(topic: "测试主题", points: [
                                 .init(kind: "核心结论", text: "占位要点。")
                             ]))
        }
        let markdown = book.markdown()
        #expect(markdown.contains("## 课程安排与待办"))
        for index in 1...7 {
            #expect(markdown.contains("第 \(index) 次作业"), "第 \(index) 条安排被截断或被误判掉了")
        }
        #expect(!markdown.contains("close to zero"), "科学语境的 close 不是课程安排")
        #expect(!markdown.contains("closes the gap"), "科学语境的 closes 不是课程安排")
    }

    /// 报名/预订 + 关闭**同句**才算课程事项 ✓；单独出现报名词不构成安排 ✗。
    @Test func logisticsKeepsRegistrationWindowsThatClose() {
        var book = LearningNotebook()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 8,
                              english: "Unit registration closes on Friday at noon.",
                              chinese: "选课注册将在周五中午截止。"),
            TranscriptSegment(startTime: 10, endTime: 18,
                              english: "The online enrolment closing date is next Monday.",
                              chinese: "在线选课的截止日期是下周一。"),
            TranscriptSegment(startTime: 20, endTime: 28,
                              english: "The booking closes when the lab is full.",
                              chinese: "实验室满员时预约就会关闭。"),
            TranscriptSegment(startTime: 30, endTime: 38,
                              english: "Registration is handled by the department office.",
                              chinese: "注册由院系办公室办理。"),
        ]
        for segment in segments {
            try? book.append(evidence: [segment], note: LearningNote(topic: "测试主题", points: [
                .init(kind: "核心结论", text: "占位要点。")
            ]))
        }
        let markdown = book.markdown()
        #expect(markdown.contains("Unit registration closes on Friday at noon."))
        #expect(markdown.contains("The online enrolment closing date is next Monday."))
        #expect(markdown.contains("The booking closes when the lab is full."))
        #expect(!markdown.contains("Registration is handled by the department office."),
                "没有关闭窗口的报名说法不是课程安排")
    }

    /// 去重按**原文 + 译文**：完全重复只留一条 ✓，同句英文但译文不同各自保留 ✓。
    @Test func logisticsDeduplicatesByOriginalTextAndTranslation() {
        var book = LearningNotebook()
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 8,
                              english: "Submission deadline is Friday.", chinese: "提交截止日期是周五。"),
            TranscriptSegment(startTime: 10, endTime: 18,
                              english: "Submission deadline is Friday.", chinese: "提交截止日期是周五。"),
            TranscriptSegment(startTime: 20, endTime: 28,
                              english: "Submission deadline is Friday.", chinese: "提交截止日期是本周五。"),
        ]
        for segment in segments {
            try? book.append(evidence: [segment], note: LearningNote(topic: "测试主题", points: [
                .init(kind: "核心结论", text: "占位要点。")
            ]))
        }
        let markdown = book.markdown()
        #expect(markdown.components(separatedBy: "提交截止日期是周五。").count - 1 == 1, "完全相同的原文+译文只留一条")
        #expect(markdown.contains("提交截止日期是本周五。"), "译文不同就各自保留")
    }

    @Test func logisticsSectionStaysAbsentWithoutScheduleEvidence() {
        var book = LearningNotebook()
        try? book.append(evidence: [TranscriptSegment(startTime: 10, endTime: 20,
                                                      english: "Orbitals describe where electrons are likely found.",
                                                      chinese: "轨道描述电子可能出现的位置。")],
                         note: LearningNote(topic: "原子结构", points: [
                             .init(kind: "核心结论", text: "电子位置用概率描述。")
                         ]))
        #expect(!book.markdown().contains("## 课程安排与待办"))
    }

    @Test func humanReadableChineseHidesFailurePlaceholderFromExports() {
        // 内存里的占位符保留（它是重试信号），但给人看的出口不该出现英文错误串。
        let placeholder = "[翻译失败：Final output budget exhausted; incomplete output is not committable]"
        #expect(SessionExporter.humanReadableChinese(placeholder) == "（本段翻译未完成，可对照英文）")
        #expect(SessionExporter.humanReadableChinese("") == "（本段暂无译文）")
        #expect(SessionExporter.humanReadableChinese("   ") == "（本段暂无译文）")
        #expect(SessionExporter.humanReadableChinese("正常的译文。") == "正常的译文。")
        // 不能误伤正文里恰好提到"翻译失败"的句子
        #expect(SessionExporter.humanReadableChinese("老师说翻译失败了要重做。") == "老师说翻译失败了要重做。")
    }

    @Test func translationLengthGuardFlagsRunawayChineseAndSparesNormalText() {
        // 实测样本：段 294 的英文 127 字符、中文 181 字 → 比 1.57 ✗ 应判不可信
        let longEnglish = String(repeating: "workshop research task ", count: 6)   // 132 字符
        #expect(!TranslationLengthGuard.isPlausible(chinese: String(repeating: "中", count: 200), english: longEnglish))
        // 正常比例（0.3–0.5）✓ 应判可信
        #expect(TranslationLengthGuard.isPlausible(chinese: String(repeating: "中", count: 40), english: longEnglish))
        // 英文过短时不判 ✓（"Okay." 这类噪声）
        #expect(TranslationLengthGuard.isPlausible(chinese: String(repeating: "中", count: 80), english: "Okay."))
        // 纯英文/无中文不判 ✓
        #expect(TranslationLengthGuard.isPlausible(chinese: "plain english", english: longEnglish))
    }

    @Test func allFourExportFormatsProduceRealFilesWithValidHeaders() throws {
        // 背景（2026-09-18）：四格式此前**只有端到端证据** ✗、没有单元级保护 ✓（round-367 记录）。
        // 本用例直接在单元层生成四种格式，并校验"文件头/魔数"与"内容确实进了文件" ✓。
        let snapshot = NotesExportSnapshot(
            className: "测试课",
            sessionName: "单元测试会话",
            scope: .wholeLesson,
            scopeDetail: "整课",
            coverageLine: "测试覆盖",
            notesMarkdown: "## 人工智能与论证\n- **核心结论**：测试要点。\n\n## 课程安排与待办\n- [00:10] three quizzes — 三次测验",
            reviewMarkdown: nil,
            transcript: [TranscriptSegment(startTime: 10, endTime: 20,
                                           english: "So you have three quizzes before the week after.",
                                           chinese: "所以你在下周之前有三次测验。")],
            generatedAt: Date(timeIntervalSince1970: 1_760_000_000),
            includesReviewAdvice: false,
            includesTranscript: true
        )
        for format in NotesExportFormat.allCases {
            let data = try NotesExportDocument.data(snapshot, format: format)
            #expect(data.count > 200, "\(format.rawValue) 太小：\(data.count) 字节")
            switch format {
            case .word:
                // .docx 是 OOXML（zip ✓）→ 应以 PK\x03\x04 开头
                #expect(Array(data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
            case .pdf:
                #expect(String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-")
            case .markdown, .plainText:
                let text = String(decoding: data, as: UTF8.self)
                #expect(text.contains("课程安排与待办"))
                #expect(text.contains("三次测验"))
            }
        }
    }

    @Test func exportsNeverCarryTheRawFailurePlaceholder() throws {
        // 占位符只在内存里当"重试信号" ✓；给人看的四种出口都不能出现英文错误串 ✗。
        let snapshot = NotesExportSnapshot(
            className: "测试课", sessionName: nil, scope: .latest, scopeDetail: "最近",
            coverageLine: "",
            notesMarkdown: "## 主题\n- 要点。",
            reviewMarkdown: nil,
            transcript: [TranscriptSegment(startTime: 0, endTime: 5, english: "Okay.",
                                           chinese: "[翻译失败：Final output budget exhausted]")],
            generatedAt: Date(timeIntervalSince1970: 1_760_000_000),
            includesReviewAdvice: false, includesTranscript: true
        )
        for format in [NotesExportFormat.markdown, .plainText] {
            let text = String(decoding: try NotesExportDocument.data(snapshot, format: format), as: UTF8.self)
            #expect(!text.contains("[翻译失败："))
            #expect(text.contains("（本段翻译未完成，可对照英文）"))
        }
    }

    @Test func dirtyCheckPremiseSortedKeysEncodingIsStable() throws {
        // 背景（2026-09-18）：复查队列的"写前脏检查"（save() 里）靠一句话成立 ——
        // **同一份内容用 `.sortedKeys` 编码后字节完全相同**。此前没有任何测试锁住这个前提 ✗，
        // 一旦有人改掉那个选项，修复就会**静默失效** ✗（又变回每 5 秒整份重写 ✗）。
        let sorted = JSONEncoder()
        sorted.outputFormatting = [.sortedKeys]

        // ① 同一 Journal 反复编码，字节必须完全一致 ✓
        let journal = LearningReviewQueue.Journal(jobs: [], userPaused: false)
        let first = try sorted.encode(journal)
        for _ in 0..<25 {
            #expect(try sorted.encode(journal) == first)
        }

        // ② 字典键序也必须钉死 ✓（模型里嵌着字典；不排序时键序会飘 ✗，这正是要排序的原因 ✓）
        let dictionary: [String: Int] = ["z": 26, "a": 1, "m": 13, "c": 3, "b": 2]
        let expected = #"{"a":1,"b":2,"c":3,"m":13,"z":26}"#
        #expect(String(decoding: try sorted.encode(dictionary), as: UTF8.self) == expected)
        let again = try sorted.encode(dictionary)
        for _ in 0..<25 {
            #expect(try sorted.encode(dictionary) == again)
        }

        // ③ 反面：**不**排序时，同一字典的编码不保证稳定 —— 只断言"至少能编码成功" ✓，
        //    不写"一定不同"✗（那要看运行环境 ✓，随口感叹会变成假证据 ✗）。
        let plain = JSONEncoder()
        #expect(try plain.encode(dictionary).isEmpty == false)
    }

    @Test @MainActor func recordingStoppedNoticeStatesTheConsequenceFirst() {
        // 这条文案在 round-365 特意改过：原文只说"已自动保存…N 段字幕" ✗，
        // 用户读到"已保存"以为没事 ✓，而事实是**后面的内容再也不会被录** ✗
        // （09-17 物理那节因此丢了近六成内容 ✗）。本测试锁住"先说后果"的顺序 ✓。
        let notice = AppModel.recordingStoppedNotice(message: "麦克风设备变化后未能自动恢复，请重新开始录音。",
                                                     segmentCount: 137)
        #expect(notice.contains("后面的内容不会再录"))
        #expect(notice.contains("麦克风设备变化后未能自动恢复"))
        #expect(notice.contains("137 段字幕"))
        // 顺序：后果必须出现在"已自动保存"之前 ✓
        let consequence = notice.range(of: "后面的内容不会再录")
        let saved = notice.range(of: "已自动保存")
        #expect(consequence != nil && saved != nil)
        if let c = consequence, let s = saved {
            #expect(c.lowerBound < s.lowerBound)
        }
    }

    @Test @MainActor func corruptReviewJournalIsKeptGeimNotOverwritten() async throws {
        // 断电容错：队列文件被写坏时，应用**不能**静默把它覆盖掉 ✗ ——
        // 代码里的行为是"保留现场 + 记录失败 + 暂停写盘" ✓（`LearningNotes.swift:1463-1466` ✓）。
        // 本测试把这条锁住 ✓：坏文件必须**逐字节原样保留** ✓。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let journalURL = directory.appendingPathComponent("review-queue.json")
        let corrupt = Data(#"{"jobs": [ {"id": "not-a-uuid"} "#.utf8)   // 故意截断的 JSON ✓
        try corrupt.write(to: journalURL)

        // 假 generator + 独立目录：这条测试不会启动本机模型。
        let queue = LearningReviewQueue(journalURL: journalURL, observeSleep: false, diagnostics: .disabled,
                                        generate: { _, _, _, _ in "{}" })
        #expect(queue.hasWork == false)                       // 坏文件不应带来任何任务 ✓
        #expect(queue.status.contains("复查进度读取失败"))      // 失败要**说出来** ✓
        #expect(try Data(contentsOf: journalURL) == corrupt)  // **现场逐字节保留** ✓（核心断言 ✓）
        #expect(queue.userPaused == false)
        await queue.shutdownForTesting()
    }

    @Test func unreadableFileHintsAreActionableInChinese() {
        // 实测（2026-09-18）：截断/损坏的三种音频都抛泛化错误 ✗
        //（"The operation could not be completed" ✗）→ 用户看了等于没看 ✓。本测试锁住"给能照着做的话" ✓。
        let generic = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed"])
        let hint = MediaFileImport.readableFailureHint(for: generic)
        #expect(hint.contains("文件可能损坏或被截断"))
        #expect(hint.contains("播放器确认"))
        #expect(hint.contains("could not be completed") == false)   // 英文原文**不得**再抛给用户 ✓

        // 空文案同样要走兜底 ✓
        let empty = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: ""])
        #expect(MediaFileImport.readableFailureHint(for: empty).contains("文件可能损坏或被截断"))

        // 既有的封装格式文案不能被破坏 ✓
        let container = NSError(domain: "AVFoundationErrorDomain", code: -11828,
                                userInfo: [NSLocalizedDescriptionKey: "cannot open"])
        #expect(MediaFileImport.readableFailureHint(for: container).contains("请先转成 MP4"))
    }

    @Test func exportingIntoAReadOnlyDirectoryThrowsInsteadOfCrashing() throws {
        // 现实场景：会话目录在**只读卷/归档**里（iCloud 归档、外置只读盘 ✓）时导出会怎样 ✗。
        // 契约：**抛错** ✓（由调用方显示"导出失败：…" ✓），**不崩溃** ✗、不静默成功 ✗。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("readonly-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            // 先把权限改回来，否则临时目录删不掉 ✓（写这个测试时特意注意过 ✓）
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        let segments = [TranscriptSegment(startTime: 0, endTime: 8,
                                          english: "So you have three quizzes before the week after.",
                                          chinese: "所以你在下周之前有三次测验。")]
        var thrown: Error?
        do {
            try SessionExporter.export(segments: segments, sessionDirectory: directory)
        } catch {
            thrown = error
        }
        #expect(thrown != nil, "只读目录下导出必须抛错 ✓，而不是静默成功 ✗")
        if let thrown {
            // 文案不能是空的 ✓（用户需要看到"导出失败：…"后面那句 ✓）
            #expect(thrown.localizedDescription.isEmpty == false)
        }
    }

    @Test @MainActor func reviewDirectoryIssuesAreClassifiedConsistently() throws {
        // 契约：会话目录可用性判定（2026-09-18 今天这节的复查正是卡在 `.Trash` 上 ✗）。
        // 这条规则此前只写在批处理内部 ✗、没有测试 ✗；抽成纯函数后逐状态验 ✓。
        let manager = FileManager.default
        #expect(LearningReviewQueue.directoryIssue(for: URL(fileURLWithPath: "/Users/li/.Trash/x")) == "directory_in_trash")
        #expect(LearningReviewQueue.directoryIssue(for: URL(fileURLWithPath: "/Volumes/Backup/.Trashes/501/x")) == "directory_in_trash")

        // 不存在的目录 → 不可写 → directory_unavailable ✓
        #expect(LearningReviewQueue.directoryIssue(for: URL(fileURLWithPath: "/tmp/liveligo-does-not-exist-\(UUID().uuidString)")) == "directory_unavailable")

        // 可写的正常目录 → nil ✓
        let good = manager.temporaryDirectory.appendingPathComponent("dir-ok-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: good, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: good) }
        #expect(LearningReviewQueue.directoryIssue(for: good) == nil)
    }

    @Test func reviewEvidenceMarksSuspiciouslyLongTranslations() {
        // 过长证据要**被标出来** ✓（重复缺陷的已知表现 ✗），正常证据不得被误标 ✗。
        let normal = LearningPrompts.markSuspiciousForReview(
            chinese: "测验在下周五，同一个教室。",
            english: "The quiz is next Friday in the same room.")
        #expect(normal == "测验在下周五，同一个教室。")
        #expect(!normal.contains("⚠️"))

        // 注意：护栏要求英文至少 24 字符才会判断比例 ✓（样例太短会"看起来正常" ✓）——
        // 我第一次就是被这条卡住 ✗，测试报错反而说明它在干活 ✓。
        let runaway = LearningPrompts.markSuspiciousForReview(
            chinese: String(repeating: "这是一段明显长于英文的译文，可能混入了相邻段落的内容。", count: 5),
            english: "So that's one example we can use for the whole exercise today.")
        #expect(runaway.contains("⚠️ 此译文明显长于英文"))
        #expect(runaway.hasPrefix("这是一段明显长于英文的译文"))
    }

    @Test func stableTranslationPrefixStopsBeforeTheFinalSentence() {
        // 契约（2026-09-19）：相邻修复把"稳定前缀"与模型对**尾句**的重译拼起来 ✓，
        // 所以这个函数返回的是 **最后一句之前**的部分 ✓ —— 最后一句**本来就是待修复的尾巴** ✓。
        //
        // ⚠️ 这个函数此前**没有测试** ✗；我第一次写测试时**四条预期全错** ✗ ——
        // 我当时以为它会保留最后一句（"已显示的部分"✓），实测却一律**排除**最后一句 ✓。
        // 下面的值全部来自一次**实测打印** ✓（不是推导 ✓）：
        func prefix(_ zh: String) -> String { QwenTranslationClient.stableTranslationPrefix(zh) }
        #expect(prefix("第一句。第二句。") == "第一句。")
        #expect(prefix("第一句。第二句") == "第一句。")
        #expect(prefix("第一句。第二句！") == "第一句。")
        #expect(prefix("第一句。第二句，") == "第一句。")
        #expect(prefix("没有标点") == "")
        #expect(prefix("") == "")
        // 只有一句、并以句号结尾时 → 没有"最后一句之前"的部分 ✓
        #expect(prefix("只有一句。") == "")
    }
}
