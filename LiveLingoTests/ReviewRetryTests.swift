import Foundation
import Testing
@testable import LiveLingo

/// 第 1–3 项：有界自动重试、中断与失败分开、每场统计。
@MainActor
struct ReviewRetryTests {
    private func makeNotebook(batches: Int = 1, label: String = "") -> LearningNotebook {
        var book = LearningNotebook()
        for index in 0..<batches {
            let segment = TranscriptSegment(
                startTime: Double(index * 10), endTime: Double(index * 10 + 8),
                english: "Electrons are described by a wave function in orbital \(label)\(index).",
                chinese: "电子在\(label)第 \(index) 个轨道中用波函数描述。"
            )
            let note = LearningNote(topic: "电子结构 \(label)\(index)", points: [
                .init(kind: "核心结论", text: "电子位置不确定，用概率分布描述 \(label)\(index)。")
            ])
            try? book.append(evidence: [segment], note: note)
        }
        return book
    }

    private func makeDirectory(trashed: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoRetry-\(UUID().uuidString)")
        let directory = trashed
            ? root.appendingPathComponent(".Trash").appendingPathComponent("session")
            : root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitFor(_ condition: @escaping () -> Bool, seconds: Double = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// 有界地确认某件事**没有**发生（例如"等待明确开始"的任务不得自动开跑）。
    /// 条件一旦成真立刻返回 false；整整 `seconds` 都没成真才返回 true。
    private func waitForNoActivity(_ happened: @escaping () -> Bool, seconds: Double = 0.5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if happened() { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !happened()
    }

    private func events(journal: URL) throws -> [ReviewQueueEvent] {
        let data = try Data(contentsOf: journal)
        let journal = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: data)
        return journal.jobs.first?.events ?? []
    }

    private func journalJobs(_ journal: URL) throws -> [LearningReviewQueue.Job] {
        try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal)).jobs
    }

    private func persistedJournal(_ journal: URL) throws -> LearningReviewQueue.Journal {
        try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
    }

