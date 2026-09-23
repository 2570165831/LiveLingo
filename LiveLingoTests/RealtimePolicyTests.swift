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
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"), observeSleep: false) { _, _, _, _ in throw CancellationError() }
        addTeardownBlock { await queue.shutdownForTesting() }
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
        XCTAssertTrue(followUps.isEmpty)
        XCTAssertNil(LearningNotebook.sourceCheckReason(book.batches[0].note.points[1]))
        XCTAssertFalse(book.markdown().contains("来源检查"))
        // Explicit uncertainty retains the source and the actionable question.
        let unclear = TranscriptSegment(startTime: 2, endTime: 3, english: "Its speed is unknown.")
        try book.append(evidence: [unclear], note: .init(topic: "速度", points: [
            .init(kind: "待确认", text: "速度归属未明。", needsContext: "这项速度属于哪个对象？",
                  sourceIDs: ["en0s0"])
        ], sourceVersion: 2))
        XCTAssertEqual(book.selectPendingPoints(for: [unclear]).count, 1)
        XCTAssertTrue(book.markdown().contains("需要回听"))
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
        var snapshot = SessionSnapshot(segments: [earlier, current])
        book.writeState(to: &snapshot)
        var draft = LearningDraft(evidence: [current], model: "4b", input: "frozen", text: "partial",
                                  contextRevision: book.revision, dependencyIDs: [earlier.id, current.id])
        draft.freezeBinding(sessionID: snapshot.sessionID, inputRevision: 0, generation: 0)
        XCTAssertTrue(book.invalidate(UUID()).isEmpty)
        XCTAssertTrue(draft.matches(snapshot: snapshot, model: "4b"))
        snapshot.segments.append(.init(startTime: 2, endTime: 3, english: "A new caption arrives."))
        XCTAssertTrue(draft.matches(snapshot: snapshot, model: "4b"))
        XCTAssertEqual(book.invalidate(earlier.id), [earlier.id])
        let revised = TranscriptSegment(id: earlier.id, startTime: earlier.startTime,
            endTime: earlier.endTime, english: "The earlier source has changed.", inputRevision: 1)
        snapshot.segments[0] = revised
        snapshot.inputRevision = 1
        snapshot.revisionHistory.append(.init(fromRevision: 0, toRevision: 1,
            previousSegment: earlier, replacementSegment: revised, reason: "test source correction"))
        XCTAssertFalse(draft.matches(snapshot: snapshot, model: "4b"))
        XCTAssertEqual(draft.text, "partial")
    }

    func testReviewCanSeeLaterOriginalClarificationWithoutModelLinkAndKeepsTimeOrder() throws {
        var book = LearningNotebook()
        for text in ["Its concentration is 0.4 mol/L.", "The concentration of 0.4 mol/L belongs to N.", "After dilution, N has concentration 0.2 mol/L."] {
            try book.append(evidence: [.init(startTime: 0, endTime: 1, english: text)], note: .init(topic: "浓度", points: [.init(kind: "核心结论", text: "测试笔记", sourceIDs: ["en0s0"])], sourceVersion: 2))
        }
        let before = book.batches
        let data = Data(try LearningPrompts.reviewInput(book.batches[0], laterBatches: Array(book.batches.dropFirst())).json.utf8)
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
        let data = Data(try LearningPrompts.reviewInput(batch, laterBatches: [later]).json.utf8)
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
        // Retiring a source preserves the historical link and all later facts.
        // The missing target is rendered independently instead of rewriting
        // immutable note provenance.
        XCTAssertTrue(book.batches.flatMap { $0.note.points }.allSatisfy { $0.clarifies == target })
        for text in ["湿度为 8%。", "B 的速度为 8 m/s。", "A 的速度为 10 m/s。"] {
            XCTAssertTrue(book.markdown().contains(text))
        }
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
        // 2026-09-20：来源元数据坏掉仍然只是"来源没链接上" ✓，不改写、不丢弃知识 ✓。
        XCTAssertEqual(result.points[0].referenceState, .unlinked)
        // 正文不再逐条挂"来源待核对"这类状态串 ✗；知识本身照旧保留 ✓，
        // 风险改由笔记本的 `## 来源检查` 集中给出 ✓，并且必须带**实际时间范围** ✓
        // （否则用户只能全课重听 ✗）。
        XCTAssertFalse(result.markdown.contains("来源待核对"))
        XCTAssertTrue(result.markdown.contains("质量保持不变。"))
        XCTAssertFalse(result.markdown.contains("归属待确认"))
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "The mass stays the same.")], note: note)
        let rendered = book.markdown()
        XCTAssertTrue(rendered.contains("质量保持不变。"))
        XCTAssertFalse(rendered.contains("来源待核对"))
        XCTAssertTrue(rendered.contains("## 来源检查"))
        XCTAssertTrue(rendered.contains("- [00:00–00:08] 来源未链接到原文，无法核对出处：质量保持不变。"))
        let legacy = try LearningNote.decode(#"{"topic":"质量","points":[{"kind":"核心结论","text":"质量保持不变。"}]}"#)
        XCTAssertEqual(legacy.binding(evidence: []), legacy)
    }

    /// 2026-09-20 设计 §2.2：正文按主题组织 ✓，不再逐条带"待核实"状态串 ✗；
    /// 真正的缺口（`待确认`／`needsContext`）进 `## 需要回听` ✓，
    /// 来源校验风险（unlinked／数值差异）进 `## 来源检查` ✓，两者都必须带实际时间范围 ✓。
    func testNotesBodyIsTopicOrganisedWithoutPerPointVerificationTags() throws {
        var book = LearningNotebook()
        // 第 1 批 0–8s：普通链接／易错点／后文待确认／待确认／数值差异／无来源补充理解。
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "The mass of cart A is 2 kg.", chinese: "小车 A 的质量为 2 kg。")],
                        note: .init(topic: "结构", points: [
                            .init(kind: "核心结论", text: "小车 A 的质量为 2 kg。",
                                  sources: [.init(index: 0, quote: "The mass of cart A is 2 kg.")]),
                            .init(kind: "易错点", text: "质量单位必须与题目一致。",
                                  sources: [.init(index: 0, quote: "The mass of cart A is 2 kg.")]),
                            .init(kind: "核心结论", text: "速度与质量都来自同一辆小车。",
                                  sources: [.init(index: 0, quote: "The mass of cart A is 2 kg.")],
                                  needsContext: "这项数据属于哪辆小车？"),
                            .init(kind: "待确认", text: "来源归属尚未明确。",
                                  sources: [.init(index: 0, quote: "The mass of cart A is 2 kg.")],
                                  needsContext: "原文有没有交代质量属于哪辆车？"),
                            .init(kind: "核心结论", text: "小车 A 的质量为 4 kg。",
                                  sources: [.init(index: 0, quote: "The mass of cart A is 2 kg.")]),
                            .init(kind: "补充理解", text: "质量与重量的区别常被混淆。", sources: [])
                        ], sourceVersion: 1))
        // 第 2 批 600–640s：同一主题 → 正文合成一个 `## 结构`；另加一句"课程安排"触发最后一节。
        try book.append(evidence: [
            .init(startTime: 600, endTime: 620, english: "Cart B has a mass of 3 kg.", chinese: "小车 B 的质量为 3 kg。"),
            .init(startTime: 620, endTime: 640, english: "The assignment is due on Friday.", chinese: "作业周五截止。")
        ], note: .init(topic: "结构", points: [
            .init(kind: "核心结论", text: "本批结论仍需对照原文。",
                  sources: [.init(index: 99, quote: "不存在的引用")])
        ], sourceVersion: 1))
        XCTAssertEqual(book.batches[0].note.points.map(\.referenceState),
                       [.linked, .linked, .awaitingContext, .awaitingContext, .numericDifference, nil])
        XCTAssertEqual(book.batches[1].note.points.map(\.referenceState), [.unlinked])

        let rendered = book.markdown()
        // 两个小标题都恰好出现一次，才能安全地按标题切出"正文／需要回听／来源检查"三段。
        let replayParts = rendered.components(separatedBy: "## 需要回听")
        let checkParts = rendered.components(separatedBy: "## 来源检查")
        XCTAssertEqual(replayParts.count, 2)
        XCTAssertEqual(checkParts.count, 2)
        let body = replayParts[0]
        XCTAssertTrue(body.contains("## 结构"))
        for text in ["小车 A 的质量为 2 kg。", "质量单位必须与题目一致。",
                     "小车 A 的质量为 4 kg。", "质量与重量的区别常被混淆。", "本批结论仍需对照原文。"] {
            XCTAssertTrue(body.contains(text), "正文应保留要点文本：\(text)")
        }
        XCTAssertFalse(body.contains("来源归属尚未明确。"))
        XCTAssertFalse(body.contains("速度与质量都来自同一辆小车。"))
        let replayOnly = replayParts[1].components(separatedBy: "## 来源检查")[0]
        XCTAssertTrue(replayOnly.contains("来源归属尚未明确。"))
        XCTAssertTrue(replayOnly.contains("速度与质量都来自同一辆小车。"))
        XCTAssertEqual(rendered.components(separatedBy: "来源归属尚未明确。").count - 1, 1)
        XCTAssertFalse(body.contains("**核心结论**"), "默认 kind 不再逐条重复标签")
        XCTAssertTrue(body.contains("- **易错点**：质量单位必须与题目一致。"))
        XCTAssertTrue(body.contains("- **补充理解**：质量与重量的区别常被混淆。"))
        for tag in ["来源待核对", "待后文补充", "引用数值待核对", "关系待核对"] {
            XCTAssertFalse(rendered.contains(tag), "正文不再出现逐条状态串：\(tag)")
        }

        // 「需要回听」在「来源检查」之前，所以正文 + 回听 = 来源检查标题之前的全部内容。
        let replay = checkParts.count > 1 ? checkParts[0] : rendered
        XCTAssertTrue(replay.contains("## 需要回听"))
        XCTAssertTrue(replay.contains("- [00:00–00:08] 这项数据属于哪辆小车？"))
        XCTAssertTrue(replay.contains("- [00:00–00:08] 原文有没有交代质量属于哪辆车？"))
        // 需要回听只给"具体问题 + 实际时间范围"，正文那条要点不在这里重复 ✓。
        XCTAssertFalse(replay.contains("相关要点："), "正文要点不在需要回听里重复")

        let checks = checkParts.count > 1 ? checkParts[1] : ""
        XCTAssertTrue(checks.contains("- [00:00–00:08] 笔记数值与引用原文不同，可能是换算或推导，需要人工核对：小车 A 的质量为 4 kg。"))
        XCTAssertTrue(checks.contains("- [10:00–10:40] 来源未链接到原文，无法核对出处：本批结论仍需对照原文。"))
        XCTAssertFalse(checks.contains("质量单位必须与题目一致。"), "已链接且不含指代的要点不进「来源检查」")

        let topic = try XCTUnwrap(rendered.range(of: "## 结构"))
        let replayHeading = try XCTUnwrap(rendered.range(of: "## 需要回听"))
        let checkHeading = try XCTUnwrap(rendered.range(of: "## 来源检查"))
        let logistics = try XCTUnwrap(rendered.range(of: "## 课程安排与待办"))
        XCTAssertLessThan(topic.lowerBound, replayHeading.lowerBound)
        XCTAssertLessThan(replayHeading.lowerBound, checkHeading.lowerBound)
        XCTAssertLessThan(checkHeading.lowerBound, logistics.lowerBound)
        XCTAssertTrue(rendered.contains("The assignment is due on Friday."))
    }

    /// 没有缺口、没有来源风险时，这两节必须整节消失 ✓（不是留一个空标题 ✗）。
    func testNotesOmitEmptyProblemSections() throws {
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Cart A has a mass of 2 kg.", chinese: "小车 A 的质量为 2 kg。")],
                        note: .init(topic: "结构", points: [
                            .init(kind: "核心结论", text: "小车 A 的质量为 2 kg。",
                                  sources: [.init(index: 0, quote: "Cart A has a mass of 2 kg.")]),
                            .init(kind: "例子", text: "同一辆小车在不同题目里质量一致。",
                                  sources: [.init(index: 0, quote: "Cart A has a mass of 2 kg.")])
                        ], sourceVersion: 1))
        XCTAssertEqual(book.batches[0].note.points.map(\.referenceState), [.linked, .linked])
        let rendered = book.markdown()
        XCTAssertTrue(rendered.contains("## 结构"))
        XCTAssertTrue(rendered.contains("小车 A 的质量为 2 kg。"))
        XCTAssertFalse(rendered.contains("## 需要回听"))
        XCTAssertFalse(rendered.contains("## 来源检查"))
    }

    /// 2026-09-20 设计 §1.1：局部复查只写自己的 `summary-review-batch-N.md` ✓，
    /// 整课报告 `summary-review.md` 与 `summary-before-review.md` 一字不动 ✓。
    @MainActor
    func testScopedReviewWritesItsOwnReportAndNeverOverwritesWholeLessonReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LLScopedReview-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")],
                        note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原子事实")]))
        try book.append(evidence: [.init(startTime: 600, endTime: 640, english: "Ions")],
                        note: .init(topic: "离子", points: [.init(kind: "核心结论", text: "离子事实")]))
        try (book.markdown() + "\n").write(to: root.appendingPathComponent("summary-zh-Hans.md"), atomically: true, encoding: .utf8)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false,
                                        diagnostics: .disabled) { _, _, _, _ in
            #"{"corrections":[],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await queue.shutdownForTesting() }

        try queue.enqueue(directory: root, notebook: book)
        for _ in 0..<300 where queue.hasWork { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.hasWork, "整课复查未在 3 秒内跑完：\(queue.status)")
        let wholeURL = root.appendingPathComponent("summary-review.md")
        let whole = try Data(contentsOf: wholeURL)
        let wholeText = try XCTUnwrap(String(data: whole, encoding: .utf8))
        XCTAssertTrue(wholeText.contains("## 第 1 批"))
        XCTAssertTrue(wholeText.contains("## 第 2 批"))
        let beforeReview = try Data(contentsOf: root.appendingPathComponent("summary-before-review.md"))

        try queue.enqueue(directory: root, notebook: book, scope: .batch(1))
        for _ in 0..<300 where queue.hasWork { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.hasWork, "局部复查未在 3 秒内跑完：\(queue.status)")
        let scoped = try String(contentsOf: root.appendingPathComponent("summary-review-batch-1.md"), encoding: .utf8)
        XCTAssertTrue(scoped.contains("第 1 批（局部）"))
        XCTAssertTrue(scoped.contains("不是整课结论"))
        XCTAssertEqual(try Data(contentsOf: wholeURL), whole, "局部复查不得覆盖整课报告")
        let kept = try String(contentsOf: wholeURL, encoding: .utf8)
        XCTAssertTrue(kept.contains("## 第 1 批"))
        XCTAssertTrue(kept.contains("## 第 2 批"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("summary-before-review.md")), beforeReview,
                       "summary-before-review.md 只由整课复查写一次")
        XCTAssertThrowsError(try queue.enqueue(directory: root, notebook: book, scope: .batch(9)),
                             "越界的批次号必须立刻报错，不能排一个空任务")
    }

    /// 2026-09-20 设计 §1.2：整课报告缺失时，导出退回同目录的局部报告 ✓，
    /// 明确标注"不是整课复查" ✓；整课报告一旦存在就优先 ✓；两份都没有仍然是 nil ✓。
    @MainActor
    func testScopedReportSurfacesInExportWhenWholeReportIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LLScopedExport-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false,
                                        diagnostics: .disabled) { _, _, _, _ in throw CancellationError() }
        addTeardownBlock { await queue.shutdownForTesting() }
        XCTAssertNil(try ReviewExportSource.markdown(for: root, queue: queue))
        let body = "# 9B 思考复查 · 第 2 批（局部） 1/1 批（约 5 分钟/批）\n\n本批没有提出复查建议。"
        try (body + "\n").write(to: root.appendingPathComponent("summary-review-batch-2.md"), atomically: true, encoding: .utf8)
        let scoped = try XCTUnwrap(try ReviewExportSource.markdown(for: root, queue: queue))
        XCTAssertTrue(scoped.hasPrefix("> 范围：第 2 批（局部）"))
        XCTAssertTrue(scoped.contains(body))
        try "整课复查意见正文\n".write(to: root.appendingPathComponent("summary-review.md"), atomically: true, encoding: .utf8)
        let combined = try XCTUnwrap(try ReviewExportSource.markdown(for: root, queue: queue))
        XCTAssertTrue(combined.contains("整课复查意见正文"))
        XCTAssertTrue(combined.contains(body))
        XCTAssertEqual(combined.components(separatedBy: body).count - 1, 1)
    }

    /// 父任务验收：报告**存在但读不出来**时必须停止导出并提示 ✗，
    /// 不能像以前那样 `try?` 静默跳过（那会让"读不到"伪装成"没有复查意见"）✗。
    @MainActor
    func testUnreadableScopedReportsStopTheExportInsteadOfBeingSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LLScopedExportFail-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false,
                                        diagnostics: .disabled) { _, _, _, _ in throw CancellationError() }
        addTeardownBlock { await queue.shutdownForTesting() }

        // ① 非 UTF-8 的局部报告：文件在，读不出来 → 抛错并指名文件。
        let corrupt = root.appendingPathComponent("summary-review-batch-1.md")
        try Data([0xff, 0xfe, 0xff, 0x00]).write(to: corrupt)
        XCTAssertThrowsError(try ReviewExportSource.markdown(for: root, queue: queue)) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.contains("读取失败"), "错误要说清是读取失败：\(text)")
            XCTAssertTrue(text.contains("summary-review-batch-1.md"), "错误要指名哪份报告：\(text)")
        }
        try FileManager.default.removeItem(at: corrupt)

        // ② 空白局部报告：与整课报告同一条规则（为空 → 停止导出）。
        let blank = root.appendingPathComponent("summary-review-batch-3.md")
        try " \n\t".write(to: blank, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ReviewExportSource.markdown(for: root, queue: queue)) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.contains("为空"), "错误要说清报告为空：\(text)")
            XCTAssertTrue(text.contains("summary-review-batch-3.md"), "错误要指名哪份报告：\(text)")
        }
        try FileManager.default.removeItem(at: blank)

        // ③ 确实没有报告（目录可读、无整课也无局部）→ 仍然是 nil，不能变成错误。
        XCTAssertNil(try ReviewExportSource.markdown(for: root, queue: queue))

        // ④ 目录整体读不了 → 同样必须抛错（权限错误会先出现在整课报告那一步；
        //    当前身份仍能列出目录时跳过这一条，例如 root）。
        let restricted = root.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restricted.path) }
        try XCTSkipIf((try? FileManager.default.contentsOfDirectory(atPath: restricted.path)) != nil,
                      "当前身份仍能列出这个目录（例如 root），跳过不可读目录这一条")
        XCTAssertThrowsError(try ReviewExportSource.markdown(for: restricted, queue: queue)) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.contains("读取失败") || text.contains("目录"),
                          "错误要说清是读取失败，而不是静默当没有报告：\(text)")
        }
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
        let data = Data(try LearningPrompts.reviewInput(prior, laterBatches: [book.batches[1]]).json.utf8)
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
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Oxygen is the terminal electron acceptor.")], note: .init(topic: "氧化磷酸化", points: [.init(kind: "核心结论", text: "质子动力势驱动 ATP 合酶。")]))
        let file = root.appendingPathComponent("summary-zh-Hans.md")
        let original = book.markdown() + "\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false) { _, _, _, _ in
            #"{"corrections":[],"additions":[{"evidenceIndex":0,"kind":"核心结论","text":"氧气是末端电子受体。","reason":"遗漏电子受体。","quoteID":"e0.en.0"}],"reviewVersion":2}"#
        }
        addTeardownBlock { await queue.shutdownForTesting() }
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
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false) { _, _, _, _ in throw CancellationError() }
        addTeardownBlock { await queue.shutdownForTesting() }
        let model = AppModel(reviewQueue: queue, backgroundServices: false, defaults: UserDefaults(suiteName: "LiveLingo-Test-\(UUID())")!)
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
    func testFailedReviewDoesNotBlockLaterRecordingAndRemovalPreservesFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LLQueueManagement-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        var dirs: [URL] = []
        for n in 0..<2 {
            let dir = root.appendingPathComponent("recording-\(n)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (book.markdown() + "\n").write(to: dir.appendingPathComponent("summary-zh-Hans.md"), atomically: true, encoding: .utf8)
            dirs.append(dir)
        }
        let journal = root.appendingPathComponent("queue.json")
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
            return #"{"corrections":[],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await queue.shutdownForTesting() }
        queue.setContext(recording: true, concurrent: false, resourcesAvailable: true)
        for dir in dirs { try queue.enqueue(directory: dir, notebook: book) }
        var saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        saved.jobs[0].failure = "模拟失败"
        try JSONEncoder().encode(saved).write(to: journal)
        await queue.shutdownForTesting()
        let restored = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled) { _, _, _, _ in #"{"corrections":[],"reviewVersion":2,"additions":[]}"# }
        addTeardownBlock { await restored.shutdownForTesting() }
        restored.setContext(recording: false, concurrent: false, resourcesAvailable: true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(restored.items.count, 1)
        XCTAssertEqual(restored.items.first?.failure, "模拟失败")
        XCTAssertTrue(try String(contentsOf: dirs[1].appendingPathComponent("summary-review.md"), encoding: .utf8).contains("1/1"))
        let id = try XCTUnwrap(restored.items.first?.id)
        restored.removeJob(id)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertEqual(try String(contentsOf: dirs[0].appendingPathComponent("summary-zh-Hans.md"), encoding: .utf8), book.markdown() + "\n")
    }

    @MainActor
    func testQueueMovingActiveRequestRetainsProgressAndIgnoresLateResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LLQueueLate-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"), observeSleep: false, diagnostics: .disabled) { _, _, _, update in
            await update("saved-prefix")
            try? await Task.sleep(for: .milliseconds(150))
            return #"{"corrections":[],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await queue.shutdownForTesting() }
        queue.setContext(recording: true, concurrent: false, resourcesAvailable: true)
        for n in 0..<2 {
            let dir = root.appendingPathComponent("recording-\(n)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try queue.enqueue(directory: dir, notebook: book)
        }
        let first = try XCTUnwrap(queue.items.first?.id)
        queue.setContext(recording: false, concurrent: false, resourcesAvailable: true)
        try await Task.sleep(for: .milliseconds(20))
        queue.moveJobToEnd(first)
        queue.setSleeping(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(queue.items.last?.id, first)
        XCTAssertEqual(queue.items.last?.completed, 0)
        let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: root.appendingPathComponent("queue.json")))
        XCTAssertEqual(saved.jobs.last?.prefix, "saved-prefix")
    }

    @MainActor
    func testReviewQueuePauseSleepRecordingAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoLearningTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("journal.json")
        let savedNotes = root.appendingPathComponent("summary-zh-Hans.md")
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        try (book.markdown() + "\n").write(to: savedNotes, atomically: true, encoding: .utf8)
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, _, _, update in
            await update("Checking atoms ")
            try await Task.sleep(for: .seconds(60))
            return #"{"corrections":[],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await queue.shutdownForTesting() }
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
        await queue.shutdownForTesting()
        let restored = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, prefix, _, _ in
            guard prefix == "Checking atoms " else { throw QwenRuntimeError.invalidResponse }
            return #"{"corrections":[{"index":0,"original":"原笔记","kind":"核心结论","text":"修正后的笔记","reason":"纠正术语"}],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await restored.shutdownForTesting() }
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
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = root.appendingPathComponent("journal.json")
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, _, _, update in
            await update("Retained thinking ")
            throw QwenRuntimeError.generationInterrupted("worker exited")
        }
        addTeardownBlock { await queue.shutdownForTesting() }
        try queue.enqueue(directory: root, notebook: book)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(queue.running)
        let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertEqual(saved.jobs.first?.prefix, "Retained thinking ")
        await queue.shutdownForTesting()
        let restored = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, prefix, _, _ in
            XCTAssertEqual(prefix, "Retained thinking ")
            return #"{"corrections":[],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await restored.shutdownForTesting() }
        restored.togglePause()
        if restored.userPaused { restored.togglePause() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(restored.hasWork)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("summary-review.md"), encoding: .utf8).contains("没有提出复查建议"))
    }

    @MainActor
    func testHistoricalReviewIsScopedAndFailedRemovalPreservesFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoReviewScope-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recording = root.appendingPathComponent("LiveLingo 2026-09-11 11.39.21")
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        let journal = root.appendingPathComponent("journal.json")
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false) { _, _, _, _ in
            XCTFail("Missing recording must not invoke model")
            return #"{"corrections":[],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await queue.shutdownForTesting() }
        // A persisted historical job can outlive its directory. Fresh enqueue
        // now correctly rejects missing courses before changing the queue.
        let historical = LearningReviewQueue.Job(directory: recording, batches: book.batches,
            original: book.markdown(), failure: "录音目录不可用")
        let oldJournal = LearningReviewQueue.Journal(jobs: [historical], userPaused: true)
        try JSONEncoder().encode(oldJournal).write(to: journal)
        let restored = LearningReviewQueue(journalURL: journal, observeSleep: false,
            diagnostics: .disabled) { _, _, _, _ in throw CancellationError() }
        addTeardownBlock { await restored.shutdownForTesting() }
        XCTAssertThrowsError(try queue.enqueue(directory: recording, notebook: book))
        XCTAssertFalse(restored.belongsTo(nil))
        XCTAssertFalse(restored.belongsTo(root.appendingPathComponent("new-recording")))
        XCTAssertTrue(restored.belongsTo(recording))
        XCTAssertEqual(restored.recordingName, recording.lastPathComponent)
        XCTAssertTrue(restored.canRemoveFailedJob)
        let original = root.appendingPathComponent("original-note.md")
        try "保留笔记".write(to: original, atomically: true, encoding: .utf8)
        restored.removeFailedJob()
        XCTAssertFalse(restored.hasWork)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "保留笔记")
        let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertTrue(saved.jobs.isEmpty)
    }

    @MainActor
    func testBackgroundReviewDoesNotOverwriteExternalNoteEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoLearningTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")], note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("journal.json"), observeSleep: false) { _, _, _, _ in #"{"corrections":[],"reviewVersion":2,"additions":[]}"# }
        addTeardownBlock { await queue.shutdownForTesting() }
        queue.togglePause()
        try queue.enqueue(directory: root, notebook: book)
        let file = root.appendingPathComponent("summary-zh-Hans.md")
        try "人工补充的内容\n".write(to: file, atomically: true, encoding: .utf8)
        queue.togglePause()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "人工补充的内容\n")
        XCTAssertTrue(queue.hasWork)
        XCTAssertFalse(queue.running)
        XCTAssertTrue(queue.status.contains("笔记与复查原文不同"))
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

    // MARK: - Review failure diagnostics

    func testReviewDecodeFailureNamesStageFieldAndPayloadSize() throws {
        XCTAssertThrowsError(try LearningReview.decode(response: "{\"corrections\": [")) { error in
            let failure = error as? ReviewFailure
            XCTAssertEqual(failure?.stage, .decode)
            XCTAssertEqual(failure?.code, "invalid_json")
            XCTAssertNil(failure?.field) // A syntax error has no addressable field.
            XCTAssertGreaterThan(failure?.responseBytes ?? 0, 0)
            XCTAssertTrue(failure?.description.contains("解析响应 JSON") == true)
            XCTAssertTrue(failure?.logLine.contains("response_bytes=") == true)
        }
        // A structurally valid JSON body missing the required key is a different
        // stage/field than a syntax error, and says which key is missing.
        XCTAssertThrowsError(try LearningReview.decode(response: #"{"additions":[]}"#)) { error in
            let failure = error as? ReviewFailure
            XCTAssertEqual(failure?.stage, .decode)
            XCTAssertEqual(failure?.code, "missing_key")
            XCTAssertEqual(failure?.field, "corrections")
            XCTAssertTrue(failure?.description.contains("字段 corrections") == true)
        }
        XCTAssertTrue(try LearningReview.decode(response: #"{"corrections":[]}"#).additions.isEmpty)
    }

    func testReviewCorrectionMismatchNamesItemPointAndField() throws {
        let note = LearningNote(topic: "化学式", points: [.init(kind: "例子", text: "待修正"),
                                                          .init(kind: "核心结论", text: "保留的事实")])
        // The model addressed point index 1 but copied point 0's original text.
        let mismatched = try LearningReview.decode(response: #"{"corrections":[{"index":1,"original":"待修正","kind":"例子","text":"修改","reason":"修正"}]}"#)
        XCTAssertThrowsError(try mismatched.applying(to: note)) { error in
            let failure = error as? ReviewFailure
            XCTAssertEqual(failure?.stage, .corrections)
            XCTAssertEqual(failure?.code, "original_mismatch")
            XCTAssertEqual(failure?.field, "original")
            XCTAssertEqual(failure?.itemIndex, 0)
            XCTAssertEqual(failure?.pointIndex, 1)
            // Actions and logs carry metadata, never the note or response text.
            XCTAssertFalse(failure?.description.contains("待修正") == true)
            XCTAssertFalse(failure?.logLine.contains("待修正") == true)
            XCTAssertTrue(failure?.description.contains("笔记要点 2") == true)
        }
        let outOfRange = try LearningReview.decode(response: #"{"corrections":[{"index":9,"original":"待修正","kind":"例子","text":"修改","reason":"修正"}]}"#)
        XCTAssertThrowsError(try outOfRange.applying(to: note)) { error in
            XCTAssertEqual((error as? ReviewFailure)?.code, "index_out_of_range")
            XCTAssertEqual((error as? ReviewFailure)?.field, "index")
        }
        let duplicate = try LearningReview.decode(response: #"{"corrections":[{"index":0,"original":"待修正","kind":"例子","text":"修改","reason":"修正"},{"index":0,"original":"待修正","kind":"例子","text":"再修改","reason":"重复"}]}"#)
        XCTAssertThrowsError(try duplicate.applying(to: note)) { error in
            XCTAssertEqual((error as? ReviewFailure)?.code, "duplicate_index")
            XCTAssertEqual((error as? ReviewFailure)?.itemIndex, 1)
        }
    }

    func testReviewAdditionCitationMismatchNamesEvidenceItemAndField() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 8, english: "Oxygen is the terminal electron acceptor."),
                        TranscriptSegment(startTime: 8, endTime: 16, english: "Water is the solvent.")]
        // The quote exists in this batch but not in the cited evidence item.
        let crossed = try LearningReview.decode(response: #"{"corrections":[],"additions":[{"evidenceIndex":0,"quote":"Water is the solvent.","kind":"核心结论","text":"水是溶剂。","reason":"遗漏电子受体。"}]}"#)
        XCTAssertThrowsError(try crossed.validateAdditions(evidence: evidence)) { error in
            let failure = error as? ReviewFailure
            XCTAssertEqual(failure?.stage, .additions)
            XCTAssertEqual(failure?.code, "quote_not_in_evidence")
            XCTAssertEqual(failure?.field, "quote")
            XCTAssertEqual(failure?.itemIndex, 0)
            XCTAssertTrue(failure?.description.contains("证据 0") == true)
        }
        let badIndex = try LearningReview.decode(response: #"{"corrections":[],"additions":[{"evidenceIndex":7,"quote":"Water is the solvent.","kind":"核心结论","text":"水是溶剂。","reason":"遗漏。"}]}"#)
        XCTAssertThrowsError(try badIndex.validateAdditions(evidence: evidence)) { error in
            XCTAssertEqual((error as? ReviewFailure)?.code, "evidence_index_out_of_range")
            XCTAssertEqual((error as? ReviewFailure)?.field, "evidenceIndex")
        }
        let emptyReason = try LearningReview.decode(response: #"{"corrections":[],"additions":[{"evidenceIndex":1,"quote":"Water is the solvent.","kind":"核心结论","text":"水是溶剂。","reason":"  "}]}"#)
        XCTAssertThrowsError(try emptyReason.validateAdditions(evidence: evidence)) { error in
            XCTAssertEqual((error as? ReviewFailure)?.code, "empty_reason")
            XCTAssertEqual((error as? ReviewFailure)?.field, "reason")
        }
    }

    func testReviewWorkerFailureRecordIsClassifiedWithoutModelText() throws {
        let parsed = try XCTUnwrap(ReviewFailure.parseWorkerMessage(
            "review failure stage=prompt_binding code=input_not_in_prompt field=input detail=review input not found in rendered prompt input_bytes=128 prompt_bytes=4096"))
        XCTAssertEqual(parsed.stage, .promptBinding)
        XCTAssertEqual(parsed.code, "input_not_in_prompt")
        XCTAssertEqual(parsed.field, "input")
        XCTAssertFalse(parsed.logLine.contains("review input not found"))
        XCTAssertEqual(parsed.localizedDetail, "复查输入未出现在渲染后的提示词中")
        XCTAssertEqual(ReviewFailure.parseWorkerMessage("本机模型返回了无法识别的数据"), nil)

        // A payload-shaped error message is replaced by a size note.
        let payload = #"{"corrections":[{"index":0,"text":"模型的原始回答"}]}"#
        let classified = ReviewFailure.classify(QwenRuntimeError.requestFailed(payload), defaultStage: .generation)
        XCTAssertEqual(classified.code, "request_failed")
        XCTAssertFalse(classified.description.contains("模型的原始回答"))
        XCTAssertFalse(classified.logLine.contains("模型的原始回答"))

        let worker = ReviewFailure.classify(QwenRuntimeError.requestFailed(
            "review failure stage=schema code=missing_field field=note.points[0].text detail=point text must be a string"),
            defaultStage: .generation)
        XCTAssertEqual(worker.stage, .schema)
        XCTAssertEqual(worker.field, "note.points[0].text")
        XCTAssertEqual(worker.localizedDetail, "复查输入缺少必需字段")
    }

    private func diagnosticSnapshot(index: Int, input: String?, response: String?) -> ReviewDiagnosticSnapshot {
        ReviewDiagnosticSnapshot(createdAt: "2026-09-15T00:00:0\(index)Z", jobID: UUID().uuidString,
                                 requestID: "abcdef0\(index)", requestCount: 1, batch: 0, batchCount: 1,
                                 stage: "decode", code: "invalid_json", field: "corrections",
                                 detail: "响应不是合法 JSON", inputBytes: input?.utf8.count ?? 0,
                                 responseBytes: response?.utf8.count ?? 0, prefixBytes: 0,
                                 timingsMS: ["decode": 1], timingsUnavailable: ["model_load"],
                                 input: input, finalResponse: response)
    }

    func testReviewAdditionsCountAndReasoningSnapshotPrivacy() throws {
        let item: [String: Any] = ["evidenceIndex": 0, "quote": "source", "kind": "核心结论", "text": "结论", "reason": "理由"]
        let data = try JSONSerialization.data(withJSONObject: ["corrections": [], "additions": Array(repeating: item, count: 26)])
        let patch = try LearningReview.decode(response: String(decoding: data, as: UTF8.self))
        XCTAssertThrowsError(try patch.validateAdditions(evidence: [])) { error in
            XCTAssertEqual((error as? ReviewFailure)?.code, "too_many_additions")
            XCTAssertTrue(error.localizedDescription.contains("26"))
        }
        let store = ReviewDiagnosticsStore(directory: FileManager.default.temporaryDirectory,
            policy: .init(maximumFiles: 2, maximumFileBytes: 8192, maximumTotalBytes: 1500))
        let snapshot = diagnosticSnapshot(index: 0, input: "input", response: "<think>PRIVATE_THOUGHT</think>{}")
        let encoded = try XCTUnwrap(store.bounded(snapshot))
        XCTAssertLessThanOrEqual(encoded.count, 1500)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE_THOUGHT"))
    }

    func testReviewDiagnosticsStoreRotatesOnlyOwnedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoReviewDiagnostics-\(UUID())")
        let directory = root.appendingPathComponent("ReviewDiagnostics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let userFile = directory.appendingPathComponent("用户笔记.json")
        try "保留的既有数据".write(to: userFile, atomically: true, encoding: .utf8)
        let lookalike = directory.appendingPathComponent("review-failure-notes.json")
        try "类似但非本地诊断".write(to: lookalike, atomically: true, encoding: .utf8)
        let store = ReviewDiagnosticsStore(directory: directory,
                                           policy: .init(maximumFiles: 2, maximumFileBytes: 4_096, maximumTotalBytes: 16_384))
        var written: [URL] = []
        for index in 0..<4 {
            written.append(try XCTUnwrap(store.write(diagnosticSnapshot(index: index, input: "输入", response: "回答"))))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { ReviewDiagnosticsStore.isOwnedName($0) }.count, 2)
        XCTAssertTrue(names.contains("用户笔记.json"))
        XCTAssertTrue(names.contains("review-failure-notes.json"))
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "保留的既有数据")
        XCTAssertEqual(try String(contentsOf: lookalike, encoding: .utf8), "类似但非本地诊断")
        // The snapshot just written is never the file removed by rotation.
        XCTAssertTrue(names.contains(written[3].lastPathComponent))
        let attributes = try FileManager.default.attributesOfItem(atPath: written[3].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(ReviewDiagnosticsStore.isOwnedName("review-failure-20260915T120000Z-abcdef01.json"))
        XCTAssertFalse(ReviewDiagnosticsStore.isOwnedName("review-failure-notes.json"))
        XCTAssertFalse(ReviewDiagnosticsStore.isOwnedName("review-failure-20260915T120000Z-abcdef01.json.bak"))
    }

    func testReviewDiagnosticsSnapshotTruncatesOversizedPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoReviewBounds-\(UUID())")
        let directory = root.appendingPathComponent("ReviewDiagnostics")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ReviewDiagnosticsStore(directory: directory,
                                           policy: .init(maximumFiles: 3, maximumFileBytes: 1_500, maximumTotalBytes: 4_500))
        let url = try XCTUnwrap(store.write(diagnosticSnapshot(index: 0,
                                                               input: String(repeating: "原", count: 4_000),
                                                               response: String(repeating: "答", count: 4_000))))
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, 1_500)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The oversized input is dropped first; the final answer is truncated next.
        XCTAssertEqual(decoded["inputOmitted"] as? Bool, true)
        XCTAssertEqual(decoded["responseTruncated"] as? Bool, true)
        XCTAssertNil(decoded["input"] as? String)
        XCTAssertLessThanOrEqual((decoded["finalResponse"] as? String)?.count ?? 0, 1_500)
        XCTAssertEqual(decoded["containsReasoning"] as? Bool, false)
        XCTAssertEqual(decoded["code"] as? String, "invalid_json")
        // A disabled policy writes nothing at all.
        let disabled = ReviewDiagnosticsStore(directory: directory, policy: .disabled)
        XCTAssertNil(disabled.write(diagnosticSnapshot(index: 1, input: "输入", response: "回答")))
    }

    @MainActor
    func testReviewFailureSnapshotKeepsInputAndFinalAnswerOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoReviewSnapshot-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Oxygen is the terminal electron acceptor.")],
                        note: .init(topic: "氧化磷酸化", points: [.init(kind: "核心结论", text: "原笔记")]))
        try (book.markdown() + "\n").write(to: root.appendingPathComponent("summary-zh-Hans.md"), atomically: true, encoding: .utf8)
        let journal = root.appendingPathComponent("journal.json")
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false,
                                        diagnostics: .init(maximumFiles: 4, maximumFileBytes: 32_768, maximumTotalBytes: 131_072)) { _, _, _, update in
            await update("PRIVATE-THINKING-MARKER 我已检查全部要点。")
            return #"{"corrections":[{"index":0,"original":"与笔记不一致的原文","kind":"核心结论","text":"修改","reason":"理由"}],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await queue.shutdownForTesting() }
        try queue.enqueue(directory: root, notebook: book)
        for _ in 0..<400 where !queue.canRemoveFailedJob { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(queue.canRemoveFailedJob)
        XCTAssertTrue(queue.status.contains("字段 original"))
        XCTAssertFalse(queue.status.contains("PRIVATE-THINKING-MARKER"))

        let directory = root.appendingPathComponent("ReviewDiagnostics")
        let owned = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { ReviewDiagnosticsStore.isOwnedName($0) }
        XCTAssertEqual(owned.count, 1)
        let path = directory.appendingPathComponent(try XCTUnwrap(owned.first))
        let text = try String(contentsOf: path, encoding: .utf8)
        // Input and final answer are present; the reasoning prefix never is.
        XCTAssertTrue(text.contains("Oxygen is the terminal electron acceptor."))
        XCTAssertTrue(text.contains("与笔记不一致的原文"))
        XCTAssertTrue(text.contains("original_mismatch"))
        XCTAssertFalse(text.contains("PRIVATE-THINKING-MARKER"))
        XCTAssertTrue(text.contains("\"timingsMS\""))
        XCTAssertTrue(text.contains("model_load"))
        XCTAssertTrue(text.contains("\"containsReasoning\":false"))
        XCTAssertEqual(LearningReviewQueue.timingLine(["decode": 2]),
                       "decode=2,model_load=unknown,prefill=unknown,thinking_phase=unknown,final_phase=unknown")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let report = try String(contentsOf: root.appendingPathComponent("summary-review.md"), encoding: .utf8)
        XCTAssertFalse(report.contains("PRIVATE-THINKING-MARKER"))
        let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertTrue(saved.jobs.first?.events?.contains { $0.code == "failed" } == true)
        XCTAssertTrue(saved.jobs.first?.events?.contains { $0.code == "diagnostics" } == true)
        XCTAssertFalse(saved.jobs.first?.failure?.contains("PRIVATE-THINKING-MARKER") == true)
    }

    @MainActor
    func testReviewQueueRecordsResumeAndCancelStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingoReviewStates-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Atoms")],
                        note: .init(topic: "原子", points: [.init(kind: "核心结论", text: "原笔记")]))
        try (book.markdown() + "\n").write(to: root.appendingPathComponent("summary-zh-Hans.md"), atomically: true, encoding: .utf8)
        let journal = root.appendingPathComponent("journal.json")
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled) { _, _, _, update in
            await update("Retained thinking ")
            throw QwenRuntimeError.generationInterrupted("worker exited")
        }
        addTeardownBlock { await queue.shutdownForTesting() }
        try queue.enqueue(directory: root, notebook: book)
        // 生成被中断（worker 退出）现在属于可自动重试的瞬时故障：前缀保留，
        // 队列记录 retry_scheduled，而不是立刻停下来等人点重试。
        for _ in 0..<400 where queue.items.first?.retryPending == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(queue.items.first?.retryPending)
        XCTAssertFalse(queue.canRemoveFailedJob, "等待自动重试期间不应显示为可移除的失败任务")
        XCTAssertTrue(queue.status.contains("自动重试"))
        var saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertEqual(saved.jobs.first?.prefix, "Retained thinking ")
        XCTAssertTrue(saved.jobs.first?.events?.contains { $0.code == "enqueued" } == true)
        XCTAssertTrue(saved.jobs.first?.events?.contains { $0.code == "retry_scheduled" && $0.detail?.contains("generation_interrupted") == true } == true)
        XCTAssertFalse(saved.jobs.first?.failure?.contains("Retained thinking") == true)

        // 让第一条队列停下来，避免它的重试定时器和下面这条争同一个日志。
        queue.setSleeping(true)

        // 手动重试：清掉等待中的退避窗口，从检查点继续。
        await queue.shutdownForTesting()
        let restored = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled) { _, prefix, _, _ in
            guard prefix == "Retained thinking " else { throw QwenRuntimeError.invalidResponse }
            try await Task.sleep(for: .seconds(30))
            return #"{"corrections":[],"reviewVersion":2,"additions":[]}"#
        }
        addTeardownBlock { await restored.shutdownForTesting() }
        let jobID = try XCTUnwrap(restored.items.first?.id)
        restored.retryJob(jobID)
        for _ in 0..<400 where !restored.running { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(restored.running, "手动重试后应当从检查点继续生成")
        restored.setSleeping(true)
        try await Task.sleep(for: .milliseconds(50))
        saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        XCTAssertTrue(saved.jobs.first?.events?.contains { $0.code == "resumed" } == true)
        XCTAssertTrue(saved.jobs.first?.events?.contains { $0.code == "cancelled" && $0.detail == "sleep" } == true)
        XCTAssertLessThanOrEqual(saved.jobs.first?.events?.count ?? 0, LearningReviewQueue.maximumEventsPerJob)
    }

    // MARK: - 父任务验收补充（2026-09-20 第 1、2、5 点）

    /// 第 1 点：疑问（`待确认` 根）与它的后文候选必须**同时**显示，且关系链不许断。
    ///
    /// 背景：补充候选只从正文的 `related()` 渲染 ✗，根一旦被跳过，整条补充就消失 ✗。
    func testPendingQuestionAndItsLaterCandidatesStayVisible() throws {
        var book = LearningNotebook()
        // 第 1 批：待确认根（问题在此）＋一条普通结论。
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Its speed is 4 m/s.")],
                        note: .init(topic: "小车运动", points: [
                            .init(kind: "待确认", text: "速度为 4 m/s，原文没有说明属于哪辆车。",
                                  needsContext: "这项速度属于哪辆车？", sourceIDs: ["en0s0"]),
                            .init(kind: "核心结论", text: "速度是矢量。", sourceIDs: ["en0s0"])
                        ], sourceVersion: 2))
        let root = LearningNotebook.reference(book.batches[0], 0)
        // 第 2 批：指向根的补充候选。
        try book.append(evidence: [.init(startTime: 8, endTime: 16, english: "Cart B moves at 4 m/s.")],
                        note: .init(topic: "小车运动", points: [
                            .init(kind: "核心结论", text: "后文说这是小车 B 的速度。", clarifies: root, sourceIDs: ["en0s0"])
                        ], sourceVersion: 2))
        let candidate = LearningNotebook.reference(book.batches[1], 0)
        // 第 3 批：候选自己的补充（链的第三层）。
        try book.append(evidence: [.init(startTime: 16, endTime: 24, english: "Cart B is the blue one.")],
                        note: .init(topic: "小车运动", points: [
                            .init(kind: "补充理解", text: "小车 B 是蓝色那辆。", clarifies: candidate, sourceIDs: ["en0s0"])
                        ], sourceVersion: 2))

        let rendered = book.markdown()
        let mainBody = String(rendered.components(separatedBy: "## 需要回听")[0])
        XCTAssertFalse(mainBody.contains("速度为 4 m/s，原文没有说明属于哪辆车。"))
        XCTAssertFalse(mainBody.contains("待确认"), "疑问只在回听区，不能重复堆在正常正文")
        XCTAssertTrue(mainBody.contains("速度是矢量。"))
        XCTAssertTrue(rendered.contains("- **待确认**：速度为 4 m/s，原文没有说明属于哪辆车。"), "疑问原文必须完整保留")
        XCTAssertTrue(rendered.contains("后文说这是小车 B 的速度。"), "根的补充候选不得整条消失")
        XCTAssertTrue(rendered.contains("小车 B 是蓝色那辆。"), "补充候选的下一层也不得消失")
        XCTAssertTrue(rendered.contains("后文补充候选，原问题仍待核对"))
        XCTAssertTrue(rendered.contains("## 需要回听"))
        XCTAssertTrue(rendered.contains("- [00:00–00:08] 这项速度属于哪辆车？"), "疑问带实际时间范围")
        // 只看最近一批时：候选仍在，且把先前那句疑问原文带出来（不隐藏记录）。
        let latest = book.markdown(covering: book.batches[1].ids)
        XCTAssertTrue(latest.contains("后文说这是小车 B 的速度。"))
        XCTAssertTrue(latest.contains("对应先前记录（仍待核对）：速度为 4 m/s，原文没有说明属于哪辆车。"))
    }

    /// 第 1 点：即使根那一行被"同主题去重"吃掉，补充候选也必须兜底显示（绝不整条消失）。
    ///
    /// 只有"带疑问的要点"才会成为 `clarifies` 的目标（程序只允许回答未解决的问题），
    /// 所以这里让两批各有一条**文字相同**的待确认要点：第 2 批那条正文行被去重，
    /// 而它的补充候选只可能从 `related()` 渲染 —— 兜底必须把它救回来。
    func testDeduplicatedRootStillKeepsItsLaterCandidates() throws {
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Its speed is unknown.")],
                        note: .init(topic: "重复主题", points: [
                            .init(kind: "待确认", text: "重复的疑问句。", needsContext: "这句话说的是 A 还是 B？", sourceIDs: ["en0s0"])
                        ], sourceVersion: 2))
        try book.append(evidence: [.init(startTime: 8, endTime: 16, english: "Its speed is still unknown.")],
                        note: .init(topic: "重复主题", points: [
                            .init(kind: "待确认", text: "重复的疑问句。", needsContext: "这句话说的是 A 还是 B？", sourceIDs: ["en0s0"])
                        ], sourceVersion: 2))
        let droppedRoot = LearningNotebook.reference(book.batches[1], 0)
        try book.append(evidence: [.init(startTime: 16, endTime: 24, english: "Cart B moves at 4 m/s.")],
                        note: .init(topic: "重复主题", points: [
                            .init(kind: "核心结论", text: "被去重根的补充候选。", clarifies: droppedRoot, sourceIDs: ["en0s0"])
                        ], sourceVersion: 2))
        XCTAssertEqual(book.batches[2].note.points[0].clarifies, droppedRoot, "构造前提：补充候选必须真的挂在被去重的那条上")

        let rendered = book.markdown()
        XCTAssertTrue(rendered.contains("被去重根的补充候选。"), "根被去重时，补充候选必须兜底显示")
        XCTAssertTrue(rendered.contains("后文补充候选，原问题仍待核对"))
        XCTAssertTrue(rendered.contains("这句话说的是 A 还是 B？"), "疑问句本身也不能丢")
    }

    /// 第 2 点：旧数据里 `kind` 是 核心结论/易错点 但带着 `needsContext` → 不能装作已确认。
    func testOldPointsWithAnOpenQuestionAreShownAsQuestions() throws {
        let evidence = [TranscriptSegment(startTime: 0, endTime: 8, english: "Its speed is 4 m/s.")]
        // 旧形状：没有 sourceVersion / sourceIDs，只有 kind、text、needsContext。
        let legacy = try LearningNote.decode(#"{"topic":"小车运动","points":[{"kind":"核心结论","text":"小车 A 的速度为 4 m/s，但未指明是哪辆车。","needsContext":"这项速度属于哪辆车？"},{"kind":"易错点","text":"速度与速率不是一回事。","needsContext":"这里说的是速率还是速度？"}]}"#)
        var book = LearningNotebook()
        try book.append(evidence: evidence, note: legacy)

        let points = book.batches[0].note.points
        XCTAssertTrue(points.allSatisfy(\.hasOpenQuestion), "带问题的旧要点必须被识别为疑问")
        XCTAssertTrue(points.allSatisfy { $0.referenceState == nil }, "旧数据没有引用状态，不编造")
        let rendered = book.markdown()
        XCTAssertTrue(rendered.contains("- **待确认**：小车 A 的速度为 4 m/s，但未指明是哪辆车。"),
                      "原文完整保留，但必须标成疑问，不能像已确认的结论")
        XCTAssertTrue(rendered.contains("- **易错点（待确认）**：速度与速率不是一回事。"))
        XCTAssertTrue(rendered.contains("- [00:00–00:08] 这项速度属于哪辆车？"))
        XCTAssertTrue(rendered.contains("- [00:00–00:08] 这里说的是速率还是速度？"))
        XCTAssertTrue(rendered.contains("## 需要回听"))
        XCTAssertFalse(rendered.contains("## 来源检查"), "没有来源信息不等于来源有错")
    }
}


