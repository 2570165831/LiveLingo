import Foundation

/// User-approved Chinese display policies. They never rewrite a course's stamped
/// targetLocale, generator input, or Simplified Chinese archival draft.
enum ChineseOutputDefaults {
    static let fixedTextFollowsDisplayLanguage = true
    static let jsonlKeepsSimplifiedDraft = true
    static let allowsChineseDisplaySwitch = true

    static func canSwitchDisplay(from current: OutputLanguage, to next: OutputLanguage) -> Bool {
        allowsChineseDisplaySwitch && current.profile.script == .han && next.profile.script == .han
    }

    /// The archival representation is chosen here, separately from display.
    /// Changing this policy also needs a versioned reader and verifier change;
    /// generation snapshots must continue to retain their original draft.
    static func encodeBilingualDraft(_ segment: TranscriptSegment, using encoder: JSONEncoder) throws -> Data {
        try encoder.encode(segment)
    }
}

/// User decisions recorded in target-languages/PLAN.md, section VII.4.
/// Changing the translation route still requires the G3 comparison.
enum LatinOutputDefaults {
    static let spanishPromptName = "Spanish"
    static let frenchPromptName = "French"
    static let spanishStyleInstruction = "Use Spanish according to the pan-Hispanic standard of the Real Academia Española (RAE) and the Asociación de Academias de la Lengua Española (ASALE). Use standard spelling, grammar and academic terminology shared across the Spanish-speaking world without favoring Spain or any one Latin American region."
    static let frenchStyleInstruction = "Use standard metropolitan French as used in France, with its standard spelling, grammar and academic terminology."

    // Apple uses es_ES/fr_FR in its offline package catalog. Request generic es
    // without making that Spain-labelled package the formal Spanish standard;
    // the formal prompts above govern pan-Hispanic output. Request fr-FR to
    // explicitly select France for the preliminary French translation. These
    // identifiers do not prove a package is installed; the installed-only gate
    // still skips a missing package without requesting a download.
    static let spanishAppleLanguageIdentifier = "es"
    static let frenchAppleLanguageIdentifier = "fr-FR"

    // User decision: same-language es/fr speech is the original caption, with
    // no translation or regional restyling. This also keeps its wording intact.
    static let spanishPassThroughSources: Set<String> = ["es"]
    static let frenchPassThroughSources: Set<String> = ["fr"]
    static let translationRoute: CaptionTranslationRoute = .direct
    static func styleInstruction(for target: CaptionTranslationTarget) -> String {
        target == .spanish ? spanishStyleInstruction : frenchStyleInstruction
    }
}

enum CaptionTranslationRoute: Sendable { case direct, viaEnglish }

