import Foundation
import XCTest
@testable import LiveLingo

/// 2026-09-22 摘要整改定向回归（**不加载模型** ✓、不碰真实录音／队列／App ✓）。
///
/// 覆盖三件事：
/// ① 后文已经明确给答案时，旧缺口必须从 `## 需要回听` 撤下并标"后文补充" ✓，
///    而缺编号／错编号／旧输入／来源对不上时**绝不能**撤下 ✓；旧批次、旧原文不改 ✓。
/// ② 数值来源核查不再拿裸数字集合下结论：编号（K7/M2）与同段多句支持不误报 ✓，
///    同数字不同单位／段落外的数字仍然报，并给具体缺口 ✓。
/// ③ 旧 Codable 数据、已完成批次、暂停／断点绑定保持兼容 ✓。
final class LearningFollowUpTests: XCTestCase {
    // MARK: - helpers

    private func segment(_ english: String, _ chinese: String = "", at time: Double = 0) -> TranscriptSegment {
        TranscriptSegment(startTime: time, endTime: time + 10, english: english, chinese: chinese)
    }

    private func section(_ markdown: String, _ title: String) -> String? {
        var lines: [String] = []
        var inside = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { inside = line.dropFirst(3) == title; continue }
            if inside { lines.append(String(line)) }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 一条"后文已经写明归属"的旧疑问 + 一条明确补充的新知识。
    private func uncertainNotebook() throws -> (notebook: LearningNotebook, target: String, original: LearningNoteBatch, first: TranscriptSegment) {
        var book = LearningNotebook()
        let first = segment("An 18 kilopascal pressure reading was taken before an inlet valve opened.",
                            "入口阀打开前测得压强18千帕，尚未说明属于哪个储罐。")
        try book.append(evidence: [first], note: LearningNote(topic: "压强", points: [
            LearningPoint(kind: "待确认", text: "18千帕的压强归属尚未说明。",
                          needsContext: "这项压强读数属于哪个储罐？", sourceIDs: ["zh0s0"])
        ], sourceVersion: 2, noNewKnowledge: false))
        let original = book.batches[0]
        let target = try XCTUnwrap(book.pendingPoints.first?.id)
        return (book, target, original, first)
    }

    private func supplementNote(text: String, sourceIDs: [String], followUp: LearningFollowUp?) -> LearningNote {
        LearningNote(topic: "压强归属", points: [
            LearningPoint(kind: "核心结论", text: text, sourceIDs: sourceIDs)
        ], sourceVersion: 2, noNewKnowledge: false, followUps: followUp.map { [$0] })
    }

    // MARK: - ① 后文补充与旧问题

    func testExplicitLaterSupplementRetiresTheOldQuestionAndKeepsHistory() throws {
        let (book, target, original, _) = try uncertainNotebook()
        var notebook = book
        let later = segment("The earlier 18 kilopascal reading belongs to Aurora and was measured before its inlet valve opened.",
                            "先前18千帕的压强属于Aurora罐，测量发生在该罐入口阀打开前。", at: 12)
        let note = supplementNote(text: "先前18千帕的压强属于Aurora罐，测量发生在该罐入口阀打开前。",
                                  sourceIDs: ["en0s0", "zh0s0"],
                                  followUp: LearningFollowUp(alias: "q0", state: .supplemented,
                                                             sourceIDs: ["en0s0", "zh0s0"],
                                                             detail: "后文明确说明了同一压强读数的储罐归属。"))
        let resolved = LearningPrompts.resolvingFollowUps(note, targets: [target])
        try notebook.append(evidence: [later], note: resolved)

        // 旧批次一个字节都没改：历史保留，旧问题、旧原文、旧状态都在。
        XCTAssertEqual(notebook.batches[0], original)
        XCTAssertEqual(notebook.batches[0].note.points[0].needsContext, "这项压强读数属于哪个储罐？")
        XCTAssertTrue(notebook.markdown().contains("18千帕的压强归属尚未说明。"))
        // 旧缺口从“需要回听”撤下，并在历史记录下标出“后文补充”。
        XCTAssertEqual(notebook.retiredQuestionReferences, [target])
        let replay = section(notebook.markdown(), LearningNotebook.replayHeading)
        XCTAssertNil(replay, "撤下后不该再有需要回听一节：\(replay ?? "")")
        let rendered = notebook.markdown()
        XCTAssertTrue(rendered.contains("后文补充"))
        XCTAssertTrue(rendered.contains("不代表知识已核实"))
        XCTAssertTrue(rendered.contains("先前18千帕的压强属于Aurora罐"))
        // 撤下后不再被当成待跟进问题重复提问。
        let next = segment("Boreal had a pressure of 31 kilopascals.", "Boreal罐压强31千帕。", at: 24)
        XCTAssertFalse(notebook.selectPendingPoints(for: [next]).map(\.id).contains(target))
        let committed = try XCTUnwrap(notebook.batches[1].followUps?.first)
        XCTAssertEqual(committed.state, .supplemented)
        XCTAssertEqual(committed.target, target)
        XCTAssertEqual(committed.pointIndex, 0)
        XCTAssertEqual(committed.evidenceIDs, [later.id])
        XCTAssertEqual(committed.notebookRevision, 1)
    }

    func testBilingualCounterpartAfterExactCitationCanSupportFollowUp() throws {
        let (book, target, _, _) = try uncertainNotebook()
        var notebook = book
        let later = segment("The earlier 18 kilopascal reading belongs to Aurora. It was measured before the valve opened.",
                            "先前18千帕的压强属于Aurora罐，测量发生在阀打开前。", at: 12)
        let note = supplementNote(text: "先前18千帕的压强属于Aurora罐，测量发生在阀打开前。",
                                  sourceIDs: ["en0s0", "en0s1"],
                                  followUp: LearningFollowUp(alias: "q0", state: .supplemented,
                                                             sourceIDs: ["en0s0", "zh0s0"],
                                                             detail: "后文明确说明了同一读数的归属。"))
        try notebook.append(evidence: [later], note: LearningPrompts.resolvingFollowUps(note, targets: [target]))
        XCTAssertEqual(notebook.batches[1].followUps?.first?.state, .supplemented)
        XCTAssertEqual(notebook.retiredQuestionReferences, [target])
    }

    /// 真 4B 在旧协议下的实际响应（`clarifies` 全空、也没有 followUps）不能消除旧问题。
    func testMissingFollowUpCannotRetireTheOldQuestion() throws {
        let (book, target, _, _) = try uncertainNotebook()
        var notebook = book
        let later = segment("The earlier 18 kilopascal reading belongs to Aurora.",
                            "先前18千帕的压强属于Aurora罐。", at: 12)
        let legacy = LearningNote(topic: "压强归属", points: [
            LearningPoint(kind: "核心结论", text: "先前18千帕的压强属于Aurora罐。", sourceIDs: ["en0s0", "zh0s0"])
        ], sourceVersion: 2, noNewKnowledge: false)
        try notebook.append(evidence: [later], note: LearningPrompts.resolvingFollowUps(legacy, targets: [target]))
        XCTAssertTrue(notebook.retiredQuestionReferences.isEmpty)
        XCTAssertNotNil(section(notebook.markdown(), LearningNotebook.replayHeading))
        XCTAssertTrue(notebook.markdown().contains("属于哪个储罐"))
        XCTAssertEqual(notebook.batches[1].followUps?.first?.state, .missing)
        XCTAssertTrue(notebook.selectPendingPoints(for: [later]).map(\.id).contains(target))
    }

    func testUnknownAliasAndStaleTargetAreNeverApplied() throws {
        let (book, target, _, _) = try uncertainNotebook()
        // 错编号：只给了 q7，q0 必须补成“缺信息”，旧问题保留。
        let wrong = LearningNote(topic: "压强归属", points: [
            LearningPoint(kind: "核心结论", text: "无关内容。", sourceIDs: ["en0s0"])
        ], sourceVersion: 2, noNewKnowledge: false,
           followUps: [LearningFollowUp(alias: "q7", state: .supplemented, sourceIDs: ["en0s0"])])
        var notebook = book
        try notebook.append(evidence: [segment("The earlier reading belongs to Aurora.", "先前读数属于Aurora罐。", at: 12)],
                            note: LearningPrompts.resolvingFollowUps(wrong, targets: [target]))
        XCTAssertEqual(notebook.batches[1].followUps?.count, 1)
        XCTAssertEqual(notebook.batches[1].followUps?.first?.state, .missing)
        XCTAssertTrue(notebook.retiredQuestionReferences.isEmpty)

        // 旧输入：目标不是当前待跟进的问题（例如已经被别的批次接手）时直接丢弃。
        var stale = book
        var record = LearningFollowUp(alias: "q0", target: "00000000-0000-0000-0000-000000000000:0", state: .supplemented)
        record.sourceIDs = ["en0s0"]
        try stale.append(evidence: [segment("The earlier reading belongs to Aurora.", "先前读数属于Aurora罐。", at: 12)],
                         note: LearningNote(topic: "压强归属", points: [
                            LearningPoint(kind: "核心结论", text: "先前读数属于Aurora罐。", sourceIDs: ["en0s0", "zh0s0"])
                         ], sourceVersion: 2, noNewKnowledge: false, followUps: [record]))
        XCTAssertNil(stale.batches[1].followUps)
        XCTAssertTrue(stale.retiredQuestionReferences.isEmpty)
        XCTAssertTrue(stale.markdown().contains("属于哪个储罐"))
    }

    /// 声称"后文补充"但同一次来源对不上（编造 id / 没有依据 / 指向别的要点）→ 降级为关系不明，旧问题保留。
    func testSupplementWithoutSameTurnSourcesIsDowngradedAndQuestionStays() throws {
        let (book, target, _, _) = try uncertainNotebook()
        for sources in [["en9s9"], [], ["en0s0"], ["en0s0", "en9s9"]] {
            var notebook = book
            let later = segment("The earlier 18 kilopascal reading belongs to Aurora.",
                                "先前18千帕的压强属于Aurora罐。", at: 12)
            // 新知识只引用中文句；上面的 follow-up 来源都不能在它身上对上。
            let note = supplementNote(text: "先前18千帕的压强属于Aurora罐。", sourceIDs: ["zh0s0"],
                                      followUp: LearningFollowUp(alias: "q0", state: .supplemented,
                                                                 sourceIDs: sources, detail: "后文说明归属。"))
            try notebook.append(evidence: [later], note: LearningPrompts.resolvingFollowUps(note, targets: [target]))
            let committed = try XCTUnwrap(notebook.batches[1].followUps?.first)
            XCTAssertNotEqual(committed.state, .supplemented, "来源 \(sources) 不该撤下旧问题")
            XCTAssertEqual(committed.state, .unclear)
            XCTAssertTrue(notebook.retiredQuestionReferences.isEmpty)
            XCTAssertTrue(notebook.markdown().contains("属于哪个储罐"))
            XCTAssertTrue(notebook.markdown().contains("关系仍不明"))
        }
    }

    func testConflictKeepsTheQuestionWithTimeAndDetail() throws {
        let (book, target, _, _) = try uncertainNotebook()
        var notebook = book
        let later = segment("The lecturer now says the 18 kilopascal reading was taken after the valve opened.",
                            "讲述者此时说18千帕是在阀打开之后测得的。", at: 12)
        let note = supplementNote(text: "讲述者此时说18千帕是在阀打开之后测得的。", sourceIDs: ["en0s0", "zh0s0"],
                                  followUp: LearningFollowUp(alias: "q0", state: .conflict, sourceIDs: ["en0s0"],
                                                             detail: "先前说打开前测得，后文说打开后测得。"))
        try notebook.append(evidence: [later], note: LearningPrompts.resolvingFollowUps(note, targets: [target]))
        XCTAssertTrue(notebook.retiredQuestionReferences.isEmpty)
        let replay = try XCTUnwrap(section(notebook.markdown(), LearningNotebook.replayHeading))
        XCTAssertTrue(replay.contains("属于哪个储罐"))
        let rendered = notebook.markdown()
        XCTAssertTrue(rendered.contains("与此前记录冲突"))
        XCTAssertTrue(rendered.contains("先前说打开前测得，后文说打开后测得。"))
        XCTAssertTrue(rendered.contains("后文（[00:12–00:22]）"))
    }

    func testFollowUpJudgementNeedsNoExtraModelRequestAndFreezesAliases() throws {
        let (initial, target, _, _) = try uncertainNotebook()
        var book = initial
        let later = segment("The earlier 18 kilopascal reading belongs to Aurora.",
                            "先前18千帕的压强属于Aurora罐。", at: 12)
        let input = try LearningPrompts.input(evidence: [later], topics: book.topics, pending: book.selectPendingPoints(for: [later]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["evidence", "pendingPoints"])
        let pending = try XCTUnwrap(object["pendingPoints"] as? [[String: Any]])
        XCTAssertEqual(pending.compactMap { $0["id"] as? String }, ["q0"])
        XCTAssertEqual(book.selectPendingPoints(for: [later]).map(\.id), [target])

        let note = supplementNote(text: "先前18千帕的压强属于Aurora罐。", sourceIDs: ["en0s0", "zh0s0"],
                                  followUp: LearningFollowUp(alias: "q0", state: .supplemented, sourceIDs: ["en0s0", "zh0s0"]))
        let resolved = LearningPrompts.resolvingFollowUps(note, targets: [target])
        XCTAssertEqual(resolved.followUps?.map(\.target), [target])
        XCTAssertEqual(resolved.followUps?.map(\.alias), ["q0"])
        // 一次 append 就把新知识 + 跟进记录一起提交；没有第二次模型请求。
        var notebook = book
        try notebook.append(evidence: [later], note: resolved)
        XCTAssertEqual(notebook.batches.count, 2)
        XCTAssertEqual(notebook.batches[1].followUps?.count, 1)
        XCTAssertNil(notebook.batches[1].note.followUps, "跟进记录只保存在新批次上")
    }

    // MARK: - ② 数值来源核查

    private func boundPoint(_ text: String, evidence: [TranscriptSegment], ids: [String]) -> LearningPoint? {
        let note = LearningNote(topic: "数值", points: [
            LearningPoint(kind: "核心结论", text: text, sourceIDs: ids)
        ], sourceVersion: 2, noNewKnowledge: false)
        return note.binding(evidence: evidence).points.first
    }

    func testIdentifiersAreNotMeasuredValues() throws {
        let source = segment("The label is an opaque identifier rather than a numerical sequence.",
                             "标签仅用于识别样品，不表示数值序列。")
        let point = try XCTUnwrap(boundPoint("样品标签（如K7、M2等）仅为不透明标识符，不表示数值序列。",
                                             evidence: [source], ids: ["en0s0", "zh0s0"]))
        XCTAssertEqual(point.referenceState, .linked)
        XCTAssertNil(point.numericGap)
        XCTAssertNil(LearningNotebook.sourceCheckReason(point))
    }

    func testCrossSentenceConditionInsideTheCitedSegmentIsNotAMismatch() throws {
        // 真样本 pump-conditions-and-negation：同一字幕段里，第 2 句说的“两个条件”
        // 就是第 1 句的“全开阀 + 20 摄氏度”，不能因为在同一句引文里找不到 20 就报警。
        let source = segment("For pump D, a fully open inlet valve and a constant water temperature of 20 degrees Celsius give a steady flow of 12 litres per minute. Both stated conditions must hold throughout the entire measured interval.",
                             "本实验中，D泵在入口阀完全打开且水温恒为20摄氏度时，稳定流量为每分钟12升。两个条件须在整个测量时段内同时成立。")
        let point = try XCTUnwrap(boundPoint("入口阀完全打开且水温恒为20摄氏度这两个条件须在整个测量时段内同时成立。",
                                             evidence: [source], ids: ["en0s1", "zh0s1"]))
        XCTAssertEqual(point.referenceState, .linked)
        XCTAssertNil(point.numericGap)
    }

    func testSameNumberWithADifferentUnitIsStillReported() throws {
        let source = segment("An 18 kilopascal pressure reading was taken before an inlet valve opened.",
                             "入口阀打开前测得压强18千帕。")
        let point = try XCTUnwrap(boundPoint("混合后Boreal罐的温度为18摄氏度。",
                                             evidence: [source], ids: ["en0s0", "zh0s0"]))
        XCTAssertEqual(point.referenceState, .numericDifference)
        let gap = try XCTUnwrap(point.numericGap)
        XCTAssertTrue(gap.contains("18摄氏度"))
        XCTAssertTrue(gap.contains("单位不同"))
        // 明确可判的差异保留原有固定措辞 ✓，具体缺口附在同一行末尾 ✓。
        XCTAssertEqual(LearningNotebook.sourceCheckReason(point),
                       "笔记数值与引用原文不同，可能是换算或推导，需要人工核对")
        XCTAssertTrue(LearningNotebook.numericGapSuffix(point).contains("18摄氏度"))
        XCTAssertFalse(point.hasOpenQuestion, "程序提示不能变成模型提问")
    }

    func testUnmeasuredBareNumberGetsASpecificGapInsteadOfAVerdict() throws {
        let source = segment("The run was completed without further detail.", "本次运行已完成，没有更多说明。")
        let point = try XCTUnwrap(boundPoint("本次运行的结果为7。", evidence: [source], ids: ["en0s0", "zh0s0"]))
        XCTAssertEqual(point.referenceState, .linked, "无法判定的裸数字不下“数值不同”结论")
        let gap = try XCTUnwrap(point.numericGap)
        XCTAssertTrue(gap.contains("没有单位或属性说明"))
        XCTAssertFalse(point.hasOpenQuestion)
    }

    /// 真样本 pump-conditions-and-negation：同一批原文的**另一条字幕**说了 20 摄氏度，
    /// 但这条要点引用的是“两个条件须…同时成立”。不判“数值与原文不同” ✗，只给具体缺口 ✓。
    func testNumberInAnotherSubtitleLineBecomesASpecificGapNotAVerdict() throws {
        let conditions = segment("For pump D, a fully open inlet valve and a constant water temperature of 20 degrees Celsius give a steady flow of 12 litres per minute.",
                                 "本实验中，D泵在入口阀完全打开且水温恒为20摄氏度时，稳定流量为每分钟12升。")
        let holds = segment("Both stated conditions must hold throughout the entire measured interval.",
                            "两个条件须在整个测量时段内同时成立。")
        let point = try XCTUnwrap(boundPoint("入口阀完全打开且水温恒为20摄氏度这两个条件须在整个测量时段内同时成立。",
                                             evidence: [conditions, holds], ids: ["en1s0", "zh1s0"]))
        XCTAssertEqual(point.referenceState, .linked, "同批其他句子有依据时不下“数值不同”结论")
        let gap = try XCTUnwrap(point.numericGap)
        XCTAssertTrue(gap.contains("20摄氏度"))
        XCTAssertTrue(gap.contains("不在所引原句里"))
        XCTAssertFalse(gap.contains("单位不同"))
    }

    /// 整批输入里都找不到的数字仍然是明确可判的差异 ✓。
    func testNumberMissingFromTheWholeBatchIsStillAVerdict() throws {
        let source = segment("The first chamber was sealed.", "第一个腔室已密封。")
        let point = try XCTUnwrap(boundPoint("第一个腔室的平衡温度为327开尔文。", evidence: [source], ids: ["en0s0", "zh0s0"]))
        XCTAssertEqual(point.referenceState, .numericDifference)
        XCTAssertTrue(try XCTUnwrap(point.numericGap).contains("在本次原文里找不到"))
    }

    /// 别批出现过的同数字不参与本次判断：不整课搜数字 ✓。
    func testSameNumberFromAnotherBatchNeverPasses() throws {
        var notebook = LearningNotebook()
        try notebook.append(evidence: [segment("The sealed sample labelled V3 has an equilibrium temperature of 327 kelvin.",
                                               "密封样品V3的平衡温度为327开尔文。")],
                            note: LearningNote(topic: "样品", points: [
                                LearningPoint(kind: "核心结论", text: "密封样品V3的平衡温度为327开尔文。", sourceIDs: ["en0s0", "zh0s0"])
                            ], sourceVersion: 2, noNewKnowledge: false))
        let second = segment("The first chamber was sealed.", "第一个腔室已密封。", at: 12)
        try notebook.append(evidence: [second], note: LearningNote(topic: "腔室", points: [
            LearningPoint(kind: "核心结论", text: "第一个腔室的平衡温度为327开尔文。", sourceIDs: ["en0s0", "zh0s0"])
        ], sourceVersion: 2, noNewKnowledge: false))
        XCTAssertEqual(notebook.batches[1].note.points[0].referenceState, .numericDifference)
    }

    func testProgramOwnedGapIsIgnoredWhenTheResponseSuppliesOne() throws {
        let source = segment("The run was completed.", "本次运行已完成。")
        let note = LearningNote(topic: "数值", points: [
            LearningPoint(kind: "核心结论", text: "本次运行的结果为7。", sourceIDs: ["en0s0"], numericGap: "模型自己写的缺口")
        ], sourceVersion: 2, noNewKnowledge: false)
        let point = try XCTUnwrap(note.binding(evidence: [source]).points.first)
        XCTAssertNotEqual(point.numericGap, "模型自己写的缺口")
        XCTAssertTrue(try XCTUnwrap(point.numericGap).contains("没有单位或属性说明"))
    }

    // MARK: - ③ 兼容与断点绑定

    func testOldCodableDataWithoutFollowUpsStillDecodes() throws {
        let legacyNote = """
        {"sourceVersion":2,"topic":"旧主题","noNewKnowledge":false,"points":[{"kind":"核心结论","text":"旧要点","sourceIDs":["en0s0"],"needsContext":null,"clarifies":null}]}
        """
        let note = try LearningNote.decode(legacyNote)
        XCTAssertNil(note.followUps)
        let legacyBatch = """
        {"id":"00000000-0000-0000-0000-0000000000AA","evidence":[],"note":\(legacyNote)}
        """
        let batch = try JSONDecoder().decode(LearningNoteBatch.self, from: Data(legacyBatch.utf8))
        XCTAssertNil(batch.followUps)
    }

    func testFollowUpsRoundTripInBothWireAndStoredShapes() throws {
        let wire = """
        {"sourceVersion":2,"topic":"主题","noNewKnowledge":false,"points":[{"kind":"核心结论","text":"新知识","sourceIDs":["en0s0"],"needsContext":null}],"followUps":{"q1":{"state":"前后冲突","sourceIDs":["en0s0"],"detail":"冲突说明"},"q0":{"state":"后文补充","sourceIDs":["en0s0"],"detail":"补充说明"}}}
        """
        let note = try LearningNote.decode(wire)
        XCTAssertEqual(note.followUps?.map(\.alias), ["q0", "q1"])
        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(LearningNote.self, from: data)
        XCTAssertEqual(decoded, note)
        let batch = LearningNoteBatch(id: UUID(), evidence: [segment("A.", "甲。")], note: note,
                                      followUps: [LearningFollowUp(alias: "q0", target: "ref:0", state: .conflict,
                                                                  sourceIDs: ["en0s0"], detail: "冲突")])
        let batchData = try JSONEncoder().encode(batch)
        XCTAssertEqual(try JSONDecoder().decode(LearningNoteBatch.self, from: batchData), batch)
    }

    func testSnapshotRoundTripKeepsFollowUpsAndRetirement() throws {
        let (book, target, _, _) = try uncertainNotebook()
        var notebook = book
        let later = segment("The earlier 18 kilopascal reading belongs to Aurora.",
                            "先前18千帕的压强属于Aurora罐。", at: 12)
        let note = supplementNote(text: "先前18千帕的压强属于Aurora罐。", sourceIDs: ["en0s0", "zh0s0"],
                                  followUp: LearningFollowUp(alias: "q0", state: .supplemented, sourceIDs: ["en0s0", "zh0s0"]))
        try notebook.append(evidence: [later], note: LearningPrompts.resolvingFollowUps(note, targets: [target]))
        var snapshot = SessionSnapshot(segments: [segment("x", "y")])
        notebook.writeState(to: &snapshot)
        let restored = try LearningNotebook(snapshot: snapshot)
        XCTAssertEqual(restored.batches, notebook.batches)
        XCTAssertEqual(restored.retiredQuestionReferences, [target])
        XCTAssertTrue(restored.markdown().contains("后文补充"))
    }

    func testMissingFollowUpTargetStaysHistoricalButSelfReferenceIsRejected() throws {
        let later = segment("Later text.", "后文。")
        let missing = "00000000-0000-0000-0000-0000000000AA:0"
        let note = LearningNote(topic: "主题", points: [
            LearningPoint(kind: "核心结论", text: "要点", sourceIDs: ["en0s0"])
        ], sourceVersion: 2, noNewKnowledge: false)
        var snapshot = SessionSnapshot(segments: [later])
        snapshot.batches = [LearningNoteBatch(id: UUID(), evidence: [later], note: note,
                                              followUps: [LearningFollowUp(alias: "q0", target: missing,
                                                                           state: .conflict, detail: "冲突")])]
        XCTAssertNoThrow(try LearningNotebook(snapshot: snapshot), "目标已被来源修订移除时保留历史")

        // 记录只能指向更早的要点：指向自己（前向引用）的旧数据必须被拒绝。
        let second = segment("Second text.", "第二段。")
        let secondID = UUID()
        let secondNote = LearningNote(topic: "主题", points: [
            LearningPoint(kind: "核心结论", text: "第二要点", sourceIDs: ["en0s0"])
        ], sourceVersion: 2, noNewKnowledge: false)
        var forward = SessionSnapshot(segments: [later, second])
        forward.batches = [
            LearningNoteBatch(id: UUID(), evidence: [later], note: note),
            LearningNoteBatch(id: secondID, evidence: [second], note: secondNote,
                              followUps: [LearningFollowUp(alias: "q0", target: "\(secondID.uuidString):0",
                                                           state: .conflict, detail: "冲突")])
        ]
        XCTAssertThrowsError(try LearningNotebook(snapshot: forward))
    }

    func testStalePromptDigestOnlyDiscardsTheUnfinishedPrefix() throws {
        let source = segment("Its speed is 8 m/s.", "速度为8 m/s。")
        var snapshot = SessionSnapshot(segments: [source])
        let draft = LearningDraft(evidence: [source], model: "4b", input: "frozen input", text: "partial")
        let checkpoint = draft.checkpoint(sessionID: snapshot.sessionID, inputRevision: 0, generation: 0)
        XCTAssertEqual(checkpoint.promptDigest, SessionArchiveCoding.digest(Data(LearningPrompts.generate.utf8)))
        XCTAssertNotNil(LearningDraft(checkpoint: checkpoint, snapshot: snapshot, model: "4b"))
        var stale = checkpoint
        stale.promptDigest = SessionArchiveCoding.digest(Data("旧协议提示词".utf8))
        XCTAssertNil(LearningDraft(checkpoint: stale, snapshot: snapshot, model: "4b"),
                     "协议改版后旧前缀必须废弃，但不能影响已完成批次")
        var completed = checkpoint
        completed.completedNote = LearningNote(topic: "旧主题", points: [
            LearningPoint(kind: "核心结论", text: "已完成要点", sourceIDs: ["en0s0"])
        ], sourceVersion: 2, noNewKnowledge: false)
        try? snapshot.generationCheckpoints.append(checkpoint)
        XCTAssertEqual(snapshot.batches.count, 0, "已完成批次不被断点改动")
    }
}