@MainActor
private final class CaptionRetryGate {
    enum FirstResult { case tooLong, failure }
    let first: FirstResult
    var count = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var entered: [Int: CheckedContinuation<Void, Never>] = [:]
    init(_ first: FirstResult) { self.first = first }

    func translate(_ update: CaptionTranslationDependencies.Update?) async throws -> String {
        count += 1
        let call = count
        if call == 1 {
            if first == .failure { throw QwenRuntimeError.invalidResponse }
            return String(repeating: "这是过长的译文。", count: 60)
        }
        if call == 3 { await update?("新会话正在翻译") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
            entered.removeValue(forKey: call)?.resume()
        }
    }
    func waitForCall(_ call: Int) async {
        if pending[call] != nil { return }
        await withCheckedContinuation { entered[call] = $0 }
    }
    func release(_ call: Int, cancelled: Bool = false) {
        let continuation = pending.removeValue(forKey: call)!
        if cancelled { continuation.resume(throwing: CancellationError()) }
        else { continuation.resume(returning: call == 3 ? "新会话的译文。" : "旧会话的译文。") }
    }
}

final class CaptionLifecycleTests: XCTestCase {
    @MainActor
    func testOldRetriesCannotMutateNewSessionOrClearItsWorker() async throws {
        executionTimeAllowance = 30
        for first in [CaptionRetryGate.FirstResult.tooLong, .failure] {
            for cancelled in [false, true] {
                for withNewCaption in [false, true] {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-Race-\(UUID())")
                    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
                    let suite = "LiveLingo-Race-\(UUID())"
                    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                    let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
                                                    observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                        XCTFail("caption tests must not start review")
                        throw CancellationError()
                    }
                    addTeardownBlock { await queue.shutdownForTesting() }
                    let gate = CaptionRetryGate(first)
                    let dependency = CaptionTranslationDependencies(
                        translate: { _, _, _, update in try await gate.translate(update) },
                        adjacent: { _, _, _, _, _, _ in
                            XCTFail("independent session cannot use adjacent translation")
                            throw CancellationError()
                        })
                    let model = AppModel(reviewQueue: queue, translation: dependency,
                                         backgroundServices: false, defaults: defaults)
                    model.resetTranslationSessionForTesting()
                    model.receiveCaptionForTesting("The temperature of the system increases when we add thermal energy.", start: 0, end: 8)
                    await gate.waitForCall(2)
                    let old = try XCTUnwrap(model.resetTranslationSessionForTesting())
                    if withNewCaption {
                        model.receiveCaptionForTesting("This is a completely new lecture about energy.", start: 0, end: 8)
                        await gate.waitForCall(3)
                    }
                    let newLive = model.liveChinese
                    let newStreaming = model.streamingChinese
                    gate.release(2, cancelled: cancelled)
                    await old.value
                    XCTAssertEqual(model.liveChinese, newLive)
                    XCTAssertEqual(model.streamingChinese, newStreaming)
                    if withNewCaption {
                        XCTAssertEqual(model.segments.count, 1)
                        XCTAssertEqual(model.segments.first?.chinese, "")
                        let newWorker = try XCTUnwrap(model.translationTaskForTesting)
                        gate.release(3)
                        await newWorker.value
                        XCTAssertEqual(model.segments.first?.chinese, "新会话的译文。")
                    } else {
                        XCTAssertTrue(model.segments.isEmpty)
                        XCTAssertNil(model.translationTaskForTesting)
                    }
                    defaults.removePersistentDomain(forName: suite)
                }
            }
        }
    }
}


