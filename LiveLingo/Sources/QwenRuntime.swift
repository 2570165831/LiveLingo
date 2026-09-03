import Foundation
import IOKit.ps

enum ModelMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case energySaver
    case highQuality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .energySaver: return "省电"
        case .highQuality: return "高质量"
        }
    }

    func resolvedProfile(isOnBattery: Bool) -> QwenModelProfile {
        switch self {
        case .automatic:
            return isOnBattery ? .energySaver : .highQuality
        case .energySaver:
            return .energySaver
        case .highQuality:
            return .highQuality
        }
    }
}

struct QwenModelProfile: Equatable, Sendable {
    let asrKey: String
    let fallbackASRKey: String?
    let translationModel: String
    let shortLabel: String

    static let energySaver = QwenModelProfile(
        asrKey: "parakeet",
        fallbackASRKey: "1.7b",
        translationModel: "qwen3.5-4b-mlx",
        shortLabel: "Parakeet → 4B"
    )

    static let highQuality = QwenModelProfile(
        asrKey: "parakeet",
        fallbackASRKey: "1.7b",
        translationModel: "qwen/qwen3.5-9b",
        shortLabel: "Parakeet → 9B"
    )
}

enum PowerSourceMonitor {
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return false }
        return (source as String) == (kIOPSBatteryPowerValue as String)
    }
}

enum QwenRuntimeError: LocalizedError {
    case serviceUnavailable
    case lmStudioUnavailable
    case modelUnavailable(String)
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "本机 Qwen 转写服务未运行。"
        case .lmStudioUnavailable:
            return "无法连接 LM Studio 本机服务（127.0.0.1:1234）。"
        case .modelUnavailable(let name):
            return "LM Studio 未找到模型：\(name)"
        case .invalidResponse:
            return "本机模型返回了无法识别的数据。"
        case .requestFailed(let message):
            return message
        }
    }
}

enum QwenASRClient {
    private static let serviceURL = URL(string: "http://127.0.0.1:18765")!

    static func checkHealth(modelKeys: [String] = []) async throws {
        var request = URLRequest(url: serviceURL.appending(path: "health"))
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw QwenRuntimeError.serviceUnavailable
            }
            if !modelKeys.isEmpty {
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let available = payload["available_models"] as? [String]
                else {
                    throw QwenRuntimeError.invalidResponse
                }
                let missing = modelKeys.filter { !available.contains($0) }
                if !missing.isEmpty {
                    throw QwenRuntimeError.requestFailed(
                        "本机缺少转写模型：\(missing.joined(separator: ", "))。"
                    )
                }
            }
        } catch let error as QwenRuntimeError {
            throw error
        } catch {
            throw QwenRuntimeError.serviceUnavailable
        }
    }

    static func transcribe(
        audioURL: URL,
        modelKey: String,
        enhanceSpeech: Bool = false
    ) async throws -> String {
        var components = URLComponents(url: serviceURL.appending(path: "transcribe"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model", value: modelKey),
            URLQueryItem(name: "enhance", value: enhanceSpeech ? "speech" : "off")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: audioURL)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QwenRuntimeError.serviceUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw QwenRuntimeError.invalidResponse }
        guard http.statusCode == 200 else { throw responseError(from: data) }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = payload["text"] as? String
        else { throw QwenRuntimeError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func responseError(from data: Data) -> Error {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = payload["error"] as? String {
            return QwenRuntimeError.requestFailed(message)
        }
        return QwenRuntimeError.invalidResponse
    }
}

enum ASRFallbackReason: Equatable, Sendable {
    case emptyTranscript
    case invalidText
    case implausiblyShort
    case repeatedLoop
    case runawayText
}

enum ASRQualityGate {
    static func fallbackReason(
        for text: String,
        audioDuration: TimeInterval
    ) -> ASRFallbackReason? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyTranscript }
        if trimmed.contains("\u{FFFD}") { return .invalidText }

        let words = trimmed.lowercased().split { character in
            !character.isLetter && !character.isNumber && character != "'"
        }.map(String.init)
        guard !words.isEmpty else { return .invalidText }

        if audioDuration >= 8, words.count == 1 {
            return .implausiblyShort
        }
        if words.count > max(40, Int(audioDuration * 7)) {
            return .runawayText
        }

        let counts = Dictionary(grouping: words, by: { $0 }).mapValues(\.count)
        if words.count >= 8,
           let dominantCount = counts.values.max(),
           dominantCount >= 6,
           Double(dominantCount) / Double(words.count) >= 0.6 {
            return .repeatedLoop
        }

        let maximumRepeatedWidth = min(4, words.count / 3)
        guard maximumRepeatedWidth > 0 else { return nil }
        for width in 1...maximumRepeatedWidth {
            guard words.count >= width * 3 else { continue }
            for start in 0...(words.count - width * 3) {
                let first = words[start..<(start + width)]
                let second = words[(start + width)..<(start + width * 2)]
                let third = words[(start + width * 2)..<(start + width * 3)]
                if first.elementsEqual(second), first.elementsEqual(third) {
                    return .repeatedLoop
                }
            }
        }
        return nil
    }
}

