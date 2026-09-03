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