final class ReviewExportIntegrationTests: XCTestCase {
    @MainActor
    func testCompletedAndRestartedReviewExportsOnlyTheSelectedRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-ReviewExport-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recording = root.appendingPathComponent("recording-A")
        let other = root.appendingPathComponent("recording-B")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var book = LearningNotebook()
        try book.append(evidence: [.init(startTime: 0, endTime: 8, english: "Temperature increases.")],
                        note: .init(topic: "温度", points: [.init(kind: "核心结论", text: "原笔记")]))
        let journal = root.appendingPathComponent("queue.json")
        let generate: LearningReviewQueue.Generator = { _, _, _, _ in
            #"{"reviewVersion":2,"corrections":[{"index":0,"original":"原笔记","kind":"核心结论","text":"温度升高。","reason":"核对方向"}],"additions":[]}"#
        }
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled, generate: generate)
        addTeardownBlock { await queue.shutdownForTesting() }
        try queue.enqueue(directory: recording, notebook: book)
        for _ in 0..<1000 where queue.hasWork { await Task.yield() }
        XCTAssertFalse(queue.hasWork, queue.status)
        XCTAssertNil(queue.reviewReportMarkdown(for: recording))
        let report = try XCTUnwrap(ReviewExportSource.markdown(for: recording, queue: queue))
        XCTAssertTrue(report.contains("温度升高。"))
        XCTAssertNil(try ReviewExportSource.markdown(for: other, queue: queue))
        await queue.shutdownForTesting()
        let restored = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled, generate: generate)
        addTeardownBlock { await restored.shutdownForTesting() }
        XCTAssertEqual(try ReviewExportSource.markdown(for: recording, queue: restored), report)
        let file = recording.appendingPathComponent("summary-review.md")
        try Data([0xff, 0xfe, 0xff]).write(to: file)
        XCTAssertThrowsError(try ReviewExportSource.markdown(for: recording, queue: restored))
        try " ".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ReviewExportSource.markdown(for: recording, queue: restored))
    }
}