/// Output metadata is independent of the language generated and stored by the
/// model. Only released profiles can be selected for a new course.
enum OutputLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChineseTaiwan = "zh-Hant-TW"
    case traditionalChineseHongKong = "zh-Hant-HK"
    case english = "en"
    case spanish = "es"
    case french = "fr"

    enum Script: Sendable { case han, latin }
    enum Renderer: Sendable { case identity, taiwan, hongKong }
    struct AppleLanguagePair: Equatable, Sendable {
        let source: String
        let target: String
    }
    struct Profile: Sendable {
        let autonym: String
        let promptName: String
        let script: Script
        let generationLocale: String
        let renderer: Renderer
        let passThroughSources: Set<String>
        let appleLanguagePair: AppleLanguagePair?
        let isReleased: Bool
    }

    private static let profiles: [Self: Profile] = [
        .simplifiedChinese: .init(autonym: "简体中文", promptName: "Simplified Chinese", script: .han,
            generationLocale: "zh-Hans", renderer: .identity, passThroughSources: ["zh"],
            appleLanguagePair: .init(source: "en", target: "zh-Hans"), isReleased: true),
        .traditionalChineseTaiwan: .init(autonym: "繁體中文（中國台灣）", promptName: "Simplified Chinese", script: .han,
            generationLocale: "zh-Hans", renderer: .taiwan, passThroughSources: ["zh"],
            appleLanguagePair: .init(source: "en", target: "zh-Hans"), isReleased: true),
        .traditionalChineseHongKong: .init(autonym: "繁體中文（中國港澳）", promptName: "Simplified Chinese", script: .han,
            generationLocale: "zh-Hans", renderer: .hongKong, passThroughSources: ["zh"],
            appleLanguagePair: .init(source: "en", target: "zh-Hans"), isReleased: true),
        .english: .init(autonym: "English", promptName: "English", script: .latin,
            generationLocale: "en", renderer: .identity, passThroughSources: ["en"],
            appleLanguagePair: nil, isReleased: false),
        .spanish: .init(autonym: "Español", promptName: LatinOutputDefaults.spanishPromptName, script: .latin,
            generationLocale: "es", renderer: .identity, passThroughSources: LatinOutputDefaults.spanishPassThroughSources,
            appleLanguagePair: .init(source: "en", target: LatinOutputDefaults.spanishAppleLanguageIdentifier), isReleased: false),
        .french: .init(autonym: "Français", promptName: LatinOutputDefaults.frenchPromptName, script: .latin,
            generationLocale: "fr", renderer: .identity, passThroughSources: LatinOutputDefaults.frenchPassThroughSources,
            appleLanguagePair: .init(source: "en", target: LatinOutputDefaults.frenchAppleLanguageIdentifier), isReleased: false),
    ]

    var id: String { rawValue }
    var profile: Profile { Self.profiles[self]! }
    var autonym: String { profile.autonym }
    var isReleased: Bool { profile.isReleased }
    var generationTarget: CaptionTranslationTarget? { CaptionTranslationTarget(rawValue: profile.generationLocale) }
    /// The default is omitted from persistence to preserve existing bytes.
    var persistedLocale: String? { self == .simplifiedChinese ? nil : rawValue }
    static var released: [Self] { allCases.filter(\.isReleased) }
    /// Chinese variants are released for both GUI and CLI creation. Latin
    /// targets retain their existing release boundary.
    static var cliGenerationLanguages: [Self] {
        allCases.filter { $0.isReleased || $0 == .traditionalChineseTaiwan || $0 == .traditionalChineseHongKong }
    }
    static func releasedLanguage(_ locale: String) -> Self? {
        guard let language = Self(rawValue: locale), language.isReleased else { return nil }
        return language
    }
    static func storedLanguage(_ locale: String?) throws -> Self {
        guard let locale else { return .simplifiedChinese }
        guard let language = Self(rawValue: locale) else {
            throw SessionStoreError.invalidState("课程输出语言不受支持")
        }
        return language
    }

    /// Course data owns this choice. Preferences apply only at creation.
    static func savedLanguage(in directory: URL, snapshot: SessionSnapshot,
                              origin: SessionLoadResult.Origin? = nil) throws -> Self {
        if let locale = snapshot.targetLocale { return try storedLanguage(locale) }
        // A persisted nil is an explicit Simplified Chinese choice. Only a
        // legacy import without a snapshot needs the export's metadata.
        let hasSnapshot = origin.map { $0 == .snapshot }
            ?? FileManager.default.fileExists(atPath: directory.appendingPathComponent(SessionStore.snapshotFileName).path)
        if hasSnapshot { return .simplifiedChinese }
        struct Metadata: Decodable { let targetLocale: String? }
        let manifest = directory.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let metadata = try? JSONDecoder().decode(Metadata.self, from: data) {
            // The non-regional code occurs in synthetic verifier fixtures,
            // not released exporters. Continue using the supported generator.
            if metadata.targetLocale == "zh-Hant" { return .simplifiedChinese }
            return try storedLanguage(metadata.targetLocale)
        }
        return .simplifiedChinese
    }

    /// Implementation availability. Regional exports also preflight the actual
    /// dictionary; this metadata check never loads resources on the default path.
    var rendererIsAvailable: Bool {
        switch profile.renderer {
        case .identity, .taiwan, .hongKong: return true
        }
    }

    func keepsSourceAsCaption(language: String?) -> Bool {
        profile.passThroughSources.contains(language ?? "en")
    }

    /// Generation text stays Simplified Chinese. Regional display and export
    /// apply this renderer exactly once; release gating is independent.
    func render(_ text: String, converter: ChineseScriptConverter = .shared) throws -> String {
        switch self {
        case .traditionalChineseTaiwan: return try converter.render(text, to: .taiwan)
        case .traditionalChineseHongKong: return try converter.render(text, to: .hongKong)
        case .simplifiedChinese, .english, .spanish, .french: return text
        }
    }

    /// Markdown supplies context from the complete document, including code or
    /// math spans that continue across the line currently displayed by the UI.
    func render(_ text: ChineseScriptConverter.RenderText, converter: ChineseScriptConverter = .shared) throws -> String {
        switch self {
        case .traditionalChineseTaiwan: return try converter.render(text, to: .taiwan)
        case .traditionalChineseHongKong: return try converter.render(text, to: .hongKong)
        case .simplifiedChinese, .english, .spanish, .french: return text.text
        }
    }

    /// AppModel prepares the same converter off the main actor and publishes
    /// any failure separately, so rendering never mutates observable UI state.
    func renderForDisplay(_ text: String, converter: ChineseScriptConverter = .shared) -> String {
        (try? render(text, converter: converter)) ?? text
    }

    func renderFixedText(_ text: String, converter: ChineseScriptConverter = .shared) throws -> String {
        ChineseOutputDefaults.fixedTextFollowsDisplayLanguage ? try render(text, converter: converter) : text
    }

    func renderFixedTextForDisplay(_ text: String, converter: ChineseScriptConverter = .shared) -> String {
        (try? renderFixedText(text, converter: converter)) ?? text
    }

    enum SavedRenderer {
        case output(OutputLanguage)
        // These layouts preserve synthetic verifier fixtures. No released
        // exporter produced them; they are never used for new exports.
        case fixtureTraditionalChinese(usesLegacyFormat: Bool)
        case fixtureEnglishTwoLine

        func targetLine(_ segment: TranscriptSegment) -> String {
            switch self {
            case .output(let language): return SessionExporter.targetLine(segment, outputLanguage: language)
            case .fixtureEnglishTwoLine:
                return SessionExporter.targetLine(segment, outputLanguage: .english)
            case .fixtureTraditionalChinese(let usesLegacyFormat):
                return usesLegacyFormat ? SessionExporter.humanReadableChinese(segment.chinese)
                    : SessionExporter.targetLine(segment, target: .simplifiedChinese)
            }
        }
        func srtCue(_ segment: TranscriptSegment, index: Int) -> String {
            switch self {
            case .output(let language): return SessionExporter.srtCue(segment, index: index, outputLanguage: language)
            case .fixtureEnglishTwoLine:
                return "\(index + 1)\n\(SessionExporter.srtTimestamp(segment.startTime)) --> \(SessionExporter.srtTimestamp(segment.endTime))\n"
                    + [segment.english, targetLine(segment)].joined(separator: "\n")
            case .fixtureTraditionalChinese(let usesLegacyFormat):
                if !usesLegacyFormat {
                    return SessionExporter.srtCue(segment, index: index, target: .simplifiedChinese)
                }
                return "\(index + 1)\n\(SessionExporter.srtTimestamp(segment.startTime)) --> \(SessionExporter.srtTimestamp(segment.endTime))\n"
                    + [segment.english, targetLine(segment)].joined(separator: "\n")
            }
        }
    }

    static func savedRenderer(for locale: String, sourceLanguages: [String]? = nil) -> SavedRenderer? {
        if locale == "zh-Hant" { return .fixtureTraditionalChinese(usesLegacyFormat: sourceLanguages == nil) }
        guard let language = Self(rawValue: locale), language.rendererIsAvailable else { return nil }
        return .output(language)
    }

}