enum EnglishTranscriptGate {
    static func accepts(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        var latinCount = 0
        var cjkCount = 0
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A,
                 0x0061...0x007A,
                 0x00C0...0x024F,
                 0x1E00...0x1EFF:
                latinCount += 1
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF:
                cjkCount += 1
            default:
                continue
            }
        }

        guard cjkCount > 0 else { return latinCount > 0 }
        return latinCount >= max(6, cjkCount * 3)
    }
}

struct AuxiliaryTranscriptObservation: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct AuxiliaryTranslationHint: Equatable, Sendable {
    enum Kind: String, Sendable {
        case formula
        case acronym
        case unit
    }

    let kind: Kind
    let value: String
}

enum AuxiliaryTranslationHintExtractor {
    private static let acronymAllowlist: Set<String> = [
        "ATP", "BFS", "CPI", "CPU", "DFS", "DNA", "GDP", "NADH", "NMR",
        "RAM", "RNA", "SN1", "SN2", "SQL", "SUVAT"
    ]

    private static let elementSymbols: Set<String> = [
        "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar",
        "K", "Ca", "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As", "Se", "Br", "Kr",
        "Rb", "Sr", "Y", "Zr", "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn", "Sb", "Te", "I", "Xe",
        "Cs", "Ba", "La", "Ce", "Pr", "Nd", "Pm", "Sm", "Eu", "Gd", "Tb", "Dy", "Ho", "Er", "Tm", "Yb", "Lu",
        "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg", "Tl", "Pb", "Bi", "Po", "At", "Rn", "Fr", "Ra",
        "Ac", "Th", "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm", "Md", "No", "Lr", "Rf", "Db",
        "Sg", "Bh", "Hs", "Mt", "Ds", "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og"
    ]

    static func timeAlignedText(
        observations: [AuxiliaryTranscriptObservation],
        start: TimeInterval,
        end: TimeInterval
    ) -> String {
        let selected = observations
            .filter { observation in
                let duration = max(0, observation.end - observation.start)
                let overlap = max(0, min(observation.end, end) - max(observation.start, start))
                let midpoint = observation.start + max(0, observation.end - observation.start) / 2
                return midpoint >= start && midpoint <= end
                    && (duration == 0 || overlap / duration >= 0.85)
            }
            .sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
            }

