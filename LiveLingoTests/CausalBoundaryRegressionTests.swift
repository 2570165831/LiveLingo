import XCTest
#if !CAUSAL_BOUNDARY_STANDALONE
@testable import LiveLingo
#endif

final class CausalBoundaryRegressionTests: XCTestCase {
    private func pendingSentence() -> CausalBoundaryPolicy {
        var policy = CausalBoundaryPolicy()
        policy.observeActivity(speech: true, start: 1, end: 1.5)
        policy.observeActivity(speech: false, start: 1.5, end: 2)
        policy.observePreview(text: "A sentence.", start: 0, end: 1.5, arrival: 1.9)
        return policy
    }

    func testCoalescedTextRevisionsMustRestartStabilityEvenWhenTextReverts() {
        // SpeechPipeline coalesces callback wakeups on its audio consumer queue.
        // Both delivery schedules must honor the most recent text revision.
        for evaluateIntermediateRevision in [false, true] {
            var policy = pendingSentence()
            XCTAssertNil(policy.decision(at: 2))
            policy.observePreview(text: "A sentence continues", start: 0, end: 1.5, arrival: 2.15)
            if evaluateIntermediateRevision { XCTAssertNil(policy.decision(at: 2.15)) }
            policy.observePreview(text: "A sentence.", start: 0, end: 1.5, arrival: 2.2)
            policy.observeActivity(speech: false, start: 1.75, end: 2.25)
            XCTAssertNil(policy.decision(at: 2.25), "The reverted text has only been stable for 0.05 s")
            policy.observeActivity(speech: false, start: 2.1, end: 2.6)
            XCTAssertEqual(policy.decision(at: 2.6)?.reason, "stable_sentence_pause")
        }
    }

    func testCoalescedTimingRevisionsMustRestartStabilityEvenWhenRangeReverts() {
        var policy = pendingSentence()
        XCTAssertNil(policy.decision(at: 2))
        policy.observePreview(text: "A sentence.", start: 0, end: 1.6, arrival: 2.15)
        policy.observePreview(text: "A sentence.", start: 0, end: 1.5, arrival: 2.2)
        policy.observeActivity(speech: false, start: 1.75, end: 2.25)
        XCTAssertNil(policy.decision(at: 2.25), "A changed audio range is also a preview revision")
        policy.observeActivity(speech: false, start: 2.1, end: 2.6)
        XCTAssertEqual(policy.decision(at: 2.6)?.end, 2.6)
    }

    func testIdenticalCallbacksBeforeFirstDecisionDoNotDelayAnAlreadyStableSentence() {
        var policy = CausalBoundaryPolicy()
        policy.observeActivity(speech: true, start: 1, end: 1.5)
        policy.observeActivity(speech: false, start: 1.5, end: 2)
        policy.observePreview(text: "A sentence.", start: 0, end: 1.5, arrival: 1.6)
        policy.observePreview(text: " A sentence. \n", start: 0, end: 1.5, arrival: 1.9)
        XCTAssertEqual(policy.decision(at: 2)?.reason, "stable_sentence_pause",
                       "An identical normalized observation must retain its original stability time")
    }

    func testIdenticalCallbacksAfterRevisionRetainThatRevisionsStabilityTime() {
        var policy = pendingSentence()
        XCTAssertNil(policy.decision(at: 2))
        policy.observePreview(text: "A revised sentence.", start: 0, end: 1.5, arrival: 2.1)
        policy.observePreview(text: "A revised sentence.", start: 0, end: 1.5, arrival: 2.4)
        policy.observeActivity(speech: false, start: 2, end: 2.5)
        XCTAssertEqual(policy.decision(at: 2.5)?.reason, "stable_sentence_pause")
    }

    func testLatePreviewCannotBorrowStabilityFromItsAudioRange() {
        var policy = CausalBoundaryPolicy()
        policy.observeActivity(speech: true, start: 1, end: 1.5)
        policy.observeActivity(speech: false, start: 1.5, end: 2)
        policy.observePreview(text: "A sentence.", start: 0, end: 1.5, arrival: 2)
        XCTAssertNil(policy.decision(at: 2))
        policy.observeActivity(speech: false, start: 2, end: 2.5)
        XCTAssertEqual(policy.decision(at: 2.5)?.reason, "stable_sentence_pause")
    }

