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

    func testRawOpenCCConversionRemainsIndependentOfProtectedRendering() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        let raw = #"`record["头发"]` \label{eq:头发}"#
        for mode in ChineseScriptConverter.Mode.allCases {
            XCTAssertEqual(try converter.convert(raw, mode: mode), #"`record["頭髮"]` \label{eq:頭髮}"#)
        }
    }

    func testOutputLanguageRenderingPreservesInlineCodeWithDifferentBacktickLengths() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        let code = #"`record["头发"]`，``record["头发"] + `头发` ``，```record["头发"] + ``头发`` ```"#
        for (language, prose) in [(OutputLanguage.traditionalChineseTaiwan, "頭髮在這裡。"),
                                  (.traditionalChineseHongKong, "頭髮在這裏。") ] {
            let input = "头发在这里。" + code + "头发在这里。"
            let expected = prose + code + prose
            XCTAssertEqual(Data(try language.render(input, converter: converter).utf8), Data(expected.utf8))
            XCTAssertEqual(Data(language.renderForDisplay(input, converter: converter).utf8), Data(expected.utf8))
        }
    }

    func testOutputLanguageRenderingPreservesJSONKeysAndConvertsNaturalLanguageValues() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        let input = #"{"头发":"头发在这里。","对象":{"后面":"头发"},"数组":[{"这里":"后面"}],"头\"发":"这里","头\u53d1":"这里"}"#
        let taiwan = #"{"头发":"頭髮在這裡。","对象":{"后面":"頭髮"},"数组":[{"这里":"後面"}],"头\"发":"這裡","头\u53d1":"這裡"}"#
        let hongKong = #"{"头发":"頭髮在這裏。","对象":{"后面":"頭髮"},"数组":[{"这里":"後面"}],"头\"发":"這裏","头\u53d1":"這裏"}"#
        for (language, expected) in [(OutputLanguage.traditionalChineseTaiwan, taiwan),
                                     (.traditionalChineseHongKong, hongKong)] {
            let rendered = try language.render(input, converter: converter)
            XCTAssertEqual(Data(rendered.utf8), Data(expected.utf8))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
            XCTAssertEqual(object["头发"] as? String, language == .traditionalChineseTaiwan ? "頭髮在這裡。" : "頭髮在這裏。")
            XCTAssertNil(object["頭髮"])
        }
    }

    func testOutputLanguageRenderingPreservesChineseMathAndLaTeXIdentifiers() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        let technical = #"\(x_{\mathrm{头发}}=1\) \[\text{这里}\label{eq:头发}\] $x_{头发}$ $$\label{eq:头发}$$ \label{eq:头发} \ref{eq:头发} \eqref{eq:头发} \cite[这里]{头发} \newcommand{\头发}[1]{#1}"#
        for (language, prose) in [(OutputLanguage.traditionalChineseTaiwan, "頭髮在這裡。"),
                                  (.traditionalChineseHongKong, "頭髮在這裏。") ] {
            XCTAssertEqual(Data(try language.render("头发在这里。" + technical + "头发在这里。", converter: converter).utf8),
                           Data((prose + technical + prose).utf8))
        }
    }

    func testRenderingDoesNotProtectOrdinaryQuotesCurrencyOrUnmatchedBackticks() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        let input = #""头发"在这里。头发价格 $5，后面是 $6。\$头发在这里。\$ `头发在这里。"#
        let expected = #""頭髮"在這裡。頭髮價格 $5，後面是 $6。\$頭髮在這裡。\$ `頭髮在這裡。"#
        XCTAssertEqual(try OutputLanguage.traditionalChineseTaiwan.render(input, converter: converter), expected)
    }

    func testRenderingProtectsDollarMathBeginningWithDigitsOrWhitespace() throws {
        let converter = try ChineseScriptConverter(resourceDirectory: resources)
        let examples = [("$3+x_{头发}$", "$3+x_{头发}$"), ("$ x_{头发} $", "$ x_{头发} $"),
                        ("头发价格 $5，后面是 $6；公式 $3+x_{头发}$ 和 $ x_{头发} $，后面是头发。",
                         "頭髮價格 $5，後面是 $6；公式 $3+x_{头发}$ 和 $ x_{头发} $，後面是頭髮。")]
        for language in [OutputLanguage.traditionalChineseTaiwan, .traditionalChineseHongKong] {
            for (input, expected) in examples {
                XCTAssertEqual(Data(try language.render(input, converter: converter).utf8), Data(expected.utf8))
                XCTAssertEqual(Data(language.renderForDisplay(input, converter: converter).utf8), Data(expected.utf8))
            }
        }
    }

    func testTechnicalRenderingIdentityPathsNeverLoadDictionaries() throws {
        let converter = ChineseScriptConverter(resourceDirectory: nil)
        let input = "头发在这里。\r\n```python\r\nrecord[\"头发\"]\r\n```\r\n" + #"{"头发":"这里"} \label{eq:头发}"#
        for language in [OutputLanguage.simplifiedChinese, .english, .spanish, .french] {
            XCTAssertEqual(Data(try language.render(input, converter: converter).utf8), Data(input.utf8))
            XCTAssertEqual(Data(language.renderForDisplay(input, converter: converter).utf8), Data(input.utf8))
        }
        XCTAssertEqual(converter.debugLoadCount, 0)
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