/// One policy switch and one table for fixed classroom output text. The user
/// has not selected target-language labels yet; interface Chinese is the default.
enum ClassroomFixedText: String, CaseIterable {
    case pendingTranslation, failedAgainstSource, failedAgainstEnglish, formulaNeedsReview, transcriptHeading, exportTranscriptToggle
    case notesHeading, replayHeading, sourceCheckHeading, sourceText, earlierSourceText
    case kindCore, kindRelationship, kindExample, kindPitfall, kindBackground
    case kindPending, stateMissing, stateSupplemented, stateConflict, stateUnclear
    case neutralQuestion, priorEvidenceRule, pendingQuestion, missingFollowUp, supplementedDetail
    case invalidSupplementDetail, conflictDetail, unclearDetail, missingDetail, retiredExplanation
    case conflictFallback, unclearFallback, followUpSupplementLine, followUpConflictLine, followUpUnclearLine
    case earlierRecordLine, sourceLine, earlierSourceLine, candidateLine, replayFallback
    case pronounSuffix, sourceUnlinked, sourceNumericDifference, sourceLegacyPending, sourceCheckLine
    case numericGapSuffix, logisticsHeading, reviewWholeScope, reviewBatchScope, reviewPartialScope
    case reviewDisclaimer, reviewInputRevision, reviewNotebookRevision, reviewSuperseded, reviewPartialExplanation
    case reviewInterrupted, reviewGenericInterruption, reviewProgress, reviewScopedProgress, reviewOriginalPoint
    case reviewSuggestion, reviewReason, reviewAddition, reviewEvidence, reviewBatchHeading
    case reviewNoSuggestions, interruptionUser, interruptionSleep, interruptionResources, interruptionRecording
    case interruptionManagement, interruptionOther, interruptionBecause, statsCompleted, statsInterruptions
    case statsFailures, statsRetries, statsAverage, statsHeading, unknownReviewPrompt

