import Foundation

/// Offline OpenCC data, with scalar-based longest-prefix matching. Conversion
/// preserves the original segmentation across every upstream conversion stage.
final class ChineseScriptConverter: @unchecked Sendable {
    enum Region: Sendable { case taiwan, hongKong }
    enum Mode: String, CaseIterable, Sendable { case s2tw, s2hk, s2twp }
    enum Failure: LocalizedError {
        case resourcesMissing
        case invalidDictionary(String)
        var errorDescription: String? {
            switch self {
            case .resourcesMissing: return "繁体转换字典缺失；当前显示简体底稿。"
            case .invalidDictionary(let name): return "繁体转换字典无法读取：\(name)；当前显示简体底稿。"
            }
        }
    }

    static let version = "opencc-ver.1.1.9+livelingo-v1"
    static let shared = ChineseScriptConverter()
    private let directory: URL?
    private let lock = NSLock()
    private var loaded: Result<Tables, Error>?
    #if DEBUG
    private var loads = 0
    var debugLoadCount: Int { lock.withLock { loads } }
    #endif

    init(resourceDirectory: URL? = ChineseScriptConverter.resourceDirectory()) {
        directory = resourceDirectory
    }

    static func resourceDirectory(bundle: Bundle = .main,
                                  executable: URL? = Bundle.main.executableURL) -> URL? {
        let bundled = bundle.resourceURL?.appendingPathComponent("ZhVariants", isDirectory: true)
        let adjacent = executable?.deletingLastPathComponent().appendingPathComponent("ZhVariants", isDirectory: true)
        return [bundled, adjacent].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SOURCE.json").path)
        }
    }

    func prepare() throws { try lock.withLock { _ = try tables() } }

    func convert(_ text: String, mode: Mode) throws -> String {
        try lock.withLock { try tables().convert(text, mode: mode) }
    }

    func convert(_ text: String, to region: Region) throws -> String {
        try lock.withLock {
            let data = try tables()
            let base = data.convert(text, mode: region == .taiwan ? .s2tw : .s2hk)
            // Match the project override first, then the reviewed phrase table.
            // A replacement is emitted once and never recursively reconverted.
            return region == .taiwan
                ? Dictionary.convert(base, dictionaries: [data.taiwanOverlay, data.reviewedTaiwan])
                : Dictionary.convert(base, dictionaries: [data.hongKongOverlay])
        }
    }

    private func tables() throws -> Tables {
        if let loaded { return try loaded.get() }
        #if DEBUG
        loads += 1
        #endif
        let result = Result { () throws -> Tables in
            guard let directory else { throw Failure.resourcesMissing }
            return try Tables(directory: directory)
        }
        loaded = result
        return try result.get()
    }

    private struct Dictionary {
        final class Node {
            var children: [UInt32: Node] = [:]
            var value: String?
        }
        let root = Node()

        init(_ names: [String], in directory: URL) throws {
            for name in names {
                guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else {
                    throw Failure.invalidDictionary(name)
                }
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard fields.count == 2, !fields[0].isEmpty,
                          let first = fields[1].split(whereSeparator: { $0.isWhitespace }).first else {
                        throw Failure.invalidDictionary(name)
                    }
                    var node = root
                    for scalar in fields[0].unicodeScalars {
                        if node.children[scalar.value] == nil { node.children[scalar.value] = Node() }
                        node = node.children[scalar.value]!
                    }
                    // DictGroup gives earlier dictionaries priority.
                    if node.value == nil { node.value = String(first) }
                }
            }
        }

        func match(_ scalars: [Unicode.Scalar], at start: Int) -> (end: Int, value: String)? {
            var node = root, index = start
            var best: (end: Int, value: String)?
            while index < scalars.count, let next = node.children[scalars[index].value] {
                index += 1
                node = next
                if let value = node.value { best = (index, value) }
            }
            return best
        }

        static func convert(_ text: String, dictionaries: [Self]) -> String {
            let scalars = Array(text.unicodeScalars)
            var output = "", index = 0
            while index < scalars.count {
                if let match = dictionaries.lazy.compactMap({ $0.match(scalars, at: index) }).first {
                    output += match.value
                    index = match.end
                } else {
                    output.unicodeScalars.append(scalars[index])
                    index += 1
                }
            }
            return output
        }

        func segment(_ text: String) -> [String] {
            let scalars = Array(text.unicodeScalars)
            var segments: [String] = [], pending = "", index = 0
            while index < scalars.count {
                if let match = match(scalars, at: index) {
                    if !pending.isEmpty { segments.append(pending); pending = "" }
                    segments.append(String(String.UnicodeScalarView(scalars[index..<match.end])))
                    index = match.end
                } else {
                    pending.unicodeScalars.append(scalars[index])
                    index += 1
                }
            }
            if !pending.isEmpty { segments.append(pending) }
            return segments
        }
    }

    private struct Tables {
        let phrases, characters, taiwan, hongKong, taiwanPhrases: Dictionary
        let reviewedTaiwan, taiwanOverlay, hongKongOverlay: Dictionary
        init(directory: URL) throws {
            phrases = try Dictionary(["STPhrases.txt"], in: directory)
            characters = try Dictionary(["STCharacters.txt"], in: directory)
            taiwan = try Dictionary(["TWVariants.txt"], in: directory)
            hongKong = try Dictionary(["HKVariants.txt"], in: directory)
            taiwanPhrases = try Dictionary(["TWPhrasesIT.txt", "TWPhrasesName.txt", "TWPhrasesOther.txt"], in: directory)
            reviewedTaiwan = try Dictionary(["TW-reviewed-phrases.txt"], in: directory)
            taiwanOverlay = try Dictionary(["LiveLingo-TW-overlay.txt"], in: directory)
            hongKongOverlay = try Dictionary(["LiveLingo-HK-overlay.txt"], in: directory)
        }
        func convert(_ text: String, mode: Mode) -> String {
            phrases.segment(text).map { segment in
                var result = Dictionary.convert(segment, dictionaries: [phrases, characters])
                if mode == .s2twp { result = Dictionary.convert(result, dictionaries: [taiwanPhrases]) }
                return Dictionary.convert(result, dictionaries: [mode == .s2hk ? hongKong : taiwan])
            }.joined()
        }
    }
}
