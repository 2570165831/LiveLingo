import AVFoundation
import Foundation
import XCTest
@testable import LiveLingo

final class AlarmDetectionTests: XCTestCase {
    private final class SoundProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [AlarmSoundObservation] = []
        private var failed = false
        func append(_ observation: AlarmSoundObservation) { lock.withLock { observations.append(observation) } }
        func fail() { lock.withLock { failed = true } }
        var snapshot: (observations: [AlarmSoundObservation], failed: Bool) {
            lock.withLock { (observations, failed) }
        }
    }
    private func window(_ end: Double, _ score: Double) -> AlarmSoundObservation {
        .init(start: max(0, end - 3), end: end, score: score)
    }
    func testPersistentAlarmNeedsThreeNonOverlappingWindowsCoveringNineSeconds() {
        var rule = AlarmTriggerRule()
        for end in [3.0, 4.5, 6, 7.5] { XCTAssertFalse(rule.observe(window(end, 0.8), now: end)) }
        XCTAssertTrue(rule.observe(window(9, 0.8), now: 9))
        XCTAssertFalse(rule.observe(window(10.5, 1), now: 10.5))
    }
    func testIntermittentAlarmToleratesOneIndependentMissWithinTwelveSeconds() {
        var rule = AlarmTriggerRule()
        XCTAssertFalse(rule.observe(window(3, 0.8), now: 3))
        XCTAssertFalse(rule.observe(window(6, 0.4), now: 6))
        XCTAssertFalse(rule.observe(window(9, 0.9), now: 9))
        XCTAssertTrue(rule.observe(window(12, 0.6), now: 12))
        rule.stop()
        for end in [3.0, 12, 30] { XCTAssertFalse(rule.observe(window(end, 1), now: end)) }
    }
    func testFifteenSecondAlarmWithTwelveSecondGapsAndFluctuatingScoresTriggersInBothPhases() {
        for phase in [0.0, 1.5] {
            var rule = AlarmTriggerRule()
            var firstTrigger: Double?
            for index in 0..<80 {
                let end = phase + 3 + Double(index) * 1.5
                let midpoint = end - 1.5
                let sounding = midpoint.truncatingRemainder(dividingBy: 27) < 15
                // Three of four independent windows clear the threshold. This
                // is a rule fixture, not a prediction of classifier confidence.
                let scores = [0.6, 0.4, 0.9, 0.7]
                let score = sounding ? scores[(index / 2) % scores.count] : 0.02
                if rule.observe(window(end, score), now: end) { firstTrigger = end; break }
            }
            XCTAssertNotNil(firstTrigger, "phase=\(phase)")
            XCTAssertLessThanOrEqual(firstTrigger ?? .infinity, phase + 15)
        }
    }
    func testShortBeepAcrossOverlappingWindowBoundariesNeverTriggers() {
        // Deliberately overestimate classification: ANY positive PCM overlap
        // gets a high score, rather than assuming one beep means just one hit.
        // Sweep start phases across the complete independent 3-second cadence.
        var scenarios = 0
        var triggers = 0
        for duration in [0.1, 1.5, 2.0, 2.5, 3.0] {
            for phase in stride(from: 0.0, through: 2.75, by: 0.25) {
                let beep = (start: 12 + phase, end: 12 + phase + duration)
                var rule = AlarmTriggerRule()
                for end in stride(from: 3.0, through: 36.0, by: 1.5) {
                    let intersects = max(end - 3, beep.start) < min(end, beep.end)
                    let triggered = rule.observe(window(end, intersects ? 0.95 : 0.03), now: end)
                    if triggered { triggers += 1 }
                    XCTAssertFalse(triggered,
                                   "duration=\(duration) phase=\(phase) end=\(end)")
                }
                scenarios += 1
            }
        }
        print("ALARM_SYNTHETIC_BEEP scenarios=\(scenarios) durations_s=0.1,1.5,2,2.5,3 phase_step_s=0.25 false_triggers=\(triggers) scoring=any_positive_overlap real_classifier=false")
    }
    func testSeparatedBeepTrainDoesNotAccumulateIndependentEvidence() {
        var rule = AlarmTriggerRule()
        let beeps = stride(from: 12.0, through: 60.0, by: 12).map { ($0, $0 + 3) }
        for end in stride(from: 3.0, through: 72.0, by: 1.5) {
            let hit = beeps.contains { max(end - 3, $0.0) < min(end, $0.1) }
            XCTAssertFalse(rule.observe(window(end, hit ? 0.95 : 0.03), now: end))
        }
    }
    func testSystemClassifierWithSyntheticBeepProducesObservationsWithoutReminder() async throws {
        let format = MediaFileImport.storageFormat
        let probe = SoundProbe()
        let analyzer = try AlarmSoundAnalyzer(format: format, handler: { probe.append($0) }, failed: { probe.fail() })
        let framesPerBuffer: AVAudioFrameCount = 1600
        let beepStart = 7.75, beepEnd = 10.25
        for index in 0..<180 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer))
            buffer.frameLength = framesPerBuffer
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            let position = AVAudioFramePosition(index) * AVAudioFramePosition(framesPerBuffer)
            for frame in 0..<Int(framesPerBuffer) {
                let time = Double(position + AVAudioFramePosition(frame)) / format.sampleRate
                samples[frame] = time >= beepStart && time < beepEnd ? Float(0.6 * sin(2 * .pi * 1000 * time)) : 0
            }
            analyzer.submit(buffer, at: position)
            await analyzer.drain()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (probe.snapshot.observations.last?.end ?? 0) < 15, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        analyzer.stop()
        await analyzer.drain()
        let result = probe.snapshot
        XCTAssertFalse(result.failed)
        XCTAssertGreaterThanOrEqual(result.observations.count, 5, "Classification must really have run")
        XCTAssertEqual(analyzer.droppedAudioSeconds, 0)
        var rule = AlarmTriggerRule()
        var triggers = 0
        for observation in result.observations.sorted(by: { $0.end < $1.end }) {
            XCTAssertEqual(observation.end - observation.start, AlarmPolicy.windowSeconds, accuracy: 0.01)
            if rule.observe(observation, now: observation.end) { triggers += 1 }
        }
        XCTAssertEqual(triggers, 0)
        let summary: [String: Any] = ["synthetic_only": true, "real_classifier": true,
            "beep_seconds": beepEnd - beepStart, "frequency_hz": 1000,
            "audio_frames": Int(framesPerBuffer) * 180, "sample_rate": format.sampleRate,
            "observations": result.observations.map { ["start": $0.start, "end": $0.end, "score": $0.score] },
            "triggers": triggers, "dropped_seconds": analyzer.droppedAudioSeconds]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: TestFixtureDirectory.root.appendingPathComponent("alarm-synthetic-beep-classifier.json"),
                   options: .withoutOverwriting)
        print("ALARM_SYSTEM_CLASSIFIER synthetic_only=true beep_seconds=\(beepEnd - beepStart) observations=\(result.observations.count) triggers=\(triggers) dropped_seconds=\(analyzer.droppedAudioSeconds)")
    }
    func testSingleBeepAndOccasionalLectureBellNeverTrigger() {
        for hits in [[3.0], [3.0, 4.5], [3.0, 45, 90]] {
            var rule = AlarmTriggerRule()
            for index in 0..<65 {
                let end = 3 + Double(index) * 1.5
                XCTAssertFalse(rule.observe(window(end, hits.contains(end) ? 0.9 : 0.03), now: end))
            }
        }
    }
    func testSpeechAndEvacuationTextCannotTriggerWithoutSoundEvidence() {
        var rule = AlarmTriggerRule()
        for index in 0..<50 { XCTAssertFalse(rule.observe(window(3 + Double(index) * 1.5, 0.49), now: Double(index))) }
        XCTAssertFalse(AlarmPolicy.labels.contains("speech"))
        XCTAssertFalse(AlarmPolicy.labels.contains("reverse_beeps"))
    }
    func testDuplicateInvalidAndCompressedObservationsCannotTrigger() {
        var rule = AlarmTriggerRule()
        XCTAssertFalse(rule.observe(window(3, 1), now: 3))
        XCTAssertFalse(rule.observe(window(3, 1), now: 3))
        XCTAssertFalse(rule.observe(window(4, 1), now: 4))
        XCTAssertFalse(rule.observe(window(5, 1), now: 5))
        XCTAssertFalse(rule.observe(window(6, .nan), now: 6))
        XCTAssertFalse(rule.observe(window(.infinity, 1), now: 6))
        XCTAssertFalse(rule.observe(.init(start: -1, end: 8, score: 1), now: 8))
    }
    func testCooldownRequiresFreshEvidenceAndStopResetsEverything() {
        var rule = AlarmTriggerRule()
        for end in [3.0, 4.5, 6, 7.5, 9] { _ = rule.observe(window(end, 1), now: end) }
        rule.dismiss(now: 10)
        XCTAssertFalse(rule.isPresented)
        XCTAssertEqual(rule.nextAllowedAt, 190)
        for end in stride(from: 7.5, through: 183, by: 1.5) { XCTAssertFalse(rule.observe(window(end, 1), now: end)) }
        XCTAssertFalse(rule.observe(window(190, 1), now: 190))
        XCTAssertFalse(rule.observe(window(191.5, 1), now: 191.5))
        XCTAssertFalse(rule.observe(window(193, 1), now: 193))
        XCTAssertFalse(rule.observe(window(194.5, 1), now: 194.5))
        XCTAssertTrue(rule.observe(window(196, 1), now: 196))
        rule.stop()
        XCTAssertFalse(rule.isPresented)
        XCTAssertEqual(rule.nextAllowedAt, 0)
    }
    func testMissingAudioAndPauseClearPersistenceEvidence() {
        var rule = AlarmTriggerRule()
        _ = rule.observe(window(3, 1), now: 3)
        _ = rule.observe(window(4.5, 1), now: 4.5)
        XCTAssertFalse(rule.observe(window(10, 1), now: 10))
        rule.clearEvidence()
        XCTAssertFalse(rule.observe(window(11.5, 1), now: 11.5))
    }
    func testCountdownCancelNeverSplits() {
        var countdown = AlarmCountdown()
        countdown.start(now: 100)
        XCTAssertEqual(countdown.remaining(now: 100), 30)
        XCTAssertEqual(countdown.remaining(now: 101.2), 29)
        countdown.cancel()
        XCTAssertFalse(countdown.takeDue(now: 131, recording: true, paused: false, importing: false, liveOnly: false, enabled: true))
    }
    func testCountdownEndsOnceAndIneligibleStatesDoNotSplit() {
        for scenario in 0..<6 {
            var countdown = AlarmCountdown()
            countdown.start(now: 100)
            XCTAssertFalse(countdown.takeDue(now: 129.99, recording: true, paused: false, importing: false, liveOnly: false, enabled: true))
            let result = countdown.takeDue(now: 130, recording: scenario != 1, paused: scenario == 2,
                importing: scenario == 3, liveOnly: scenario == 4, enabled: scenario != 5)
            XCTAssertEqual(result, scenario == 0)
            XCTAssertNil(countdown.deadline)
            XCTAssertFalse(countdown.takeDue(now: 131, recording: true, paused: false, importing: false, liveOnly: false, enabled: true))
        }
    }
    func testSlowBreathingIsBelowFlashLimitAndConstantsAreCentralized() {
        XCTAssertGreaterThanOrEqual(AlarmPolicy.breathingPeriod, 1)
        XCTAssertLessThan(1 / AlarmPolicy.breathingPeriod, 3)
        XCTAssertEqual(AlarmPolicy.countdownSeconds, 30)
        XCTAssertEqual(AlarmPolicy.postAlarmFolderSuffix, " · 警报后")
    }
}