        var fragments: [String] = []
        for observation in selected {
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = fragments.last,
               comparable(text).contains(comparable(last)) {
                fragments[fragments.count - 1] = text
            } else if !fragments.contains(where: { comparable($0) == comparable(text) }) {
                fragments.append(text)
            }
        }
        return fragments.joined(separator: " ")
    }

    static func extract(from appleText: String, primary: String) -> [AuxiliaryTranslationHint] {
        let evidence = appleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty else { return [] }

        var hints: [AuxiliaryTranslationHint] = []
        let formulaPatterns = [
            #"(?<![A-Za-z])(?:[A-Z]\s+){1,5}[A-Z](?:\s+\d+)?\s+(?:minus|negative|plus|positive)(?![A-Za-z])"#,
            #"(?<![A-Za-z])[A-Z][A-Za-z0-9()]{0,12}(?:\s+\d+)?\s+(?:minus|negative|plus|positive)(?![A-Za-z])"#,
            #"(?<![A-Za-z])[A-Z][A-Za-z0-9()]{0,12}\s*(?:\^\s*\d*)?[+\-−](?![A-Za-z])"#,
            #"(?<![A-Za-z])(?:[A-Z][a-z]?\d*){2,6}(?![A-Za-z])"#,
        ]
        for pattern in formulaPatterns {
            for raw in matches(pattern: pattern, in: evidence, options: [.caseInsensitive]) {
                guard let formula = normalizedFormula(raw),
                      isNovel(formula, comparedWith: primary)
                else { continue }
                appendUnique(.init(kind: .formula, value: formula), to: &hints)
            }
        }

        for token in matches(pattern: #"(?<![A-Za-z0-9])(?:[A-Z][A-Z0-9]{1,7})(?![A-Za-z0-9])"#, in: evidence) {
            let acronym = token.uppercased()
            guard acronymAllowlist.contains(acronym),
                  isNovel(acronym, comparedWith: primary)
            else { continue }
            appendUnique(.init(kind: .acronym, value: acronym), to: &hints)
        }

        let unitPattern = #"(?<![A-Za-z0-9])\d+(?:\.\d+)?\s*(?:km|cm|mm|meters?|metres?|mL|μL|uL|L|kg|mg|g|mol(?:\s*/\s*L)?|m\s*/\s*s(?:\^?2)?|ms|seconds?|Hz|kHz|MHz|Pa|kPa|MPa|bar|atm|°C|K|N|J|W|V|A)(?![A-Za-z])"#
        for raw in matches(pattern: unitPattern, in: evidence, options: [.caseInsensitive]) {
            let unit = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard isNovel(unit, comparedWith: primary) else { continue }
            appendUnique(.init(kind: .unit, value: unit), to: &hints)
        }

        return Array(hints.prefix(8))
    }

    private static func normalizedFormula(_ raw: String) -> String? {
        var normalized = raw
            .replacingOccurrences(of: "negative", with: "-", options: .caseInsensitive)
            .replacingOccurrences(of: "minus", with: "-", options: .caseInsensitive)
            .replacingOccurrences(of: "positive", with: "+", options: .caseInsensitive)
            .replacingOccurrences(of: "plus", with: "+", options: .caseInsensitive)
            .replacingOccurrences(of: "−", with: "-")
        normalized = normalized
            .replacingOccurrences(of: "+", with: " + ")
            .replacingOccurrences(of: "-", with: " - ")
        var tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var charge = ""
        if let sign = tokens.last, sign == "+" || sign == "-" {
            tokens.removeLast()
            var magnitude = ""
            if tokens.count >= 2, let last = tokens.last, last.allSatisfy(\.isNumber) {
                magnitude = last
                tokens.removeLast()
            }
            charge = magnitude.isEmpty ? sign : "^\(magnitude)\(sign)"
        }

        var body = tokens.joined()
        if charge.isEmpty,
           let expression = try? NSRegularExpression(pattern: #"^(.*?)(?:\^(\d*))?([+\-])$"#),
           let match = expression.firstMatch(
               in: body,
               range: NSRange(body.startIndex..<body.endIndex, in: body)
           ),
           let bodyRange = Range(match.range(at: 1), in: body),
           let signRange = Range(match.range(at: 3), in: body) {
            let magnitude = match.range(at: 2).location == NSNotFound
                ? ""
                : String(body[Range(match.range(at: 2), in: body)!])
            charge = magnitude.isEmpty ? String(body[signRange]) : "^\(magnitude)\(body[signRange])"
            body = String(body[bodyRange])
        }

        guard let elementCount = parsedElementCount(in: body) else { return nil }
        let hasDigit = body.contains(where: \.isNumber)
        let hasMixedCase = body.contains(where: \.isLowercase)
        guard hasDigit || !charge.isEmpty || (elementCount >= 2 && hasMixedCase) else { return nil }
        return body + charge
    }

    private static func parsedElementCount(in formula: String) -> Int? {
        let stripped = formula.filter { $0.isLetter }
        guard !stripped.isEmpty else { return nil }
        if stripped.allSatisfy(\.isUppercase) {
            let symbols = stripped.map(String.init)
            return symbols.allSatisfy(elementSymbols.contains) ? symbols.count : nil
        }

        let characters = Array(stripped)
        var index = 0
        var count = 0
        while index < characters.count {
            guard characters[index].isUppercase else { return nil }
            var symbol = String(characters[index])
            if index + 1 < characters.count, characters[index + 1].isLowercase {
                symbol.append(characters[index + 1])
                index += 1
            }
            guard elementSymbols.contains(symbol) else { return nil }
            count += 1
            index += 1
        }
        return count
    }

    private static func matches(
        pattern: String,
        in source: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            Range(match.range, in: source).map { String(source[$0]) }
        }
    }

    private static func appendUnique(
        _ hint: AuxiliaryTranslationHint,
        to hints: inout [AuxiliaryTranslationHint]
    ) {
        guard !hints.contains(where: { $0.kind == hint.kind && comparable($0.value) == comparable(hint.value) }) else {
            return
        }
        hints.append(hint)
    }

    private static func isNovel(_ candidate: String, comparedWith primary: String) -> Bool {
        !comparable(primary).contains(comparable(candidate))
    }

    private static func comparable(_ source: String) -> String {
        source.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }
    }
}

