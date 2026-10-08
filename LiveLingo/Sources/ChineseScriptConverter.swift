import Foundation

/// Offline OpenCC data, with scalar-based longest-prefix matching. Conversion
/// preserves the original segmentation across every upstream conversion stage.
final class ChineseScriptConverter: @unchecked Sendable {
    enum Region: Hashable, Sendable { case taiwan, hongKong }
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
    private struct CacheKey: Hashable {
        let region: Region
        let text: String

        // Swift String equality folds canonically equivalent Unicode. Cache
        // keys must preserve the original UTF-8 spelling of non-Han content.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.region == rhs.region && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(region)
            for byte in text.utf8 { hasher.combine(byte) }
        }
    }
    private struct CacheEntry {
        let text: String
        let utf8Bytes: Int
    }
    private let cacheEntryLimit: Int
    private let cacheByteLimit: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cacheBytes = 0
    #if DEBUG
    private var loads = 0
    private var cacheHits = 0
    var debugLoadCount: Int { lock.withLock { loads } }
    var debugCacheEntryCount: Int { lock.withLock { cache.count } }
    /// Counts the retained original and converted UTF-8 payloads. Entry count
    /// separately bounds the dictionary/order bookkeeping, not measured RSS.
    var debugCacheByteCount: Int { lock.withLock { cacheBytes } }
    var debugCacheHitCount: Int { lock.withLock { cacheHits } }
    #endif

    init(resourceDirectory: URL? = ChineseScriptConverter.resourceDirectory(),
         cacheEntryLimit: Int = 256, cacheByteLimit: Int = 1_048_576) {
        precondition(cacheEntryLimit >= 0 && cacheByteLimit >= 0)
        directory = resourceDirectory
        self.cacheEntryLimit = cacheEntryLimit
        self.cacheByteLimit = cacheByteLimit
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
            let key = CacheKey(region: region, text: text)
            if let entry = cache[key] {
                #if DEBUG
                cacheHits += 1
                #endif
                if let index = cacheOrder.firstIndex(of: key) { cacheOrder.remove(at: index) }
                cacheOrder.append(key)
                return entry.text
            }
            let data = try tables()
            let base = data.convert(text, mode: region == .taiwan ? .s2tw : .s2hk)
            // Match the project override first, then the reviewed phrase table.
            // A replacement is emitted once and never recursively reconverted.
            let result = region == .taiwan
                ? Dictionary.convert(base, dictionaries: [data.taiwanOverlay, data.reviewedTaiwan])
                : Dictionary.convert(base, dictionaries: [data.hongKongOverlay])
            storeInCache(result, for: key)
            return result
        }
    }

    /// Rendering is separate from raw OpenCC conversion: technical fragments
    /// keep their exact UTF-8 bytes, while prose uses the original algorithm.
    func render(_ text: String, to region: Region) throws -> String {
        try render(RenderText(text), to: region)
    }

    func render(_ text: RenderText, to region: Region) throws -> String {
        try prepare()
        return try text.render { try convert($0, to: region) }
    }

    /// Called only with lock held. Oversized entries bypass the cache without
    /// changing conversion or evicting reusable short captions.
    private func storeInCache(_ result: String, for key: CacheKey) {
        guard cacheEntryLimit > 0, cacheByteLimit > 0 else { return }
        let originalBytes = key.text.utf8.count
        guard originalBytes <= cacheByteLimit else { return }
        let (bytes, overflow) = originalBytes.addingReportingOverflow(result.utf8.count)
        guard !overflow, bytes <= cacheByteLimit else { return }
        while cache.count >= cacheEntryLimit || cacheBytes > cacheByteLimit - bytes {
            let oldest = cacheOrder.removeFirst()
            if let entry = cache.removeValue(forKey: oldest) { cacheBytes -= entry.utf8Bytes }
        }
        cache[key] = CacheEntry(text: result, utf8Bytes: bytes)
        cacheOrder.append(key)
        cacheBytes += bytes
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

extension ChineseScriptConverter {
    /// The byte scanner is mirrored by Scripts.zh_variants.RenderText. Keeping
    /// original slices avoids Unicode normalization and JSON re-serialization.
    struct RenderText {
        private let bytes: [UInt8]
        private let protected: [Bool]
        var text: String { String(decoding: bytes, as: UTF8.self) }
        var byteCount: Int { bytes.count }
        var isFullyProtected: Bool { !bytes.isEmpty && protected.allSatisfy { $0 } }

        init(_ text: String) {
            var scanner = Scanner(bytes: Array(text.utf8))
            scanner.blocks()
            scanner.blockProtected = scanner.protected
            scanner.inlineCode()
            scanner.latex()
            scanner.jsonKeys()
            bytes = scanner.bytes
            protected = scanner.protected
        }

        private init(bytes: [UInt8], protected: [Bool]) {
            self.bytes = bytes
            self.protected = protected
        }

        func slice(_ range: Range<Int>) -> Self {
            Self(bytes: Array(bytes[range]), protected: Array(protected[range]))
        }

        func render(_ convert: (String) throws -> String) rethrows -> String {
            var result = "", start = 0
            while start < bytes.count {
                var end = start + 1
                while end < bytes.count, protected[end] == protected[start] { end += 1 }
                let text = String(decoding: bytes[start..<end], as: UTF8.self)
                result += protected[start] ? text : try convert(text)
                start = end
            }
            return result
        }

        private struct Scanner {
            let bytes: [UInt8]
            var protected: [Bool]
            var blockProtected: [Bool] = []
            var inlineBlocks: [Int]
            private static let whitespace: Set<UInt8> = [32, 9, 13, 10]
            private static let mathEnvironments: Set<String> = [
                "math", "displaymath", "equation", "equation*", "align", "align*", "aligned",
                "gather", "gather*", "multline", "multline*", "eqnarray", "eqnarray*",
                "cases", "matrix", "pmatrix", "bmatrix", "vmatrix", "Vmatrix"
            ]

            init(bytes: [UInt8]) {
                self.bytes = bytes
                protected = Array(repeating: false, count: bytes.count)
                inlineBlocks = Array(repeating: 0, count: bytes.count)
            }

            mutating func mark(_ range: Range<Int>) {
                for index in range { protected[index] = true }
            }

            func escaped(_ index: Int) -> Bool {
                var start = index
                while start > 0, bytes[start - 1] == 92 { start -= 1 }
                return (index - start) % 2 != 0
            }

            func runEnd(_ index: Int, byte: UInt8) -> Int {
                var end = index
                while end < bytes.count, bytes[end] == byte { end += 1 }
                return end
            }

            func spaceEnd(_ index: Int, end: Int? = nil) -> Int {
                var index = index
                let end = end ?? bytes.count
                while index < end, Self.whitespace.contains(bytes[index]) { index += 1 }
                return index
            }

            func balancedEnd(_ index: Int) -> Int? {
                guard bytes[index] == 123 || bytes[index] == 91 else { return nil }
                var stack: [UInt8] = [bytes[index] == 123 ? 125 : 93]
                var cursor = index + 1
                while cursor < bytes.count {
                    let byte = bytes[cursor]
                    if byte == 92 { cursor += 2; continue }
                    if byte == 123 || (byte == 91 && stack.last != 125) {
                        stack.append(byte == 123 ? 125 : 93)
                    } else if byte == stack.last {
                        stack.removeLast()
                        if stack.isEmpty { return cursor + 1 }
                    }
                    cursor += 1
                }
                return nil
            }

            private enum Container: Equatable {
                case quote
                case list(indent: Int)
            }

            private func indentation(_ start: Int, columns: Int = 0, end: Int) -> (index: Int, columns: Int) {
                var index = start, columns = columns
                while index < end, bytes[index] == 32 || bytes[index] == 9 {
                    columns += bytes[index] == 32 ? 1 : 4 - columns % 4
                    index += 1
                }
                return (index, columns)
            }

            private func listMarkerEnd(_ index: Int, end: Int) -> Int? {
                guard index < end else { return nil }
                var markerEnd = index
                if [45, 43, 42].contains(bytes[index]) {
                    markerEnd += 1
                } else {
                    while markerEnd < end, (48...57).contains(bytes[markerEnd]), markerEnd - index < 9 { markerEnd += 1 }
                    guard markerEnd > index, markerEnd < end, [46, 41].contains(bytes[markerEnd]) else { return nil }
                    markerEnd += 1
                }
                return markerEnd == end || [32, 9].contains(bytes[markerEnd]) ? markerEnd : nil
            }

            private func heading(_ index: Int, end: Int) -> Bool {
                guard index < end, bytes[index] == 35 else { return false }
                let last = runEnd(index, byte: 35)
                return last - index <= 6 && (last == end || [32, 9].contains(bytes[last]))
            }

            private func rule(_ index: Int, end: Int) -> Bool {
                guard index < end, [42, 45, 95, 61].contains(bytes[index]) else { return false }
                let marker = bytes[index]
                let body = bytes[index..<end].filter { $0 != 32 && $0 != 9 }
                return body.count >= (marker == 61 ? 1 : 3) && body.allSatisfy { $0 == marker }
            }

            private func interruptsParagraph(_ index: Int, columns: Int, end: Int) -> Bool {
                guard columns <= 3, index < end else { return false }
                return bytes[index] == 62 || heading(index, end: end) || rule(index, end: end)
                    || listMarkerEnd(index, end: end) != nil
                    || ([96, 126].contains(bytes[index]) && runEnd(index, byte: bytes[index]) - index >= 3)
            }

            mutating func blocks() {
                var containers: [Container] = []
                var fence: (byte: UInt8, count: Int, containers: [Container])?
                var indented = false, previousBlank = true, paragraph = false, blockID = 0, start = 0
                while start < bytes.count {
                    let end = bytes[start...].firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
                    var contentEnd = end
                    while contentEnd > start, bytes[contentEnd - 1] == 13 || bytes[contentEnd - 1] == 10 { contentEnd -= 1 }
                    let leading = indentation(start, end: contentEnd)
                    var index = leading.index, columns = leading.columns, matched = 0
                    containerLoop: for container in containers {
                        switch container {
                        case .quote:
                            guard columns <= 3, index < contentEnd, bytes[index] == 62 else { break containerLoop }
                            index += 1
                            if index < contentEnd, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
                            let next = indentation(index, end: contentEnd)
                            index = next.index
                            columns = next.columns
                        case .list(let indent):
                            guard index == contentEnd || columns >= indent else { break containerLoop }
                            columns = max(0, columns - indent)
                        }
                        matched += 1
                    }
                    if matched < containers.count {
                        // Lazy continuation is allowed only for an existing
                        // paragraph, never for a fence or indented code block.
                        let lazy = paragraph && !previousBlank && fence == nil && !indented
                            && index < contentEnd && !interruptsParagraph(index, columns: columns, end: contentEnd)
                        if !lazy {
                            containers = Array(containers.prefix(matched))
                            fence = nil
                            indented = false
                            paragraph = false
                        }
                    }

                    if let active = fence, containers == active.containers {
                        mark(start..<end)
                        let markerEnd = index < contentEnd ? runEnd(index, byte: active.byte) : index
                        if columns <= 3, markerEnd - index >= active.count,
                           spaceEnd(markerEnd, end: contentEnd) == contentEnd { fence = nil }
                        previousBlank = index == contentEnd
                        paragraph = false
                        start = end
                        continue
                    }

                    var openedContainer = false
                    while columns <= 3, index < contentEnd {
                        if bytes[index] == 62 {
                            containers.append(.quote)
                            index += 1
                            if index < contentEnd, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
                            let next = indentation(index, end: contentEnd)
                            index = next.index
                            columns = next.columns
                        } else if !rule(index, end: contentEnd), let markerEnd = listMarkerEnd(index, end: contentEnd) {
                            let markerWidth = markerEnd - index
                            let next = indentation(markerEnd, columns: columns + markerWidth, end: contentEnd)
                            let padding = next.columns - columns - markerWidth
                            let spacing = padding > 0 && padding <= 4 ? padding : 1
                            containers.append(.list(indent: columns + markerWidth + spacing))
                            index = next.index
                            columns = max(0, padding - spacing)
                        } else { break }
                        openedContainer = true
                    }

                    let blank = index == contentEnd
                    let markerEnd = !blank && [96, 126].contains(bytes[index]) ? runEnd(index, byte: bytes[index]) : index
                    let count = markerEnd - index
                    if columns <= 3, count >= 3,
                       bytes[index] == 126 || !bytes[markerEnd..<contentEnd].contains(96) {
                        fence = (bytes[index], count, containers)
                        mark(start..<end)
                        indented = false
                        paragraph = false
                    } else if indented && blank {
                        mark(start..<end)
                    } else if columns >= 4 && (indented || previousBlank || openedContainer) {
                        mark(start..<end)
                        indented = true
                        paragraph = false
                    } else {
                        indented = false
                        if blank {
                            paragraph = false
                        } else {
                            let separate = columns <= 3 && (heading(index, end: contentEnd) || rule(index, end: contentEnd))
                            if !paragraph || openedContainer || separate { blockID += 1 }
                            for position in start..<end { inlineBlocks[position] = blockID }
                            paragraph = !separate
                        }
                    }
                    previousBlank = blank
                    start = end
                }
            }

            mutating func inlineCode() {
                var index = 0
                while index < bytes.count {
                    guard !protected[index], bytes[index] == 96, !escaped(index) else { index += 1; continue }
                    let openingEnd = runEnd(index, byte: 96)
                    var cursor = openingEnd, closingEnd: Int?
                    while cursor < bytes.count, !protected[cursor], inlineBlocks[cursor] == inlineBlocks[index] {
                        if bytes[cursor] == 96 {
                            let end = runEnd(cursor, byte: 96)
                            if end - cursor == openingEnd - index { closingEnd = end; break }
                            cursor = end
                        } else { cursor += 1 }
                    }
                    if let closingEnd { mark(index..<closingEnd); index = closingEnd }
                    else { index = openingEnd }
                }
            }

            func delimiterEnd(_ start: Int, delimiter: [UInt8]) -> Int? {
                var cursor = start
                while cursor < bytes.count {
                    if blockProtected[cursor] { return nil }
                    if cursor + delimiter.count <= bytes.count,
                       bytes[cursor..<(cursor + delimiter.count)].elementsEqual(delimiter), !escaped(cursor) {
                        return cursor + delimiter.count
                    }
                    cursor += 1
                }
                return nil
            }

            func commandEnd(_ start: Int) -> Int {
                var end = start
                while end < bytes.count {
                    let byte = bytes[end]
                    let length = byte < 128 ? 1 : (byte < 224 ? 2 : (byte < 240 ? 3 : 4))
                    guard end + length <= bytes.count,
                          let scalar = String(decoding: bytes[end..<(end + length)], as: UTF8.self).unicodeScalars.first else { break }
                    switch scalar.properties.generalCategory {
                    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: end += length
                    default: return end
                    }
                }
                return end
            }

            func hasMathSyntax(_ range: Range<Int>) -> Bool {
                var start = range.lowerBound, end = range.upperBound
                while start < end, Self.whitespace.contains(bytes[start]) { start += 1 }
                while end > start, Self.whitespace.contains(bytes[end - 1]) { end -= 1 }
                let operators: Set<UInt8> = [95, 94, 92, 61, 43, 45, 42, 47, 60, 62]
                guard start < end, !operators.contains(bytes[end - 1]),
                      !bytes[start..<end].contains(13), !bytes[start..<end].contains(10) else { return false }
                let body = String(decoding: bytes[start..<end], as: UTF8.self)
                guard !"，。；！？：".contains(where: { body.contains($0) }) else { return false }
                return bytes[start..<end].contains { operators.contains($0) }
            }

            mutating func latex() {
                var index = 0
                while index < bytes.count {
                    guard !protected[index], !escaped(index) else { index += 1; continue }
                    if bytes[index] == 36 {
                        let openingEnd = runEnd(index, byte: 36), length = runEnd(index, byte: 36) - index
                        guard [1, 2].contains(length), openingEnd < bytes.count else {
                            index = openingEnd
                            continue
                        }
                        var cursor = openingEnd, closing: Int?
                        while cursor < bytes.count, !blockProtected[cursor] {
                            if bytes[cursor] == 36, !escaped(cursor) {
                                let end = runEnd(cursor, byte: 36)
                                if end - cursor == length {
                                    let conventional = !Self.whitespace.contains(bytes[openingEnd]) && !(48...57).contains(bytes[openingEnd])
                                        && !Self.whitespace.contains(bytes[cursor - 1])
                                    if length == 2 || ((end == bytes.count || !(48...57).contains(bytes[end]))
                                        && (conventional || hasMathSyntax(openingEnd..<cursor))) { closing = end }
                                }
                                // Stop at a rejected pair instead of swallowing
                                // prose/currency through a later real formula.
                                if closing != nil || length == 1 { break }
                                cursor = end
                            } else { cursor += 1 }
                        }
                        if let closing { mark(index..<closing); index = closing }
                        else { index = openingEnd }
                        continue
                    }
                    guard bytes[index] == 92, index + 1 < bytes.count else { index += 1; continue }
                    if [40, 91].contains(bytes[index + 1]),
                       let end = delimiterEnd(index + 2, delimiter: bytes[index + 1] == 40 ? [92, 41] : [92, 93]) {
                        mark(index..<end)
                        index = end
                        continue
                    }
                    var endOfCommand = commandEnd(index + 1)
                    guard endOfCommand > index + 1 else { index += 2; continue }
                    let command = String(decoding: bytes[(index + 1)..<endOfCommand], as: UTF8.self)
                    if endOfCommand < bytes.count, bytes[endOfCommand] == 42 { endOfCommand += 1 }
                    var end = endOfCommand
                    if command == "verb", end < bytes.count, !Self.whitespace.contains(bytes[end]) {
                        if let closing = bytes[(end + 1)...].firstIndex(of: bytes[end]), !bytes[end..<closing].contains(10) { end = closing + 1 }
                    } else {
                        while true {
                            let group = spaceEnd(end)
                            guard group < bytes.count, [123, 91].contains(bytes[group]), let groupEnd = balancedEnd(group) else { break }
                            let environment = String(decoding: bytes[(group + 1)..<(groupEnd - 1)], as: UTF8.self)
                            if command == "begin", group == spaceEnd(endOfCommand), Self.mathEnvironments.contains(environment),
                               let mathEnd = delimiterEnd(groupEnd, delimiter: Array("\\end{\(environment)}".utf8)) {
                                end = mathEnd
                                break
                            }
                            end = groupEnd
                        }
                    }
                    mark(index..<end)
                    index = end
                }
            }

            mutating func jsonKeys() {
                var stack: [UInt8] = [], index = 0
                while index < bytes.count {
                    if protected[index] { index += 1; continue }
                    let byte = bytes[index]
                    if byte == 123 {
                        let following = spaceEnd(index + 1)
                        if !stack.isEmpty || (following < bytes.count && [34, 125].contains(bytes[following])) { stack.append(123) }
                    } else if byte == 91 && !stack.isEmpty {
                        stack.append(91)
                    } else if [125, 93].contains(byte), stack.last == (byte == 125 ? 123 : 91) {
                        stack.removeLast()
                    } else if byte == 34 {
                        var end = index + 1
                        while end < bytes.count {
                            if bytes[end] == 92 { end += 2 }
                            else if [34, 13, 10].contains(bytes[end]) { break }
                            else { end += 1 }
                        }
                        if end < bytes.count, bytes[end] == 34 {
                            end += 1
                            let following = spaceEnd(end)
                            if stack.last == 123, following < bytes.count, bytes[following] == 58 { mark(index..<end) }
                            index = end
                            continue
                        }
                    }
                    index += 1
                }
            }
        }
    }
}
