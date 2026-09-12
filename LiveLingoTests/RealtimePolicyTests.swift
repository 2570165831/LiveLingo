import AVFoundation
import XCTest
@testable import LiveLingo

final class RealtimePolicyTests: XCTestCase {
    func testSummaryCadenceDoesNotAddGenerationTimeToRefreshInterval() {
        // A round started at 100 and finished at 220. At 280 the next round
        // is due, instead of waiting another 180 seconds after completion.
        XCTAssertEqual(SummaryRefreshPolicy.delay(now: 220, lastCaptionActivity: nil,
                                                  lastCycleStarted: 100, allowConcurrent: true), 60)
        XCTAssertEqual(SummaryRefreshPolicy.delay(now: 280, lastCaptionActivity: 280,
                                                  lastCycleStarted: 100, allowConcurrent: true), 0)
        XCTAssertEqual(SummaryRefreshPolicy.delay(now: 350, lastCaptionActivity: nil,
                                                  lastCycleStarted: 100, allowConcurrent: true), 0)
        XCTAssertEqual(SummaryRefreshPolicy.delay(now: 280, lastCaptionActivity: 280,
                                                  lastCycleStarted: 100, allowConcurrent: false), 2)
    }

    func testSummaryFailureBackoffIsBoundedAndDoesNotWaitAWholeRefreshCycle() {
        XCTAssertEqual((1...6).map { SummaryRefreshPolicy.failureRetryDelay(consecutiveFailures: $0) },
                       [10, 20, 40, 60, 60, 60])
    }

