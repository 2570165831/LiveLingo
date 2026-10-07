import Foundation
import CryptoKit
import Darwin

/// Offline probe: imports the App sources, never initializes a model/worker.
@main
struct TargetAcceptanceCLI {
    struct Request: Decodable {
        let id: String
        let source: String
        let candidate: String
        let sourceLanguage: String
        let targetLocale: String
        let maximumLengthRatio: Double?
    }
    struct Verdict: Encodable {
        let id: String
        let targetLocale: String
        let accepted: Bool
        let rejection: String?
        let reason: String
        let sourceLetters: Int
        let candidateLetters: Int
        let lengthRatio: Double?
        let lengthAccepted: Bool
        let maximumOutputLetters: Double?
        let configuredMaximumLengthRatio: Double?
        let minimumSourceLetters: Int?
        let absoluteLetterAllowance: Int
        let stablePrefix: String
        let sourceNumbers: [String]
        let targetNumbers: [String]
        let detectedLanguage: String?
        let candidateLanguages: [String]

        // Nulls are part of the JSONL protocol, rather than absent keys.
        enum CodingKeys: String, CodingKey, CaseIterable {
            case id, targetLocale, accepted, rejection, reason, sourceLetters, candidateLetters,
                 lengthRatio, lengthAccepted, maximumOutputLetters, configuredMaximumLengthRatio,
                 minimumSourceLetters, absoluteLetterAllowance, stablePrefix, sourceNumbers,
                 targetNumbers, detectedLanguage, candidateLanguages
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(targetLocale, forKey: .targetLocale)
            try c.encode(accepted, forKey: .accepted); try c.encode(rejection, forKey: .rejection)
            try c.encode(reason, forKey: .reason); try c.encode(sourceLetters, forKey: .sourceLetters)
            try c.encode(candidateLetters, forKey: .candidateLetters); try c.encode(lengthRatio, forKey: .lengthRatio)
            try c.encode(lengthAccepted, forKey: .lengthAccepted); try c.encode(maximumOutputLetters, forKey: .maximumOutputLetters)
            try c.encode(configuredMaximumLengthRatio, forKey: .configuredMaximumLengthRatio)
            try c.encode(minimumSourceLetters, forKey: .minimumSourceLetters)
            try c.encode(absoluteLetterAllowance, forKey: .absoluteLetterAllowance)
            try c.encode(stablePrefix, forKey: .stablePrefix); try c.encode(sourceNumbers, forKey: .sourceNumbers)
            try c.encode(targetNumbers, forKey: .targetNumbers); try c.encode(detectedLanguage, forKey: .detectedLanguage)
            try c.encode(candidateLanguages, forKey: .candidateLanguages)
        }
    }
    enum Failure: Error { case usage, unsupportedTarget(String), invalidRatio, unsafeOutput, outputRoot(String), outputExists, promptCapture, unmappedRejection }

    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("target-acceptance-cli: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run(_ arguments: [String]) async throws {
        if arguments == ["judge"] {
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            while let line = readLine() {
                let request = try decoder.decode(Request.self, from: Data(line.utf8))
                let result = try judge(request)
                FileHandle.standardOutput.write(try encoder.encode(result) + Data([10]))
            }
        } else if arguments.count == 3, arguments[0] == "prompts", arguments[1] == "--output-dir" {
            try await exportPrompts(arguments[2])
        } else if arguments.count == 5, arguments[0] == "prompts", arguments[1] == "--output-dir",
                  arguments[3] == "--target", arguments[4] == "en" {
            try await exportPrompts(arguments[2], target: .english)
        } else { throw Failure.usage
        }
    }
    static func judge(_ row: Request) throws -> Verdict {
        if let ratio = row.maximumLengthRatio, !ratio.isFinite || ratio <= 0 { throw Failure.invalidRatio }
        if row.targetLocale == "zh-Hans" {
            let source = row.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = row.candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let failure: TranslationAcceptance.Rejection?
            let caption: String
            do {
                // The App owns branch selection, JSON restoration and length
                // acceptance. In particular, non-English never uses the English guard.
                caption = try TranslationAcceptance.validatedCaption(candidate, source: source,
                                                                      sourceLanguage: row.sourceLanguage)
                failure = nil
            } catch QwenRuntimeError.translationRejected {
                if let rejection = TranslationAcceptance.rejection(candidate: candidate, source: source,
                                                                    sourceLanguage: row.sourceLanguage) {
                    failure = rejection
                    caption = candidate
                } else {
                    // validatedCaption exposes errors as messages. Map its one
                    // additional rejection only after checking the actual guard;
                    // an unknown future failure must never become an acceptance.
                    let restored = try TranslationAcceptance.validated(candidate, source: source,
                                                                       sourceLanguage: row.sourceLanguage)
                    guard row.sourceLanguage == "en",
                          !TranslationLengthGuard.isPlausible(chinese: restored, english: source) else {
                        throw Failure.unmappedRejection
                    }
                    failure = .disproportionateLength
                    caption = restored
                }
            }
            // The English guard counts the restored caption; nonEnglishRejection
            // counts the original candidate before restoring embedded JSON.
            let length = ChineseLengthDiagnostics(source: source,
                candidate: row.sourceLanguage == "en" ? caption : candidate, sourceLanguage: row.sourceLanguage)
            return .init(id: row.id, targetLocale: row.targetLocale, accepted: failure == nil,
                         rejection: failure.map { String(describing: $0) }, reason: failure?.reason ?? "接受",
                         sourceLetters: length.sourceCount, candidateLetters: length.candidateCount,
                         lengthRatio: length.sourceCount > 0 ? Double(length.candidateCount) / Double(length.sourceCount) : nil,
                         lengthAccepted: length.plausible,
                         maximumOutputLetters: length.maximum,
                         configuredMaximumLengthRatio: length.ratio,
                         minimumSourceLetters: length.floor, absoluteLetterAllowance: 0,
                         stablePrefix: QwenTranslationClient.stableTranslationPrefix(row.candidate),
                         sourceNumbers: [], targetNumbers: [], detectedLanguage: nil, candidateLanguages: [])
        }
        guard let target = LatinTargetAcceptance.Target(rawValue: row.targetLocale) else {
            throw Failure.unsupportedTarget(row.targetLocale)
        }
        let sourceCount = LatinTargetLengthGuard.letterCount(row.source)
        let candidateCount = LatinTargetLengthGuard.letterCount(row.candidate)
        let failure = LatinTargetAcceptance.rejection(candidate: row.candidate, source: row.source, target: target,
                                                     sourceLanguage: row.sourceLanguage, maximumLengthRatio: row.maximumLengthRatio)
        let language = LatinTargetAcceptance.identifyLanguage(row.candidate, target: target, sourceLanguage: row.sourceLanguage)
        let plausible = LatinTargetLengthGuard.isPlausible(candidate: row.candidate, source: row.source,
                                                          target: target, sourceLanguage: row.sourceLanguage,
                                                          maximumRatio: row.maximumLengthRatio)
        return .init(id: row.id, targetLocale: row.targetLocale, accepted: failure == nil,
                     rejection: failure?.rawValue, reason: failure?.reason ?? "接受", sourceLetters: sourceCount,
                     candidateLetters: candidateCount, lengthRatio: sourceCount > 0 ? Double(candidateCount) / Double(sourceCount) : nil,
                     lengthAccepted: plausible,
                     maximumOutputLetters: LatinTargetLengthGuard.maximumOutputLetters(source: row.source, target: target,
                         sourceLanguage: row.sourceLanguage, maximumRatio: row.maximumLengthRatio),
                     configuredMaximumLengthRatio: row.maximumLengthRatio ?? LatinTargetLengthGuard.maximumRatio(target: target, sourceLanguage: row.sourceLanguage),
                     minimumSourceLetters: LatinTargetLengthGuard.minimumSourceLetters,
                     absoluteLetterAllowance: LatinTargetLengthGuard.absoluteLetterAllowance,
                     stablePrefix: LatinStableTranslationPrefix.prefix(row.candidate),
                     sourceNumbers: LatinNumericParser.numbers(in: row.source, language: row.sourceLanguage),
                     targetNumbers: LatinNumericParser.numbers(in: row.candidate, language: target.rawValue),
                     detectedLanguage: language.detectedLanguage, candidateLanguages: language.candidateLanguages)
    }