enum QwenTranslationClient {
    private static let chatURL = URL(string: "http://127.0.0.1:1234/api/v1/chat")!
    private static let modelsURL = URL(string: "http://127.0.0.1:1234/api/v1/models")!

    static let systemPrompt = """
    Translate live English academic lecture captions into Simplified Chinese.
    Translate the entire input faithfully. Never refuse, explain, summarize, shorten, or omit any sentence, filler, question, number, or answer choice, even when the content is not chemistry.
    Correct an obvious ASR error only when the intended term is clear from context.
    Preserve formulas, variables, equations, algorithm names, acronyms, orbital labels, reaction names, units, and charge notation exactly.
    The input may include a short list of time-aligned auxiliary token hints from a second recognizer. They are not another transcript. Use a hint only to normalize a matching formula, allowlisted acronym, or number-with-unit already present or clearly phonetically implied by the primary transcript. Never add a clause, replace ordinary wording wholesale, or change a number based only on a hint.
    Chemistry glossary and normalization rules:
    - ionization energy = 电离能
    - lanthanide contraction = 镧系收缩
    - four d / five d = 4d / 5d, never periods
    - F E three plus = Fe³⁺
    - S C N minus = SCN⁻
    - F E S C N two plus = [FeSCN]²⁺
    - S N two = SN2
    - nucleophile = 亲核试剂
    Mathematics glossary: eigenvalue=特征值; eigenvector=特征向量; characteristic equation=特征方程; determinant=行列式; linearly independent=线性无关.
    Physics glossary: special relativity=狭义相对论; time dilation=时间膨胀; proper time=固有时; rest frame=静止参考系; gamma=γ; electromotive force=电动势; Born rule=玻恩规则; absolute square=模平方.
    Biology glossary: oxidative phosphorylation=氧化磷酸化; proton motive force=质子动力势; ATP synthase=ATP合酶; NADH stays NADH; Complex I=复合物 I; terminal electron acceptor=末端电子受体; DNA replication=DNA复制; helicase=解旋酶; DNA polymerase=DNA聚合酶; leading strand=前导链; lagging strand=滞后链; Michaelis-Menten equation=米氏方程.
    Computer science glossary: Dijkstra's algorithm=Dijkstra 算法; Bellman-Ford algorithm=Bellman-Ford 算法; binary search=二分查找; negative-weight cycle=负权环; time complexity=时间复杂度; O(VE) stays O(VE).
    Economics glossary: policy rate=政策利率; aggregate demand=总需求; monetary policy=货币政策; Phillips curve=菲利普斯曲线.
    Additional chemistry rules: Le Chatelier's principle=勒夏特列原理; parts per million=ppm.
    Return only the complete Simplified Chinese translation. Do not use markdown.
    """

