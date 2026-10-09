import AppKit
import Darwin
import PDFKit
import XCTest
@testable import LiveLingo

/// 第 5 项：摘要导出格式（Markdown / 纯文本 / PDF）。
/// 这些测试只使用已有笔记与复查数据，不调用模型。
final class NotesExportTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, _ english: String, _ chinese: String) -> TranscriptSegment {
        TranscriptSegment(startTime: start, endTime: end, english: english, chinese: chinese)
    }

    private func snapshot(
        scope: NotesExportScope = .wholeLesson,
        notes: String = """
        ## 电子云与原子轨道
        - **核心结论**：电子位置不确定，用电子云描述概率分布。
        - **公式**：$v = \\frac{d}{t}$ 表示平均速率（待核对）。
        """,
        review: String? = """
        # 9B 思考复查 1/1 批（约 5 分钟/批）

        以下是模型复查意见，仅供核对，可能有误；没有修改笔记正文。

        ## 第 1 批 · 电子云与原子轨道
        - **原笔记 · 要点 3**：第 3 点可能把速率说成速度，请核对原文。
        """,
        withReview: Bool = false,
        withTranscript: Bool = true,
        transcript: [TranscriptSegment]? = nil
    ) -> NotesExportSnapshot {
        NotesExportSnapshot(
            className: "实时课堂",
            sessionName: "LiveLingo 2026-09-16 14.07.48",
            scope: scope,
            scopeDetail: scope == .wholeLesson ? "已整理 24 / 26 段已翻译内容" : "最近完成：12:30–15:00",
            coverageLine: "已整理 24 / 26 段已翻译内容",
            notesMarkdown: notes,
            reviewMarkdown: review,
            transcript: transcript ?? [
                segment(0, 5, "Electrons are described by a cloud.", "电子用电子云描述。"),
                segment(5, 9, "Speed is not velocity.", "速率不是速度。")
            ],
            generatedAt: Date(timeIntervalSince1970: 1_789_550_000),
            includesReviewAdvice: withReview,
            includesTranscript: withTranscript
        )
    }

    /// 四种格式的可见文本（PDF/Word 走系统解析，和用户看到的一致）。
    private func plainText(of snapshot: NotesExportSnapshot, format: NotesExportFormat) throws -> String {
        let data = try NotesExportDocument.data(snapshot, format: format)
        switch format {
        case .markdown, .plainText:
            return String(decoding: data, as: UTF8.self)
        case .word:
            return try NSAttributedString(data: data, options: [:], documentAttributes: nil).string
        case .pdf:
            let document = try XCTUnwrap(PDFDocument(data: data))
            return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        }
    }

    /// 小节标题必须**独占一行**：Markdown/纯文本里是 `## 需要回听` / `需要回听`，
    /// Word/PDF 里 `## ` 会被渲染层去掉、只剩标题文字 ✓。
    /// 不能用 `contains("需要回听")` 代替 ✗ —— 免责声明那行也提到这两个小节的**名字** ✓，
    /// 那样写即使导出把整节丢了也照样通过 ✗。
    private func containsSectionHeading(_ heading: String, in text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            return trimmed == heading || trimmed == "## " + heading
        }
    }

    func testMarkdownExportKeepsScopeFormulasAndTimestamps() {
        let text = NotesExportDocument.markdown(snapshot())

        XCTAssertTrue(text.contains("# 实时课堂 · 整课笔记 · 2026-09-16"), "标题要含日期与内容范围")
        XCTAssertTrue(text.contains("## 学习笔记"))
        XCTAssertTrue(text.contains("$v = \\frac{d}{t}$"), "公式要原样保留")
        XCTAssertTrue(text.contains("待核对"), "不确定性标记要保留")
        XCTAssertTrue(text.contains("[00:00–00:05] Electrons are described by a cloud."), "字幕要带来源时间")
        XCTAssertFalse(text.contains(NotesExportDocument.reviewHeading), "未勾选时不得出现复查章节")
    }

    func testScopeSelectsTheMatchingContentInsteadOfAlwaysExportingTheWholeLesson() {
        let latest = snapshot(scope: .latest, notes: "## 最近一批\n- 只应出现在最近更新里。")
        let whole = snapshot(scope: .wholeLesson, notes: "## 整课\n- 只应出现在整课笔记里。")

        let latestText = NotesExportDocument.markdown(latest)
        let wholeText = NotesExportDocument.markdown(whole)

        XCTAssertTrue(latestText.contains("只应出现在最近更新里"))
        XCTAssertFalse(latestText.contains("只应出现在整课笔记里"))
        XCTAssertTrue(latestText.contains("最近完成：12:30–15:00"))
        XCTAssertTrue(wholeText.contains("只应出现在整课笔记里"))
        XCTAssertFalse(wholeText.contains("只应出现在最近更新里"))
    }

    func testReviewAdviceIsAnIndependentSectionAndNeverMergedIntoTheNotesBody() {
        let text = NotesExportDocument.markdown(snapshot(withReview: true))
        XCTAssertTrue(text.contains(NotesExportDocument.reviewHeading))
        XCTAssertTrue(text.contains("请核对原文"))

        let notesSection = text.components(separatedBy: "## \(NotesExportDocument.notesHeading)")[1]
            .components(separatedBy: "## \(NotesExportDocument.reviewHeading)")[0]
        XCTAssertFalse(notesSection.contains("请核对原文"), "复查意见不得混入笔记正文")
    }

    /// 四格式共用**一次**复查章节：报告里的批次标题保留为子级、顶层标题转成进度文字，
    /// 不再各自加"复查批次 1/2"这种重复编号，也绝不重复渲染整篇报告。
    func testReviewSectionIsRenderedOnceInEveryFormatWithoutDuplicateBatchNumbering() throws {
        let review = """
        # 9B 思考复查 2/2 批（约 5 分钟/批）

        以下是模型复查意见，仅供核对，可能有误；没有修改笔记正文。

        ## 第 1 批 · 电子云
        - **原笔记 · 要点 1**：这里是一段无法归类的自由正文，必须原样保留。

        ## 第 2 批 · 原子轨道
        - **9B 建议（待核对）**：第二条建议。
        """
        let document = snapshot(review: review, withReview: true)
        for format in NotesExportFormat.allCases {
            let text = try plainText(of: document, format: format)
            let headingCount = text.components(separatedBy: NotesExportDocument.reviewHeading).count - 1
            XCTAssertEqual(headingCount, 1, "\(format.rawValue) 的复查章节出现了 \(headingCount) 次")
            XCTAssertFalse(text.contains("复查批次 1"), "\(format.rawValue) 仍有重复的批次编号")
            XCTAssertFalse(text.contains("复查批次 2"), "\(format.rawValue) 仍有重复的批次编号")
            XCTAssertTrue(text.contains("第 1 批"), "\(format.rawValue) 丢了批次标题")
            XCTAssertTrue(text.contains("第 2 批"), "\(format.rawValue) 丢了批次标题")
            XCTAssertTrue(text.contains("复查进度：9B 思考复查 2/2 批"), "\(format.rawValue) 的顶层标题没有转成进度文字")
            XCTAssertEqual(text.components(separatedBy: "9B 思考复查").count - 1, 1,
                           "\(format.rawValue) 把顶层标题又抄了一遍")
            XCTAssertTrue(text.contains("无法归类的自由正文"), "\(format.rawValue) 丢掉了正文内容")
            XCTAssertTrue(text.contains("第二条建议"), "\(format.rawValue) 丢了第二批内容")
        }
    }

    /// 章节层级：批次标题必须是**子级**（`###`），不能和"复查意见"章节标题同级。
    func testBatchHeadingsStayBelowTheReviewSectionHeading() {
        let text = NotesExportDocument.markdown(snapshot(withReview: true))
        XCTAssertTrue(text.contains("\n### 第 1 批"), "批次标题应为子级")
        XCTAssertFalse(text.contains("\n## 第 1 批"), "批次标题不得与复查章节同级")
        XCTAssertFalse(text.contains("\n# 9B 思考复查"), "顶层报告标题不得再当章节标题")
    }

    /// 「最近更新」范围只限制笔记正文；复查意见覆盖本录音所有已完成的复查批次，导出里要注明。
    func testLatestScopeStatesThatReviewCoversAllFinishedBatches() {
        let latest = NotesExportDocument.markdown(snapshot(scope: .latest, withReview: true))
        XCTAssertTrue(latest.contains("复查范围：本录音所有已完成的复查批次"))
        XCTAssertTrue(PDFNotesWriter.attributedDocument(snapshot(scope: .latest, withReview: true)).string.contains("复查范围：本录音所有已完成的复查批次"))
        XCTAssertFalse(latest.contains("复查批次 1"))

        let withoutReview = NotesExportDocument.markdown(snapshot(scope: .latest, withReview: false))
        XCTAssertFalse(withoutReview.contains("复查范围："), "没勾选复查时不该出现复查范围")

        let whole = NotesExportDocument.markdown(snapshot(scope: .wholeLesson, withReview: true))
        XCTAssertFalse(whole.contains("复查范围："), "整课范围不需要这条说明")
    }

    /// 快照里带了报告但没勾选"包含复查意见" → 章节不得出现（四种格式一致）。
    func testReviewSectionIsAbsentWhenTheOptionIsOff() throws {
        for format in NotesExportFormat.allCases {
            let text = try plainText(of: snapshot(withReview: false), format: format)
            XCTAssertFalse(text.contains(NotesExportDocument.reviewHeading),
                           "\(format.rawValue) 未勾选时出现了复查章节")
            XCTAssertFalse(text.contains("请核对原文"), "\(format.rawValue) 未勾选时仍带出了复查内容")
        }
    }

    func testPlainTextDropsMarkdownSyntaxButKeepsContent() {
        let text = NotesExportDocument.plainText(snapshot())
        XCTAssertFalse(text.contains("## "))
        XCTAssertFalse(text.contains("**"))
        XCTAssertTrue(text.contains("电子云与原子轨道"))
        XCTAssertTrue(text.contains("$v = \\frac{d}{t}$"))
        XCTAssertTrue(text.contains("待核对"))
        XCTAssertTrue(text.contains("00:00–00:05"))
    }

    // MARK: - 粗体标记只去成对的 `**`（issue #10）

    /// 纯文本只去掉真正成对的 `**`：代码里的 `__init__`、正文里的 `x ** 2`、
    /// 不成对的 `**` 和 `snake__case` 都必须原样保留。
    func testPlainTextStripsOnlyRealBoldAndKeepsCodeAndOperators() {
        let cases: [(String, String)] = [
            ("- **例子**：构造函数 `__init__` 被调用", "- 例子：构造函数 `__init__` 被调用"),
            ("x ** 2 与 2 ** 10 = 1024", "x ** 2 与 2 ** 10 = 1024"),
            (#"if __name__ == "__main__":"#, #"if __name__ == "__main__":"#),
            ("snake__case 与 **重点**", "snake__case 与 重点"),
            ("**重点** 和 **难点**", "重点 和 难点"),
            ("a ** b，**未闭合", "a ** b，**未闭合"),
            ("**see `a**b`**", "see `a**b`"),
            ("## **标题**\r", "标题\r"),
            ("> **引用**：内容", "引用：内容"),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(NotesExportDocument.strippingMarkdown(source), expected, source)
        }
    }

    /// 围栏和缩进代码块整行原样保留：不去 `#`、`> `，也不碰里面的 `**`/`__`。
    func testPlainTextKeepsFencedAndIndentedCodeBlocksVerbatim() {
        let fence = "```python\n# 注释\ndef __init__(self): return 2 ** 3\n> 不是引用\nf(**a)**2\n```"
        XCTAssertEqual(NotesExportDocument.strippingMarkdown("## 例子\n\(fence)\n- **要点**：x"),
                       "例子\n\(fence)\n- 要点：x")
        let indented = "    y = f(**opts)**2\n    z = __b__"
        XCTAssertEqual(NotesExportDocument.strippingMarkdown("说明：\n\n\(indented)\n\n**结束**"),
                       "说明：\n\n\(indented)\n\n结束")
        // 同一行在代码块外才按粗体处理 ✓（证明上面保留的是代码块判定，不是规则本身）。
        XCTAssertEqual(NotesExportDocument.strippingMarkdown("y = f(**opts)**2"), "y = f(opts)2")
    }

    func testPlainTextExportKeepsCodeInNotesAndReviewAdvice() throws {
        let notes = """
        ## Python 类
        - **例子**：构造函数 `__init__` 在 `if __name__ == "__main__":` 之前定义，2 ** 10 = 1024。
        ```python
        # 计算平方
        print(3 ** 2)
        ```
        """
        let review = """
        # 9B 思考复查 1/1 批（约 5 分钟/批）

        ## 第 1 批 · Python 类
        - **9B 建议（待核对）**：`__init__` 不要写成 `init`，x ** 2 是平方。
        """
        let text = String(decoding: try NotesExportDocument.data(
            snapshot(notes: notes, review: review, withReview: true, withTranscript: false), format: .plainText),
            as: UTF8.self)
        XCTAssertTrue(text.contains("- 例子：构造函数 `__init__` 在 `if __name__ == \"__main__\":` 之前定义，2 ** 10 = 1024。"), text)
        XCTAssertTrue(text.contains("```python\n# 计算平方\nprint(3 ** 2)\n```"), text)
        XCTAssertTrue(text.contains("- 9B 建议（待核对）：`__init__` 不要写成 `init`，x ** 2 是平方。"), text)
    }

    /// PDF/Word 的粗体判定与纯文本共用同一套配对：运算符和不成对的 `**` 不加粗。
    func testPDFBoldRunsUseTheSamePairingAsPlainText() {
        let boldFont = PDFNotesWriter.font(size: PDFNotesWriter.bodySize, bold: true).fontName
        func rendered(_ source: String) -> (text: String, bold: [String]) {
            let runs = PDFNotesWriter.inlineRuns(source, size: PDFNotesWriter.bodySize, bold: false)
            let bold = runs.filter { ($0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName == boldFont }
            return (runs.map(\.string).joined(), bold.map(\.string))
        }
        XCTAssertEqual(rendered("2 ** 10 = 1024，而 x ** 2 是平方").text, "2 ** 10 = 1024，而 x ** 2 是平方")
        XCTAssertEqual(rendered("2 ** 10 = 1024，而 x ** 2 是平方").bold, [])
        XCTAssertEqual(rendered("**重点** 和 a ** b 以及 **未闭合").text, "重点 和 a ** b 以及 **未闭合")
        XCTAssertEqual(rendered("**重点** 和 a ** b 以及 **未闭合").bold, ["重点"])
        XCTAssertEqual(rendered("**see `a**b`**").text, "see `a**b`")
        XCTAssertEqual(rendered("**see `a**b`**").bold.joined(), "see `a**b`")
    }

    private func boldPieces(_ line: String) -> [String] {
        MarkdownBold.segments(line).filter(\.bold).map(\.text)
    }

    /// 粗体以 `\Omega`、`\n` 这类命令结尾时，命令后的第一个 `*` 不能被当成
    /// `\command*` 的星号后缀吞掉，否则闭合的 `**` 失配，粗体整段失效。
    func testBoldEndingInBackslashCommandStillPairs() {
        let cases: [(String, String)] = [
            (#"**单位 \Omega**"#, #"单位 \Omega"#),
            (#"**\alpha**"#, #"\alpha"#),
            (#"**换行符 \n** 和 **角 \theta 的值**"#, #"换行符 \n 和 角 \theta 的值"#),
            (#"带星号的 \section* 与 **重点**"#, #"带星号的 \section* 与 重点"#),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(NotesExportDocument.strippingMarkdown(source), expected, source)
            let new = PDFNotesWriter.inlineRuns(source, size: PDFNotesWriter.bodySize, bold: false)
            XCTAssertEqual(new, legacyInlineRuns(source, size: PDFNotesWriter.bodySize, bold: false), source)
        }
        XCTAssertEqual(boldPieces(#"**单位 \Omega**"#), [#"单位 \Omega"#])
        XCTAssertEqual(boldPieces(#"**\alpha**"#), [#"\alpha"#])
        // 公式里的 `**` 仍然不配对。
        XCTAssertEqual(NotesExportDocument.strippingMarkdown(#"$\alpha**$ 与 **b**"#), #"$\alpha**$ 与 b"#)
    }

    /// `***注意***` 按 CommonMark 是粗体外再套一层 `*`：去掉粗体，外层 `*` 留作字面，
    /// 和修复前的纯文本、PDF 输出一致；单独一行的 `***` 分隔线不动。
    func testTripleStarRunsStripBoldAndKeepOneLiteralStar() {
        for source in ["***注意***", "***注意** 后文", "前文 **注意***"] {
            XCTAssertEqual(NotesExportDocument.strippingMarkdown(source), legacyStrippingMarkdown(source), source)
        }
        XCTAssertEqual(NotesExportDocument.strippingMarkdown("***注意***"), "*注意*")
        XCTAssertEqual(NotesExportDocument.strippingMarkdown("***注意** 后文"), "*注意 后文")
        XCTAssertEqual(NotesExportDocument.strippingMarkdown("前文 **注意***"), "前文 注意*")
        XCTAssertEqual(NotesExportDocument.strippingMarkdown("***\n  *** "), "***\n  *** ")
        XCTAssertEqual(boldPieces("***注意***"), ["注意"])
        let new = PDFNotesWriter.inlineRuns("***注意***", size: PDFNotesWriter.bodySize, bold: false)
        XCTAssertEqual(new, legacyInlineRuns("***注意***", size: PDFNotesWriter.bodySize, bold: false))
    }

    /// 正文里不加空格的幂运算（两侧都是 ASCII 字母或数字）不当粗体，
    /// 和汉字相邻的粗体照常去掉。
    func testUnspacedPowerOperatorsInProseStayLiteral() {
        for source in ["面积 = x**2 + y**2", "(a+b)**2 + c**2", "2**10 = 1024", "x**(n+1) + y**2"] {
            XCTAssertEqual(NotesExportDocument.strippingMarkdown(source), source)
            XCTAssertEqual(boldPieces(source), [], source)
        }
        let cases: [(String, String)] = [
            ("这是**重点**内容", "这是重点内容"),
            ("使用**API**接口", "使用API接口"),
            ("**GPT-4**模型与 x**2", "GPT-4模型与 x**2"),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(NotesExportDocument.strippingMarkdown(source), expected, source)
        }
    }

    /// 普通笔记（粗体标签 + 正文）的导出必须和修复前逐字节一致 ✓：
    /// 下面是修复前两段实现的原样副本，只用于比对，不参与导出。
    private func legacyStrippingMarkdown(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var text = String(line)
            if let range = text.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
            text = text.replacingOccurrences(of: "**", with: "")
            text = text.replacingOccurrences(of: "__", with: "")
            if text.hasPrefix("> ") { text = String(text.dropFirst(2)) }
            return text
        }.joined(separator: "\n")
    }

    private func legacyInlineRuns(_ source: String, size: CGFloat, bold: Bool) -> [NSAttributedString] {
        var runs: [NSAttributedString] = []
        let pattern = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
        let ns = source as NSString
        var cursor = 0
        func appendPlain(_ piece: String, strong: Bool) {
            guard !piece.isEmpty else { return }
            for run in FormulaDisplay.runs(piece) {
                let fontSize = run.script == 0 ? size : size * 0.72
                let font = PDFNotesWriter.font(size: fontSize, bold: strong || (run.math && !run.text.isEmpty))
                var attributes: [NSAttributedString.Key: Any] = [.font: font]
                if run.script != 0 {
                    attributes[.baselineOffset] = run.script > 0 ? size * 0.34 : -size * 0.16
                }
                if run.math {
                    attributes[.foregroundColor] = NSColor.labelColor
                }
                runs.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        if let pattern {
            for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > cursor {
                    appendPlain(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), strong: bold)
                }
                appendPlain(ns.substring(with: match.range(at: 1)), strong: true)
                cursor = NSMaxRange(match.range)
            }
        }
        if cursor < ns.length {
            appendPlain(ns.substring(from: cursor), strong: bold)
        }
        if runs.isEmpty { runs.append(NSAttributedString(string: source, attributes: [.font: PDFNotesWriter.font(size: size, bold: bold)])) }
        return runs
    }

    func testOrdinaryNotesExportExactlyAsBeforeTheBoldPairingFix() throws {
        var book = LearningNotebook()
        try book.append(evidence: [
            segment(0, 300, "The mass stays the same in a closed system.", "在封闭系统中质量保持不变。"),
            segment(300, 600, "Temperature and pressure change together.", "温度与压强一起变化。"),
        ], note: LearningNote(topic: "质量守恒", points: [
            .init(kind: "核心结论", text: "质量在封闭系统中保持不变。", sourceIDs: ["en0s0"]),
            .init(kind: "易错点", text: "质量守恒不等于体积不变。", sourceIDs: ["zh0s0"]),
            .init(kind: "核心结论", text: "温度与压强成正比。", sourceIDs: ["missing"]),
            .init(kind: "待确认", text: "速度随温度升高而增大。", needsContext: "这项速度属于哪个对象？", sourceIDs: ["en0s0"]),
        ], sourceVersion: 2))
        let fixture = snapshot()
        let review = try XCTUnwrap(fixture.reviewMarkdown)
        let fixtures = [
            fixture.notesMarkdown,
            review,
            NotesExportDocument.reviewSection(review),
            book.markdown(),
            "- **要点 1**：第一条内容。\n- **要点 2**：第二条内容。",
            "## 电子云与原子轨道\n- **公式**：速率 $v = \\frac{d}{t}$，数列 $a_n = b^2$ 表示第 n 项的平方（待核对）。",
            "## 公式\n- 质能方程 $E = mc^2$，下标写法 $a_n$。",
            (1...60).map { "- **要点 \($0)**：包含公式 $a_\($0) = b^2$ 与待核对标记。" }.joined(separator: "\n"),
            "- **Example**: the mass stays the same.\n- **Pending**: which object?\n\n> **Note**：引用里的 **粗体**。",
        ]
        for source in fixtures {
            XCTAssertEqual(NotesExportDocument.strippingMarkdown(source), legacyStrippingMarkdown(source), source)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let style = PDFNotesWriter.Style.markdown(String(line))
                let text = PDFNotesWriter.text(of: style, line: String(line))
                for bold in [false, true] {
                    let new = PDFNotesWriter.inlineRuns(text, size: PDFNotesWriter.bodySize, bold: bold)
                    let old = legacyInlineRuns(text, size: PDFNotesWriter.bodySize, bold: bold)
                    XCTAssertEqual(new, old, text)
                }
            }
        }
    }

    func testDefaultFileNameCarriesClassDateScopeAndFormat() {
        for format in NotesExportFormat.allCases {
            let name = NotesExportDocument.defaultFileName(snapshot(), format: format)
            XCTAssertTrue(name.hasPrefix("实时课堂 2026-09-16 "), name)
            XCTAssertTrue(name.contains("整课笔记"), name)
            XCTAssertTrue(name.hasSuffix(".\(format.fileExtension)"), name)
        }
        XCTAssertEqual(
            NotesExportDocument.defaultFileName(snapshot(scope: .latest), format: .plainText),
            "实时课堂 2026-09-16 最近更新.txt"
        )
    }

    func testEmptyScopeIsMarkedInsteadOfWritingAnEmptyDocument() throws {
        let data = try NotesExportDocument.data(snapshot(notes: "   \n ", withTranscript: false), format: .markdown)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("（所选范围暂无笔记）"), "空范围必须显式标注，不能导出成空白或整课内容")
        XCTAssertFalse(text.contains("## 电子云"))
    }

    func testExportedFileLandsOnDiskWithTheChosenExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoExport-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try NotesExportDocument.write(snapshot(), format: .markdown, to: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(written.contains("## 学习笔记"))
    }

    // MARK: - 新笔记形状（`## 需要回听` / `## 来源检查`）与旧数据兼容

    /// 2026-09-20：正文按主题组织、不再逐条挂 `**核心结论**` 标签，风险集中到
    /// `## 需要回听`（缺对象/条件的具体问题 + 实际时间）与 `## 来源检查`（来源对不上）两节 ✓。
    ///
    /// 这里的 `notesMarkdown` **由真实代码生成**（`LearningNotebook.markdown()`）✓，不是手写字符串 ✗：
    /// 手写字符串只能证明"导出器会搬运"✓，证明不了"笔记渲染出来的新小节真的四种格式都有"✓。
    func testNewNoteSectionsStayConsistentAcrossAllFourFormats() throws {
        let gapQuestion = "这项速度属于哪个对象？"
        let firstBatch = [
            segment(0, 300, "The mass stays the same in a closed system.", "在封闭系统中质量保持不变。"),
            segment(300, 600, "Temperature and pressure change together.", "温度与压强一起变化。"),
        ]
        let secondBatch = [
            // 要点只引用第 1 段（12:30–13:20），整批范围是 12:30–15:00 —— 时间标签必须跟着来源走 ✓。
            segment(750, 800, "The measured speed increases with temperature.", "测得的速度随温度升高。"),
            segment(840, 900, "The container was heated for ten minutes.", "容器加热了十分钟。"),
        ]

        var book = LearningNotebook()
        try book.append(evidence: firstBatch, note: LearningNote(topic: "质量守恒", points: [
            .init(kind: "核心结论", text: "质量在封闭系统中保持不变。", sourceIDs: ["en0s0"]),
            .init(kind: "易错点", text: "质量守恒不等于体积不变。", sourceIDs: ["zh0s0"]),
            .init(kind: "核心结论", text: "温度与压强成正比。", sourceIDs: ["missing"]),
        ], sourceVersion: 2))
        try book.append(evidence: secondBatch, note: LearningNote(topic: "速度与温度", points: [
            .init(kind: "待确认", text: "速度随温度升高而增大。", needsContext: gapQuestion, sourceIDs: ["en0s0"]),
        ], sourceVersion: 2))

        let notes = book.markdown()
        // 前提自检：下面四个格式的断言必须建立在"真实渲染确实长这样"之上 ✓。
        XCTAssertTrue(notes.contains("## \(LearningNotebook.replayHeading)"), "笔记里就该有需要回听这一节")
        XCTAssertTrue(notes.contains("## \(LearningNotebook.sourceCheckHeading)"), "unlinked 来源要进来源检查")
        XCTAssertTrue(notes.contains("- **易错点**："), "非默认 kind 仍要保留标签")
        XCTAssertFalse(notes.contains("**核心结论**"), "正文不该再有逐条的 `核心结论` 标签")

        // 关掉字幕节：否则 "[MM:SS–MM:SS]" 可能来自字幕时间戳，掩盖"小节丢了时间标签" ✗。
        let document = snapshot(notes: notes, withTranscript: false)
        for format in NotesExportFormat.allCases {
            let text = try plainText(of: document, format: format)
            XCTAssertTrue(containsSectionHeading(LearningNotebook.replayHeading, in: text),
                          "\(format.rawValue) 丢了「需要回听」小节标题")
            XCTAssertTrue(containsSectionHeading(LearningNotebook.sourceCheckHeading, in: text),
                          "\(format.rawValue) 丢了「来源检查」小节标题")
            XCTAssertTrue(text.contains(gapQuestion), "\(format.rawValue) 丢了需要回听的具体问题")
            XCTAssertTrue(text.contains("[12:30–13:20]"), "\(format.rawValue) 丢了需要回听的来源时间范围")
            XCTAssertTrue(text.contains("来源未链接到原文"), "\(format.rawValue) 丢了来源检查条目")
            XCTAssertFalse(text.contains("**核心结论**"), "\(format.rawValue) 又出现了逐条 `核心结论` 标签")
            XCTAssertFalse(text.contains("来源待核对"), "\(format.rawValue) 又出现了旧的状态后缀")
        }
    }

    /// 旧数据（`sourceVersion` 1、只有 `sources` 数组、没有 `needsContext`/`referenceState`）必须照样能读 ✓：
    /// 引文能对上原文就是一条正常笔记 ✓，不该被塞进 `## 来源检查` ✗，更不该凭空多出 `## 需要回听` ✗。
    func testLegacyNoteShapesStillExport() throws {
        let legacy = #"{"sourceVersion":1,"topic":"质量","points":[{"kind":"核心结论","text":"质量保持不变。","sources":[{"index":0,"quote":"The mass stays the same."}]}]}"#
        // 原文与要点文字刻意不同 ✓：下面 `contains("质量保持不变。")` 只能来自笔记正文 ✓。
        let evidence = [segment(0, 8, "The mass stays the same.", "质量在封闭系统中保持不变。")]

        let bound = try LearningNote.decode(legacy).binding(evidence: evidence)
        let point = try XCTUnwrap(bound.points.first)
        XCTAssertEqual(point.referenceState, LearningPoint.ReferenceState.linked, "旧来源引文仍要能对上原文")

        var book = LearningNotebook()
        try book.append(evidence: evidence, note: bound)
        let markdown = book.markdown()
        XCTAssertTrue(markdown.contains("质量保持不变。"), "旧笔记正文仍然要能读出来")
        XCTAssertFalse(markdown.contains("## \(LearningNotebook.sourceCheckHeading)"),
                       "来源已对上的旧笔记不该进来源检查")
        XCTAssertFalse(markdown.contains("## \(LearningNotebook.replayHeading)"),
                       "旧笔记没有待确认的问题，不该多出需要回听")

        let document = snapshot(notes: markdown, withTranscript: false)
        for format in NotesExportFormat.allCases {
            let text = try plainText(of: document, format: format)
            XCTAssertTrue(text.contains("质量保持不变。"), "\(format.rawValue) 丢了旧笔记正文")
            XCTAssertFalse(containsSectionHeading(LearningNotebook.sourceCheckHeading, in: text),
                           "\(format.rawValue) 给旧笔记加了来源检查小节")
            XCTAssertFalse(containsSectionHeading(LearningNotebook.replayHeading, in: text),
                           "\(format.rawValue) 给旧笔记加了需要回听小节")
        }
    }

    // MARK: - Word (.docx)

    func testWordExportIsARealDocxPackageWithChineseFormulasAndScripts() throws {
        let notes = """
        ## 电子云与原子轨道
        - **公式**：速率 $v = \\frac{d}{t}$，数列 $a_n = b^2$ 表示第 n 项的平方（待核对）。
        """
        let data = try NotesExportDocument.data(snapshot(notes: notes, withReview: true), format: .word)
        XCTAssertGreaterThan(data.count, 1_000)

        // A .docx is a ZIP package: PK header, and ZIP stores member names in
        // clear text even when the members themselves are deflated.
        XCTAssertEqual(data.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]), "docx 必须是 ZIP 包")
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("word/document.xml"), "缺少 OOXML 主文档")
        XCTAssertTrue(raw.contains("[Content_Types].xml"), "缺少 OOXML 内容类型表")

        // Round-trip through the system reader: Word 用的是同一套解析。
        let restored = try NSAttributedString(
            data: data, options: [:], documentAttributes: nil
        )
        let plain = restored.string
        XCTAssertTrue(plain.contains("学习笔记"), "中文标题要能读回")
        XCTAssertTrue(plain.contains("待核对"), "不确定性标记要保留")
        XCTAssertTrue(plain.contains("复查意见"), "勾选后应带独立复查章节")
        XCTAssertTrue(plain.contains("电子云与原子轨道"))

        var scripts = 0
        restored.enumerateAttribute(.baselineOffset, in: NSRange(location: 0, length: restored.length)) { value, _, _ in
            if let number = value as? NSNumber, number.doubleValue != 0 { scripts += 1 }
        }
        XCTAssertGreaterThan(scripts, 0, "公式的上下标要在 Word 里保留")

        let noReview = try NSAttributedString(
            data: try NotesExportDocument.data(snapshot(withReview: false), format: .word),
            options: [:], documentAttributes: nil
        )
        XCTAssertFalse(noReview.string.contains("复查意见"), "未勾选时不得出现复查章节")
    }

    // MARK: - PDF

    /// PDF 的行序必须是"从上往下"。
    /// 曾经的缺陷：`NSGraphicsContext(flipped: false)` 下 TextKit 会把每段文字**向上**堆叠，
    /// 于是小标题落在它自己的条目下方、文档标题跑到页尾——视觉和文本层都能看出来。
    func testPDFKeepsTopDownReadingOrder() throws {
        let notes = "- **要点 1**：第一条内容。\n- **要点 2**：第二条内容。"
        let data = try NotesExportDocument.data(snapshot(notes: notes, withTranscript: true), format: .pdf)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")

        let heading = try XCTUnwrap(text.range(of: "学习笔记"), "标题必须能被取回")
        let first = try XCTUnwrap(text.range(of: "要点 1"), "第一条要点必须能被取回")
        let second = try XCTUnwrap(text.range(of: "要点 2"), "第二条要点必须能被取回")
        XCTAssertLessThan(heading.lowerBound, first.lowerBound, "文档标题必须排在正文之前")
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "同一段的要点顺序不能颠倒")

        let english = try XCTUnwrap(text.range(of: "Electrons are described by a cloud."), "英文转写必须存在")
        XCTAssertLessThan(first.lowerBound, english.lowerBound, "笔记必须排在转写之前")
    }

    func testPDFRendersChineseTextWrapsAndPaginates() throws {
        let longNotes = (1...60).map { index in
            "- **要点 \(index)**：这是一条用于验证换行与分页的中文笔记内容，包含公式 $a_\(index) = b^2$ 与待核对标记。"
        }.joined(separator: "\n")
        let data = try NotesExportDocument.data(snapshot(notes: longNotes, withTranscript: false), format: .pdf)
        XCTAssertGreaterThan(data.count, 1_000, "PDF 不能只是空文件")

        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(document.pageCount, 2, "长内容必须分成多页")

        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        XCTAssertTrue(text.contains("学习笔记"), "中文标题要能从 PDF 中取回（字体与编码正确）")
        XCTAssertTrue(text.contains("要点 60"), "分页后内容不能丢失")
        XCTAssertTrue(text.contains("待核对"), "不确定性标记要保留")
        XCTAssertFalse(text.contains("\u{FFFD}"), "不得出现字体缺失替换字符")

        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let pageBounds = page.bounds(for: .mediaBox)
            let full = NSRange(location: 0, length: page.numberOfCharacters)
            guard let selection = page.selection(for: full) else { continue }
            let bounds = selection.bounds(for: page)
            XCTAssertGreaterThanOrEqual(bounds.minX, pageBounds.minX - 1, "第 \(index + 1) 页文字越出左边距")
            XCTAssertLessThanOrEqual(bounds.maxX, pageBounds.maxX + 1, "第 \(index + 1) 页文字越出右边距（换行失败）")
            XCTAssertGreaterThanOrEqual(bounds.minY, pageBounds.minY - 1, "第 \(index + 1) 页文字越出下边距")
            XCTAssertLessThanOrEqual(bounds.maxY, pageBounds.maxY + 1, "第 \(index + 1) 页文字越出上边距")
        }
    }

    func testPDFUsesACJKCapableFontForFormulaText() throws {
        let data = try NotesExportDocument.data(
            snapshot(notes: "## 公式\n- 速率 $v = \\frac{d}{t}$，能量 $E = mc^2$。", withTranscript: false),
            format: .pdf
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let attributed = try XCTUnwrap(page.attributedString)

        var fonts: Set<String> = []
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let font = value as? NSFont { fonts.insert(font.fontName) }
        }
        XCTAssertFalse(fonts.isEmpty, "PDF 必须记录所用字体")
        let cjkFonts = ["PingFang", "Hiragino", "Heiti", "Songti", "STSong", "STHeiti"]
        XCTAssertTrue(
            fonts.contains { name in cjkFonts.contains { name.localizedCaseInsensitiveContains($0) } },
            "应使用中文字体，实际为：\(fonts.sorted())"
        )
        XCTAssertTrue((page.string ?? "").contains("速率"), "中文字符必须能正确取回")
    }

    /// 回归：PDF 文字层必须是被搜索/复制的那套汉字，而不是康熙部首码点。
    /// 2026-09-18 实测 PingFang SC 会把「一/水/而/氏…」共 33 种 149 处写成 U+2F00–U+2FDF，
    /// 人眼看不出来但搜索、复制、朗读全废；改用 Hiragino Sans GB 后为 0。
    func testPDFTextLayerUsesRealIdeographsNotKangxiRadicals() throws {
        let sample = "溶解度与摄氏度：水、而、用、心、氏、里、目。"
        let data = try NotesExportDocument.data(
            snapshot(notes: "## 易错点\n" + sample, withTranscript: false),
            format: .pdf
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()

        XCTAssertTrue(text.contains("摄氏度"), "中文字符必须能按原样取回")
        XCTAssertTrue(text.contains("溶解度"))

        var radicals: [Character] = []
        for character in text {
            guard let value = character.unicodeScalars.first?.value else { continue }
            if (0x2E80...0x2FDF).contains(value) || (0xF900...0xFAFF).contains(value) {
                radicals.append(character)
            }
        }
        XCTAssertTrue(
            radicals.isEmpty,
            "PDF 文字层出现康熙部首/兼容区字符（\(radicals.count) 个：\(String(radicals.prefix(8)))），搜索与复制会失效"
        )
    }

    /// 公式的上下标必须留在 PDF 文字层里（能被复制/搜索），不能只画出来。
    func testPDFTextLayerKeepsFormulaScripts() throws {
        let data = try NotesExportDocument.data(
            snapshot(notes: "## 公式\n- 质能方程 $E = mc^2$，下标写法 $a_n$。", withTranscript: false),
            format: .pdf
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        XCTAssertTrue(text.contains("质能方程"), "中文必须完整：\(text.prefix(60))")
        XCTAssertTrue(text.contains("mc"), "公式基底必须保留")
        XCTAssertTrue(text.contains("2"), "上标数字必须留在文字层")
        XCTAssertTrue(text.contains("a") && text.contains("n"), "下标字符必须留在文字层")
    }

    func testPDFIncludesReviewSectionOnlyWhenRequested() throws {
        let withReview = try NotesExportDocument.data(snapshot(withReview: true), format: .pdf)
        let withoutReview = try NotesExportDocument.data(snapshot(withReview: false), format: .pdf)
        let withText = (0..<(PDFDocument(data: withReview)?.pageCount ?? 0))
            .compactMap { PDFDocument(data: withReview)?.page(at: $0)?.string }.joined()
        let withoutText = (0..<(PDFDocument(data: withoutReview)?.pageCount ?? 0))
            .compactMap { PDFDocument(data: withoutReview)?.page(at: $0)?.string }.joined()
        XCTAssertTrue(withText.contains("复查"), "勾选后应出现独立复查章节；实际：\(withText.suffix(120))")
        XCTAssertTrue(withText.contains("仅供核对"))
        XCTAssertFalse(withoutText.contains("复查"), "未勾选时不得出现复查章节")
    }
}

/// 第 6 项：专注模式（应用内任务优先级）。
final class ProcessingFocusTests: XCTestCase {
    private func context(
        focus: Bool,
        recording: Bool = false,
        memoryNormal: Bool = true,
        backlog: Bool = false,
        liveWork: Bool = false,
        available: UInt64 = 16 * 1_024 * 1_024 * 1_024,
        latencyAllows: Bool = true
    ) -> ProcessingFocusPolicy.Context {
        .init(focusMode: focus, recording: recording, memoryNormal: memoryNormal,
              hasCaptionBacklog: backlog, liveWorkPending: liveWork,
              availableBytes: available, latencyAllowsConcurrency: latencyAllows)
    }

    func testStandardModeKeepsTheExistingThresholds() {
        let idle = ProcessingFocusPolicy.decision(context(focus: false))
        XCTAssertTrue(idle.resourcesAvailable)
        XCTAssertTrue(idle.allowConcurrentReview)

        let backlog = ProcessingFocusPolicy.decision(context(focus: false, backlog: true))
        XCTAssertFalse(backlog.resourcesAvailable, "字幕积压时后台复查让路")

        let lowMemory = ProcessingFocusPolicy.decision(context(focus: false, available: 2 * 1_024 * 1_024 * 1_024))
        XCTAssertFalse(lowMemory.resourcesAvailable)

        let recordingLowMemory = ProcessingFocusPolicy.decision(
            context(focus: false, recording: true, available: 6 * 1_024 * 1_024 * 1_024))
        XCTAssertFalse(recordingLowMemory.resourcesAvailable, "录音时保留更高的内存余量")
    }

    func testFocusModeNeverRunsBackgroundReviewWhileLiveWorkIsPending() {
        let pending = ProcessingFocusPolicy.decision(context(focus: true, liveWork: true))
        XCTAssertFalse(pending.resourcesAvailable)
        XCTAssertFalse(pending.allowConcurrentReview)

        let idle = ProcessingFocusPolicy.decision(context(focus: true))
        XCTAssertTrue(idle.resourcesAvailable, "完全空闲时才允许后台复查")

        let recording = ProcessingFocusPolicy.decision(context(focus: true, recording: true))
        XCTAssertFalse(recording.allowConcurrentReview, "专注模式下录音期间不并行复查")
    }

    func testFocusModeDoesNotResumeAUserPausedReview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoFocus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("queue.json")
        // The focus-mode decision only ever restricts background work.
        let decision = ProcessingFocusPolicy.decision(context(focus: true))
        let queue = await MainActor.run { () -> LearningReviewQueue in
            // 假 generator + 独立目录：这条测试不碰真实 9B。
            let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled,
                                            generate: { _, _, _, _, _ in "{}" })
            queue.togglePause()
            XCTAssertTrue(queue.userPaused)
            queue.setContext(recording: false, concurrent: decision.allowConcurrentReview,
                             resourcesAvailable: decision.resourcesAvailable)
            XCTAssertTrue(queue.userPaused, "专注模式不得自动恢复用户手动暂停的复查")
            XCTAssertFalse(queue.running)
            return queue
        }
        await queue.shutdownForTesting()
        let stillPaused = await MainActor.run { queue.userPaused }
        XCTAssertTrue(stillPaused, "收尾不得改变暂停语义")
    }

    /// 本机实测：.default / .userInitiated / .userInteractive 都映射到同一个 BSD 优先级
    /// 31，只有 .utility(20) 与 .background(4) 更低。因此“提高进程优先级”没有可做的空间，
    /// 专注模式只负责让后台复查为实时任务让路。
    func testSchedulingClassCeilingIsAlreadyReached() throws {
        func waitForReady(_ handle: FileHandle) throws {
            let descriptor = handle.fileDescriptor
            let originalFlags = fcntl(descriptor, F_GETFL)
            guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }
            let expected = Data("ready\n".utf8)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var received = Data()
            while received.count < expected.count {
                guard ContinuousClock.now < deadline else {
                    XCTFail("The synthetic QoS child did not become ready before its deadline")
                    throw CocoaError(.fileReadUnknown)
                }
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let available = poll(&descriptorState, 1, Int32(max(1, min(10_000, milliseconds))))
                if available < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if available == 0 { continue }
                var buffer = [UInt8](repeating: 0, count: 64)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard count > 0 else {
                    XCTFail("The synthetic QoS child exited before its ready handshake")
                    throw CocoaError(.fileReadUnknown)
                }
                received.append(contentsOf: buffer.prefix(count))
            }
            XCTAssertEqual(received, expected, "The synthetic child must complete its exact ready handshake")
            guard received == expected else { throw CocoaError(.fileReadUnknown) }
        }
        func launch(_ qos: QualityOfService) throws -> (process: Process, input: FileHandle) {
            let process = Process()
            let input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Both commands are shell builtins. Stdin owns the child's lifetime.
            process.arguments = ["-c", "printf 'ready\\n'; IFS= read -r livelingo_test_input"]
            process.environment = [:]
            process.qualityOfService = qos
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            do {
                try waitForReady(output.fileHandleForReading)
                return (process, input.fileHandleForWriting)
            } catch {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                throw error
            }
        }
        // Probe access before measuring the policy. A later inspection failure
        // is a failure, rather than a skip that could hide a real regression.
        let probe = try launch(.default)
        defer { try? probe.input.close(); probe.process.waitUntilExit() }
        var probeInfo = proc_taskinfo()
        let probeSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let probeResult = proc_pidinfo(probe.process.processIdentifier, PROC_PIDTASKINFO, 0, &probeInfo, probeSize)
        try XCTSkipUnless(probeResult == probeSize,
                          "The host must permit task-info inspection of this test's own child process")
        func priority(of qos: QualityOfService) throws -> Int32 {
            let child = try launch(qos)
            defer { try? child.input.close(); child.process.waitUntilExit() }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let result = proc_pidinfo(child.process.processIdentifier, PROC_PIDTASKINFO, 0, &info, size)
            XCTAssertEqual(result, size, "Task-info access failed after its prerequisite probe succeeded")
            guard result == size else { throw CocoaError(.fileReadUnknown) }
            return info.pti_priority
        }

        let interactive = try priority(of: .userInteractive)
        let live = try priority(of: .userInitiated)
        let standard = try priority(of: .default)
        let background = try priority(of: .background)
        XCTAssertEqual(interactive, live)
        XCTAssertEqual(live, standard)
        XCTAssertGreaterThan(standard, background, "唯一可验证的空间是“降低后台”，不是“提高前台”")
    }

    func testFocusModeNeverContributesToTheRecordingGate() {
        // The recording gate is `!phase.isBusy`; the focus policy only returns
        // review decisions, so it can neither start nor block a recording.
        let recording = ProcessingFocusPolicy.decision(context(focus: true, recording: true, latencyAllows: false))
        let notRecording = ProcessingFocusPolicy.decision(context(focus: true, recording: false, latencyAllows: false))
        XCTAssertEqual(recording.allowConcurrentReview, notRecording.allowConcurrentReview)
        XCTAssertEqual(recording.resourcesAvailable, notRecording.resourcesAvailable)
    }

}