    /// Preserve the JSONL keys, but report each guard's actual units: English
    /// source Characters / candidate Han scalars, otherwise alphanumeric scalars.
    struct ChineseLengthDiagnostics {
        let sourceCount: Int
        let candidateCount: Int
        let maximum: Double?
        let ratio: Double?
        let floor: Int?
        let plausible: Bool

        init(source: String, candidate: String, sourceLanguage: String) {
            // The App helper is fileprivate. Keep this small annotation removal
            // identical to bodyWithoutApplicationNotice, including repeated notices.
            var body = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            while body.hasPrefix(TranslationAcceptance.formulaNotice) {
                body = String(body.dropFirst(TranslationAcceptance.formulaNotice.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if sourceLanguage == "en" {
                sourceCount = source.trimmingCharacters(in: .whitespacesAndNewlines).count
                candidateCount = body.unicodeScalars.filter(TranslationAcceptance.isHan).count
                ratio = TranslationLengthGuard.maximumRatio
                floor = TranslationLengthGuard.minimumEnglishCount
                maximum = Double(max(sourceCount, TranslationLengthGuard.minimumEnglishCount))
                    * TranslationLengthGuard.maximumRatio
                plausible = TranslationLengthGuard.isPlausible(chinese: candidate, english: source)
            } else {
                sourceCount = source.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                candidateCount = body.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                if let language = SpokenLanguage.find(sourceLanguage) {
                    let limit = CaptionTranslationTarget.simplifiedChinese.maximumOutputCharacters(source: source, language: language)
                    maximum = limit
                    // Only legacy reporting metadata mirrors these constants;
                    // neither acceptance nor the actual maximum uses this table.
                    switch language.writingSystem {
                    case .han, .japanese, .thai: ratio = 2; floor = 12
                    case .hangul: ratio = 2.5; floor = 12
                    case .arabic, .devanagari: ratio = 2; floor = 24
                    case .cyrillic, .greek: ratio = 1.5; floor = 24
                    case .latin: ratio = 1.3; floor = 24
                    }
                    plausible = Double(candidateCount) <= limit
                } else {
                    // The App rejects unsupported languages before applying a
                    // length guard. Null metadata avoids inventing a limit.
                    maximum = nil; ratio = nil; floor = nil; plausible = true
                }
            }
        }
    }

    actor CapturedPrompt {
        private var value: String?
        func capture(_ prompt: String) { value = prompt }
        func read() throws -> String { guard let value else { throw Failure.promptCapture }; return value }
    }
    static func captionPrompt(model: String, attempt: CaptionTranslationAttempt = .standard,
                              previous: Bool = false, typed: Bool = false,
                              target: CaptionTranslationTarget = .simplifiedChinese) async throws -> String {
        let capture = CapturedPrompt()
        let source = target == .english ? "温度升高。" : "The temperature increases."
        let translated = target == .english ? "The temperature increases." : "温度升高。"
        if typed {
            _ = try await QwenTranslationClient.translateTypedText(source, modelName: model, target: target,
                request: { _, prompt, _ in await capture.capture(prompt); return translated })
        } else if previous {
            _ = try await QwenTranslationClient.repairPreviousCaption(previous: source,
                previousChinese: translated, current: "The pressure decreases.", context: "", modelName: model, target: target,
                request: { _, prompt, _ in await capture.capture(prompt); return translated })
        } else {
            _ = try await QwenTranslationClient.translate(source, modelName: model, sourceLanguage: target == .english ? "zh" : nil, target: target,
                attempt: attempt, request: { _, prompt, _ in await capture.capture(prompt); return translated })
        }
        return try await capture.read()
    }

    static func checkedOutput(_ path: String) throws -> URL {
        let variable = "LIVELINGO_TARGET_EVAL_OUTPUT_ROOT"
        guard let configured = ProcessInfo.processInfo.environment[variable], !configured.isEmpty else {
            throw Failure.outputRoot("\(variable) is required")
        }
        let root = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard configured.hasPrefix("/"), !configured.split(separator: "/").contains(".."),
              root.resolvingSymlinksInPath() == root,
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.outputRoot("\(variable) must be an existing absolute directory without symlinks or '..'")
        }
        let destination = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard path.hasPrefix("/"), root.resolvingSymlinksInPath() == root,
              destination.path.hasPrefix(root.path + "/"), destination.resolvingSymlinksInPath() == destination else {
            throw Failure.unsafeOutput
        }
        var cursor = destination
        while true {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil { throw Failure.unsafeOutput }
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
                throw Failure.unsafeOutput
            }
            if cursor.path == "/" { break }
            cursor.deleteLastPathComponent()
        }
        return destination
    }
    static func exportPrompts(_ path: String, target: CaptionTranslationTarget = .simplifiedChinese) async throws {
        let directory = try checkedOutput(path)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.outputExists }
        // Request substitutes capture private/constructed prompts from the App;
        // copying their source strings here would silently drift from production.
        let models = [("9b", QwenModelProfile.highQuality.translationModel), ("4b", QwenModelProfile.energySaver.translationModel)]
        var prompts: [String: String] = [
            "caption-base": QwenTranslationClient.systemPrompt,
            "summary-legacy": QwenTranslationClient.summarySystemPrompt,
            "note-generate": LearningPrompts.generate,
            "note-review": LearningPrompts.review,
            "quoted-value-repair": TranslationAcceptance.QuotedTranslationRepairPlan.prompt,
            "json-status-repair": TranslationAcceptance.JSONStatusRepairPlan.prompt
        ]
        if target == .english {
            prompts = ["caption-base": QwenTranslationClient.englishSystemPrompt,
                "caption-base-4b": QwenTranslationClient.englishSourceFaithfulCaptionPrompt,
                "wrapper-4b": QwenTranslationClient.englishWrapper4B,
                "wrapper-9b": QwenTranslationClient.englishWrapper9B,
                "recovery": QwenTranslationClient.englishRecoverySuffix]
        }
        for (key, model) in models {
            prompts["caption-\(key)"] = try await captionPrompt(model: model, target: target)
            prompts["caption-content-repair-\(key)"] = try await captionPrompt(model: model, attempt: .repairContent, target: target)
            prompts["caption-adjacent-repair-\(key)"] = try await captionPrompt(model: model, previous: true, target: target)
            prompts["typed-\(key)"] = try await captionPrompt(model: model, typed: true, target: target)
        }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try checkedOutput(path)
        guard Darwin.mkdir(directory.path, 0o700) == 0 else { throw Failure.outputExists }
        var entries: [[String: Any]] = []
        for name in prompts.keys.sorted() {
            let data = Data(prompts[name]!.utf8), fileName = "\(target.rawValue)-\(name).utf8"
            let file = try checkedOutput(directory.appendingPathComponent(fileName).path)
            try data.write(to: file, options: .withoutOverwriting)
            // Bind metadata to re-read bytes, not just intended content.
            let reread = try Data(contentsOf: file)
            guard reread == data else { throw Failure.promptCapture }
            entries.append(["targetLocale": target.rawValue, "name": name, "file": fileName,
                            "byteCount": reread.count, "sha256": SHA256.hash(data: reread).map { String(format: "%02x", $0) }.joined()])
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "encoding": "UTF-8", "addedTrailingNewline": false,
            "targetsWithPrompts": [target.rawValue], "targetsWithoutPrompts": target == .english ? ["es", "fr"] : ["en", "es", "fr"],
            "capture": "App constants and injected request substitutes; no model or network", "prompts": entries]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: try checkedOutput(directory.appendingPathComponent("manifest.json").path), options: .withoutOverwriting)
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