    func testQuietTailNeedsContiguousCoverage() {
        var policy = pendingSentence()
        policy.observeActivity(speech: false, start: 2.1, end: 2.4)
        XCTAssertNil(policy.decision(at: 2.4), "The unclassified gap from 2 to 2.1 cannot count as silence")
        policy.observeActivity(speech: false, start: 1.9, end: 2.2)
        XCTAssertEqual(policy.decision(at: 2.4)?.reason, "stable_sentence_pause")
    }

    func testLateSpeechObservationShortensTheQuietTail() {
        var policy = pendingSentence()
        policy.observeActivity(speech: false, start: 1.75, end: 2.25)
        // Out-of-order speech overlaps a previously observed quiet window.
        policy.observeActivity(speech: true, start: 1.6, end: 2.1)
        XCTAssertNil(policy.decision(at: 2.25))
        policy.observeActivity(speech: false, start: 2, end: 2.5)
        XCTAssertNil(policy.decision(at: 2.5))
        policy.observeActivity(speech: false, start: 2.25, end: 2.75)
        XCTAssertEqual(policy.decision(at: 2.75)?.reason, "stable_sentence_pause")
    }

    func testStaleActivityCannotCommitAStablePreview() {
        var policy = pendingSentence()
        XCTAssertNil(policy.decision(at: 2.4))
        XCTAssertEqual(policy.decision(at: 10)?.reason, "maximum_wait")
    }

    func testPauseDoesNotAdvancePreviewStabilityOnTheCapturedAudioClock() {
        var policy = pendingSentence()
        for _ in 0..<3 { XCTAssertNil(policy.decision(at: 2)) }
        policy.observeActivity(speech: false, start: 1.75, end: 2.25)
        XCTAssertEqual(policy.decision(at: 2.25)?.reason, "stable_sentence_pause")
        XCTAssertNil(policy.finish(at: 2.25))
    }

    func testNextChunkDoesNotReuseACommittedPreview() {
        var policy = pendingSentence()
        policy.observeActivity(speech: false, start: 1.75, end: 2.25)
        XCTAssertEqual(policy.decision(at: 2.25)?.reason, "stable_sentence_pause")
        policy.observeActivity(speech: true, start: 3, end: 3.5)
        policy.observeActivity(speech: false, start: 3.5, end: 4.5)
        XCTAssertNil(policy.decision(at: 4.5))
        policy.observePreview(text: "Next sentence.", start: 3, end: 3.5, arrival: 4.5)
        XCTAssertNil(policy.decision(at: 4.5))
        policy.observeActivity(speech: false, start: 4.25, end: 5)
        XCTAssertEqual(policy.decision(at: 5),
                       CausalBoundaryDecision(start: 2.25, end: 5, reason: "stable_sentence_pause"))
    }

    func testPunctuationAndMinimumDurationRemainRequired() {
        for text in ["An unfinished sentence", "We ask Dr.", "Still waiting..."] {
            var policy = pendingSentence()
            policy.observePreview(text: text, start: 0, end: 1.5, arrival: 1.9)
            policy.observeActivity(speech: false, start: 1.75, end: 2.25)
            XCTAssertNil(policy.decision(at: 2.25))
        }
        var early = CausalBoundaryPolicy()
        early.observeActivity(speech: true, start: 0, end: 1)
        early.observeActivity(speech: false, start: 1, end: 1.75)
        early.observePreview(text: "A sentence.", start: 0, end: 1, arrival: 1.1)
        XCTAssertNil(early.decision(at: 1.75))
    }

    func testPreviewlessLimitAndFinalizationStillWork() {
        var pause = CausalBoundaryPolicy()
        pause.observeActivity(speech: true, start: 0, end: 7.5)
        pause.observeActivity(speech: false, start: 7.5, end: 8)
        XCTAssertEqual(pause.decision(at: 8)?.reason, "approaching_limit_pause")
        var ceiling = CausalBoundaryPolicy()
        XCTAssertNil(ceiling.decision(at: 9.99))
        XCTAssertEqual(ceiling.decision(at: 10)?.reason, "maximum_wait")
        XCTAssertEqual(ceiling.finish(at: 10.5),
                       CausalBoundaryDecision(start: 10, end: 10.5, reason: "end_of_input"))
        XCTAssertNil(ceiling.finish(at: 10.5))
    }
}