    func testLatestNotesContainOnlyLastCommittedBatchEvenWithinSameTopic() throws {
        let a = TranscriptSegment(startTime: 0, endTime: 8, english: "Atoms", chinese: "原子")
        let b = TranscriptSegment(startTime: 8, endTime: 16, english: "Ions", chinese: "离子")
        let c = TranscriptSegment(startTime: 16, endTime: 24, english: "Okay.", chinese: "好的")
        var book = LearningNotebook()
        try book.append(evidence: [a], note: .init(topic: "结构", points: [.init(kind: "核心结论", text: "先前事实")]))
        try book.append(evidence: [b], note: .init(topic: "结构", points: [.init(kind: "核心结论", text: "新增事实")]))
        XCTAssertEqual(book.latestEvidenceIDs, [b.id])
        let latest = book.markdown(covering: book.latestEvidenceIDs)
        XCTAssertTrue(latest.contains("新增事实"))
        XCTAssertFalse(latest.contains("先前事实"))
        XCTAssertTrue(book.markdown().contains("先前事实"))
        XCTAssertTrue(book.markdown().contains("新增事实"))
        let noKnowledge = try LearningNote.decode(#"{"sourceVersion":2,"topic":"无新增学习知识","points":[],"noNewKnowledge":true}"#)
        try book.append(evidence: [c], note: noKnowledge)
        XCTAssertEqual(book.latestEvidenceIDs, [c.id])
        XCTAssertEqual(book.markdown(covering: book.latestEvidenceIDs), "")
        XCTAssertTrue(book.markdown().contains("先前事实"))
    }

    @MainActor
    func testExplicitNonKnowledgeBatchAdvancesCoverageWithoutNotesOrReview() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1, english: "Wonderful. Next, we then go.")]
        let note = try LearningNote.decode("{\"sourceVersion\":2,\"topic\":\"无新增学习知识\",\"points\":[],\"noNewKnowledge\":true}")
        var book = LearningNotebook()
        try book.append(evidence: evidence, note: note)
        XCTAssertEqual(book.batches.first?.ids, Set(evidence.map(\.id)))
        XCTAssertTrue(book.markdown().isEmpty)
        XCTAssertTrue(book.topics.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"), observeSleep: false)
        try queue.enqueue(directory: directory, notebook: book)
        XCTAssertFalse(queue.hasWork)
        XCTAssertThrowsError(try LearningNote.decode("{\"topic\":\"缺失内容\",\"points\":[]}"))
        XCTAssertThrowsError(try LearningNote.decode("{\"topic\":\"矛盾标记\",\"points\":[{\"kind\":\"核心结论\",\"text\":\"保留学科内容\"}],\"noNewKnowledge\":true}"))
    }

    func testNumberedSourcesPreserveDecimalsConditionsAndBothLanguages() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1, english: "R has a concentration of 0.25 mol/L. If temperature is constant, V = IR; otherwise check the material.", chinese: "R 的浓度为 0.25 mol/L。温度不变时，V = IR。")]
        let units = LearningSourceUnit.make(evidence)
        XCTAssertEqual(Set(units.map(\.id)).count, units.count)
        XCTAssertEqual(units.filter { $0.language == "en" }.map(\.text), ["R has a concentration of 0.25 mol/L.", "If temperature is constant, V = IR; otherwise check the material."])
        XCTAssertTrue(units.contains { $0.language == "zh" && $0.text.contains("0.25 mol/L") })
        for unit in units { XCTAssertTrue(evidence[unit.index].english.contains(unit.text) || evidence[unit.index].chinese.contains(unit.text)) }
        let id = try XCTUnwrap(units.first?.id)
        let note = LearningNote(topic: "浓度", points: [.init(kind: "核心结论", text: "R 的浓度为 0.25 mol/L。", sourceIDs: [id])], sourceVersion: 2).binding(evidence: evidence)
        XCTAssertEqual(note.points.first?.sources, [.init(index: 0, quote: "R has a concentration of 0.25 mol/L.")])
        XCTAssertEqual(note.points.first?.referenceState, .linked)
        XCTAssertEqual(try JSONDecoder().decode(LearningNote.self, from: JSONEncoder().encode(note)), note)
    }

    func testUnknownOrDuplicateSourceIDsCannotUseModelSuppliedQuoteAsFallback() {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1, english: "R is red.")]
        for ids in [["unknown"], ["en0s0", "en0s0"], []] {
            let point = LearningPoint(kind: "核心结论", text: "R 是红色。", sources: [.init(index: 0, quote: "R is red.")], sourceIDs: ids)
            let bound = LearningNote(topic: "颜色", points: [point], sourceVersion: 2).binding(evidence: evidence)
            XCTAssertEqual(bound.points[0].referenceState, .unlinked)
            XCTAssertEqual(bound.points[0].text, point.text)
        }
    }

    func testOrdinaryPronounsDoNotCreateSemanticQuestions() throws {
        var book = LearningNotebook()
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1, english: "The rule states that energy is conserved. A cart has its mass measured.")]
        try book.append(evidence: evidence, note: .init(topic: "测量", points: [
            .init(kind: "核心结论", text: "能量守恒。", sourceIDs: ["en0s0"]),
            .init(kind: "例子", text: "测量小车的质量。", sourceIDs: ["en0s1"])
        ], sourceVersion: 2))
        XCTAssertTrue(book.pendingPoints.isEmpty)
        XCTAssertEqual(book.batches[0].note.points.map(\.referenceState), [.linked, .linked])
        XCTAssertEqual(book.batches[0].note.points.map(\.sourceHasPronoun), [false, true])
        let followUps = book.selectPendingPoints(for: evidence)
        XCTAssertTrue(followUps.allSatisfy(\.referenceCheck))
    }

    func testFollowupInputContainsQuestionsAndEvidenceInsteadOfOldAssertion() throws {
        var book = LearningNotebook()
        let source = TranscriptSegment(startTime: 0, endTime: 1, english: "Its speed is 8 m/s.")
        try book.append(evidence: [source], note: .init(topic: "速度", points: [
            .init(kind: "核心结论", text: "错误猜测：A 的速度为 8 m/s。", sources: [.init(index: 0, quote: source.english)], needsContext: "这项速度属于哪个对象？")
        ], sourceVersion: 1))
        let next = [TranscriptSegment(startTime: 1, endTime: 2, english: "The speed belongs to B.")]
        let input = try LearningPrompts.input(evidence: next, topics: ["旧标题中的错误假设"], pending: book.selectPendingPoints(for: next))
        XCTAssertFalse(input.contains("错误猜测"))
        XCTAssertFalse(input.contains("旧标题中的错误假设"))
        XCTAssertTrue(input.contains("同一对象、属性、条件或指代关系"))
        XCTAssertTrue(input.contains("Its speed"))
    }

    func testFollowupAliasesUseTheFrozenDraftMappingAndRejectUnknownTargets() {
        let source = TranscriptSegment(startTime: 0, endTime: 1, english: "A is moving.")
        let draft = LearningDraft(evidence: [source], model: "4b", input: "frozen input", text: "partial", pendingTargets: ["old-question-2", "old-question-1"])
        let note = LearningNote(topic: "运动", points: ["q0", "q1", "q2", "q-1", "q01", "old-question-1"].map {
            LearningPoint(kind: "核心结论", text: "后文候选", clarifies: $0)
        })
        let resolved = LearningPrompts.resolvingFollowUps(note, targets: draft.pendingTargets)
        XCTAssertEqual(resolved.points.map(\.clarifies), ["old-question-2", "old-question-1", nil, nil, nil, nil])
        XCTAssertEqual(draft.text, "partial")
        XCTAssertTrue(draft.matches(evidence: [source], model: "4b"))
    }

    func testDraftSurvivesNewCaptionsButNotRevisedEarlierEvidence() throws {
        let earlier = TranscriptSegment(startTime: 0, endTime: 1, english: "Its mass is unknown.")
        let current = TranscriptSegment(startTime: 1, endTime: 2, english: "The mass belongs to B.")
        var book = LearningNotebook()
        try book.append(evidence: [earlier], note: .init(topic: "质量", points: [.init(kind: "待确认", text: "质量归属未明。", needsContext: "质量属于谁？", sourceIDs: ["en0s0"])], sourceVersion: 2))
        let draft = LearningDraft(evidence: [current], model: "4b", input: "frozen", text: "partial", contextRevision: book.revision)
        XCTAssertTrue(book.invalidate(UUID()).isEmpty)
        XCTAssertTrue(draft.matches(evidence: [current], model: "4b", contextRevision: book.revision))
        XCTAssertEqual(book.invalidate(earlier.id), [earlier.id])
        XCTAssertFalse(draft.matches(evidence: [current], model: "4b", contextRevision: book.revision))
        XCTAssertEqual(draft.text, "partial")
    }

    func testReviewCanSeeLaterOriginalClarificationWithoutModelLinkAndKeepsTimeOrder() throws {
        var book = LearningNotebook()
        for text in ["Its concentration is 0.4 mol/L.", "The concentration of 0.4 mol/L belongs to N.", "After dilution, N has concentration 0.2 mol/L."] {
            try book.append(evidence: [.init(startTime: 0, endTime: 1, english: text)], note: .init(topic: "浓度", points: [.init(kind: "核心结论", text: "测试笔记", sourceIDs: ["en0s0"])], sourceVersion: 2))
        }
        let before = book.batches
        let data = Data(try LearningPrompts.reviewInput(book.batches[0], laterBatches: Array(book.batches.dropFirst())).utf8)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((input["laterContext"] as? [Any])?.isEmpty == true)
        let later = try XCTUnwrap(input["laterEvidence"] as? [[String: Any]])
        XCTAssertEqual(later.compactMap { $0["batchOffset"] as? Int }, [1, 2])
        XCTAssertEqual((later[0]["source"] as? [String: Any])?["text"] as? String, "The concentration of 0.4 mol/L belongs to N.")
        XCTAssertEqual(book.batches, before)
    }

    func testLaterReviewContextHasBoundedSizeAndNeverCutsASentence() throws {
        let evidence = TranscriptSegment(startTime: 0, endTime: 1, english: "Concentration changes.")
        let note = LearningNote(topic: "浓度", points: [.init(kind: "核心结论", text: "浓度变化。")])
        let batch = LearningNoteBatch(id: UUID(), evidence: [evidence], note: note)
        let text = "Concentration " + String(repeating: "unknown ", count: 500) + "."
        let later = LearningNoteBatch(id: UUID(), evidence: [.init(startTime: 1, endTime: 2, english: text)], note: note)
        let data = Data(try LearningPrompts.reviewInput(batch, laterBatches: [later]).utf8)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((input["laterEvidence"] as? [Any])?.isEmpty == true)
        XCTAssertEqual(input["laterEvidenceOmittedCount"] as? Int, 1)
    }

    func testUnrelatedAndContradictoryCandidatesDoNotCloseQuestionsOrHideRecords() throws {
        var book = LearningNotebook()
        let original = TranscriptSegment(startTime: 0, endTime: 1, english: "Its speed is 8 m/s.")
        try book.append(evidence: [original], note: .init(topic: "速度", points: [.init(kind: "待确认", text: "速度为 8 m/s，归属未明。", needsContext: "速度属于哪个对象？", sourceIDs: ["en0s0"])], sourceVersion: 2))
        let old = book.batches[0]
        let target = try XCTUnwrap(book.pendingPoints.first?.id)
        for (english, text) in [("Humidity is 8 percent.", "湿度为 8%。"), ("B moves at 8 m/s.", "B 的速度为 8 m/s。"), ("A moves at 10 m/s.", "A 的速度为 10 m/s。") ] {
            try book.append(evidence: [.init(startTime: 1, endTime: 2, english: english)], note: .init(topic: "速度", points: [.init(kind: "核心结论", text: text, clarifies: target, sourceIDs: ["en0s0"])], sourceVersion: 2))
            XCTAssertEqual(book.batches[0], old)
            XCTAssertEqual(book.pendingPoints.first?.id, target)
        }
        let rendered = book.markdown()
        for text in ["速度为 8 m/s，归属未明。", "湿度为 8%。", "B 的速度为 8 m/s。", "A 的速度为 10 m/s。"] {
            XCTAssertEqual(rendered.components(separatedBy: text).count - 1, 1)
        }
        XCTAssertTrue(rendered.contains(original.english))
        XCTAssertTrue(rendered.contains("原问题仍待核对"))
        _ = book.invalidate(original.id)
        XCTAssertTrue(book.batches.flatMap { $0.note.points }.allSatisfy { $0.clarifies == nil })
    }

    func testCandidateWithItsOwnQuestionAndLaterCandidateRemainVisible() throws {
        var book = LearningNotebook()
        let source = TranscriptSegment(startTime: 0, endTime: 1, english: "Its speed is unknown.")
        try book.append(evidence: [source], note: .init(topic: "速度", points: [.init(kind: "待确认", text: "最初关系。", needsContext: "速度属于谁？", sourceIDs: ["en0s0"])], sourceVersion: 2))
        let root = try XCTUnwrap(book.pendingPoints.first?.id)
        try book.append(evidence: [.init(startTime: 1, endTime: 2, english: "B may be moving.")], note: .init(topic: "速度", points: [.init(kind: "待确认", text: "中间候选。", needsContext: "B 是否在运动？", clarifies: root, sourceIDs: ["en0s0"])], sourceVersion: 2))
        let child = LearningNotebook.reference(book.batches[1], 0)
        try book.append(evidence: [.init(startTime: 2, endTime: 3, english: "B is moving.")], note: .init(topic: "速度", points: [.init(kind: "核心结论", text: "后续候选。", clarifies: child, sourceIDs: ["en0s0"])], sourceVersion: 2))
        XCTAssertEqual(book.pendingPoints.count, 2)
        for text in ["最初关系。", "中间候选。", "后续候选。"] {
            XCTAssertEqual(book.markdown().components(separatedBy: text).count - 1, 1)
        }
        XCTAssertTrue(book.markdown(covering: book.batches[2].ids).contains("中间候选。"))
    }

    func testEarlierQuestionsRemainEligibleBeyondFourAndSelectionRotates() throws {
        var book = LearningNotebook()
        for index in 0..<9 {
            try book.append(evidence: [.init(startTime: Double(index), endTime: Double(index + 1), english: "Object \(index) has an unknown property.")], note: .init(topic: "属性", points: [.init(kind: "待确认", text: "旧猜测 \(index)", needsContext: "属性对应哪个对象？", sourceIDs: ["en0s0"])], sourceVersion: 2))
        }
        XCTAssertEqual(book.pendingPoints.count, 9)
        var offered: Set<String> = []
        for _ in 0..<9 {
            let selection = book.selectPendingPoints(for: [.init(startTime: 10, endTime: 11, english: "Object properties are discussed next.")])
            XCTAssertLessThanOrEqual(selection.count, 4)
            XCTAssertEqual(Set(selection.map(\.id)).count, selection.count)
            offered.formUnion(selection.map(\.id))
        }
        XCTAssertEqual(offered, Set(book.pendingPoints.map(\.id)))
    }
    func testMissingCitationAloneDoesNotAskForContextButAnExplicitQuestionDoes() throws {
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 1, english: "Its mass is unknown.")], note: .init(topic: "质量", points: [
            .init(kind: "核心结论", text: "已有的一项知识。", sources: []),
            .init(kind: "待确认", text: "质量归属尚未明确。", sources: [], needsContext: "its 指代谁？")
        ], sourceVersion: 1))
        XCTAssertEqual(book.pendingPoints.count, 1)
        XCTAssertEqual(book.pendingPoints[0].question, "its 指代谁？")
        XCTAssertEqual(book.batches[0].note.points[0].kind, "核心结论")
    }

    func testClippedPronounRemainsUnreviewedRatherThanProven() {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1, english: "Its speed is 5 m/s.")]
        let result = LearningNote(topic: "速度", points: [.init(kind: "核心结论", text: "速度为 5 m/s。", sources: [.init(index: 0, quote: "speed is 5 m/s.")])], sourceVersion: 1).binding(evidence: evidence)
        XCTAssertEqual(result.points[0].referenceState, .linked)
        XCTAssertEqual(result.points[0].sourceHasPronoun, true)
        XCTAssertEqual(result.points[0].kind, "核心结论")
    }

    func testNumericConflictOnlyFlagsItsOwnPointWithoutChangingValues() {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1, english: "A has a mass of 2 kg. B has a mass of 3 kg.")]
        let result = LearningNote(topic: "质量", points: [
            .init(kind: "核心结论", text: "A 的质量为 2 kg。", sources: [.init(index: 0, quote: "A has a mass of 2 kg.")]),
            .init(kind: "核心结论", text: "B 的质量为 4 kg。", sources: [.init(index: 0, quote: "B has a mass of 3 kg.")])
        ], sourceVersion: 1).binding(evidence: evidence)
        XCTAssertEqual(result.points.map(\.referenceState), [.linked, .numericDifference])
        XCTAssertEqual(result.points[1].text, "B 的质量为 4 kg。")
        XCTAssertEqual(result.points[1].kind, "核心结论")
    }

    func testNumericClaimWithOnlyANonnumericQuoteIsASourceDifferenceNotAFactRewrite() {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1, english: "The two volumes must use consistent units.")]
        let point = LearningPoint(kind: "核心结论", text: "N 的浓度为 0.4 mol/L。", sourceIDs: ["en0s0"])
        let bound = LearningNote(topic: "浓度", points: [point], sourceVersion: 2).binding(evidence: evidence)
        XCTAssertEqual(bound.points[0].referenceState, .numericDifference)
        XCTAssertEqual(bound.points[0].text, point.text)
        XCTAssertEqual(bound.points[0].kind, point.kind)
    }

    func testPointSourcesDoNotTransferOtherObjectsProperties() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 8, english: "Cart A has a mass of 2 kg, while cart B has a mass of 3 kg. Its speed is 5 m/s.")]
        let points: [LearningPoint] = [
            .init(kind: "核心结论", text: "小车 A 的质量为 2 kg。", sources: [.init(index: 0, quote: "Cart A has a mass of 2 kg")]),
            .init(kind: "核心结论", text: "小车 B 的质量为 3 kg。", sources: [.init(index: 0, quote: "cart B has a mass of 3 kg.")]),
            .init(kind: "核心结论", text: "小车 A 的速度为 5 m/s。", sources: [.init(index: 0, quote: "Its speed is 5 m/s.")])
        ]
        let note = LearningNote(topic: "小车", points: points, sourceVersion: 1).binding(evidence: evidence)
        XCTAssertEqual(note.points.map(\.text), points.map(\.text))
        XCTAssertEqual(note.points.map(\.kind), points.map(\.kind))
        XCTAssertEqual(note.points.map(\.referenceState), [.linked, .linked, .linked])
        XCTAssertEqual(note.points[2].sourceHasPronoun, true)
        XCTAssertFalse(note.markdown.contains("已核实"))
    }

    func testMissingOrMalformedSourcesAreNotFactualUncertainty() throws {
        let note = try LearningNote.decode(#"{"sourceVersion":1,"topic":"质量","points":[{"kind":"核心结论","text":"质量保持不变。","sources":"bad metadata"}]}"#)
        let result = note.binding(evidence: [])
        XCTAssertEqual(result.points[0].text, note.points[0].text)
        XCTAssertEqual(result.points[0].kind, "核心结论")
        XCTAssertEqual(result.points[0].referenceState, .unlinked)
        XCTAssertTrue(result.markdown.contains("来源待核对"))
        XCTAssertFalse(result.markdown.contains("归属待确认"))
        let legacy = try LearningNote.decode(#"{"topic":"质量","points":[{"kind":"核心结论","text":"质量保持不变。"}]}"#)
        XCTAssertEqual(legacy.binding(evidence: []), legacy)
    }

    func testBadSourceDoesNotAffectNeighborAndBackgroundNeedsNoInventedQuote() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 2, english: "A is red. B is blue.")]
        let note = LearningNote(topic: "颜色", points: [
            .init(kind: "核心结论", text: "A 是红色。", sources: [.init(index: 99, quote: "A is red.")]),
            .init(kind: "核心结论", text: "B 是蓝色。", sources: [.init(index: 0, quote: "B is blue.")]),
            .init(kind: "补充理解", text: "这是背景解释。", sources: [])
        ], sourceVersion: 1).binding(evidence: evidence)
        XCTAssertEqual(note.points.map(\.referenceState), [.unlinked, .linked, nil])
        XCTAssertEqual(note.points[1].text, "B 是蓝色。")
    }

    func testLaterContextLinksOnlyItsPendingPointAndDoesNotOverwriteIt() throws {
        let earlier = TranscriptSegment(startTime: 0, endTime: 8, english: "Its speed is 5 m/s.")
        var book = LearningNotebook()
        try book.append(evidence: [earlier], note: .init(topic: "小车", points: [.init(kind: "核心结论", text: "速度为 5 m/s，对象尚未核对。", sources: [.init(index: 0, quote: earlier.english)], needsContext: "速度属于哪个对象？")], sourceVersion: 1))
        let prior = book.batches[0]
        let target = try XCTUnwrap(book.pendingPoints.first?.id)
        let later = TranscriptSegment(startTime: 8, endTime: 16, english: "The speed of cart B is 5 m/s.")
        try book.append(evidence: [later], note: .init(topic: "小车", points: [.init(kind: "核心结论", text: "小车 B 的速度为 5 m/s。", sources: [.init(index: 0, quote: later.english)], clarifies: target)], sourceVersion: 1))
        XCTAssertEqual(book.batches[0], prior)
        XCTAssertEqual(book.pendingPoints.first?.id, target)
        XCTAssertEqual(book.pendingPoints.first?.candidateQuotes, [later.english])
        XCTAssertTrue(book.markdown().contains("后文补充候选，原问题仍待核对"))
        let data = Data(try LearningPrompts.reviewInput(prior, laterBatches: [book.batches[1]]).utf8)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let followUp = try XCTUnwrap((input["laterContext"] as? [[String: Any]])?.first)
        XCTAssertEqual(followUp["pointIndex"] as? Int, 0)
        XCTAssertEqual(followUp["sources"] as? [String], [later.english])
        _ = book.invalidate(later.id)
        XCTAssertEqual(book.pendingPoints.first?.id, target)
        XCTAssertEqual(book.batches[0], prior)
    }

    func testUnknownClarificationIsDroppedAndDuplicateTextStillFolds() throws {
        var book = LearningNotebook()
        for index in 0..<2 {
            let evidence = TranscriptSegment(startTime: Double(index), endTime: Double(index + 1), english: "A is red.")
            try book.append(evidence: [evidence], note: .init(topic: "颜色", points: [.init(kind: "核心结论", text: "A 是红色。", sources: [.init(index: 0, quote: evidence.english)], clarifies: "unknown")], sourceVersion: 1))
        }
        XCTAssertTrue(book.batches.allSatisfy { $0.note.points[0].clarifies == nil })
        XCTAssertEqual(book.markdown().components(separatedBy: "A 是红色。").count - 1, 1)
    }


    func testReviewAdditionsRequireExactEvidenceAndSupportOldResponses() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 8, english: "Oxygen is the terminal electron acceptor.")]
        func decode(_ json: String) throws -> LearningReview {
            try JSONDecoder().decode(LearningReview.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try decode(#"{"corrections":[]}"#).additions.isEmpty)
        let valid = #"{"corrections":[],"additions":[{"evidenceIndex":0,"quote":"Oxygen is the terminal electron acceptor.","kind":"核心结论","text":"氧气是末端电子受体。","reason":"原笔记遗漏电子受体。"}]}"#
        XCTAssertNoThrow(try decode(valid).validateAdditions(evidence: evidence))
        XCTAssertThrowsError(try decode(valid.replacingOccurrences(of: "\"evidenceIndex\":0", with: "\"evidenceIndex\":1")).validateAdditions(evidence: evidence))
        XCTAssertThrowsError(try decode(valid.replacingOccurrences(of: "Oxygen is", with: "Carbon is")).validateAdditions(evidence: evidence))
    }

    @MainActor
    func testReviewQueueDisplaysMissingKnowledgeWithoutChangingBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoLearningTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Oxygen is the terminal electron acceptor.")], note: .init(topic: "氧化磷酸化", points: [.init(kind: "核心结论", text: "质子动力势驱动 ATP 合酶。")]))
        let file = root.appendingPathComponent("summary-zh-Hans.md")
        let original = book.markdown() + "\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false) { _, _, _ in
            #"{"corrections":[],"additions":[{"evidenceIndex":0,"quote":"Oxygen is the terminal electron acceptor.","kind":"核心结论","text":"氧气是末端电子受体。","reason":"遗漏电子受体。"}]}"#
        }
        try queue.enqueue(directory: root, notebook: book)
        for _ in 0..<100 where queue.hasWork { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.hasWork)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
        let report = try String(contentsOf: root.appendingPathComponent("summary-review.md"), encoding: .utf8)
        XCTAssertTrue(report.contains("遗漏补充建议"))
        XCTAssertTrue(report.contains("氧气是末端电子受体"))
    }

    @MainActor
    func testReviewAdviceIsConnectedOnStartupAndDoesNotReplaceNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoLearningTests-\(UUID())")
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false)
        let model = AppModel(reviewQueue: queue)
        XCTAssertNotNil(queue.onUpdate)
        queue.onUpdate?(root, "旧录音建议", "复查完成")
        XCTAssertEqual(model.reviewAdvice, "")
        XCTAssertEqual(model.lectureSummary, "")
    }

    func testReviewConcurrencyUsesMeasuredLatencyRatherThanChipName() {
        var policy = ReviewConcurrencyPolicy()
        XCTAssertFalse(policy.allows(mode: .highQuality))
        for _ in 0..<3 { policy.observe(elapsed: 2, successful: true) }
        XCTAssertTrue(policy.allows(mode: .automatic))
        XCTAssertTrue(policy.allows(mode: .highQuality))
        XCTAssertFalse(policy.allows(mode: .energySaver))
        policy.observe(elapsed: 6, successful: true)
        XCTAssertFalse(policy.allows(mode: .highQuality))
        for _ in 0..<3 { policy.observe(elapsed: 1, successful: true) }
        XCTAssertTrue(policy.allows(mode: .automatic))
        policy.observe(elapsed: 0, successful: false)
        XCTAssertFalse(policy.allows(mode: .automatic))
    }

    func testThinkingContinuationRetainsWirePrefixButHidesReasoning() throws {
        var stream = QwenCompletionStreamState(thinking: true, initialText: "Checking charge </thi")
        _ = try stream.consume(#"{"choices":[{"text":"nk>\n{\"corrections\":[]}","finish_reason":"stop"}]}"#)
        _ = try stream.consume("[DONE]")
        XCTAssertTrue(stream.wireText.hasPrefix("Checking charge </think>"))
        XCTAssertEqual(try stream.result(), #"{"corrections":[]}"#)
        var afterReasoning = QwenCompletionStreamState(thinking: true, initialText: "Checking </think>\n{\"corrections\":")
        _ = try afterReasoning.consume(#"{"choices":[{"text":"[]}","finish_reason":"stop"}]}"#)
        _ = try afterReasoning.consume("[DONE]")
        XCTAssertEqual(try afterReasoning.result(), #"{"corrections":[]}"#)
    }

    func testReasoningLimitCanBeClosedWithoutAcceptingTruncatedFinalAnswer() throws {
        var thinking = QwenCompletionStreamState(thinking: true, allowContinuationAtLimit: true)
        _ = try thinking.consume(#"{"choices":[{"text":"Checked each point","finish_reason":"length"}]}"#)
        _ = try thinking.consume("[DONE]")
        XCTAssertThrowsError(try thinking.result()) { error in
            XCTAssertEqual((error as? QwenCompletionLimit)?.prefix, "Checked each point")
        }
        var final = QwenCompletionStreamState(thinking: true, initialText: "Checked </think>\n", allowContinuationAtLimit: true)
        _ = try final.consume(#"{"choices":[{"text":"{\"corrections\":","finish_reason":"length"}]}"#)
        _ = try final.consume("[DONE]")
        XCTAssertThrowsError(try final.result()) { error in XCTAssertNotNil(error as? QwenCompletionLimit) }
    }

    @MainActor
    func testReviewQueuePauseSleepRecordingAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoLearningTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("journal.json")
        let savedNotes = root.appendingPathComponent("summary-zh-Hans.md")
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        try (book.markdown() + "\n").write(to: savedNotes, atomically: true, encoding: .utf8)
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, _, update in
            await update("Checking atoms ")
            try await Task.sleep(for: .seconds(60))
            return #"{"corrections":[]}"#
        }
        queue.setContext(recording: true, concurrent: false, resourcesAvailable: true)
        try queue.enqueue(directory: root, notebook: book)
        XCTAssertFalse(queue.running)
        queue.setContext(recording: true, concurrent: true, resourcesAvailable: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(queue.running)
        queue.setSleeping(true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(queue.running)
        let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertEqual(saved.jobs[0].prefix, "Checking atoms ")
        queue.togglePause()
        queue.setSleeping(false)
        XCTAssertTrue(queue.userPaused)
        XCTAssertFalse(queue.running)
        let restored = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, prefix, _ in
            guard prefix == "Checking atoms " else { throw QwenRuntimeError.invalidResponse }
            return #"{"corrections":[{"index":0,"original":"原笔记","kind":"核心结论","text":"修正后的笔记","reason":"纠正术语"}]}"#
        }
        XCTAssertTrue(restored.userPaused)
        restored.togglePause()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(restored.hasWork)
        XCTAssertEqual(try String(contentsOf: savedNotes, encoding: .utf8), book.markdown() + "\n")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("summary-review.md"), encoding: .utf8).contains("修正后的笔记"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("summary-before-review.md"), encoding: .utf8).contains("原笔记"))
    }

    @MainActor
    func testInterruptedReviewPreservesPrefixAcrossQueueRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoLearningTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("journal.json")
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, _, update in
            await update("Retained thinking ")
            throw QwenRuntimeError.generationInterrupted("worker exited")
        }
        try queue.enqueue(directory: root, notebook: book)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(queue.running)
        let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertEqual(saved.jobs.first?.prefix, "Retained thinking ")
        let restored = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, prefix, _ in
            XCTAssertEqual(prefix, "Retained thinking ")
            return #"{"corrections":[]}"#
        }
        restored.togglePause()
        if restored.userPaused { restored.togglePause() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(restored.hasWork)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("summary-review.md"), encoding: .utf8).contains("没有提出复查建议"))
    }

    @MainActor
    func testBackgroundReviewDoesNotOverwriteExternalNoteEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoLearningTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false) { _, _, _ in #"{"corrections":[]}"# }
        queue.togglePause()
        try queue.enqueue(directory: root, notebook: book)
        let file = root.appendingPathComponent("summary-zh-Hans.md")
        try "人工补充的内容\n".write(to: file, atomically: true, encoding: .utf8)
        queue.togglePause()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "人工补充的内容\n")
        XCTAssertTrue(queue.hasWork)
        XCTAssertFalse(queue.running)
        XCTAssertTrue(queue.status.contains("其他地方修改"))
    }

    func testLearningNotebookPreservesOldTopicsAndInvalidatesOnlyTheirEvidence() throws {
        let a = TranscriptSegment(startTime: 0, endTime: 8, english: "Atoms", chinese: "原子")
        let b = TranscriptSegment(startTime: 8, endTime: 16, english: "Balance", chinese: "配平")
        var book = LearningNotebook()
        try book.append(evidence: [a], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "先前的事实")]))
        try book.append(evidence: [b], note: .init(topic: "配平", points: [.init(kind: "例子", text: "新的例子")]))
        XCTAssertTrue(book.markdown().contains("先前的事实"))
        XCTAssertFalse(book.markdown(covering: [b.id]).contains("先前的事实"))
        XCTAssertTrue(book.markdown(covering: [b.id]).contains("新的例子"))
        XCTAssertThrowsError(try book.append(evidence: [a], note: book.batches[0].note))
        XCTAssertEqual(book.invalidate(a.id), [a.id])
        XCTAssertEqual(book.batches.count, 1)
        XCTAssertTrue(book.markdown().contains("新的例子"))
    }

    func testLearningReviewIsAtomicAndCannotRemoveOrAddressOtherPoints() throws {
        let segment = TranscriptSegment(startTime: 0, endTime: 8, english: "Cu(OH)2")
        var book = LearningNotebook()
        let note = LearningNote(topic: "化学式", points: [.init(kind: "例子", text: "待修正"), .init(kind: "核心结论", text: "保留的事实")])
        try book.append(evidence: [segment], note: note)
        let id = book.batches[0].id
        let bad = #"{"corrections":[{"index":0,"original":"待修正","kind":"例子","text":"修改","reason":"修正"},{"index":99,"original":"待修正","kind":"例子","text":"越界","reason":"错误"}]}"#
        XCTAssertThrowsError(try book.review(batchID: id, response: bad))
        XCTAssertEqual(book.batches[0].note, note)
        let wrongTarget = #"{"corrections":[{"index":1,"original":"待修正","kind":"例子","text":"错误目标","reason":"编号错位"}]}"#
        XCTAssertThrowsError(try book.review(batchID: id, response: wrongTarget))
        XCTAssertEqual(book.batches[0].note, note)
        let good = #"{"corrections":[{"index":0,"original":"待修正","kind":"例子","text":"Cu(OH)₂ 含两个氧原子","reason":"修正原子计数"}]}"#
        _ = try book.review(batchID: id, response: good)
        XCTAssertEqual(book.batches[0].note.points[1].text, "保留的事实")
        XCTAssertEqual(book.batches[0].note.points.count, 2)
    }

    func testLearningDraftRequiresIdenticalEvidenceAndModel() throws {
        let a = TranscriptSegment(startTime: 0, endTime: 8, english: "one", chinese: "一")
        var b = a
        b.chinese = "已校正"
        let draft = LearningDraft(evidence: [a], model: "4b", input: "frozen", text: "partial ")
        XCTAssertTrue(draft.matches(evidence: [a], model: "4b"))
        XCTAssertFalse(draft.matches(evidence: [b], model: "4b"))
        XCTAssertFalse(draft.matches(evidence: [a], model: "9b"))
    }

    func testContinuationPreservesWhitespaceAndCanFinishImmediately() throws {
        var first = QwenCompletionStreamState()
        _ = try first.consume(#"{"choices":[{"text":"{\"topic\":\"a ","finish_reason":null}]}"#)
        XCTAssertTrue(first.rawText.hasSuffix(" "))
        var resumed = QwenCompletionStreamState(initialText: first.rawText)
        _ = try resumed.consume(#"{"choices":[{"text":"b\",\"points\":[{\"kind\":\"例子\",\"text\":\"ok\"}]}","finish_reason":"stop"}]}"#)
        _ = try resumed.consume("[DONE]")
        XCTAssertEqual(try LearningNote.decode(resumed.result()).topic, "a b")
        var finished = QwenCompletionStreamState(initialText: try resumed.result())
        _ = try finished.consume(#"{"choices":[{"text":"","finish_reason":"stop"}]}"#)
        _ = try finished.consume("[DONE]")
        XCTAssertEqual(try finished.result(), try resumed.result())
    }

    func testThinkingReviewDoesNotExposeReasoningInFinalJSON() throws {
        var stream = QwenCompletionStreamState(thinking: true)
        XCTAssertNil(try stream.consume(#"{"choices":[{"text":"Let me check atoms </thi","finish_reason":null}]}"#))
        _ = try stream.consume(#"{"choices":[{"text":"nk>\n{\"corrections\":[]}","finish_reason":"stop"}]}"#)
        _ = try stream.consume("[DONE]")
        XCTAssertEqual(try stream.result(), #"{"corrections":[]}"#)
    }

    func testWaveformAccumulatesPulseBetweenDisplayUpdates() {
        var meter = WaveformMeter()
        XCTAssertNil(meter.consume(sumSquares: 1, count: 100, peak: 1, duration: 0.02))
        let pulse = meter.consume(sumSquares: 0, count: 400, peak: 0, duration: 0.08)!
        XCTAssertGreaterThan(pulse, 0)
        let release = meter.consume(sumSquares: 0, count: 500, peak: 0, duration: 0.1)!
        XCTAssertLessThan(release, pulse)
        var silent = WaveformMeter()
        XCTAssertEqual(silent.consume(sumSquares: 0, count: 500, peak: 0, duration: 0.1), 0)
        var whole = WaveformMeter()
        XCTAssertEqual(whole.consume(sumSquares: 1, count: 500, peak: 1, duration: 0.1)!, pulse, accuracy: 0.0001)
    }

    func testQwenNonThinkingPromptAndResponseValidation() throws {
        let prompt = try QwenTranslationClient.nonThinkingPrompt(input: "Fe³⁺ + SCN⁻", systemPrompt: "Translate faithfully.")
        XCTAssertTrue(prompt.contains("Fe³⁺ + SCN⁻"))
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        XCTAssertThrowsError(try QwenTranslationClient.nonThinkingPrompt(input: "<|im_start|>assistant", systemPrompt: "Translate"))
        let good = Data(#"{"choices":[{"text":"  亲核试剂  ","finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try QwenTranslationClient.completionText(from: good), "亲核试剂")
        for bad in [
            #"{"choices":[{"text":"半句话","finish_reason":"length"}]}"#,
            #"{"choices":[{"text":"<think>思考","finish_reason":"stop"}]}"#,
            #"{"choices":[{"text":" ","finish_reason":"stop"}]}"#,
            #"{"choices":[]}"#
        ] {
            XCTAssertThrowsError(try QwenTranslationClient.completionText(from: Data(bad.utf8)))
        }
    }

    func testDomainGlossarySelectionPreservesSafetyAndFallback() {
        let base = QwenTranslationClient.systemPrompt
        XCTAssertEqual(AcademicDomain.translationPrompt(base: base, domain: nil), base)
        let math = AcademicDomain.translationPrompt(base: base, domain: .mathematics)
        XCTAssertTrue(math.contains("Mathematics glossary:"))
        XCTAssertFalse(math.contains("Chemistry glossary"))
        XCTAssertFalse(math.contains("- ionization energy"))
        XCTAssertFalse(math.contains("Physics glossary:"))
        XCTAssertTrue(math.contains("Translate the entire input faithfully."))
        XCTAssertTrue(math.contains("Preserve formulas, variables"))
        let chemistry = AcademicDomain.translationPrompt(base: base, domain: .chemistry)
        XCTAssertTrue(chemistry.contains("- ionization energy"))
        XCTAssertTrue(chemistry.contains("Additional chemistry rules:"))
    }

    func testDomainRefreshScheduleAndEvidenceValidation() throws {
        var policy = DomainRefreshPolicy()
        XCTAssertFalse(policy.reserve(at: 59))
        XCTAssertTrue(policy.reserve(at: 60))
        XCTAssertFalse(policy.reserve(at: 60))
        XCTAssertEqual(policy.nextDue, 240)
        XCTAssertTrue(policy.reserve(at: 240))
        XCTAssertEqual(policy.nextDue, 420)
        XCTAssertTrue(policy.reserve(at: 900))
        XCTAssertEqual(policy.nextDue, 960)
        XCTAssertThrowsError(try DomainModelResult.parse("{\"domain\":\"physics\",\"evidence\":[\"invented\"]}", transcript: "velocity"))
        let value = try DomainModelResult.parse("{\"domain\":\"physics\",\"evidence\":[\"velocity\"]}", transcript: "velocity")
        XCTAssertEqual(value.academicDomain, .physics)
    }

    func testCapturePauseDoesNotAdvanceBoundaryAndFinishDoesNotDuplicate() {
        var policy = CausalBoundaryPolicy()
        XCTAssertNil(policy.decision(at: 4))
        XCTAssertNil(policy.decision(at: 4))
        XCTAssertEqual(policy.finish(at: 4)?.end, 4)
        XCTAssertNil(policy.finish(at: 4))
    }

    func testStaleSilenceCannotCommitNewSpeech() {
        var policy = CausalBoundaryPolicy()
        policy.observeActivity(speech: true, start: 0, end: 1)
        policy.observeActivity(speech: false, start: 1, end: 2)
        policy.observePreview(text: "Sentence.", start: 0, end: 1, arrival: 1.2)
        XCTAssertNil(policy.decision(at: 3))
        XCTAssertEqual(policy.decision(at: 10)?.reason, "maximum_wait")
    }

    func testApproachingLimitUsesFreshPauseWithoutPreviewPunctuation() {
        var policy = CausalBoundaryPolicy()
        policy.observeActivity(speech: true, start: 0, end: 7.5)
        policy.observeActivity(speech: false, start: 7.5, end: 8)
        XCTAssertNil(policy.decision(at: 7.9))
        XCTAssertEqual(policy.decision(at: 8)?.reason, "approaching_limit_pause")
        XCTAssertNil(policy.decision(at: 8.1))
        var stale = CausalBoundaryPolicy()
        stale.observeActivity(speech: true, start: 0, end: 6)
        stale.observeActivity(speech: false, start: 6, end: 7)
        XCTAssertNil(stale.decision(at: 8))
    }

    func testSummaryRepairRemovesWholeAffectedBatchOnly() {
        let a = UUID(), b = UUID(), c = UUID()
        let old = SummaryEvidenceBatch(ids: [a, b], text: "old claim")
        let keep = SummaryEvidenceBatch(ids: [c], text: "unrelated fact")
        let repair = SummaryEvidenceBatch.invalidating(b, in: [old, keep])
        XCTAssertEqual(repair.invalidated, [a, b])
        XCTAssertEqual(repair.remaining, [keep])
        XCTAssertEqual(SummaryEvidenceBatch.invalidating(UUID(), in: [keep]).remaining, [keep])
    }

    func testOrphanStartingLineRequiresExplicitContinuation() {
        let previous = "A student returns to the starting position."
        XCTAssertEqual(QwenTranslationClient.boundaryTranslationTarget("Line has traveled a non-zero distance", previous: previous), "has traveled a non-zero distance")
        XCTAssertEqual(QwenTranslationClient.boundaryTranslationTarget("Line has traveled", previous: "We draw a line."), "Line has traveled")
        XCTAssertEqual(QwenTranslationClient.boundaryTranslationTarget("Line graphs show speed.", previous: previous), "Line graphs show speed.")
    }

    func testRepairPreservesEarlierSentencePrefix() {
        XCTAssertEqual(QwenTranslationClient.stableTranslationPrefix("距离是路程。学生返回起点。"), "距离是路程。")
        XCTAssertEqual(QwenTranslationClient.stableTranslationPrefix("距离是路程。学生返回"), "距离是路程。")
        XCTAssertEqual(QwenTranslationClient.stableTranslationPrefix("学生返回起点。"), "")
    }

    func testFrozenBoundaryConstants() {
        let value = CausalBoundaryConfiguration()
        XCTAssertEqual(value.minimumDuration, 2)
        XCTAssertEqual(value.clauseSearchDuration, 6)
        XCTAssertEqual(value.maximumDuration, 10)
        XCTAssertEqual(value.pauseDuration, 0.5)
        XCTAssertEqual(value.previewStabilityDuration, 0.3)
        XCTAssertEqual(value.activityFreshnessDuration, 0.35)
        XCTAssertEqual(value.boundarySlackDuration, 0.15)
        XCTAssertEqual(value.policyVersion, "causal-pause-boundary-dev-v1")
    }

    func testStableSentenceAndCoveredPauseCommitEarly() {
        var policy = CausalBoundaryPolicy()
        policy.observeActivity(speech: true, start: 0, end: 0.5)
        policy.observePreview(text: "This is complete.", start: 0, end: 1.5, arrival: 1.6)
        policy.observeActivity(speech: false, start: 1.5, end: 1.75)
        policy.observeActivity(speech: false, start: 1.75, end: 2.0)
        policy.observeActivity(speech: false, start: 2.0, end: 2.25)

        XCTAssertEqual(
            policy.decision(at: 2.25),
            CausalBoundaryDecision(start: 0, end: 2.25, reason: "stable_sentence_pause")
        )
    }

    func testCommaRequiresClauseSearchDuration() {
        var policy = CausalBoundaryPolicy()
        policy.observeActivity(speech: true, start: 0, end: 5.0)
        policy.observePreview(text: "A useful clause,", start: 4.0, end: 5.25, arrival: 5.3)
        policy.observeActivity(speech: false, start: 5.25, end: 5.5)
        policy.observeActivity(speech: false, start: 5.5, end: 5.75)
        XCTAssertNil(policy.decision(at: 5.75))
        policy.observeActivity(speech: false, start: 5.75, end: 6.0)
        policy.observeActivity(speech: false, start: 6.0, end: 6.25)
        XCTAssertEqual(policy.decision(at: 6.25)?.reason, "stable_clause_pause")
    }

    func testMaximumWaitDoesNotNeedClassifierEvidence() {
        var policy = CausalBoundaryPolicy()
        XCTAssertNil(policy.decision(at: 9.99))
        XCTAssertEqual(
            policy.decision(at: 10.01),
            CausalBoundaryDecision(start: 0, end: 10.01, reason: "maximum_wait")
        )
    }

    func testSummaryConcurrencyUsesPowerPressureAndHysteresis() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        for lowPower in [false, true] {
            for normalPressure in [false, true] {
                for enabled in [false, true] {
                    for available: UInt64 in [0, 3, 4, 7, 8, 16] {
                        XCTAssertEqual(SummaryResourcePolicy.allowsConcurrency(
                            lowPower: lowPower, pressureNormal: normalPressure,
                            availableBytes: available * gib, alreadyEnabled: enabled
                        ), normalPressure && available >= (enabled ? 4 : 8))
                    }
                }
            }
        }
        XCTAssertEqual(SummaryRefreshPolicy.delay(now: 100, lastCaptionActivity: 100,
                                                 lastCycleStarted: nil, allowConcurrent: true), 0)
    }

    func testSummaryYieldsOnlyForSignificantCaptionBacklog() {
        XCTAssertFalse(SummaryRefreshPolicy.shouldYieldToCaptions(now: 100, pendingCount: 0, oldestEnqueuedAt: 0))
        XCTAssertFalse(SummaryRefreshPolicy.shouldYieldToCaptions(now: 100, pendingCount: 1, oldestEnqueuedAt: 100))
        XCTAssertFalse(SummaryRefreshPolicy.shouldYieldToCaptions(now: 100, pendingCount: 2, oldestEnqueuedAt: 92.01))
        XCTAssertTrue(SummaryRefreshPolicy.shouldYieldToCaptions(now: 100, pendingCount: 3, oldestEnqueuedAt: 100))
        XCTAssertTrue(SummaryRefreshPolicy.shouldYieldToCaptions(now: 100, pendingCount: 1, oldestEnqueuedAt: 92))
    }

    func testIncrementalSummaryKeepsOldestPendingAndRetriesUncommittedBatch() {
        let a = TranscriptSegment(startTime: 0, endTime: 10, english: "First fact.", chinese: "第一点。")
        let b = TranscriptSegment(startTime: 10, endTime: 20, english: "Second fact.", chinese: "第二点。")
        let first = LectureSummaryInput.incremental(from: [a, b], coveredIDs: [], previousSummary: "", maximumCharacters: 1)
        XCTAssertEqual(first.segmentIDs, [a.id])
        XCTAssertEqual(LectureSummaryInput.incremental(from: [a, b], coveredIDs: [], previousSummary: "", maximumCharacters: 1).segmentIDs, first.segmentIDs)
        let next = LectureSummaryInput.incremental(from: [a, b], coveredIDs: first.segmentIDs, previousSummary: "第一点。")
        XCTAssertEqual(next.segmentIDs, [b.id])
        XCTAssertTrue(next.text.contains("第一点。"))
        XCTAssertFalse(next.text.contains(a.english))
        XCTAssertTrue(next.text.contains(b.english))
        XCTAssertTrue(LectureSummaryInput.incremental(from: [a, b], coveredIDs: [a.id,b.id], previousSummary: "done").text.isEmpty)
    }

    func testSummaryDelayRequiresTranslationIdleAndThreeMinuteSpacing() {
        XCTAssertEqual(
            SummaryRefreshPolicy.delay(
                now: 100,
                lastCaptionActivity: 99,
                lastCycleStarted: 80
            ),
            160
        )
        XCTAssertEqual(
            SummaryRefreshPolicy.delay(
                now: 100,
                lastCaptionActivity: 99.5,
                lastCycleStarted: nil
            ),
            1.5
        )
        XCTAssertEqual(
            SummaryRefreshPolicy.delay(
                now: 180,
                lastCaptionActivity: 90,
                lastCycleStarted: 0
            ),
            0
        )
    }

    func testSystemSpeechClassifierProducesStreamingObservations() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        let detector = SpeechActivityDetector()
        let observation = expectation(description: "SoundAnalysis observation")
        observation.assertForOverFulfill = false
        try detector.start(format: format) { _ in observation.fulfill() }
        defer { detector.finish() }

        for _ in 0..<8 {
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)
            )
            buffer.frameLength = 8_000
            if let channel = buffer.floatChannelData?[0] {
                for frame in 0..<Int(buffer.frameLength) {
                    channel[frame] = Float(sin(Double(frame) * 2 * .pi * 220 / 16_000) * 0.05)
                }
            }
            detector.analyze(buffer)
        }

        wait(for: [observation], timeout: 5)
    }
}