// MARK: - 苹果初译（预览）调度：假翻译器回归测试
//
// 这些用例只驱动 PreviewTranslationScheduler / PreviewTranslationRunner，
// 用假翻译器和假时钟，不创建 TranslationSession，也不碰麦克风、文件或网络。

private enum PreviewTestFailure: Error, Equatable {
    case unavailable
}

@MainActor
private final class PreviewLoopHarness {
    var clock: TimeInterval = 1_000
    var source = PreviewTranslationScheduler.Source(text: "", revision: 0)
    /// 事件路径记录的「源文本最近一次变化」时刻。
    var sourceChangedAt: TimeInterval = 1_000
    var active = true
    /// 新会话已接替：旧 runner 必须自行退出。
    var superseded = false
    private(set) var requested: [String] = []
    private(set) var delivered: [(source: String, translated: String,
                                  timing: PreviewTranslationRunner.Timing)] = []
    private(set) var failures: [(revision: Int, failures: Int, backoff: TimeInterval)] = []
    private(set) var idleWaits = 0
    private(set) var loopExited = false

    private let idleSignal = PreviewWakeSignal()
    private var pendingWake = false
    private var pendingResults: [Int: CheckedContinuation<String, Error>] = [:]
    private var scriptedResults: [Int: Result<String, Error>] = [:]
    private var loops: [Task<Void, Never>] = []

