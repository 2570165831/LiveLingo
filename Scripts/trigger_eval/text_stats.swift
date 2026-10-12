import Foundation
import NaturalLanguage
import Darwin

// CPU-only JSONL service. Transcript content stays in stdin and process memory;
// responses contain only the statistics below, or a fixed error_code.
// Keep these gates aligned with QwenRuntime.swift and the acceptance exception
// in SpeechPipeline.preferredTranscript, used by DurableTranscriptionQueue.
private enum ASRFallbackReason: String {
    case emptyTranscript
    case invalidText
    case implausiblyShort
    case repeatedLoop
    case runawayText
}

private enum ASRQualityGate {
    static func words(in text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split {
            !$0.isLetter && !$0.isNumber && $0 != "'"
        }.map(String.init)
    }

    static func fallbackReason(for text: String, audioDuration: TimeInterval) -> ASRFallbackReason? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyTranscript }
        if trimmed.contains("\u{FFFD}") { return .invalidText }

        let words = words(in: trimmed)
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
                    var repeatedEnd = start + width * 3
                    while repeatedEnd + width <= words.count,
                          first.elementsEqual(words[repeatedEnd..<(repeatedEnd + width)]) {
                        repeatedEnd += width
                    }
                    // Local emphasis is allowed; only a dominant loop is rejected.
                    if words.count >= 8, Double(repeatedEnd - start) / Double(words.count) >= 0.6 {
                        return .repeatedLoop
                    }
                }
            }
        }
        return nil
    }
}

private enum EnglishTranscriptGate {
    enum Verdict {
        case accepted
        case hanDominant
        case noLatin
    }

    static func accepts(_ text: String) -> Bool { verdict(text) == .accepted }

    static func verdict(_ text: String) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .accepted }

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

        guard cjkCount > 0 else {
            return latinCount > 0 || trimmed.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
                ? .accepted : .noLatin
        }
        return latinCount >= max(6, cjkCount * 3) ? .accepted : .hanDominant
    }
}

private enum InputError: Error { case invalidInput }

private struct InputKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct Request: Decodable {
    let text: String
    let duration: Double

    private enum Keys: String, CodingKey { case text, duration }

    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: InputKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(["text", "duration"]) else {
            throw InputError.invalidInput
        }
        let values = try decoder.container(keyedBy: Keys.self)
        text = try values.decode(String.self, forKey: .text)
        duration = try values.decode(Double.self, forKey: .duration)
        // Preserve the source gate's Int conversion without allowing a malformed
        // or unrepresentable duration to trap this long-lived process.
        guard duration.isFinite, duration >= 0,
              (duration * 7).isFinite, duration * 7 < Double(Int.max) else {
            throw InputError.invalidInput
        }
    }
}

private struct Stats: Encodable {
    let wordCount: Int
    // Count trimmed Swift Characters (extended grapheme clusters), not bytes.
    let charCount: Int
    let englishAccepted: Bool
    let qualityReason: ASRFallbackReason?
    let parakeetAccepted: Bool
    let nlLanguage: String?
    let nlProbability: Double?
    let nlEnglishProbability: Double?

    private enum Keys: String, CodingKey {
        case wordCount = "pk_word_count"
        case charCount = "pk_char_count"
        case englishAccepted = "english_gate_accepted"
        case qualityReason = "quality_reason"
        case parakeetAccepted = "parakeet_accepted"
        case nlLanguage = "nl_language"
        case nlProbability = "nl_probability"
        case nlEnglishProbability = "nl_english_probability"
    }

    init(_ request: Request) {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        wordCount = ASRQualityGate.words(in: text).count
        charCount = text.count
        englishAccepted = EnglishTranscriptGate.accepts(text)
        qualityReason = ASRQualityGate.fallbackReason(for: text, audioDuration: request.duration)
        parakeetAccepted = !text.isEmpty && englishAccepted
            && (qualityReason == nil || qualityReason == .implausiblyShort)

        if text.isEmpty {
            nlLanguage = nil
            nlProbability = nil
            nlEnglishProbability = nil
        } else {
            // A fresh recognizer prevents preceding requests influencing this one.
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let language = recognizer.dominantLanguage
            nlLanguage = language?.rawValue
            let best = recognizer.languageHypotheses(withMaximum: 1)
            nlProbability = language.flatMap { best[$0] }
            nlEnglishProbability = recognizer.languageHypotheses(withMaximum: 30)[.english]
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(wordCount, forKey: .wordCount)
        try values.encode(charCount, forKey: .charCount)
        try values.encode(englishAccepted, forKey: .englishAccepted)
        // Explicitly encode optionals so all eight fields, including nulls, exist.
        try values.encode(qualityReason?.rawValue, forKey: .qualityReason)
        try values.encode(parakeetAccepted, forKey: .parakeetAccepted)
        try values.encode(nlLanguage, forKey: .nlLanguage)
        try values.encode(nlProbability, forKey: .nlProbability)
        try values.encode(nlEnglishProbability, forKey: .nlEnglishProbability)
    }
}

private let invalidInput = Data("{\"error_code\":\"invalid_input\"}\n".utf8)
private let internalError = Data("{\"error_code\":\"internal_error\"}\n".utf8)

private func response(for line: Data) -> Data {
    // JSONDecoder alone can repair some bad UTF-8 strings; reject those first.
    guard String(data: line, encoding: .utf8) != nil else { return invalidInput }
    let request: Request
    do { request = try JSONDecoder().decode(Request.self, from: line) }
    catch { return invalidInput }
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(Stats(request))
        data.append(0x0A)
        return data
    } catch {
        // Never render an exception: it could include request content.
        return internalError
    }
}

private func emit(_ line: Data) -> Bool {
    let data = autoreleasepool { response(for: line) }
    do {
        try FileHandle.standardOutput.write(contentsOf: data)
        return true
    } catch { return false }
}

private func run() {
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        // FileHandle.read(upToCount:) can wait to fill its buffer on a pipe.
        // POSIX read returns available bytes so one request gets one immediate reply.
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
        }
        if count < 0 {
            if errno == EINTR { continue }
            return
        }
        if count == 0 {
            if !pending.isEmpty { _ = emit(pending) }
            return
        }
        let chunk = Data(buffer.prefix(count))
        var start = chunk.startIndex
        for index in chunk.indices where chunk[index] == 0x0A {
            pending.append(contentsOf: chunk[start..<index])
            guard emit(pending) else { return }
            pending.removeAll(keepingCapacity: true)
            start = chunk.index(after: index)
        }
        pending.append(contentsOf: chunk[start..<chunk.endIndex])
    }
}

run()