    case exportReviewHeading, exportDisclaimer, emptyNotes, exportScopeLine, exportCoverageLine, exportReviewScope, exportSessionLine, exportTimeLine, exportExplanationLine, exportProgressLine, latestScope, wholeScope
    case numericIndexElsewhere, numericIndexMissing, numericIndexGap, numericFieldConflict
    case numericLiteralElsewhere, numericFieldElsewhere, numericLiteralMissing, numericFieldScope, numericLiteralGap
    case numericCountElsewhere, numericCountMissing, numericCountGap, numericElsewhere, numericMissing
    case numericValueMissing, numericAmbiguous, numericUnitConflict, noUnit
    case noCompletedBatch, latestCompletedRange, captionCoverage, liveClass

    static let usesTargetLanguage = false
    private static let labels: [Self: [String: String]] = [
        .pendingTranslation: ["zh": "（本段暂无译文）", "en": "(Translation pending)"],
        .failedAgainstSource: ["zh": "（本段翻译未完成，可对照原文）", "en": "(Translation incomplete; see source)"],
        .failedAgainstEnglish: ["zh": "（本段翻译未完成，可对照英文）", "en": "(Translation incomplete; see English source)"],
        .formulaNeedsReview: ["zh": "【公式待核对】", "en": "[Formula needs review]"],
        .transcriptHeading: ["zh": "字幕（含时间戳）", "en": "Captions (with timestamps)"],
        .exportTranscriptToggle: ["zh": "附带字幕与时间戳（按所选范围）", "en": "Include captions and timestamps for this scope"],
        .exportReviewHeading: ["zh": "9B 复查意见（仅供核对，未合并进笔记正文）", "en": "9B review suggestions (for checking; separate from the notes)"],
        .exportDisclaimer: ["zh": "本文件由本机模型生成，未经人工逐句核对；正文按主题整理，“需要回听”和“来源检查”两节列出的内容仍需自行核对。", "en": "This file was generated locally and has not been checked sentence by sentence. Notes are grouped by topic; items under Listen again and Source checks still need checking."],
        .emptyNotes: ["zh": "（所选范围暂无笔记）", "en": "(No notes in the selected scope)"],
        .exportScopeLine: ["zh": "内容范围：{0}（{1}）", "en": "Scope: {0} ({1})"],
        .exportCoverageLine: ["zh": "整理进度：{0}", "en": "Note progress: {0}"],
        .exportReviewScope: ["zh": "复查范围：本录音所有已完成的复查批次（不受“最近更新”笔记范围限制）", "en": "Review scope: all completed review batches in this recording, including those outside the latest notes"],
        .exportSessionLine: ["zh": "来源录音：{0}", "en": "Source recording: {0}"],
        .exportTimeLine: ["zh": "导出时间：{0}", "en": "Exported at: {0}"],
        .exportExplanationLine: ["zh": "说明：{0}", "en": "Notice: {0}"],
        .exportProgressLine: ["zh": "复查进度：{0}", "en": "Review progress: {0}"],
        .latestScope: ["zh": "最近更新", "en": "Latest update"],
        .wholeScope: ["zh": "整课笔记", "en": "Whole lesson notes"],
        .numericIndexElsewhere: ["zh": "本批其他原文出现过相同写法，请核对是否漏引了来源。", "en": "The same notation appears elsewhere in this batch; check whether its source should also be cited."],
        .numericIndexMissing: ["zh": "请核对对象名、完整下标和来源；原文里单独出现相同数字不能证明这处引用。", "en": "Check the object name, complete subscript and source; a separate matching number does not support this reference."],
        .numericIndexGap: ["zh": "正文里的代码引用“{0}”未在所引原句及同一字幕中找到；{1}", "en": "The code reference '{0}' was not found in the cited text or its caption; {1}"],
        .numericFieldConflict: ["zh": "正文里的完整数字片段“{0}”对应字段 {1}；所引原句及同一字幕对该字段有不同写法，请核对时间、条件或中英文差异，不能任选一种当作已确认。", "en": "The complete numeric literal '{0}' belongs to field {1}, which has conflicting forms in the cited text or caption. Check the time, conditions or language differences; do not choose one as confirmed."],
        .numericLiteralElsewhere: ["zh": "本批其他原文出现过相同的完整写法，请核对是否漏引了来源。", "en": "The same complete literal appears elsewhere in this batch; check whether its source should also be cited."],
        .numericFieldElsewhere: ["zh": "本批原文有相同的完整写法，请核对它对应的字段、对象与引用来源。", "en": "The batch contains the same complete literal; check its field, object and cited source."],
        .numericLiteralMissing: ["zh": "请核对完整数字、前面的正负号及分隔符，不能用原文里分散出现的数字证明拼接后的号码。", "en": "Check the full number, leading sign and separators; scattered digits cannot support a concatenated number."],
        .numericFieldScope: ["zh": "与字段 {0} 对应的写法", "en": " in the form associated with field {0}"],
        .numericLiteralGap: ["zh": "正文里的完整数字片段“{0}”未在所引原句及同一字幕中找到{1}；{2}", "en": "The complete numeric literal '{0}' was not found in the cited text or its caption{1}; {2}"],
        .numericCountElsewhere: ["zh": "本次原文的其他句子出现过相同数量，请确认是否该把那一句也列为来源。", "en": "The same count appears in another sentence in this input; check whether that sentence should also be cited."],
        .numericCountMissing: ["zh": "同样的数字不一定表示同样的数量，请核对它是数量、目标值还是编号。", "en": "The same numeral may refer to a different quantity; check whether it is a count, target value or identifier."],
        .numericCountGap: ["zh": "正文里的计数“{0}”未在所引原句及同一字幕中找到计数支持；{1}", "en": "The count '{0}' has no count support in the cited text or its caption; {1}"],
        .numericElsewhere: ["zh": "正文里的“{0}”不在所引原句里；本次原文的其他句子出现过同样的数值，请确认是否该把那一句也列为来源。", "en": "'{0}' is absent from the cited sentence, but the same value appears elsewhere in this input. Check whether that sentence should also be cited."],
        .numericMissing: ["zh": "正文里的“{0}”在本次原文里找不到；请人工确认它对应的对象、条件和来源。", "en": "'{0}' was not found in this input; manually check its object, conditions and source."],
        .numericValueMissing: ["zh": "正文里的“{0}”在本次原文里找不到同值；请人工确认它对应的对象、条件和来源。", "en": "No matching value for '{0}' was found in this input; manually check its object, conditions and source."],
        .numericAmbiguous: ["zh": "正文里的“{0}”没有单位或属性说明，也没有出现在本次原文中；请人工确认它是编号还是测量值，并补上单位或来源。", "en": "'{0}' has no stated unit or property and was not found in this input. Check whether it is an identifier or measurement, and add the unit or source."],
        .numericUnitConflict: ["zh": "正文里的“{0}”与原文中同一数字的单位不同（原文为 {1}）；请人工确认是换算、推导还是引用错位。", "en": "'{0}' has a different unit from the matching source number ({1}); manually check whether this is conversion, derivation or a misplaced citation."],
        .noUnit: ["zh": "无单位", "en": "no unit"],
        .noCompletedBatch: ["zh": "尚无已完成批次", "en": "No completed batches yet"],
        .latestCompletedRange: ["zh": "最近完成：{0}–{1}", "en": "Latest completed: {0}–{1}"],
        .captionCoverage: ["zh": "已整理 {0} / {1} 段已翻译内容", "en": "Prepared notes for {0} / {1} usable caption segments"],
        .liveClass: ["zh": "实时课堂", "en": "Live class"],
        .notesHeading: ["zh": "学习笔记", "en": "Study notes"],
        .replayHeading: ["zh": "需要回听", "en": "Listen again"],
        .sourceCheckHeading: ["zh": "来源检查", "en": "Source checks"],
        .sourceText: ["zh": "原文", "en": "Source"],
        .earlierSourceText: ["zh": "先前原文", "en": "Earlier source"],
        .kindCore: ["zh": "核心结论", "en": "Key finding", "es": "Conclusión clave", "fr": "Conclusion clé"],
        .kindRelationship: ["zh": "概念关系", "en": "Concept relationship", "es": "Relación conceptual", "fr": "Relation conceptuelle"],
        .kindExample: ["zh": "例子", "en": "Example", "es": "Ejemplo", "fr": "Exemple"],
        .kindPitfall: ["zh": "易错点", "en": "Common pitfall", "es": "Error frecuente", "fr": "Piège courant"],
        .kindBackground: ["zh": "补充理解", "en": "Background", "es": "Contexto", "fr": "Éclairage complémentaire"],
        .kindPending: ["zh": "待确认", "en": "Needs clarification", "es": "Por aclarar", "fr": "À clarifier"],
        .stateMissing: ["zh": "缺信息", "en": "Missing information", "es": "Falta información", "fr": "Informations manquantes"],
        .stateSupplemented: ["zh": "后文补充", "en": "Later clarification", "es": "Aclaración posterior", "fr": "Précision ultérieure"],
        .stateConflict: ["zh": "前后冲突", "en": "Conflicting accounts", "es": "Versiones contradictorias", "fr": "Versions contradictoires"],
        .stateUnclear: ["zh": "关系不明", "en": "Relationship unclear", "es": "Relación incierta", "fr": "Relation incertaine"],
        .neutralQuestion: ["zh": "当前原文是否明确补充了所引原文中的同一对象、属性、条件或指代关系？没有新依据就不重复旧问题。", "en": "Does the current source explicitly clarify the same object, property, condition or reference as the cited source? Do not repeat an old question without new evidence.", "es": "¿La fuente actual aclara explícitamente el mismo objeto, propiedad, condición o referencia de la fuente citada? No repitas una pregunta anterior sin nuevas pruebas.", "fr": "La source actuelle précise-t-elle explicitement le même objet, la même propriété, condition ou référence que la source citée ? Ne répète pas une ancienne question sans nouveaux éléments."],
        .priorEvidenceRule: ["zh": "quoteIDs 和 candidateQuoteIDs 引用 priorEvidence 的旧原文或 evidence 的当前原文。h 编号只作历史上下文，不能用于当前正文 sourceIDs；旧引文不作为本批新知识重复整理。", "en": "quoteIDs and candidateQuoteIDs refer to priorEvidence or current evidence. Historical h IDs are context only: never use them in current point sourceIDs or repeat old quotations as new knowledge.", "es": "quoteIDs y candidateQuoteIDs remiten a priorEvidence o evidence actual. Los identificadores h son solo contexto histórico: nunca los uses en sourceIDs de puntos actuales ni repitas citas anteriores como conocimiento nuevo.", "fr": "quoteIDs et candidateQuoteIDs renvoient à priorEvidence ou aux evidence actuelles. Les identifiants h servent uniquement de contexte historique : ne les utilise jamais dans les sourceIDs des points actuels et ne répète pas les anciennes citations comme connaissances nouvelles."],
        .pendingQuestion: ["zh": "原文中有哪项关系需要澄清？请仅依据原文判断。", "en": "Which relationship in the source needs clarification? Use only the source."],
        .missingFollowUp: ["zh": "本次响应没有给出这条跟进判断，旧问题仍然保留。", "en": "This response supplied no follow-up decision for this question; the original question remains open."],
        .supplementedDetail: ["zh": "后文明确补充了同一对象、同一属性的信息。", "en": "Later source text explicitly adds information about the same object and property."],
        .invalidSupplementDetail: ["zh": "本次响应标注为后文补充，但同一次来源没有指向本批中已有原文依据的要点，旧问题保留。", "en": "The claimed clarification is not bound to an evidence-backed point from this same response; the original question remains open."],
        .conflictDetail: ["zh": "后文与此前记录存在冲突，需要人工核对具体冲突点。", "en": "Later source text conflicts with the earlier record; check the specific conflict manually."],
        .unclearDetail: ["zh": "后文与此前记录的关系仍不明确，需要人工核对。", "en": "The relationship to the earlier record remains unclear and needs manual checking."],
        .missingDetail: ["zh": "本次响应没有给出这条线索的补充，旧问题保留。", "en": "This response supplied no additional evidence for this lead; the original question remains open."],
        .retiredExplanation: ["zh": "原问题由此撤下；后文补充只表示有新增原文依据，不代表知识已核实。", "en": "The original question is retired because new source evidence was supplied; this does not establish factual correctness."],
        .conflictFallback: ["zh": "具体冲突点需要人工核对。", "en": "Check the specific conflict manually."],
        .unclearFallback: ["zh": "无法确定是否同一对象、属性或条件。", "en": "It is unclear whether the object, property or condition is the same."],
        .followUpSupplementLine: ["zh": "**后文补充{0}：**{1}", "en": "**Later clarification{0}:** {1}"],
        .followUpConflictLine: ["zh": "后文{0}与此前记录冲突：{1}", "en": "Later source{0} conflicts with the earlier record: {1}"],
        .followUpUnclearLine: ["zh": "后文{0}关系仍不明：{1}", "en": "The relationship of later source{0} remains unclear: {1}"],
        .earlierRecordLine: ["zh": "对应先前记录（仍待核对）：{0}", "en": "Related earlier record (still needs checking): {0}"],
        .sourceLine: ["zh": "原文：{0}", "en": "Source: {0}"],
        .earlierSourceLine: ["zh": "先前原文：{0}", "en": "Earlier source: {0}"],
        .candidateLine: ["zh": "**后文补充候选，原问题仍待核对：**", "en": "**Candidate clarification; the original question still needs checking:**"],
        .replayFallback: ["zh": "原文没有交代这项要点的对象或条件，需要回听确认。", "en": "The source does not identify the object or condition for this point; listen again to clarify."],
        .pronounSuffix: ["zh": "（引用原文含指代）", "en": " (The cited source contains a pronoun.)"],
        .sourceUnlinked: ["zh": "来源未链接到原文，无法核对出处", "en": "The source link is missing, so provenance cannot be checked"],
        .sourceNumericDifference: ["zh": "笔记数值与引用原文不同，可能是换算或推导，需要人工核对", "en": "Numbers differ from the cited source; this may reflect conversion or derivation and needs manual checking"],
        .sourceLegacyPending: ["zh": "旧版记录的关系尚未核对", "en": "The relationship in this legacy record has not been checked"],
        .sourceCheckLine: ["zh": "{0}：{1}", "en": "{0}: {1}"],
        .numericGapSuffix: ["zh": "　（{0}）", "en": " ({0})"],
        .logisticsHeading: ["zh": "课程安排与待办", "en": "Course arrangements and tasks"],
        .reviewWholeScope: ["zh": "整课", "en": "Whole lesson"],
        .reviewBatchScope: ["zh": "第 {0} 批（局部）", "en": "Batch {0} (partial)"],
        .reviewPartialScope: ["zh": "局部批次", "en": "Partial batch"],
        .reviewDisclaimer: ["zh": "以下是模型复查意见，仅供核对，可能有误；没有修改笔记正文。", "en": "These model review suggestions may be wrong and are for checking only. The original notes have not been modified."],
        .reviewInputRevision: ["zh": "本报告对应课程输入版本 {0}。", "en": "This report uses course input revision {0}."],
        .reviewNotebookRevision: ["zh": "冻结笔记版本 {0}，后续新增内容不在本次范围内。", "en": "Notebook revision {0} was frozen; later additions are outside this review."],
        .reviewSuperseded: ["zh": "后续课程版本已替代本任务；以下保留已完成的历史意见，未完成部分已停止续写。", "en": "A newer course revision superseded this task. Completed historical suggestions remain; unfinished work will not resume."],
        .reviewPartialExplanation: ["zh": "本次只复查 {0}，不是整课结论；整课复查报告在另一个文件里，不会被这次覆盖。", "en": "This review covers only {0}. It is not a whole-lesson conclusion and does not overwrite the separate whole-lesson report."],
        .reviewInterrupted: ["zh": "本场复查尚未跑完：已完成 {0}/{1} 批，{2}暂停，进度已保存，回来会接着跑。", "en": "Review is incomplete: {0}/{1} batches finished; paused {2}. Progress is saved for resumption."],
        .reviewGenericInterruption: ["zh": "被中断", "en": "after interruption"],
        .reviewProgress: ["zh": "9B 思考复查 {0}/{1} 批（约 5 分钟/批）", "en": "9B reasoning review {0}/{1} batches (about 5 minutes per batch)"],
        .reviewScopedProgress: ["zh": "9B 思考复查 · {0} {1}/{2} 批（约 5 分钟/批）", "en": "9B reasoning review · {0} {1}/{2} batches (about 5 minutes per batch)"],
        .reviewOriginalPoint: ["zh": "**原笔记 · 要点 {0}**：{1}", "en": "**Original note · point {0}:** {1}"],
        .reviewSuggestion: ["zh": "**9B 建议（待核对）**：{0}", "en": "**9B suggestion (needs checking):** {0}"],
        .reviewReason: ["zh": "**建议理由**：{0}", "en": "**Reason:** {0}"],
        .reviewAddition: ["zh": "**遗漏补充建议（待核对） · {0}**：{1}", "en": "**Suggested missing point (needs checking) · {0}:** {1}"],
        .reviewEvidence: ["zh": "**依据 · 片段 {0}**：{1}", "en": "**Evidence · fragment {0}:** {1}"],
        .reviewBatchHeading: ["zh": "第 {0} 批 · {1}", "en": "Batch {0} · {1}"],
        .reviewNoSuggestions: ["zh": "本批没有提出复查建议。", "en": "No review suggestions for this batch."],
        .interruptionUser: ["zh": "手动暂停", "en": "manual pause"],
        .interruptionSleep: ["zh": "系统睡眠", "en": "system sleep"],
        .interruptionResources: ["zh": "内存或字幕优先", "en": "memory pressure or caption priority"],
        .interruptionRecording: ["zh": "录音进行中", "en": "recording in progress"],
        .interruptionManagement: ["zh": "队列操作", "en": "queue operation"],
        .interruptionOther: ["zh": "任务切换", "en": "task switch"],
        .interruptionBecause: ["zh": "因{0}", "en": "because of {0}"],
        .statsCompleted: ["zh": "完成 {0} 批", "en": "{0} batches completed"],
        .statsInterruptions: ["zh": "中断 {0} 次", "en": "{0} interruptions"],
        .statsFailures: ["zh": "失败 {0} 次", "en": "{0} failures"],
        .statsRetries: ["zh": "自动重试 {0} 次", "en": "{0} automatic retries"],
        .statsAverage: ["zh": "平均每批 {0} 秒（{1} 批计时）", "en": "average {0} seconds per batch ({1} timed batches)"],
        .statsHeading: ["zh": "本场统计：", "en": "Session statistics: "],
        .unknownReviewPrompt: ["zh": "旧复查提示词与当前目标不匹配，任务已暂停；原提示词和未完成前缀已保留。", "en": "The saved review prompt is unrecognized for this target. The task is paused; its original prompt and unfinished prefix are preserved."],
    ]

