import CryptoKit
import Foundation
import XCTest
@testable import LiveLingo

final class ChineseScriptConverterTests: XCTestCase, @unchecked Sendable {
    private var resources: URL { get throws { try XCTUnwrap(ChineseScriptConverter.resourceDirectory()) } }
    private var fixtures: URL { get throws {
        try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("zh-variants-v1/upstream")
    } }

    func testUpstreamConversionCasesAreByteIdentical() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        for mode in ChineseScriptConverter.Mode.allCases {
            let input = try String(contentsOf: fixtures.appendingPathComponent(mode.rawValue + ".in"), encoding: .utf8)
            let expected = try Data(contentsOf: fixtures.appendingPathComponent(mode.rawValue + ".ans"))
            XCTAssertEqual(Data(try converter.convert(input, mode: mode).utf8), expected, mode.rawValue)
        }
        XCTAssertEqual(converter.debugLoadCount, 1)
    }

    func testUpstreamAndBundledLicenseHashes() throws {
        struct Source: Decodable {
            struct File: Decodable { let path: String; let sha256: String }
            struct Notice: Decodable { let sha256: String }
            let files, testFiles: [File]
            let notice: Notice
            let converterVersion: String
        }
        let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: resources.appendingPathComponent("SOURCE.json")))
        XCTAssertEqual(source.converterVersion, ChineseScriptConverter.version)
        for file in source.files {
            XCTAssertEqual(try digest(resources.appendingPathComponent(file.path)), file.sha256, file.path)
        }
        for file in source.testFiles {
            XCTAssertEqual(try digest(fixtures.appendingPathComponent(URL(fileURLWithPath: file.path).lastPathComponent)), file.sha256)
        }
        XCTAssertEqual(try digest(resources.appendingPathComponent("NOTICE")), source.notice.sha256)
        XCTAssertTrue(try String(contentsOf: resources.appendingPathComponent("LICENSE"), encoding: .utf8).contains("Apache License"))
    }

    func testNonHanScalarsArePreservedIncludingCombiningMarks() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        let raw = "DNA pH 7.4 CaCO₃ H₂O \\(x^2\\) $a+b$ e\u{0301} かな カナ 한글 😀\n\t"
        for mode in ChineseScriptConverter.Mode.allCases {
            XCTAssertEqual(Data(try converter.convert(raw, mode: mode).utf8), Data(raw.utf8))
        }
    }

    func testMissingAndMalformedDictionariesFail() throws {
        let absent = ChineseScriptConverter(resourceDirectory: nil)
        XCTAssertThrowsError(try absent.convert("头发", to: .taiwan))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZhVariants-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try "bad line".write(to: root.appendingPathComponent("STPhrases.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ChineseScriptConverter(resourceDirectory: root).convert("头发", to: .taiwan))
    }

    func testExecutableAdjacentDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ZhVariants-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ZhVariants"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("ZhVariants/SOURCE.json"))
        let emptyBundle = try XCTUnwrap(Bundle(path: "/System/Library/Frameworks/Foundation.framework"))
        XCTAssertEqual(ChineseScriptConverter.resourceDirectory(bundle: emptyBundle, executable: root.appendingPathComponent("cli")),
                       root.appendingPathComponent("ZhVariants"))
    }

    func testConcurrentConversionsLoadOnce() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
        }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do { results.append(try converter.convert("头发在这里。", to: index.isMultiple(of: 2) ? .taiwan : .hongKong)) }
            catch { results.append("FAIL") }
        }
        XCTAssertEqual(results.values.count, 40)
        XCTAssertEqual(results.values.filter { $0 == "頭髮在這裡。" }.count, 20)
        XCTAssertEqual(results.values.filter { $0 == "頭髮在這裏。" }.count, 20)
        XCTAssertEqual(converter.debugLoadCount, 1)
    }

    func testMeasureColdDictionaryLoad() throws {
        let directory = try resources
        measure {
            do { try ChineseScriptConverter(resourceDirectory: directory).prepare() }
            catch { XCTFail(String(describing: error)) }
        }
    }

    func testMeasureSyntheticLessonConversion() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        try converter.prepare()
        let lesson = String(repeating: "头发在这里，计算电离能和特征值。pH 7.4 CaCO₃。\n", count: 500)
        measure {
            do { _ = try converter.convert(lesson, to: .taiwan) }
            catch { XCTFail(String(describing: error)) }
        }
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
