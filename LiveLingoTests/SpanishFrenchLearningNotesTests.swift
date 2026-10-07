import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class SpanishFrenchLearningNotesTests: XCTestCase {
    private let targets: [CaptionTranslationTarget] = [.spanish, .french]
    private func text(_ target: CaptionTranslationTarget) -> String {
        target == .spanish ? "Su masa es 3,14 gramos." : "Sa masse est de 3,14 grammes."
    }
    private func foreign(_ target: CaptionTranslationTarget, at time: Double = 0) -> TranscriptSegment {
        .init(startTime: time, endTime: time + 1, english: "质量为 3.14 克。", chinese: text(target), sourceLanguage: "zh")
    }
    private func note(_ target: CaptionTranslationTarget, ids: [String]? = nil) -> LearningNote {
        .init(topic: "Masa / Masse", points: [.init(kind: "例子", text: text(target),
            sourceIDs: ids ?? [target.rawValue + "0s0"])], sourceVersion: 2, noNewKnowledge: false)
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    func testLiteralPromptsRemainUnreleasedAndUseNeutralNames() {
        for target in targets {
            XCTAssertFalse(target.learningNotePrompt.isEmpty)
            XCTAssertTrue(target.learningNotePrompt.contains(target.promptName))
            XCTAssertTrue(target.learningReviewPrompt.contains("en/" + target.rawValue))
            XCTAssertNil(LearningReviewQueue.reviewPrompt(for: target.rawValue))
            XCTAssertEqual(LearningReviewQueue.reviewPrompt(for: target.rawValue, allowUnreleased: true), target.learningReviewPrompt)
            XCTAssertEqual(LearningPrompts.generationPrompt(target: target), target.learningNotePrompt)
            XCTAssertFalse(OutputLanguage(rawValue: target.rawValue)!.isReleased)
        }
    }
    func testArabicLocaleValuesBindAcrossEnglishAndTargetGroups() {
        for target in targets {
            let grouped = target == .spanish ? "1.000" : "1\u{202F}000"
            let caption = target == .spanish ? "La masa es " + grouped + " gramos." : "La masse est de " + grouped + " grammes."
            let source = TranscriptSegment(startTime: 0, endTime: 1, english: "The mass is 1,000 grams.", chinese: caption, sourceLanguage: "en")
            let n = LearningNote(topic: "Mass", points: [.init(kind: "核心结论", text: caption,
                sourceIDs: ["en0s0"])], sourceVersion: 2, noNewKnowledge: false).binding(evidence: [source], target: target)
            XCTAssertEqual(n.points[0].referenceState, .linked)
            XCTAssertNil(n.points[0].numericGap)
            let same = note(target).binding(evidence: [foreign(target)], target: target)
            XCTAssertEqual(same.points[0].referenceState, .linked)
            XCTAssertNil(same.points[0].numericGap)
            var wrong = note(target); wrong.points[0].text = text(target).replacingOccurrences(of: "3,14", with: "314")
            XCTAssertEqual(wrong.binding(evidence: [foreign(target)], target: target).points[0].referenceState, .numericDifference)
            XCTAssertEqual(LatinNumericParser.numbers(in: grouped + ",50", language: target.rawValue), ["10005e-1"])
            XCTAssertEqual(LatinNumericParser.numbers(in: "-3,14 +9,01e2", language: target.rawValue), ["-314e-2", "901e0"])
            XCTAssertTrue(LatinNumericParser.numbers(in: "1,2,3", language: target.rawValue).isEmpty)
        }
    }
    func testSourceIDsAndNumericScopeRejectForeignAndHistoricalColumns() {
        for target in targets {
            for invalid in ["zh0s0", "h0", "de0s0"] {
                XCTAssertEqual(note(target, ids: [invalid]).binding(evidence: [foreign(target)], target: target).points[0].referenceState, .unlinked)
            }
            let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "质量为 314 克。", chinese: text(target), sourceLanguage: "zh")
            var claim = note(target); claim.points[0].text = text(target).replacingOccurrences(of: "3,14", with: "314")
            XCTAssertEqual(claim.binding(evidence: [segment], target: target).points[0].referenceState, .numericDifference)
            XCTAssertEqual(LearningSourceUnit.make([segment], target: target).map(\.language), [target.rawValue])
        }
    }
    func testSameLanguagePassThroughIgnoresStoredChineseAndPronounsFollowSourceLanguage() {
        for target in targets {
            let own = TranscriptSegment(startTime: 0, endTime: 1, english: text(target), chinese: "旧中文", sourceLanguage: target.rawValue)
            XCTAssertEqual(LearningSourceUnit.textGroups(for: own, target: target).map(\.text), [text(target)])
            XCTAssertTrue(note(target).binding(evidence: [own], target: target).points[0].sourceHasPronoun == true)
        }
        let en = TranscriptSegment(startTime: 0, endTime: 1, english: "The son studies mass.", chinese: "Le fils étudie la masse.", sourceLanguage: "en")
        let n = LearningNote(topic: "Mass", points: [.init(kind: "例子", text: "Le fils étudie la masse.", sourceIDs: ["en0s0"])], sourceVersion: 2, noNewKnowledge: false)
        XCTAssertEqual(n.binding(evidence: [en], target: .french).points[0].sourceHasPronoun, false)
        for pronoun in ["son", "sa", "ses", "leur", "leurs"] {
            let own = TranscriptSegment(startTime: 0, endTime: 1, english: pronoun + " masse change.", sourceLanguage: "fr")
            var n = note(.french); n.points[0].sourceIDs = ["fr0s0"]
            XCTAssertEqual(n.binding(evidence: [own], target: .french).points[0].sourceHasPronoun, true)
        }
    }
    func testAccentedRetrievalAndStopWordsReachPendingAndLaterEvidence() throws {
        for target in targets {
            let accent = target == .spanish ? "presión" : "température"
            let stop = target == .spanish ? "el la los las de en y su sus" : "le la les des de en et sa ses leur"
            XCTAssertEqual(LearningNotebook.terms(stop + " " + accent, target: target), [accent])
            let decomposed = accent.decomposedStringWithCanonicalMapping
            XCTAssertEqual(LearningNotebook.terms(decomposed, target: target), [accent])
            let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "来源", chinese: accent + " change.", sourceLanguage: "zh")
            var book = LearningNotebook(target: target)
            try book.append(evidence: [segment], note: .init(topic: accent, points: [.init(kind: "待确认", text: accent,
                needsContext: "?", referenceState: .pending)]))
            let next = TranscriptSegment(startTime: 2, endTime: 3, english: "后文", chinese: accent + " stable.", sourceLanguage: "zh")
            XCTAssertEqual(book.selectPendingPoints(for: [next]).count, 1)
            let later = LearningNoteBatch(id: UUID(), evidence: [next], note: .init(topic: accent, points: []))
            let review = try object(LearningPrompts.reviewInput(book.batches[0], laterBatches: [later], target: target).json)
            XCTAssertFalse((review["laterEvidence"] as? [Any] ?? []).isEmpty)
        }
    }
    func testLegacyPendingFallbackAndQuoteOriginsAreTargetBound() throws {
        for target in targets {
            let evidence = [foreign(target)]
            let old = LearningNote(topic: "Mass", points: [.init(kind: "待确认", text: "?",
                sources: [.init(index: 0, quote: "质量为 3.14 克。")], needsContext: "?", referenceState: .pending)])
            let batch = LearningNoteBatch(id: UUID(), evidence: evidence, note: old)
            let book = try LearningNotebook(snapshot: SessionSnapshot(segments: evidence, batches: [batch], targetLocale: target.rawValue))
            let pending = try XCTUnwrap(book.pendingPoints.first)
            XCTAssertEqual(pending.quotes, [text(target)])
            XCTAssertEqual(pending.quoteOrigins.flatMap { $0 }.map(\.language), [target.rawValue])
            let input = try LearningPrompts.input(evidence: [foreign(target, at: 3)], topics: [], pending: [pending], target: target)
            XCTAssertFalse(input.contains("质量为"))
            let root = try object(input)
            XCTAssertEqual((root["priorEvidence"] as? [[String: Any]])?.first?["text"] as? String, text(target))
            XCTAssertFalse((root["pendingEvidenceRule"] as? String ?? "").contains("旧原文"))
        }
    }
    func testEnglishFallbackKeepsSeparateGroupsAndTheirOrigins() throws {
        for target in targets {
            let source = TranscriptSegment(startTime: 0, endTime: 1, english: "Its mass is 3.14 grams.", chinese: text(target), sourceLanguage: "en")
            var book = LearningNotebook(target: target)
            try book.append(evidence: [source], note: .init(topic: "Mass", points: [.init(kind: "待确认", text: "?", needsContext: "?", referenceState: .pending)]))
            let pending = try XCTUnwrap(book.pendingPoints.first)
            XCTAssertEqual(pending.quotes, [source.english, text(target)])
            XCTAssertEqual(pending.quoteOrigins.flatMap { $0 }.map(\.index), [0, 0])
            XCTAssertEqual(pending.quoteOrigins.flatMap { $0 }.map(\.language), ["en", target.rawValue])
            let json = try object(LearningPrompts.input(evidence: [foreign(target, at: 3)], topics: [], pending: [pending], target: target))
            let history = try XCTUnwrap(json["priorEvidence"] as? [[String: Any]])
            XCTAssertEqual(history.compactMap { ($0["locations"] as? [[String: Any]])?.first?["language"] as? String }, ["en", target.rawValue])
        }
    }
    func testIndependentLearningPromptDigestsAreFrozen() {
        let expected: [(CaptionTranslationTarget, [String])] = [
            (.spanish, ["55a0a2e95bd0e207ecf00e6787b98a5b7ee635eaeb7c14ed14df5f39a9c2f30d", "66087ccda675a66be0aa52ef1ce91add69224ea4f76efb0265c054505ea1f2ba", "19789a9068af441b4db0d2082ecb0350117729e816e757e618234c3332589bc5"]),
            (.french, ["0894e13c4f69a1e08401a8878d6a0f2c1549ad366ee96bda466cd6c5254465a0", "49a1e81fde20c0a12847c68850ee7731615591e1b8cce2a045c553f642713c84", "cb345034aabdc6c6384c8081c421e67d3da8e01bda5572b7387bf7244298ac5b"])]
        for (target, hashes) in expected {
            let prompts = [target.learningNotePrompt, target.learningReviewPrompt,
                LearningPrompts.generationPrompt(target: target, recoveringAfterOutputLimit: true)]
            XCTAssertEqual(prompts.map { SessionArchiveCoding.digest(Data($0.utf8)) }, hashes)
        }
    }
    func testNotebookCommitsFollowUpsWithoutRewritingEarlierNote() throws {
        for target in targets {
            var book = LearningNotebook(target: target)
            var first = note(target); first.points[0].kind = "待确认"; first.points[0].needsContext = "?"
            try book.append(evidence: [foreign(target)], note: first)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let frozen = try encoder.encode(book.batches[0].note)
            let pending = try XCTUnwrap(book.pendingPoints.first)
            var next = note(target)
            next.followUps = [.init(alias: "q0", target: pending.id, state: .supplemented, sourceIDs: [target.rawValue + "0s0"], detail: text(target))]
            try book.append(evidence: [foreign(target, at: 3)], note: next)
            XCTAssertEqual(try encoder.encode(book.batches[0].note), frozen)
            XCTAssertEqual(book.batches[1].followUps?.first?.state, .supplemented)
            XCTAssertTrue(book.pendingPoints.isEmpty)
            XCTAssertTrue(book.markdown().contains(LearningFollowUp.State.supplemented.label(target: target)))
        }
    }
    func testActualReviewQueueForwardsPromptInputAndPrefix() async throws {
        for target in targets {
            let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SpanishFrenchReview-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var book = LearningNotebook(target: target); try book.append(evidence: [foreign(target)], note: note(target))
            var snapshot = SessionSnapshot(segments: book.batches.flatMap(\.evidence), targetLocale: target.rawValue)
            book.writeState(to: &snapshot); try SessionStore(directory: root).save(snapshot)
            let journal = root.appendingPathComponent("queue.json")
            var calls = 0
            let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled) { input, prefix, prompt, _, _ in
                calls += 1
                XCTAssertEqual(prompt, target.learningReviewPrompt)
                let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
                let job = try XCTUnwrap(saved.jobs.first)
                XCTAssertEqual(prefix, job.prefix)
                XCTAssertEqual(input, try LearningReviewQueue.prepareInput(job, allowUnreleased: true).input.json)
                XCTAssertEqual(try LearningReviewQueue.prepareInput(job, allowUnreleased: true).input.catalog.keys.sorted(), ["e0." + target.rawValue + ".0"])
                return #"{"reviewVersion":2,"corrections":[],"additions":[]}"#
            }
            addTeardownBlock { await queue.shutdownForTesting(); try FileManager.default.removeItem(at: root) }
            queue.allowUnreleasedTargetsForTesting()
            try queue.enqueue(directory: root, notebook: book, targetLocale: target.rawValue)
            for _ in 0..<200 where queue.hasWork { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(calls, 1); XCTAssertFalse(queue.hasWork)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("summary-review.md").path))
        }
    }
    func testRecoveryCheckpointAcceptsOnlyMatchingTargetPrompt() throws {
        for target in targets {
            let evidence = [foreign(target)], snapshot = SessionSnapshot(segments: [foreign(target)], targetLocale: target.rawValue)
            let stableSnapshot = SessionSnapshot(sessionID: snapshot.sessionID, segments: evidence, targetLocale: target.rawValue)
            let input = try LearningPrompts.input(evidence: evidence, topics: [], target: target)
            for recovering in [false, true] {
                let prompt = LearningPrompts.generationPrompt(target: target, recoveringAfterOutputLimit: recovering)
                let draft = LearningDraft(evidence: evidence, model: "proposal-stub", input: input, target: target, systemPrompt: prompt, text: "Frozen prefix", attempts: 2)
                let checkpoint = draft.checkpoint(sessionID: stableSnapshot.sessionID, inputRevision: stableSnapshot.inputRevision, generation: stableSnapshot.generation)
                let restored = try XCTUnwrap(LearningDraft(checkpoint: checkpoint, snapshot: stableSnapshot, model: "proposal-stub"))
                XCTAssertEqual(restored.target, target); XCTAssertEqual(restored.systemPrompt, prompt); XCTAssertEqual(restored.text, "Frozen prefix")
                XCTAssertNil(LearningDraft(checkpoint: checkpoint, snapshot: stableSnapshot, model: "proposal-stub", systemPrompt: "Unknown"))
            }
        }
    }
    func testNarrowKindLabelsLeaveWireAndClassroomDefaultsIntact() {
        for target in targets {
            let point = LearningPoint(kind: "例子", text: text(target))
            XCTAssertEqual(point.kind, "例子")
            XCTAssertTrue(point.markdown(target: target).contains(target == .spanish ? "**Ejemplo**" : "**Exemple**"))
            XCTAssertEqual(ClassroomFixedText.replayHeading.noteText(target: target), "需要回听")
            XCTAssertEqual(ClassroomFixedText.sourceLine.noteFormat([text(target)], target: target), "原文：" + text(target))
        }
        XCTAssertFalse(ClassroomFixedText.usesTargetLanguage)
        XCTAssertEqual(SummaryRefreshPolicy.automaticBatchCharacters, 4_000)
    }
    func testRepairNumericVetoRecognizesCommaDecimalsWithoutVetoingWrittenCandidates() {
        for target in targets {
            XCTAssertEqual(RepairNumericNovelty.assess(candidate: "3,14 g", support: ["3.14 g"], targetCode: target.rawValue, supportLanguages: ["en"]).unsupported, [])
            XCTAssertEqual(RepairNumericNovelty.assess(candidate: "3,15 g", support: ["3.14 g"], targetCode: target.rawValue, supportLanguages: ["en"]).unsupported, ["3,15"])
            XCTAssertTrue(RepairNumericNovelty.assess(candidate: target == .spanish ? "tres" : "trois", support: ["2"], targetCode: target.rawValue).unsupported.isEmpty)
        }
    }
}
