import AVFoundation
import Foundation
import XCTest
@testable import LiveLingo

final class AlarmDetectionTests: XCTestCase {
    private func window(_ end: Double, _ score: Double) -> AlarmSoundObservation {
        .init(start: max(0, end - 3), end: end, score: score)
    }
    func testPersistentAlarmTriggersOnlyAfterThreeSpacedWindows() {
        var rule = AlarmTriggerRule()
        XCTAssertFalse(rule.observe(window(3, 0.5), now: 3))
        XCTAssertFalse(rule.observe(window(4.5, 0.7), now: 4.5))
        XCTAssertTrue(rule.observe(window(6, 0.6), now: 6))
        XCTAssertFalse(rule.observe(window(7.5, 1), now: 7.5))
    }
    func testIntermittentAlarmCanTriggerButWidelySeparatedHitsCannot() {
        var rule = AlarmTriggerRule()
        let scores = [0.7, 0.1, 0.8, 0.1, 0.8]
        var triggers = 0
        for (index, score) in scores.enumerated() {
            let end = 3 + Double(index) * 1.5
            if rule.observe(window(end, score), now: end) { triggers += 1 }
        }
        XCTAssertEqual(triggers, 1)
        rule.stop()
        for end in [3.0, 12, 30] { XCTAssertFalse(rule.observe(window(end, 1), now: end)) }
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
        for end in [3.0, 4.5, 6] { _ = rule.observe(window(end, 1), now: end) }
        rule.dismiss(now: 10)
        XCTAssertFalse(rule.isPresented)
        XCTAssertEqual(rule.nextAllowedAt, 190)
        for end in stride(from: 7.5, through: 183, by: 1.5) { XCTAssertFalse(rule.observe(window(end, 1), now: end)) }
        XCTAssertFalse(rule.observe(window(190, 1), now: 190))
        XCTAssertFalse(rule.observe(window(191.5, 1), now: 191.5))
        XCTAssertTrue(rule.observe(window(193, 1), now: 193))
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