    static let summarySystemPrompt = """
    You summarize a live university lecture for a Chinese-speaking student.
    Use only facts present in the supplied bilingual transcript. Never invent a topic, definition, formula, conclusion, or example.
    Correct only obvious speech-recognition errors when the intended academic term is unambiguous.
    Preserve formulas, variables, equations, algorithm names, acronyms, units, and charge notation exactly.
    Write concise Simplified Chinese in this exact Markdown shape:
    ## 本段主题
    One or two sentences describing what the lecturer is doing.
    ## 核心要点
    - Two to seven non-redundant bullets, each beginning with a bold short label. Use fewer bullets when the transcript contains fewer distinct facts.
    ## 待确认
    - Mention unclear recognition or incomplete claims. If nothing is unclear, write “暂无”。
    Do not add study advice, motivational language, or information absent from the transcript.
    """

    static func checkModel(_ modelName: String) async throws {
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 3
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw QwenRuntimeError.lmStudioUnavailable
        }
        guard try modelIsAvailable(modelName, in: data) else {
            throw QwenRuntimeError.modelUnavailable(modelName)
        }
    }

    static func modelIsAvailable(_ modelName: String, in data: Data) throws -> Bool {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = payload["models"] as? [[String: Any]]
        else { throw QwenRuntimeError.invalidResponse }
        return models.contains { $0["key"] as? String == modelName }
    }

    static func translate(
        _ text: String,
        modelName: String,
        hints: [AuxiliaryTranslationHint] = []
    ) async throws -> String {
        try await chat(
            translationInput(text: text, modelName: modelName, hints: hints),
            modelName: modelName,
            systemPrompt: systemPrompt,
            maximumOutputTokens: 160,
            timeout: 30
        )
    }

    static func translationInput(
        text: String,
        modelName: String,
        hints: [AuxiliaryTranslationHint]
    ) -> String {
        guard modelName == QwenModelProfile.highQuality.translationModel,
              !hints.isEmpty
        else { return text }
        let hintLines = hints.prefix(8).map { "- \($0.kind.rawValue): \($0.value)" }
        return """
        Primary ASR transcript:
        \(text)

        Auxiliary token hints (time-aligned; not a transcript):
        \(hintLines.joined(separator: "\n"))
        """
    }

    static func summarize(_ transcript: String, modelName: String) async throws -> String {
        try await chat(
            transcript,
            modelName: modelName,
            systemPrompt: summarySystemPrompt,
            maximumOutputTokens: 640,
            timeout: 45
        )
    }

    private static func chat(
        _ input: String,
        modelName: String,
        systemPrompt: String,
        maximumOutputTokens: Int,
        timeout: TimeInterval
    ) async throws -> String {
        var payload: [String: Any] = [
            "model": modelName,
            "temperature": 0,
            "max_output_tokens": maximumOutputTokens,
            "store": false,
            "system_prompt": systemPrompt,
            "input": input,
        ]
        if modelName == QwenModelProfile.highQuality.translationModel {
            payload["reasoning"] = "off"
        }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw QwenRuntimeError.lmStudioUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw QwenRuntimeError.invalidResponse }
        guard http.statusCode == 200 else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = payload["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw QwenRuntimeError.requestFailed(message)
            }
            throw QwenRuntimeError.invalidResponse
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = payload["output"] as? [[String: Any]],
              let message = output.first(where: { $0["type"] as? String == "message" }),
              let content = message["content"] as? String
        else { throw QwenRuntimeError.invalidResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LectureSummaryInput {
    static func make(
        from segments: [TranscriptSegment],
        maximumCharacters: Int = 12_000
    ) -> String {
        let completed = segments.filter {
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.chinese.hasPrefix("[翻译失败：")
        }
        guard !completed.isEmpty else { return "" }

        var selected: [String] = []
        var characterCount = 0
        for segment in completed.reversed() {
            let entry = """
            [\(clock(segment.startTime))]
            EN: \(segment.english)
            ZH: \(segment.chinese)
            """
            if !selected.isEmpty, characterCount + entry.count > maximumCharacters {
                break
            }
            selected.append(entry)
            characterCount += entry.count
        }
        return selected.reversed().joined(separator: "\n\n")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum AcademicInputNormalizer {
    static func normalize(_ source: String) -> String {
        var normalized = source
            .replacingOccurrences(of: "thiosyanate", with: "thiocyanate", options: .caseInsensitive)
            .replacingOccurrences(of: "FeSCN²⁺", with: "[FeSCN]²⁺")
            .replacingOccurrences(of: "F E three plus", with: "Fe³⁺", options: .caseInsensitive)
            .replacingOccurrences(of: "S C N minus", with: "SCN⁻", options: .caseInsensitive)
            .replacingOccurrences(of: "F E S C N two plus", with: "[FeSCN]²⁺", options: .caseInsensitive)
            .replacingOccurrences(of: "S N two", with: "SN2", options: .caseInsensitive)
            .replacingOccurrences(of: "eigen vectors", with: "eigenvectors", options: .caseInsensitive)
            .replacingOccurrences(of: "Bellman Ford", with: "Bellman-Ford", options: .caseInsensitive)
            .replacingOccurrences(of: "N A D H", with: "NADH", options: .caseInsensitive)
            .replacingOccurrences(of: "A T P", with: "ATP", options: .caseInsensitive)

        if normalized.range(of: "Bellman-Ford", options: .caseInsensitive) != nil,
           normalized.range(of: "time complexity", options: .caseInsensitive) != nil {
            normalized = replacing(
                pattern: #"\bO\s+(?:of\s+)?V\s+times\s+(?:E|Z|zee|zed)\b"#,
                in: normalized,
                with: "O(VE)"
            )
        }

        if normalized.range(of: "SCN", options: .caseInsensitive) != nil
            || normalized.range(of: "FeSCN", options: .caseInsensitive) != nil {
            normalized = normalized
                .replacingOccurrences(of: "thiosionate", with: "thiocyanate", options: .caseInsensitive)
                .replacingOccurrences(of: "thiosilane", with: "thiocyanate", options: .caseInsensitive)
            normalized = replacing(
                pattern: #"\bFe\s*SCN\s*2\s*\+"#,
                in: normalized,
                with: "[FeSCN]²⁺"
            )
            normalized = replacing(
                pattern: #"\bFe\s*3\s*\+"#,
                in: normalized,
                with: "Fe³⁺"
            )
            normalized = replacing(
                pattern: #"\bSCN\s*[−-]"#,
                in: normalized,
                with: "SCN⁻"
            )
            normalized = replacing(
                pattern: #"(?<![A-Za-z])SN\s*(?:2|₂)\b"#,
                in: normalized,
                with: "SN2"
            )
            if normalized.contains("Fe³⁺") {
                normalized = replacing(
                    pattern: #"\b(?:Ferri|Ferric|Ferrous)\s+ions?\b"#,
                    in: normalized,
                    with: "Ferric ions"
                )
            }
        }

        if normalized.range(of: "equilibrium", options: .caseInsensitive) != nil,
           normalized.range(of: "principle", options: .caseInsensitive) != nil,
           normalized.range(of: "stress", options: .caseInsensitive) != nil {
            normalized = replacing(
                pattern: #"\b(?:The\s+)?(?:Schrodinger|Lashari|Lagrange|Le\s+Chatelier)'?s\s+principle\b"#,
                in: normalized,
                with: "Le Chatelier's principle"
            )
        }

        if normalized.range(of: "Faraday", options: .caseInsensitive) != nil,
           normalized.range(of: "magnetic flux", options: .caseInsensitive) != nil {
            normalized = normalized.replacingOccurrences(
                of: "electromagnetic force",
                with: "electromotive force",
                options: .caseInsensitive
            )
        }

        if normalized.range(of: "reaction velocity", options: .caseInsensitive) != nil,
           normalized.range(of: "substrate concentration", options: .caseInsensitive) != nil {
            normalized = replacing(
                pattern: #"\b(?:Michaelis\s+Menten|Machileus\s+meant\s+an)\s+equation\b"#,
                in: normalized,
                with: "Michaelis-Menten equation"
            )
        }

        if normalized.range(of: "oxidative phosphorylation", options: .caseInsensitive) != nil
            || normalized.range(of: "NADH", options: .caseInsensitive) != nil {
            normalized = replacing(
                pattern: #"\bcomplex\s+one\b"#,
                in: normalized,
                with: "Complex I"
            )
        }

        return normalized
    }

    private static func replacing(pattern: String, in source: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: replacement
        )
    }
}