    func text(targetCode: String, useTargetLanguage: Bool = usesTargetLanguage) -> String {
        let locale = useTargetLanguage && !targetCode.hasPrefix("zh") ? targetCode : "zh"
        return Self.labels[self]![locale] ?? Self.labels[self]!["zh"]!
    }


    // All classroom fixed text follows the one existing switch, including notes.
    func noteText(target: CaptionTranslationTarget) -> String {
        text(targetCode: target.rawValue)
    }

    /// Substitute only numbered placeholders in the template, in one pass.
    /// User text/quotes inserted as arguments are never searched or rewritten.
    func format(args: [String], targetCode: String,
                useTargetLanguage: Bool = usesTargetLanguage) -> String {
        let template = text(targetCode: targetCode, useTargetLanguage: useTargetLanguage)
        let regex = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        var result = ""
        var cursor = template.startIndex
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template),
                  let digits = Range(match.range(at: 1), in: template),
                  let index = Int(template[digits]), args.indices.contains(index) else { continue }
            result += template[cursor..<range.lowerBound]
            result += args[index]
            cursor = range.upperBound
        }
        return result + template[cursor...]
    }

    func noteFormat(_ args: [String], target: CaptionTranslationTarget) -> String {
        format(args: args, targetCode: target.rawValue)
    }

    static func kindLabel(_ kind: String, target: CaptionTranslationTarget) -> String {
        let key: Self?
        switch kind {
        case "核心结论": key = .kindCore
        case "概念关系": key = .kindRelationship
        case "例子": key = .kindExample
        case "易错点": key = .kindPitfall
        case "补充理解": key = .kindBackground
        case "待确认": key = .kindPending
        default: key = nil
        }
        // Wire kind codes stay Chinese; English kind display is task-specific.
        return key?.text(targetCode: target.rawValue, useTargetLanguage: target != .simplifiedChinese) ?? kind
    }
}