    func changeSource(_ value: PreviewTranslationScheduler.Source) {
        source = value
        sourceChangedAt = clock
    }

    func wake() {
        pendingWake = true
        idleSignal.signal()
    }

    func startLoop() -> Task<Void, Never> {
        let task = Task {
            await self.makeRunner().run()
            self.loopExited = true
        }
        loops.append(task)
        return task
    }

    func waitForLoopExit() async {
        for _ in 0..<10_000 {
            if loopExited { return }
            await Task.yield()
        }
        XCTFail("预览循环没有退出（isSuperseded 后不应继续等待）")
    }

    /// 有界收尾：取消循环 + 释放所有未完成的假请求。
    /// 测试断言失败提前结束时也必须能回来，不能悬挂在 continuation 上。
    func shutdown() async {
        for loop in loops { loop.cancel() }
        drainPendingRequests()
        await waitForLoopExit()
    }

    private func drainPendingRequests() {
        let waiting = pendingResults
        pendingResults = [:]
        for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }
    }

    func translate(_ text: String) async throws -> String {
        requested.append(text)
        let call = requested.count
        if let result = scriptedResults.removeValue(forKey: call) { return try result.get() }
        // 生产里的 TranslationSession 会响应取消，假翻译器必须同样响应：
        // 否则 loop.cancel() 之后请求永远不返回，测试会挂死。
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingResults[call] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(call) }
        }
    }

    private func cancelRequest(_ call: Int) {
        pendingResults.removeValue(forKey: call)?.resume(throwing: CancellationError())
    }

    /// 等第 `call` 次翻译请求已经发出。有界让步等待（不用 continuation），
    /// 循环没进展时由 XCTFail 结束，绝不无限挂起。
    func waitForRequest(_ call: Int) async {
        for _ in 0..<10_000 {
            if requested.count >= call { return }
            await Task.yield()
        }
        XCTFail("第 \(call) 次翻译请求没有发出（requested=\(requested.count)）")
    }

    func release(_ call: Int, _ result: Result<String, Error>) {
        guard let continuation = pendingResults.removeValue(forKey: call) else {
            scriptedResults[call] = result
            return
        }
        continuation.resume(with: result)
    }

    func waitForDelivered(_ count: Int) async {
        for _ in 0..<10_000 {
            if delivered.count >= count { return }
            await Task.yield()
        }
        XCTFail("预览结果没有落地（delivered=\(delivered.count)）")
    }

    /// 等循环回到「没有待翻译内容」的等待状态：说明上一轮结果已被处理完。
    func waitUntilIdle(_ count: Int = 1) async {
        for _ in 0..<10_000 {
            if idleWaits >= count { return }
            await Task.yield()
        }
        XCTFail("预览循环没有回到等待状态（idleWaits=\(idleWaits)）")
    }

    func makeRunner() -> PreviewTranslationRunner {
        PreviewTranslationRunner(
            now: { self.clock },
            source: { self.source },
            sourceArrivedAt: { self.sourceChangedAt },
            isActive: { self.active },
            isSuperseded: { self.superseded },
            translate: { try await self.translate($0) },
            deliver: { source, translated, timing in
                self.delivered.append((source.text, translated, timing))
            },
            reportFailure: { source, _, backoff, failures in
                self.failures.append((source.revision, failures, backoff))
            },
            waitForChange: { timeout in
                if let timeout {
                    // 假时钟：有变化就提前醒，否则等待即前进，不依赖真实时间。
                    if self.pendingWake {
                        self.pendingWake = false
                        return
                    }
                    self.clock += timeout
                    return
                }
                self.pendingWake = false
                self.idleWaits += 1
                await self.idleSignal.wait(timeout: nil)
            }
        )
    }
}

final class PreviewTranslationSchedulingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 假时钟用例不该真的等待；这条只作为卡死保护。
        executionTimeAllowance = 30
    }

    private func text(_ value: String, revision: Int = 0) -> PreviewTranslationScheduler.Source {
        .init(text: value, revision: revision)
    }

    // MARK: 纯调度状态机

    func testPreviewFirstRequestStartsImmediatelyWithoutFixedDelay() {
        var scheduler = PreviewTranslationScheduler()
        scheduler.note(text("The temperature rises"), at: 100)
        XCTAssertEqual(scheduler.action(at: 100), .translate(text("The temperature rises")),
                       "首条初译必须立即开始，而不是先等 800ms")
    }

    func testPreviewSameSourceIsNotRepeatedUntilRevisionChanges() {
        var scheduler = PreviewTranslationScheduler()
        scheduler.note(text("The temperature rises"), at: 10)
        XCTAssertEqual(scheduler.action(at: 10), .translate(text("The temperature rises")))
        scheduler.beginRequest(text("The temperature rises"), at: 10)
        scheduler.finishRequest(success: true, at: 10.1)
        scheduler.note(text("The temperature rises"), at: 10.2)
        XCTAssertEqual(scheduler.action(at: 10.2), .idle, "同一来源不应重复翻译")
        // 修订号变化（取消、开关、前缀改写、会话切换）后同样的文本要重译：
        // 只受限频约束，不受「同源不重复」约束。
        scheduler.note(text("The temperature rises", revision: 1), at: 10.2)
        guard case .wait(let rateLimit) = scheduler.action(at: 10.2) else {
            return XCTFail("限频间隔内应等待")
        }
        XCTAssertLessThanOrEqual(rateLimit, PreviewTranslationPolicy.minimumRequestInterval)
        XCTAssertEqual(scheduler.action(at: 10.35),
                       .translate(text("The temperature rises", revision: 1)))
    }

    func testPreviewMergesUpdatesArrivingDuringOneRequest() {
        var scheduler = PreviewTranslationScheduler()
        scheduler.note(text("The temperature"), at: 0)
        scheduler.beginRequest(text("The temperature"), at: 0)
        // 请求在途时到达的三次增长：全部合并，只保留最新版本，且不能并发发请求。
        for (offset, value) in ["The temperature of", "The temperature of the",
                                "The temperature of the system"].enumerated() {
            let arrival = 0.02 * Double(offset + 1)
            scheduler.note(text(value), at: arrival)
            XCTAssertEqual(scheduler.action(at: arrival), .idle, "单请求在途时不能再发请求")
        }
        scheduler.finishRequest(success: true, at: 0.08)
        guard case .wait(let rateLimit) = scheduler.action(at: 0.08) else {
            return XCTFail("请求结束得很快时仍要遵守限频间隔")
        }
        XCTAssertEqual(rateLimit, PreviewTranslationPolicy.minimumRequestInterval - 0.08,
                       accuracy: 1e-9)
        XCTAssertEqual(scheduler.action(at: 0.36), .translate(text("The temperature of the system")),
                       "限频一过就只翻译合并后的最新文本，中间版本不再单独请求")
    }

    func testPreviewGrowthIsRateLimitedButNeverStarves() {
        var scheduler = PreviewTranslationScheduler()
        // 太短的文本不值得请求。
        scheduler.note(text("Hi"), at: 0)
        XCTAssertEqual(scheduler.action(at: 0), .idle)
        scheduler.note(text("Alpha"), at: 0)
        XCTAssertEqual(scheduler.action(at: 0), .translate(text("Alpha")))
        scheduler.beginRequest(text("Alpha"), at: 0)
        scheduler.finishRequest(success: true, at: 0.05)
        // 请求结束得比限频间隔还快：按限频等剩下的时间。
        scheduler.note(text("Alpha beta"), at: 0.05)
        XCTAssertEqual(scheduler.action(at: 0.05),
                       .wait(PreviewTranslationPolicy.minimumRequestInterval - 0.05))
        // 文本一直在长（每次都是新的 pending）：截止时间不会被刷新，永不饿死。
        for step in 1...20 {
            scheduler.note(text(String(repeating: "a", count: 4 + step)), at: 0.05 * Double(step))
        }
        let deadline = scheduler.pendingSince + PreviewTranslationPolicy.maximumCoalescingDelay
        XCTAssertEqual(scheduler.action(at: deadline), .translate(scheduler.pending!),
                       "连续增长必须在截止时间前发出请求，不能被 debounce 拖成饥饿")
    }

    func testPreviewFailureBackoffIsBoundedAndResetsOnSuccess() {
        var scheduler = PreviewTranslationScheduler()
        let source = text("This sentence fails")
        scheduler.note(source, at: 0)
        XCTAssertEqual(scheduler.action(at: 0), .translate(source))
        var now: TimeInterval = 0
        var waits: [TimeInterval] = []
        for _ in 1...6 {
            scheduler.beginRequest(source, at: now)
            now += 0.05
            scheduler.finishRequest(success: false, at: now)
            // 失败后同一文本可以重试，但必须等退避，不能忙循环。
            scheduler.note(source, at: now)
            guard case .wait(let delay) = scheduler.action(at: now) else {
                return XCTFail("失败后应该退避等待，而不是立即重试")
            }
            XCTAssertGreaterThan(delay, 0)
            waits.append(delay)
            now += delay
        }
        let ladder: [TimeInterval] = [0.5, 1, 2, 4, 8, 8]
        XCTAssertEqual(waits.count, ladder.count)
        for (index, pair) in zip(waits, ladder).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: 1e-9, "第 \(index + 1) 次退避必须有界")
        }
        scheduler.beginRequest(source, at: now)
        scheduler.finishRequest(success: true, at: now + 0.05)
        XCTAssertEqual(scheduler.consecutiveFailures, 0, "成功后退避清零")
    }

    // MARK: 循环 + 假翻译器

    @MainActor
    func testPreviewRunnerTranslatesImmediatelyAndMergesInFlightGrowth() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("The temperature"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        XCTAssertEqual(harness.clock, 1_000, "首条初译开始时不该有固定等待")
        XCTAssertEqual(harness.requested, ["The temperature"])
        harness.changeSource(text("The temperature of"))
        harness.changeSource(text("The temperature of the"))
        harness.changeSource(text("The temperature of the system"))
        harness.release(1, .success("温度"))
        await harness.waitForRequest(2)
        XCTAssertEqual(harness.requested, ["The temperature", "The temperature of the system"],
                       "在途增长只合并为最新一条")
        XCTAssertEqual(harness.delivered.map(\.source), ["The temperature"],
                       "前缀兼容：旧的前缀初译仍然显示")
        loop.cancel()
        await harness.waitForLoopExit()
    }

    @MainActor
    func testPreviewRunnerRestartsRightAfterCompletionWithoutTheOldDelay() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("The temperature"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        harness.changeSource(text("The temperature of the system"))
        harness.release(1, .success("温度"))
        await harness.waitForRequest(2)
        XCTAssertEqual(harness.delivered.count, 1)
        // 请求一结束就排最新文本，只等限频的间隔，而不是旧的 800ms。
        XCTAssertEqual(harness.clock - 1_000, PreviewTranslationPolicy.minimumRequestInterval,
                       accuracy: 0.0001)
        XCTAssertEqual(harness.delivered.first?.timing.firstSourceToResult, 0,
                       "首条结果要带「首次出现文本 → 首条结果」的时序")
        XCTAssertGreaterThanOrEqual(harness.delivered.first?.timing.queue ?? -1, 0)
        XCTAssertGreaterThanOrEqual(harness.delivered.first?.timing.execute ?? -1, 0)
        harness.release(2, .success("系统的温度"))
        await harness.waitForDelivered(2)
        XCTAssertEqual(harness.delivered.map(\.translated), ["温度", "系统的温度"])
        XCTAssertNil(harness.delivered.last?.timing.firstSourceToResult, "首条结果以外的时序不重复记录")
        loop.cancel()
        await harness.waitForLoopExit()
    }

    /// 排队时间必须从「源文本最近一次变化」算起：请求在途期间到达的新文本
    /// 已经在等待，不能只从请求返回后调度器再次 note 的时刻起算。
    @MainActor
    func testPreviewRunnerQueueCountsTheTimeTheNewSourceWaitedInFlight() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("The temperature"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        // 请求还没有回来，文本已经变了；再等 0.8s 旧请求才结束。
        harness.clock += 0.2
        harness.changeSource(text("The temperature of the system"))
        harness.clock += 0.8
        harness.release(1, .success("温度"))
        await harness.waitForRequest(2)
        harness.release(2, .success("系统的温度"))
        await harness.waitForDelivered(2)
        guard let second = harness.delivered.last else { return XCTFail("缺少第二条初译") }
        XCTAssertEqual(second.timing.queue, 0.8, accuracy: 0.0001,
                       "queue 要从 1000.2 的源变化算到 1001.0 的请求开始")
        XCTAssertEqual(second.timing.schedulerDelay, 0, accuracy: 0.0001,
                       "调度器自身没有再额外等待")
        loop.cancel()
        await harness.waitForLoopExit()
    }

    @MainActor
    func testPreviewRunnerDropsResultAfterPrefixRewrite() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("The temperature of the system"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        // 识别纠正：新文本不再是旧文本的前缀，旧结果必须丢弃。
        harness.changeSource(text("A completely different sentence"))
        harness.release(1, .success("旧译文"))
        await harness.waitForRequest(2)
        XCTAssertTrue(harness.delivered.isEmpty, "前缀被改写后的旧结果不能串进界面")
        XCTAssertEqual(harness.requested,
                       ["The temperature of the system", "A completely different sentence"])
        harness.release(2, .success("新译文"))
        await harness.waitForDelivered(1)
        XCTAssertEqual(harness.delivered.map(\.translated), ["新译文"])
        loop.cancel()
        await harness.waitForLoopExit()
    }

    @MainActor
    func testPreviewRunnerRepeatsSameTextUnderNewRevisionAndDropsStaleResult() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("The temperature rises"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        // 修订号变化：文本相同，但这是新的会话/新的开关状态，旧结果作废。
        harness.changeSource(text("The temperature rises", revision: 1))
        harness.release(1, .success("旧译文"))
        await harness.waitForRequest(2)
        XCTAssertTrue(harness.delivered.isEmpty, "修订号变化后旧结果不能显示")
        XCTAssertEqual(harness.requested, ["The temperature rises", "The temperature rises"])
        harness.release(2, .success("新译文"))
        await harness.waitForDelivered(1)
        XCTAssertEqual(harness.delivered.map(\.translated), ["新译文"])
        loop.cancel()
        await harness.waitForLoopExit()
    }

    @MainActor
    func testPreviewRunnerDropsResultWhenPreviewWasDisabledMidRequest() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("The temperature rises"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        harness.active = false
        harness.release(1, .success("旧译文"))
        await harness.waitUntilIdle()
        XCTAssertTrue(harness.delivered.isEmpty, "关闭初译后返回的结果不能显示")
        loop.cancel()
        await harness.waitForLoopExit()
    }

    /// 会话被替换后旧 runner 必须自己退出，而不是在「不活跃」状态里无限等待。
    @MainActor
    func testPreviewRunnerExitsWhenTheSessionWasSuperseded() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("The temperature rises"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        harness.release(1, .success("温度"))
        await harness.waitForDelivered(1)
        await harness.waitUntilIdle()
        // 新会话接替：旧 runner 会被唤醒，检查令牌后直接结束。
        harness.superseded = true
        harness.active = false
        harness.wake()
        await harness.waitForLoopExit()
        XCTAssertEqual(harness.delivered.count, 1, "旧 runner 退出后不能再产出结果")
        XCTAssertFalse(loop.isCancelled, "退出靠令牌判断，不是靠取消")
    }

    @MainActor
    func testPreviewRunnerBacksOffAfterFailureAndCancelsCleanly() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("This sentence fails"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        harness.release(1, .failure(PreviewTestFailure.unavailable))
        await harness.waitForRequest(2)
        XCTAssertEqual(harness.clock - 1_000, 0.5, accuracy: 0.0001, "第一次失败退避 0.5s，不是忙循环")
        XCTAssertEqual(harness.failures.map(\.failures), [1])
        harness.release(2, .failure(PreviewTestFailure.unavailable))
        await harness.waitForRequest(3)
        XCTAssertEqual(harness.clock - 1_000, 1.5, accuracy: 0.0001, "第二次失败退避翻倍到 1s")
        XCTAssertEqual(harness.failures.map(\.failures), [1, 2])
        harness.release(3, .success("成功译文"))
        await harness.waitForDelivered(1)
        XCTAssertEqual(harness.delivered.map(\.translated), ["成功译文"])
        await harness.waitUntilIdle()
        loop.cancel()
        await harness.waitForLoopExit()
        XCTAssertEqual(harness.requested.count, 3, "取消后不应再发新请求")
    }

    /// 旧会话的失败退避不能拖慢新会话（否则一次失败会把新会话压住 8 秒）。
    @MainActor
    func testPreviewRunnerDoesNotCarryOldBackoffIntoTheNewRevision() async {
        let harness = PreviewLoopHarness()
        // 断言失败/提前返回也会走这里：取消循环并释放所有未完成的假请求，
        // 任何情况下都不会留下悬挂的 continuation。
        addTeardownBlock { await harness.shutdown() }
        harness.changeSource(text("This sentence fails"))
        let loop = harness.startLoop()
        await harness.waitForRequest(1)
        harness.release(1, .failure(PreviewTestFailure.unavailable))
        await harness.waitForRequest(2)
        harness.release(2, .failure(PreviewTestFailure.unavailable))
        // 同步地（先于 runner 恢复）切到新修订号：旧会话的 1s 退避必须失效。
        harness.changeSource(text("This sentence fails", revision: 1))
        harness.wake()
        await harness.waitForRequest(3)
        XCTAssertEqual(harness.clock - 1_000.5, PreviewTranslationPolicy.minimumRequestInterval,
                       accuracy: 0.0001, "新修订号只等限频间隔，不继承旧退避")
        harness.release(3, .success("新会话译文"))
        await harness.waitForDelivered(1)
        loop.cancel()
        await harness.waitForLoopExit()
    }

    /// 修订号变化要清掉旧会话的失败退避（纯调度层）。
    func testPreviewFailureBackoffResetsWhenTheRevisionChanges() {
        var scheduler = PreviewTranslationScheduler()
        var now: TimeInterval = 0
        let failing = text("Broken sentence")
        for _ in 1...5 {
            scheduler.note(failing, at: now)
            scheduler.beginRequest(failing, at: now)
            now += 0.01
            scheduler.finishRequest(success: false, at: now)
        }
        XCTAssertEqual(scheduler.consecutiveFailures, 5)
        XCTAssertEqual(PreviewTranslationPolicy.failureBackoff(consecutiveFailures: 5), 8)
        // 新会话（修订号变化）只受限频约束，不受旧退避约束。
        let renewed = text("Broken sentence", revision: 1)
        scheduler.note(renewed, at: now)
        XCTAssertEqual(scheduler.consecutiveFailures, 0, "修订号变化要重置失败计数")
        guard case .wait(let delay) = scheduler.action(at: now) else {
            return XCTFail("限频间隔内仍应等待")
        }
        XCTAssertLessThanOrEqual(delay, PreviewTranslationPolicy.minimumRequestInterval)
        XCTAssertEqual(scheduler.action(at: now + PreviewTranslationPolicy.minimumRequestInterval),
                       .translate(renewed))
    }

    @MainActor
    func testPreviewWakeSignalTimesOutAndWakesOnEvent() async {
        let signal = PreviewWakeSignal()
        let started = ProcessInfo.processInfo.systemUptime
        await signal.wait(timeout: 0.05)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.04,
                                    "没有事件时必须按超时返回，不能提前")
        signal.signal()
        await signal.wait(timeout: 5)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1,
                          "有事件时必须立即唤醒")
    }
}