    /// 写一份队列日志。`version` 为 nil 时**删掉 `version` 键** —— 这正是旧版本 App 写出的
    /// 文件形状，也是升级迁移唯一的判断依据（用当前类型编码再删键，与真实升级路径一致）。
    private func writeQueueJournal(_ jobs: [LearningReviewQueue.Job], userPaused: Bool = false,
                                   version: Int? = nil, to url: URL) throws {
        let encoded = try JSONEncoder().encode(LearningReviewQueue.Journal(jobs: jobs, userPaused: userPaused,
                                                                          version: version))
        var root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "version")
        if let version { root["version"] = version }
        try JSONSerialization.data(withJSONObject: root).write(to: url, options: .atomic)
    }

    /// 合法 v2 响应（模型只回 quoteID；这里没有建议）。
    private static let emptyV2Response = #"{"reviewVersion":2,"corrections":[],"additions":[]}"#

    private func makeBatch(english: String, chinese: String, topic: String = "测试主题") -> LearningNoteBatch {
        let segment = TranscriptSegment(startTime: 0, endTime: 8, english: english, chinese: chinese)
        let note = LearningNote(topic: topic, points: [.init(kind: "核心结论", text: "占位要点。")])
        return LearningNoteBatch(id: UUID(), evidence: [segment], note: note)
    }

    /// 队列测试统一用假 generator + 独立目录（绝不碰真实 9B 与真实录音）。
    private func makeQueue(journal: URL, retryDelays: [TimeInterval] = [0.05, 0.05],
                           generate: @escaping LearningReviewQueue.Generator) -> LearningReviewQueue {
        LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled,
                            generate: generate, retryDelays: retryDelays)
    }

    // MARK: - 策略本身

    @Test func activeRuntimeIdentityBelongsOnlyToTheCurrentGeneration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        var attempts = 0
        let queue = makeQueue(journal: directory.appendingPathComponent("queue.json")) { _, _, record, update in
            attempts += 1
            record("review-owned-\(attempts)")
            await update("unfinished generation")
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        do {
            try queue.enqueue(directory: directory, notebook: makeNotebook())
            #expect(await waitFor { queue.activeRuntimeRequestID == "review-owned-1" })
            #expect(queue.running)
            await queue.pauseAndWait()
            #expect(queue.activeRuntimeRequestID == nil)
            #expect(queue.userPaused)
            queue.togglePause()
            #expect(await waitFor { queue.activeRuntimeRequestID == "review-owned-2" })
            await queue.pauseAndWait()
            #expect(queue.activeRuntimeRequestID == nil)
            await queue.shutdownForTesting()
        } catch {
            await queue.shutdownForTesting()
            throw error
        }
    }

    @Test func onlyModelSideProtocolFailuresAreRetryable() {
        func failure(_ stage: ReviewFailureStage, _ code: String) -> ReviewFailure {
            ReviewFailure(stage: stage, code: code, detail: "x")
        }
        #expect(ReviewRetryPolicy.isRetryable(failure(.generation, "request_failed")))
        #expect(ReviewRetryPolicy.isRetryable(failure(.generation, "generation_interrupted")))
        #expect(ReviewRetryPolicy.isRetryable(failure(.decode, "invalid_response")))
        #expect(ReviewRetryPolicy.isRetryable(failure(.schema, "schema_mismatch")))
        // 目录、写入、进度保存类问题重试没有意义。
        #expect(!ReviewRetryPolicy.isRetryable(failure(.directory, "directory_in_trash")))
        #expect(!ReviewRetryPolicy.isRetryable(failure(.directory, "directory_unavailable")))
        #expect(!ReviewRetryPolicy.isRetryable(failure(.output, "request_failed")))
        #expect(!ReviewRetryPolicy.isRetryable(failure(.journal, "request_failed")))
        #expect(!ReviewRetryPolicy.isRetryable(failure(.input, "input_too_large")))
        #expect(!ReviewRetryPolicy.isRetryable(failure(.cancelled, "cancelled")))
        // 离线包缺模型：重试也不会变出模型。
        #expect(!ReviewRetryPolicy.isRetryable(failure(.generation, "model_unavailable")))
    }

    @Test func backoffGrowsThenStops() {
        #expect(ReviewRetryPolicy.delay(forAttempt: 1) == 30)
        #expect(ReviewRetryPolicy.delay(forAttempt: 2) == 120)
        #expect(ReviewRetryPolicy.delay(forAttempt: 3) == 120)
        #expect(ReviewRetryPolicy.maximumAttempts == 2)
    }

    @Test func sessionStatsLineIsReadableAndComplete() {
        var stats = LearningReviewQueue.JobStats()
        stats.completedBatches = 6
        stats.interruptions = 4
        stats.failures = 1
        stats.retries = 2
        stats.timedBatches = 6
        stats.generationMilliseconds = 6 * 90_000
        let line = stats.summaryLine
        #expect(line.contains("完成 6 批"))
        #expect(line.contains("中断 4 次"))
        #expect(line.contains("失败 1 次"))
        #expect(line.contains("自动重试 2 次"))
        #expect(line.contains("平均每批 90 秒"))
    }

    @Test func statsDecodeFromAnOlderJournalWithoutTheNewKeys() throws {
        let json = #"{"completedBatches":3}"#.data(using: .utf8)!
        let stats = try JSONDecoder().decode(LearningReviewQueue.JobStats.self, from: json)
        #expect(stats.completedBatches == 3)
        #expect(stats.interruptions == 0)
        #expect(stats.generationMilliseconds == 0)
        #expect(stats.averageGenerationSeconds == 0)
    }

    // MARK: - 队列行为

    @Test func transientFailureRetriesTwiceThenReportsOneFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let journal = directory.deletingLastPathComponent().appendingPathComponent("queue.json")
        var attempts = 0
        let queue = makeQueue(journal: journal) { _, _, _, _ in
            attempts += 1
            throw QwenRuntimeError.requestFailed("模拟本机模型协议错误")
        }
        try queue.enqueue(directory: directory, notebook: makeNotebook())
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)

        let done = await waitFor { queue.items.first?.failure != nil }
        #expect(done, "两次自动重试之后应当给出终止失败")
        #expect(attempts == 3, "一共尝试 3 次（1 次原始 + 2 次重试），实际 \(attempts)")
        let item = try #require(queue.items.first)
        let stats = try #require(item.stats)
        #expect(stats.retries == 2)
        #expect(stats.failures == 1)
        #expect(item.retryPending == nil, "重试用尽后不应再挂着等待中的重试")

        let journalEvents = try events(journal: journal)
        #expect(journalEvents.filter { $0.code == "retry_scheduled" }.count == 2)
        #expect(journalEvents.filter { $0.code == "failed" }.count == 1)
        await queue.shutdownForTesting()
    }

    @Test func directoryFailureIsReportedImmediatelyWithoutRetrying() async throws {
        let directory = try makeDirectory(trashed: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let journal = directory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("queue.json")
        var attempts = 0
        let queue = makeQueue(journal: journal) { _, _, _, _ in
            attempts += 1
            return Self.emptyV2Response
        }
        try queue.enqueue(directory: directory, notebook: makeNotebook())
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)

        let done = await waitFor { queue.items.first?.failure != nil }
        #expect(done)
        #expect(attempts == 0, "目录问题不该再叫模型")
        let item = try #require(queue.items.first)
        #expect(item.failure?.contains("废纸篓") == true)
        #expect(item.stats?.retries == 0)
        #expect(item.stats?.failures == 1)
        #expect(item.retryPending == nil)
        await queue.shutdownForTesting()
    }

    @Test func interruptIsCountedAsInterruptionNotFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let journal = directory.deletingLastPathComponent().appendingPathComponent("queue.json")
        let queue = makeQueue(journal: journal) { _, _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.emptyV2Response
        }
        try queue.enqueue(directory: directory, notebook: makeNotebook())
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let started = await waitFor { queue.running }
        #expect(started)

        queue.togglePause()   // 用户暂停：属于中断，不是失败
        let interrupted = await waitFor { queue.items.first?.interruption != nil }
        #expect(interrupted)
        let item = try #require(queue.items.first)
        #expect(item.failure == nil, "中断不得写成失败")
        #expect(item.stats?.interruptions == 1)
        #expect(item.stats?.failures == 0)
        #expect(item.interruption?.label == "手动暂停")
        #expect(queue.status.contains("已手动暂停"), "暂停状态要如实显示，而不是写成失败")
        #expect(!queue.status.contains("复查失败"))
        #expect(queue.userPaused, "暂停语义不变")
        await queue.shutdownForTesting()
    }

    @Test func completedBatchCountsStatsAndClearsInterruption() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let journal = directory.deletingLastPathComponent().appendingPathComponent("queue.json")
        var calls = 0
        let queue = makeQueue(journal: journal) { _, _, _, _ in
            calls += 1
            // 第一批立刻完成，第二批卡住，方便观察稳定的中间状态。
            if calls > 1 { try await Task.sleep(for: .seconds(30)) }
            return Self.emptyV2Response
        }
        try queue.enqueue(directory: directory, notebook: makeNotebook(batches: 2))
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)

        let firstDone = await waitFor { queue.items.first?.completed == 1 }
        #expect(firstDone, "第一批应当完成")
        let item = try #require(queue.items.first)
        let stats = try #require(item.stats)
        #expect(stats.completedBatches == 1)
        #expect(stats.timedBatches == 1)
        #expect(stats.generationMilliseconds >= 0)
        #expect(stats.failures == 0)
        #expect(stats.retries == 0)
        #expect(item.interruption == nil, "完成一批后旧的终端中断标记要清掉")

        // 报告文件里也要能看到中断/统计，而不是把未完成写成失败。
        let report = try String(contentsOf: directory.appendingPathComponent("summary-review.md"), encoding: .utf8)
        #expect(report.contains("本场统计：完成 1 批"))
        #expect(!report.contains("复查失败"))
        await queue.shutdownForTesting()
    }

    /// 「重新定位文件夹…」的安全校验：目标目录的笔记必须与这项复查的原文一致，
    /// 否则回滚且不改动队列（`managementError` 会说明"队列未更改"）。
    /// 之前这条路径没有任何测试覆盖。
    @Test func relocatingAJobOnlyAcceptsTheMatchingOriginalNotes() async throws {
        let notebook = makeNotebook()
        let original = notebook.markdown()
        let session = try makeDirectory()
        let journal = session.deletingLastPathComponent().appendingPathComponent("queue.json")
        // 假 generator：绝不在测试里启动本机模型。
        let queue = makeQueue(journal: journal) { _, _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return Self.emptyV2Response
        }
        try queue.enqueue(directory: session, notebook: notebook)

        // 从 journal 读出任务 id（jobs 是私有的，但队列会原子写盘）
        let journalData = try Data(contentsOf: journal)
        let decoded = try JSONSerialization.jsonObject(with: journalData) as? [String: Any]
        let firstJob = (decoded?["jobs"] as? [[String: Any]])?.first
        let rawID = try #require(firstJob?["id"] as? String)
        let jobID = try #require(UUID(uuidString: rawID))

        // 正确的目标：笔记与原文逐字一致
        let moved = try makeDirectory()
        try (original + "\n").write(to: moved.appendingPathComponent("summary-zh-Hans.md"),
                                    atomically: true, encoding: .utf8)
        queue.relocateJob(jobID, to: moved)
        let relocated = await waitForRelocation(queue: queue, expected: moved)
        #expect(relocated, "选对了目录应当重定位成功；managementError=\(queue.managementError ?? "无")")

        // 错误的目标：笔记不一致 → 必须回滚
        let wrong = try makeDirectory()
        try "完全不同的笔记\n".write(to: wrong.appendingPathComponent("summary-zh-Hans.md"),
                                    atomically: true, encoding: .utf8)
        queue.relocateJob(jobID, to: wrong)
        let stayed = await waitForRejection(queue: queue, expected: moved)
        #expect(stayed, "笔记不一致时必须拒绝并保持原目录；managementError=\(queue.managementError ?? "无")")
        await queue.shutdownForTesting()
    }

    // MARK: - v2 输入 / 引用目录

    /// v2 输入：片段是**连续原文**，拼起来与原文逐字相同，单个片段不超过 2400 个
    /// Swift Character，且不重复整段全文。
    @Test func reviewInputQuotesCoverTheWholeOriginalTextInContiguousFragments() throws {
        let english = "Electrons are described by a wave function."
        let chinese = (1...3).map { _ in String(repeating: "这段中文明显比英文长，用来验证长文本会被切成连续片段。", count: 40) }
            .joined() + "🎓🧪"
        let batch = makeBatch(english: english, chinese: chinese)
        let prepared = try LearningPrompts.reviewInput(batch)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(prepared.json.utf8)) as? [String: Any])
        #expect(root["reviewVersion"] as? Int == 2, "模型输入根必须有 reviewVersion:2")

        let evidence = try #require((root["evidence"] as? [[String: Any]])?.first)
        #expect(Set(evidence.keys) == ["index", "quotes"] || Set(evidence.keys) == ["index", "quotes", "chineseWarning"],
                "证据条目不得再整体重复全文，实际字段：\(evidence.keys.sorted())")
        let quotes = try #require(evidence["quotes"] as? [[String: Any]])
        try #require(!quotes.isEmpty, "必须给出引用片段")
        #expect(quotes.allSatisfy { Set($0.keys) == ["id", "language", "text"] },
                "wire 片段必须只有 id/language/text（不含内部证据编号 index），实际：\(quotes.map { $0.keys.sorted() })")
        let chineseQuotes = quotes.filter { $0["language"] as? String == "zh" }.compactMap { $0["text"] as? String }
        try #require(chineseQuotes.count >= 2, "超长中文必须被切成多段")
        #expect(chineseQuotes.allSatisfy { $0.count <= PreparedReviewInput.maximumQuoteCharacters },
                "单个片段不得超过 2400 个 Swift Character")
        #expect(chineseQuotes.joined() == chinese, "所有片段拼回来必须与原文逐字相同")
        #expect(quotes.allSatisfy { ($0["id"] as? String)?.isEmpty == false })
        #expect(Set(quotes.compactMap { $0["id"] as? String }).count == quotes.count, "引用 id 必须唯一")

        // 引用第二段（Unicode 长文本的后半段）也要能通过原始证据校验。
        let secondID = try #require(quotes.filter { $0["language"] as? String == "zh" }[1]["id"] as? String)
        let response = #"{"reviewVersion":2,"corrections":[],"additions":[{"evidenceIndex":0,"quoteID":"\#(secondID)","kind":"核心结论","text":"补充：这一段有被遗漏的内容。","reason":"笔记没有覆盖后半段。"}]}"#
        let patch = try LearningReview.decode(response: response, catalog: prepared.catalog)
        #expect(patch.additions.first?.quote == chineseQuotes[1])
        try patch.validateAdditions(evidence: batch.evidence)
    }

    /// 中文可疑时，警告是**独立字段**：引用文本仍是未污染的原文，
    /// 警告既不会进入 quote，也不会让"引用原文"的校验失败。
    @Test func reviewFragmentsPreserveLongWhitespaceRuns() throws {
        let english = "First claim." + String(repeating: " ", count: 5000) + "Last claim."
        let prepared = try LearningPrompts.reviewInput(makeBatch(english: english, chinese: ""))
        let root = try #require(JSONSerialization.jsonObject(with: Data(prepared.json.utf8)) as? [String: Any])
        let evidence = try #require((root["evidence"] as? [[String: Any]])?.first)
        let quotes = try #require(evidence["quotes"] as? [[String: Any]])
        #expect(quotes.compactMap { $0["text"] as? String }.joined() == english)
        #expect(quotes.allSatisfy { ($0["text"] as? String)?.count ?? 0 <= 2400 })
    }

    @Test func reviewInputKeepsTheChineseWarningOutOfTheQuoteText() throws {
        let english = "So that's one example we can use for the whole exercise today."
        let chinese = String(repeating: "这是一段明显长于英文的译文，可能混入了相邻段落的内容。", count: 6)
        let batch = makeBatch(english: english, chinese: chinese)
        let prepared = try LearningPrompts.reviewInput(batch)
        #expect(prepared.catalog.values.contains { $0.text == chinese }, "警告不得污染引用文本")
        #expect(prepared.catalog.values.allSatisfy { !$0.text.contains("⚠️ 此译文") }, "警告不得再拼进引用文本")
        #expect(prepared.json.contains("chineseWarning"), "警告必须作为独立字段出现")

        let id = try #require(prepared.catalog.values.first { $0.language == "zh" }?.id)
        let response = #"{"reviewVersion":2,"corrections":[],"additions":[{"evidenceIndex":0,"quoteID":"\#(id)","kind":"待确认","text":"这段译文可能与相邻段落混在了一起。","reason":"译文明显长于英文。"}]}"#
        let patch = try LearningReview.decode(response: response, catalog: prepared.catalog)
        try patch.validateAdditions(evidence: batch.evidence)
    }

    /// ID 错配：未知 id、证据编号不一致、混用旧 `quote` 字段、缺版本，全部拒绝。
    @Test func v2DecodeRejectsMismatchedQuoteIDs() throws {
        let batch = makeBatch(english: "Water is the solvent.", chinese: "水是溶剂。")
        let prepared = try LearningPrompts.reviewInput(batch)
        let valid = try #require(prepared.catalog.values.first)

        func failure(_ response: String) -> ReviewFailure? {
            do { _ = try LearningReview.decode(response: response, catalog: prepared.catalog); return nil }
            catch let failure as ReviewFailure { return failure }
            catch { return nil }
        }
        let base = #"{"reviewVersion":2,"corrections":[],"additions":[{"evidenceIndex":0,"quoteID":"\#(valid.id)","kind":"核心结论","text":"水是溶剂。","reason":"理由"}]}"#
        let patch = try LearningReview.decode(response: base, catalog: prepared.catalog)
        try patch.validateAdditions(evidence: batch.evidence)

        let unknown = base.replacingOccurrences(of: valid.id, with: "e9.en.9")
        #expect(failure(unknown)?.code == "unknown_quote_id")
        #expect(failure(unknown)?.stage == .additions)

        let crossed = base.replacingOccurrences(of: "\"evidenceIndex\":0", with: "\"evidenceIndex\":1")
        #expect(failure(crossed)?.code == "quote_id_mismatch")

        let mixed = #"{"reviewVersion":2,"corrections":[],"additions":[{"evidenceIndex":0,"quote":"Water is the solvent.","kind":"核心结论","text":"水是溶剂。","reason":"理由"}]}"#
        #expect(failure(mixed)?.code == "legacy_quote_field")

        let withoutID = #"{"reviewVersion":2,"corrections":[],"additions":[{"evidenceIndex":0,"kind":"核心结论","text":"水是溶剂。","reason":"理由"}]}"#
        #expect(failure(withoutID)?.code == "missing_quote_id")

        let noVersion = #"{"corrections":[],"additions":[]}"#
        #expect(failure(noVersion)?.code == "missing_review_version")

        let futureVersion = #"{"reviewVersion":3,"corrections":[],"additions":[]}"#
        #expect(failure(futureVersion)?.code == "unsupported_review_version")

        // 旧入口只吃没有版本的旧响应：v2 响应必须被挡住，避免两套引用口径混用。
        do {
            _ = try LearningReview.decode(response: base)
            Issue.record("旧入口不得接受 v2 响应")
        } catch let failure as ReviewFailure {
            #expect(failure.code == "unexpected_review_version")
        }
    }

    /// 旧无版本响应仍可解码（只服务旧单测/旧数据）。
    @Test func legacyResponsesWithoutAVersionStillDecode() throws {
        let legacy = #"{"corrections":[],"additions":[{"evidenceIndex":0,"quote":"Water is the solvent.","kind":"核心结论","text":"水是溶剂。","reason":"理由"}]}"#
        let evidence = [TranscriptSegment(startTime: 0, endTime: 8, english: "Water is the solvent.")]
        let patch = try LearningReview.decode(response: legacy)
        try patch.validateAdditions(evidence: evidence)
        #expect(patch.additions.first?.quoteID == nil)
        #expect(patch.additions.first?.quote == "Water is the solvent.")

        let mixed = #"{"corrections":[],"additions":[{"evidenceIndex":0,"quoteID":"e0.en.0","kind":"核心结论","text":"水是溶剂。","reason":"理由"}]}"#
        do {
            _ = try LearningReview.decode(response: mixed)
            Issue.record("没有版本的响应不得携带 quoteID")
        } catch let failure as ReviewFailure {
            #expect(failure.code == "unexpected_quote_id")
        }
    }

    // MARK: - 未完成前缀的绑定指纹

    @Test func unfinishedPrefixSurvivesOnlyWhenItsInputBindingMatches() async throws {
        let notebook = makeNotebook()
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let journal = directory.deletingLastPathComponent().appendingPathComponent("queue.json")
        let batch = try #require(notebook.batches.first)
        let prepared = try LearningPrompts.reviewInput(batch, laterBatches: [])
        let digest = LearningReviewQueue.prefixDigest(json: prepared.json, prompt: LearningPrompts.review)

        func writeJournal(prefix: String, digest: String?, next: Int = 0, reports: [String] = [],
                          version: Int? = nil) throws {
            // A completed report belongs to a completed batch. Keep a second,
            // unreviewed batch so prefix migration exercises a valid journal.
            var batches = notebook.batches
            if !reports.isEmpty {
                batches.append(.init(id: UUID(), evidence: batches[0].evidence,
                    note: batches[0].note))
            }
            let job = LearningReviewQueue.Job(directory: directory, batches: batches, original: notebook.markdown(),
                                              next: next, prefix: prefix, reports: reports,
                                              prefixInputDigest: digest)
            try writeQueueJournal([job], version: version, to: journal)
        }

        // ① 指纹一致 → 前缀保留，并且真的被送进 generator。
        // 这里刻意写**当前版本**的日志（带 version）：它不触发升级迁移，是纯前缀测试；
        // 「旧日志迁移后等待明确开始」由 ②③ 与 legacyJournalWaitsForManualStartAndPreservesProgress 覆盖。
        try writeJournal(prefix: "已经想了一半的前缀", digest: digest, version: LearningReviewQueue.journalVersion)
        #expect(try persistedJournal(journal).version == LearningReviewQueue.journalVersion)
        var deliveredPrefix: String?
        let queue = makeQueue(journal: journal) { _, prefix, _, _ in
            deliveredPrefix = prefix
            return Self.emptyV2Response
        }
        #expect(try journalJobs(journal).first?.prefix == "已经想了一半的前缀", "指纹一致时前缀必须保留")
        #expect(!queue.frontJobAwaitingManualStart, "有 version 的日志不得被当成旧日志迁移")
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let finished = await waitFor { queue.items.isEmpty }
        #expect(finished, "这批应当跑完")
        #expect(deliveredPrefix == "已经想了一半的前缀")
        await queue.shutdownForTesting()

        // ② 旧日志没有指纹 → 前缀作废并**存盘**，批次进度与报告不丢；
        //    同时这套旧任务进"等待明确开始"，不会自动续跑。
        try writeJournal(prefix: "旧日志里的前缀", digest: nil, next: 1, reports: ["## 第 1 批 · 旧主题\n- 旧报告"])
        #expect(try persistedJournal(journal).version == nil, "② 用的必须是旧日志（没有 version）")
        var restoredCalls = 0
        var restoredPrefix: String?
        let restored = makeQueue(journal: journal) { _, prefix, _, _ in
            restoredCalls += 1
            restoredPrefix = prefix
            return Self.emptyV2Response
        }
        let saved = try #require(try journalJobs(journal).first)
        #expect(saved.prefix.isEmpty, "丢前缀必须立刻存盘")
        #expect(saved.prefixInputDigest == nil)
        #expect(saved.reports == ["## 第 1 批 · 旧主题\n- 旧报告"], "报告不得被清理")
        #expect(saved.next == 1)
        #expect(saved.batches.count == notebook.batches.count + 1, "批次缓存不得被清理")
        // 迁移状态：进度全在盘上，但任务先停住等用户明确开始。
        #expect(restored.frontJobAwaitingManualStart, "旧日志的未完成任务必须等待手动开始")
        #expect(saved.awaitingManualStart == true, "等待开始必须立刻存盘")
        #expect(try persistedJournal(journal).version == LearningReviewQueue.journalVersion, "迁移后写回当前版本号")
        #expect(restored.status.contains("已排队，等待开始（不会自动运行）"), "实际状态：\(restored.status)")
        #expect(!restored.running)
        restored.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let restoredStayedIdle = await waitForNoActivity { restoredCalls > 0 || restored.running }
        #expect(restoredStayedIdle, "等待明确开始时不得调用模型")
        #expect(restoredCalls == 0, "迁移后的任务自动跑了 \(restoredCalls) 次")
        restored.performPrimaryAction()   // 用户明确开始：唯一放行路径
        let restoredFinished = await waitFor({ restored.items.isEmpty }, seconds: 5)
        #expect(restoredFinished)
        #expect(restoredPrefix == "", "没有指纹的旧前缀不得继续使用")
        await restored.shutdownForTesting()

        // ③ 旧日志 + 指纹对不上（输入变了）→ 同样丢前缀、同样等待明确开始，
        //    但已完成批次照旧保留。
        let otherDigest = LearningReviewQueue.prefixDigest(json: prepared.json + " ", prompt: LearningPrompts.review)
        try writeJournal(prefix: "错误的绑定", digest: otherDigest, next: 0)
        var mismatchedCalls = 0
        var mismatchedPrefix: String?
        let mismatched = makeQueue(journal: journal) { _, prefix, _, _ in
            mismatchedCalls += 1
            mismatchedPrefix = prefix
            return Self.emptyV2Response
        }
        let mismatchedSaved = try #require(try journalJobs(journal).first)
        #expect(mismatchedSaved.prefix.isEmpty)
        #expect(mismatchedSaved.prefixInputDigest == nil)
        #expect(mismatched.frontJobAwaitingManualStart, "旧日志的未完成任务必须等待手动开始")
        #expect(mismatchedSaved.awaitingManualStart == true, "等待开始必须立刻存盘")
        #expect(mismatched.status.contains("等待开始"), "实际状态：\(mismatched.status)")
        mismatched.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let mismatchedStayedIdle = await waitForNoActivity { mismatchedCalls > 0 || mismatched.running }
        #expect(mismatchedStayedIdle, "等待明确开始时不得调用模型")
        #expect(mismatchedCalls == 0, "迁移后的任务自动跑了 \(mismatchedCalls) 次")
        mismatched.performPrimaryAction()   // 用户明确开始：唯一放行路径
        let mismatchedFinished = await waitFor({ mismatched.items.isEmpty }, seconds: 5)
        #expect(mismatchedFinished)
        #expect(mismatchedPrefix == "", "指纹对不上时前缀必须作废")
        await mismatched.shutdownForTesting()
    }

    /// 升级迁移契约（2026-09-20）：旧版本 App 写的日志（没有 `version` 键）里的未完成任务
    /// 一律标成"等待手动开始"——`next`/`prefix`/`reports`/`batches`/`userPaused` 全部保留、
    /// 一个都不删，但绝不自动跑模型；只有用户点主按钮（`performPrimaryAction()`）才继续。
    @Test func legacyJournalWaitsForManualStartAndPreservesProgress() async throws {
        let notebook = makeNotebook(batches: 2)
        // 目录统一成"纯字符串构成"的 URL：队列比较的是 `standardizedFileURL`，
        // 而 `appendingPathComponent` 造出的 URL 在日志往返后会丢掉目录标记（两种形式不相等）。
        // 这里要测的是迁移契约，不是 URL 形式的差异。
        let directory = URL(fileURLWithPath: try makeDirectory().path)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let journal = directory.deletingLastPathComponent().appendingPathComponent("queue.json")
        let secondBatch = try #require(notebook.batches.dropFirst().first)
        let prepared = try LearningPrompts.reviewInput(secondBatch, laterBatches: [])
        let digest = LearningReviewQueue.prefixDigest(json: prepared.json, prompt: LearningPrompts.review)
        let oldReport = "## 第 1 批 · 旧主题\n- 旧报告"

        // 旧日志：手写第 1 批已完成的状态（next=1、报告、未写完的前缀都在），
        // 再用当前类型编码后删掉 `version` 键 —— 真实升级时旧 App 写出的就是这种文件。
        let legacyJob = LearningReviewQueue.Job(directory: directory, batches: notebook.batches,
                                                original: notebook.markdown(), next: 1, prefix: "旧前缀",
                                                reports: [oldReport], prefixInputDigest: digest)
        try writeQueueJournal([legacyJob], userPaused: false, version: nil, to: journal)
        #expect(try persistedJournal(journal).version == nil, "构造的必须是旧日志（没有 version）")

        var calls = 0
        var deliveredPrefix: String?
        let queue = makeQueue(journal: journal) { _, prefix, _, _ in
            calls += 1
            deliveredPrefix = prefix
            return Self.emptyV2Response
        }
        #expect(queue.items.count == 1)
        let item = try #require(queue.items.first)
        #expect(item.completed == 1, "已完成的第 1 批必须保留")
        #expect(item.total == 2)
        #expect(item.awaitingManualStart, "队列条目本身也要标成等待开始（界面按钮据此显示）")
        #expect(queue.frontJobAwaitingManualStart, "旧日志的未完成任务必须等待手动开始")
        #expect(!queue.running)
        #expect(queue.status.contains("已排队，等待开始（不会自动运行）"), "实际状态：\(queue.status)")

        // 进度在盘上（不只是内存里）：前缀、报告、批次、下一步、版本号一个都不能丢。
        let reloaded = try persistedJournal(journal)
        let reloadedJob = try #require(reloaded.jobs.first)
        #expect(reloadedJob.prefix == "旧前缀", "迁移不得丢掉未完成的思考前缀")
        #expect(reloadedJob.prefixInputDigest == digest, "指纹必须原样保留")
        #expect(reloadedJob.reports == [oldReport], "旧批次的报告不得被清理")
        #expect(reloadedJob.next == 1, "已完成批次数不得被重置")
        #expect(reloadedJob.batches.count == 2, "批次缓存不得被清理")
        #expect(reloadedJob.awaitingManualStart == true, "等待开始必须立刻存盘")
        #expect(reloaded.version == LearningReviewQueue.journalVersion, "迁移后写回当前版本号")
        let renderedReport = try #require(queue.reviewReportMarkdown(for: directory))
        #expect(renderedReport.contains("## 第 1 批 · 旧主题"), "旧报告必须原样还在")

        // 开机路径（AppModel 启动时的 setContext）也不得把它自动跑起来。
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let stayedIdle = await waitForNoActivity { calls > 0 || queue.running }
        #expect(stayedIdle, "等待明确开始的旧任务不得自动调用模型")
        #expect(calls == 0, "迁移后自动调用了模型 \(calls) 次")

        // 明确开始：只补跑剩下的第 2 批，旧报告必须原样留在 summary-review.md 里。
        queue.performPrimaryAction()
        let finished = await waitFor { queue.items.isEmpty }
        #expect(finished, "明确开始后剩余批次应当跑完")
        #expect(calls == 1, "只应补跑剩下的 1 批，实际 \(calls) 次")
        #expect(deliveredPrefix == "旧前缀", "明确开始后应当接着用保留下来的前缀")
        let report = try String(contentsOf: directory.appendingPathComponent("summary-review.md"), encoding: .utf8)
        #expect(report.contains("## 第 1 批 · 旧主题"), "旧的已完成批次报告不得被覆盖")
        #expect(report.contains("- 旧报告"))
        #expect(report.contains("## 第 2 批 · \(notebook.batches[1].note.topic)"), "新批次要接着写进同一份报告")
        #expect(report.contains("2/2 批"), "整课报告进度要如实显示 2/2")
        await queue.shutdownForTesting()

        // 旧日志里 userPaused = true：暂停状态必须保真，同样不得自动跑；
        // 主按钮此时是"继续复查"，`performPrimaryAction()` 照样要能接着跑完。
        let pausedDirectory = URL(fileURLWithPath: try makeDirectory().path)
        defer { try? FileManager.default.removeItem(at: pausedDirectory.deletingLastPathComponent()) }
        let pausedJournal = pausedDirectory.deletingLastPathComponent().appendingPathComponent("queue.json")
        let pausedLegacyJob = LearningReviewQueue.Job(directory: pausedDirectory, batches: notebook.batches,
                                                      original: notebook.markdown(), next: 1, prefix: "旧前缀",
                                                      reports: [oldReport], prefixInputDigest: digest)
        try writeQueueJournal([pausedLegacyJob], userPaused: true, version: nil, to: pausedJournal)
        #expect(try persistedJournal(pausedJournal).version == nil, "构造的必须是旧日志（没有 version）")

        var pausedCalls = 0
        let paused = makeQueue(journal: pausedJournal) { _, _, _, _ in
            pausedCalls += 1
            return Self.emptyV2Response
        }
        #expect(paused.userPaused, "旧日志里的暂停状态必须保真保留")
        #expect(paused.frontJobAwaitingManualStart, "未完成的任务同样要等明确开始")
        #expect(paused.items.first?.completed == 1)
        #expect(paused.items.first?.total == 2)
        #expect(try persistedJournal(pausedJournal).userPaused, "盘上的暂停状态不得被改写")
        #expect(paused.status.contains("已手动暂停"), "暂停优先显示，实际状态：\(paused.status)")
        #expect(!paused.running)
        paused.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let pausedStayedIdle = await waitForNoActivity { pausedCalls > 0 || paused.running }
        #expect(pausedStayedIdle, "暂停的旧任务不得自动跑")
        #expect(pausedCalls == 0)

        paused.performPrimaryAction()   // 主按钮此时是"继续复查"
        #expect(!paused.userPaused, "明确开始要同时清掉暂停")
        let pausedFinished = await waitFor { paused.items.isEmpty }
        #expect(pausedFinished, "明确继续后剩余批次应当跑完")
        #expect(pausedCalls == 1, "只应补跑剩下的 1 批，实际 \(pausedCalls) 次")
        let pausedReport = try String(contentsOf: pausedDirectory.appendingPathComponent("summary-review.md"),
                                      encoding: .utf8)
        #expect(pausedReport.contains("## 第 1 批 · 旧主题"), "暂停时的旧报告同样不得被覆盖")
        #expect(pausedReport.contains("## 第 2 批 · \(notebook.batches[1].note.topic)"))
        await paused.shutdownForTesting()
    }

    /// 回归护栏：**当前版本**写入的日志（有 `version` 键）不得被迁移 —— 未完成任务照旧
    /// 自动续跑，不需要用户点任何按钮；否则升级会把所有正常任务全部卡死。
    @Test func currentVersionJournalStillAutoResumesWithoutExplicitAction() async throws {
        let notebook = makeNotebook(batches: 2)
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let journal = directory.deletingLastPathComponent().appendingPathComponent("queue.json")
        let secondBatch = try #require(notebook.batches.dropFirst().first)
        let prepared = try LearningPrompts.reviewInput(secondBatch, laterBatches: [])
        let digest = LearningReviewQueue.prefixDigest(json: prepared.json, prompt: LearningPrompts.review)
        let job = LearningReviewQueue.Job(directory: directory, batches: notebook.batches,
                                          original: notebook.markdown(), next: 1, prefix: "未写完的前缀",
                                          reports: ["## 第 1 批 · 旧主题\n- 旧报告"], prefixInputDigest: digest)
        try writeQueueJournal([job], userPaused: false, version: LearningReviewQueue.journalVersion, to: journal)

        var calls = 0
        var deliveredPrefix: String?
        let queue = makeQueue(journal: journal) { _, prefix, _, _ in
            calls += 1
            deliveredPrefix = prefix
            return Self.emptyV2Response
        }
        #expect(!queue.frontJobAwaitingManualStart, "有 version 的日志不得被当成旧日志迁移")
        #expect(queue.items.first?.awaitingManualStart != true)
        #expect(try journalJobs(journal).first?.awaitingManualStart != true, "盘上也不得出现等待开始")
        #expect(!queue.running)

        // 开机路径：只靠 setContext 就要把剩下的第 2 批接着跑完，不需要任何明确动作。
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let finished = await waitFor { queue.items.isEmpty }
        #expect(finished, "当前版本日志必须自动续跑")
        #expect(calls == 1, "只补跑剩下的 1 批，实际 \(calls) 次")
        #expect(deliveredPrefix == "未写完的前缀", "自动续跑要带上保存下来的未完成前缀")
        let report = try String(contentsOf: directory.appendingPathComponent("summary-review.md"), encoding: .utf8)
        #expect(report.contains("## 第 1 批 · 旧主题"))
        #expect(report.contains("## 第 2 批 · \(notebook.batches[1].note.topic)"))
        #expect(report.contains("2/2 批"))
        await queue.shutdownForTesting()
    }

    /// 父任务验收第 4 点：队首是"等待手动开始"的旧整课任务时，用户新提交的明确局部复查
    /// **必须能直接跑**，不需要先跑整课 ✓；旧任务仍留在队列里等用户点"开始复查" ✓。
    @Test func explicitScopedReviewRunsEvenWhenAnOlderJobWaitsForManualStart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoManualFront-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("queue.json")
        // 目录统一成纯字符串 URL：队列按 standardizedFileURL 比较（见上一条测试的说明）。
        let legacyDirectory = URL(fileURLWithPath: root.appendingPathComponent("old-lesson").path)
        let freshDirectory = URL(fileURLWithPath: root.appendingPathComponent("fresh-lesson").path)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshDirectory, withIntermediateDirectories: true)

        let legacyNotebook = makeNotebook(batches: 2, label: "旧")
        let freshNotebook = makeNotebook(batches: 2, label: "新")
        try (freshNotebook.markdown() + "\n").write(to: freshDirectory.appendingPathComponent("summary-zh-Hans.md"),
                                                     atomically: true, encoding: .utf8)
        let legacyJob = LearningReviewQueue.Job(directory: legacyDirectory, batches: legacyNotebook.batches,
                                                original: legacyNotebook.markdown(), next: 1,
                                                reports: ["## 第 1 批 · 旧主题\n- 旧报告"])
        try writeQueueJournal([legacyJob], userPaused: false, version: nil, to: journal)

        var calls: [String] = []
        let queue = makeQueue(journal: journal) { input, _, _, _ in
            calls.append(input)
            return Self.emptyV2Response
        }
        #expect(queue.frontJobAwaitingManualStart, "构造前提：队首是等待手动开始的旧任务")

        // 用户明确提交"只复查第 1 批"（另一场录音）。
        try queue.enqueue(directory: freshDirectory, notebook: freshNotebook, scope: .batch(1))
        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let scopedFinished = await waitFor { queue.items.count == 1 && !queue.running }
        #expect(scopedFinished, "新提交的局部复查必须自己跑完，不能被前面的等待任务挡住")
        #expect(calls.count == 1, "只应跑这一次局部复查，实际 \(calls.count) 次")

        // 局部报告落在独立文件里；旧任务什么都没被改写，也还在队列里等着。
        let scoped = try String(contentsOf: freshDirectory.appendingPathComponent("summary-review-batch-1.md"),
                                encoding: .utf8)
        #expect(scoped.contains("第 1 批（局部）"))
        #expect(scoped.contains("不是整课结论"))
        #expect(!FileManager.default.fileExists(atPath: freshDirectory.appendingPathComponent("summary-review.md").path),
                "局部复查不得写出整课报告文件")
        #expect(!FileManager.default.fileExists(atPath: legacyDirectory.appendingPathComponent("summary-review.md").path),
                "旧等待任务不得因为这次提交而开跑")
        #expect(queue.items.count == 1, "旧任务必须仍留在队列里")
        #expect(queue.frontJobAwaitingManualStart, "旧任务仍在等待用户明确开始")
        #expect(try persistedJournal(journal).jobs.count == 1, "等待中的旧任务不得被删除")
        #expect(try persistedJournal(journal).jobs.first?.reports == ["## 第 1 批 · 旧主题\n- 旧报告"],
                "等待中的旧任务进度不得被清掉")

        // 用户又明确点了一次"复查整课"：同一目录同一范围不重复建任务，
        // 但要把它从"等待开始"变成"现在就跑"（不需要再找第二个按钮）。
        try queue.enqueue(directory: legacyDirectory, notebook: legacyNotebook, scope: .wholeLesson)
        let legacyFinished = await waitFor { queue.items.isEmpty }
        #expect(legacyFinished, "明确点同一个范围后旧任务应当跑完")
        #expect(calls.count == 2, "旧任务只补跑剩下的 1 批，实际总计 \(calls.count) 次")
        let legacyReport = try String(contentsOf: legacyDirectory.appendingPathComponent("summary-review.md"),
                                      encoding: .utf8)
        #expect(legacyReport.contains("## 第 1 批 · 旧主题"), "旧的已完成批次报告不得被覆盖")
        #expect(legacyReport.contains("2/2 批"))
        await queue.shutdownForTesting()
    }

    @Test func finishedJobKeepsItsReportOnDiskAndDirectoryMatchingStaysExact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoReport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let unrelated = root.appendingPathComponent("unrelated")
        for url in [first, second, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let journal = root.appendingPathComponent("queue.json")
        let notebookA = makeNotebook(batches: 2, label: "甲")
        let notebookB = makeNotebook(label: "乙")
        let queue = makeQueue(journal: journal) { input, _, _, _ in
            // 第一个任务（甲，两批）立刻完成；第二个任务卡住，方便稳定观察"出队后"的状态。
            if input.contains("orbital 乙0") { try await Task.sleep(for: .seconds(30)) }
            return Self.emptyV2Response
        }

        // 先挡住运行，验证"还没有跑完的批次也能给出进度"，且目录必须精确匹配。
        queue.setContext(recording: true, concurrent: false, resourcesAvailable: false)
        try queue.enqueue(directory: first, notebook: notebookA)
        try queue.enqueue(directory: second, notebook: notebookB)

        let idleFirst = try #require(queue.reviewReportMarkdown(for: first))
        let idleSecond = try #require(queue.reviewReportMarkdown(for: second))
        #expect(idleFirst.contains("0/2 批"), "0 批也要给出进度")
        #expect(idleSecond.contains("0/1 批"))
        #expect(idleFirst != idleSecond, "两个录音各自的报告不能串")
        #expect(queue.reviewReportMarkdown(for: unrelated) == nil, "没有任务必须返回 nil")

        queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        let firstFinished = await waitFor { queue.items.first?.directory.standardizedFileURL == second.standardizedFileURL }
        #expect(firstFinished, "第一个任务应当跑完出队")

        // 出队后队列里查不到，但磁盘报告必须还在（AppModel 的兜底读盘就靠它）。
        #expect(queue.reviewReportMarkdown(for: first) == nil, "任务出队后队列不再持有它")
        let disk = try String(contentsOf: first.appendingPathComponent("summary-review.md"), encoding: .utf8)
        #expect(disk.contains("2/2 批"))
        #expect(disk.contains("第 1 批"))
        #expect(disk.contains(notebookA.batches[0].note.topic))
        #expect(!disk.contains(notebookB.batches[0].note.topic), "磁盘报告不得混入别的录音")

        let secondReport = try #require(queue.reviewReportMarkdown(for: second))
        #expect(secondReport.contains("0/1 批"))
        #expect(!secondReport.contains(notebookA.batches[0].note.topic), "进行中的任务也不能串目录")
        await queue.shutdownForTesting()
    }

    /// 等待异步 editQueue 落地（`relocateJob` 通过 editQueue 改队列）。
    @MainActor
    private func waitForRelocation(queue: LearningReviewQueue, expected: URL, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queue.items.first?.directory.standardizedFileURL == expected.standardizedFileURL,
               queue.managementError == nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor
    private func waitForRejection(queue: LearningReviewQueue, expected: URL, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = queue.managementError, error.contains("队列未更改"),
               queue.items.first?.directory.standardizedFileURL == expected.standardizedFileURL {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
