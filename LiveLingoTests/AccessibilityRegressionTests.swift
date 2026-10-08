import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

/// Only synthetic fixtures and unshown windows. AX probes enable the lazy tree
/// in this test process and restore its previous setting after each test.
@MainActor
final class AccessibilityRegressionTests: XCTestCase {
    private var enhancedUI: Bool?
    private var measurements: [[String: Any]] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        let app = NSApplication.shared
        let getter = NSSelectorFromString("accessibilityEnhancedUserInterfaceAttribute")
        let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
        XCTAssertTrue(app.responds(to: getter) && app.responds(to: setter), "The AX probe must actually enable the lazy tree")
        enhancedUI = try XCTUnwrap(app.perform(getter)?.takeUnretainedValue() as? NSNumber).boolValue
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        if let enhancedUI { NSApplication.shared.setValue(enhancedUI, forKey: "accessibilityEnhancedUserInterface") }
        if !measurements.isEmpty {
            let url = screenshots.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-") + ".json")
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
        try await super.tearDown()
    }

    private var screenshots: URL {
        TestFixtureDirectory.root.appendingPathComponent("screenshots", isDirectory: true)
    }

    private func fixture() throws -> (AppModel, UserDefaults) {
        let suite = "LiveLingo-Test-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = TestFixtureDirectory.root.appendingPathComponent(suite, isDirectory: true)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Accessibility fixtures must never invoke generation")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: store)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove()
        }
        return (model, store)
    }

    private func host<V: View>(_ root: V, width: CGFloat = 640, height: CGFloat = 360,
                               dark: Bool = false) async throws -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: AnyView(root.environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(.init(width: width, height: height))
        windows.append(window)
        try await settle(controller.view)
        XCTAssertFalse(window.isVisible, "These snapshots must stay offscreen")
        return controller
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private struct Node {
        let object: NSObject
        func value(_ key: String) -> Any? {
            let getter = key == "accessibilityEnabled" ? "isAccessibilityEnabled" : key
            return object.responds(to: NSSelectorFromString(getter)) ? object.value(forKey: key) : nil
        }
        var strings: [String] { ["accessibilityValue", "accessibilityLabel", "accessibilityTitle", "accessibilityHelp"]
            .compactMap { value($0) as? String } }
        var id: String? { value("accessibilityIdentifier") as? String }
        var frame: NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }

    private func nodes(_ view: NSView) -> [Node] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ root: NSObject, depth: Int = 0) -> [Node] {
            guard depth < 30, visited.insert(ObjectIdentifier(root)).inserted else { return [] }
            let node = Node(object: root)
            return [node] + ((node.value("accessibilityChildren") as? [NSObject]) ?? []).flatMap { walk($0, depth: depth + 1) }
        }
        return (view.window.map { walk($0) } ?? []) + walk(view)
    }

    private func node(_ id: String, in view: NSView) throws -> Node {
        try XCTUnwrap(nodes(view).first { $0.id == id }, "Missing real AX element \(id)")
    }

    private func textNode(_ text: String, in view: NSView) throws -> Node {
        try XCTUnwrap(nodes(view).first { $0.strings.contains(text) }, "Missing real AX text \(text)")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func capture(_ view: NSView, _ name: String) throws -> NSBitmapImageRep {
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: screenshots.appendingPathComponent(name + ".png"))
        let tree = nodes(view).map { node -> [String: Any] in
            var item: [String: Any] = ["class": String(describing: type(of: node.object))]
            for key in ["accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue",
                        "accessibilityHelp", "accessibilityIdentifier", "accessibilityEnabled"] {
                if let value = node.value(key) as? String { item[key] = value }
                else if let value = node.value(key) as? NSNumber { item[key] = value }
            }
            item["frame"] = [node.frame.minX, node.frame.minY, node.frame.width, node.frame.height]
            return item
        }
        try JSONSerialization.data(withJSONObject: ["is_visible": view.window?.isVisible ?? false, "nodes": tree],
            options: [.prettyPrinted, .sortedKeys]).write(to: screenshots.appendingPathComponent(name + "-ax.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return bitmap
    }

    private struct Pixel: Hashable {
        let r: Int, g: Int, b: Int, a: Int
        var rgb: [Double] { [Double(r), Double(g), Double(b)].map { $0 / 255 } }
        var rgba: [Int] { [r, g, b, a] }
    }

    /// Convert the bitmap's embedded color space once. colorAt() labels some
    /// cached Display-P3 bytes as device RGB on current AppKit, so converting
    /// each returned NSColor would mismeasure both foreground and background.
    private func srgbPixels(_ image: NSBitmapImageRep) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.pixelsWide * image.pixelsHigh * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.pixelsWide,
                height: image.pixelsHigh, bitsPerComponent: 8, bytesPerRow: image.pixelsWide * 4,
                space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh))
        }
        return bytes
    }

    private func histogram(_ image: NSBitmapImageRep) throws -> [Pixel: Int] {
        let bytes = try srgbPixels(image)
        var counts: [Pixel: Int] = [:]
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            counts[Pixel(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]), a: Int(bytes[offset + 3])), default: 0] += 1
        }
        return counts
    }

    private func press(_ node: Node) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(node.object.responds(to: selector), "The probe must press a real action element")
        guard node.object.responds(to: selector) else { return }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(node.object.method(for: selector), to: Action.self)
        XCTAssertTrue(action(node.object, selector))
    }

    private func contrast(_ foreground: [Double], _ background: [Double]) -> Double {
        func luminance(_ rgb: [Double]) -> Double {
            zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { total, pair in
                let c = pair.0
                return total + pair.1 * (c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
            }
        }
        let values = [luminance(foreground), luminance(background)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    private func assertContrast(_ counts: [Pixel: Int], name: String, minimum: Double,
                                foreground: (Pixel) -> Bool, background: (Pixel) -> Bool) throws {
        let fg = try XCTUnwrap(counts.filter { foreground($0.key) }.max { $0.value < $1.value }, "No glyph core in \(name)")
        let bg = try XCTUnwrap(counts.filter { background($0.key) }.max { $0.value < $1.value }, "No surface in \(name)")
        XCTAssertGreaterThan(fg.value, 8, "Need fully covered glyph pixels, not a blank/antialiased sample")
        let ratio = contrast(fg.key.rgb, bg.key.rgb)
        XCTAssertGreaterThanOrEqual(ratio, minimum, name)
        measurements.append(["name": name, "foreground_srgb8": fg.key.rgba, "background_srgb8": bg.key.rgba,
                             "core_pixels": fg.value, "ratio": ratio, "required": minimum])
        print("A11Y_CONTRAST \(name) ratio=\(ratio) required=\(minimum) corePixels=\(fg.value)")
    }

    func testTemporaryDirectoryIsInsideThisInvocationsBuildRoot() throws {
        XCTAssertEqual(SessionDirectoryLocation.canonical(FileManager.default.temporaryDirectory),
                       SessionDirectoryLocation.canonical(TestFixtureDirectory.root))
        XCTAssertEqual(screenshots.deletingLastPathComponent(), TestFixtureDirectory.root)
        let fixture = try DataSafetyFixtures.make("a11y-path-boundary")
        XCTAssertEqual(fixture.deletingLastPathComponent(), TestFixtureDirectory.root)
        DataSafetyFixtures.preserve(fixture)
    }

    func testA01SmallFloatingLanguageLabelMeetsAAOnWhiteSlide() async throws {
        let (model, store) = try fixture()
        let preferences = FloatingSubtitlePreferences(store: store)
        preferences.sourceTextSize = 16
        preferences.translationTextSize = 16
        preferences.backgroundOpacity = 0.7
        model.loadPresentationForTesting(phase: .recording, evidence: [
            .init(startTime: 0, endTime: 2, english: "El agua está fría.", chinese: "水很冷。", sourceLanguage: "es")])
        let windowController = FloatingSubtitleWindowController(defaults: store)
        let controller = try await host(FloatingSubtitleView(windowController: windowController)
            .environmentObject(model).defaultAppStorage(store).background(Color.white), height: 330, dark: true)
        let counts = try histogram(capture(controller.view, "A01-floating-small-white-slide"))
        try assertContrast(counts, name: "floating-13pt-language", minimum: 4.5,
            foreground: { abs($0.r - 219) <= 1 && $0.r == $0.g && $0.g == $0.b && $0.a == 255 },
            background: { (70...110).contains($0.r) && $0.r == $0.g && $0.g == $0.b && $0.a == 255 })
        XCTAssertNotNil(try textNode("语种：西班牙语", in: controller.view))
    }

    func testA02RenderedReviewDifferenceContrastInBothAppearances() async throws {
        for dark in [false, true] {
            let controller = try await host(ReviewChangeView(original: "速度为 12 m/s。", proposed: "速度为 18 m/s。")
                .background(Color(nsColor: .textBackgroundColor)), width: 500, height: 190, dark: dark)
            let counts = try histogram(capture(controller.view, "A02-review-\(dark ? "dark" : "light")"))
            let background: (Pixel) -> Bool = { $0.r == $0.g && $0.g == $0.b && $0.a == 255 && (dark ? $0.r < 60 : $0.r > 240) }
            try assertContrast(counts, name: "review-proposed-\(dark)", minimum: 3,
                foreground: { $0.g > $0.r * 2 && $0.b > $0.r * 2 && $0.a == 255 }, background: background)
            try assertContrast(counts, name: "review-removed-\(dark)", minimum: 3,
                foreground: { $0.r > $0.g * 2 && $0.r > $0.b * 2 && $0.a == 255 }, background: background)
            _ = try textNode("速度为 12 m/s。", in: controller.view)
            _ = try textNode("速度为 18 m/s。", in: controller.view)
        }
    }

    func testA03CaptionAndImportantSettingsTextMeetSmallTextAA() async throws {
        let (model, store) = try fixture()
        let segment = TranscriptSegment(startTime: 10, endTime: 20, english: "El agua está fría.", chinese: "水很冷。", sourceLanguage: "es")
        for dark in [false, true] {
            let row = try await host(TranscriptCaptionRow(segment: segment, textSize: 18, stream: FinalCaptionState())
                .background(Color(nsColor: .textBackgroundColor)), width: 820, height: 180, dark: dark)
            let settings = try await host(ClassroomSettingsView().environmentObject(model).defaultAppStorage(store)
                .background(Color(nsColor: .windowBackgroundColor)), width: 520, height: 1500, dark: dark)
            for (name, view) in [("caption", row.view), ("settings", settings.view)] {
                let counts = try histogram(capture(view, "A03-\(name)-\(dark ? "dark" : "light")"))
                let core = dark ? 184 : 102
                try assertContrast(counts, name: "secondary-\(name)-\(dark)", minimum: 4.5,
                    foreground: { abs($0.r - core) <= 1 && $0.r == $0.g && $0.g == $0.b && $0.a == 255 },
                    background: { $0.r == $0.g && $0.g == $0.b && $0.a == 255 && (dark ? $0.r < 60 : $0.r > 240) })
            }
            _ = try textNode("实时暂存会在停止后删除临时录音并清空内容；录音期间可用“转为录音”保留这次课堂。", in: settings.view)
        }
    }

    /// Split the rendered formula into glyph columns; the right-hand digits
    /// isolate superscript ink, so growing only the base glyph cannot pass.
    private func scriptInkHeight(_ image: NSBitmapImageRep) throws -> Int {
        let bytes = try srgbPixels(image)
        var ink: [Int: [Int]] = [:]
        for x in 0..<image.pixelsWide {
            for y in 0..<image.pixelsHigh {
                let offset = (y * image.pixelsWide + x) * 4
                if bytes[offset + 3] > 230 && bytes[offset] < 128 { ink[x, default: []].append(y) }
            }
        }
        let columns = ink.keys.sorted()
        let first = try XCTUnwrap(columns.first)
        var lastBaseColumn = first
        for x in columns.dropFirst() {
            if x > lastBaseColumn + 1 { break }
            lastBaseColumn = x
        }
        let ys = ink.filter { $0.key > lastBaseColumn + 1 }.flatMap(\.value)
        return try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min()) + 1
    }

    func testA04ReadingScaleCoversNotesTimestampLanguageAndFormulaScripts() async throws {
        let formula = "$x^{2222}$"
        XCTAssertEqual(FormulaDisplay.runs(formula), [
            .init(text: "x", script: 0, math: true), .init(text: "2222", script: 1, math: true)
        ], "Every digit used by the ink measurement must be superscript, not body text")
        let normal = try await host(SummaryMarkdownView(text: formula).padding(16).background(Color.white), width: 360, height: 140)
        let enlarged = try await host(SummaryMarkdownView(text: formula).environment(\.classroomReadingScale, 2)
            .padding(16).background(Color.white), width: 360, height: 140)
        let first = try scriptInkHeight(capture(normal.view, "A04-script-normal"))
        let second = try scriptInkHeight(capture(enlarged.view, "A04-script-twofold"))
        XCTAssertGreaterThanOrEqual(Double(second) / Double(first), 1.8)
        XCTAssertEqual(ReadingTypography.scriptSize(bodySize: 36), 2 * ReadingTypography.scriptSize(bodySize: 18))
        XCTAssertEqual(ReadingTypography.scriptOffset(script: -1, bodySize: 36), -6)
        XCTAssertEqual(ReadingTypography.scriptOffset(script: 1, bodySize: 36), 10)
        let noteText = "## 合成课程要点\n速度为 12 m/s。\n- 合成条目"
        let notes = try await host(SummaryMarkdownView(text: noteText).padding(16).background(Color.white), width: 500, height: 320)
        let notesLarge = try await host(SummaryMarkdownView(text: noteText).environment(\.dynamicTypeSize, .accessibility5)
            .padding(16).background(Color.white), width: 500, height: 320)
        for text in ["合成课程要点", "速度为 12 m/s。", "合成条目"] {
            let n = try textNode(text, in: notes.view).frame
            let l = try textNode(text, in: notesLarge.view).frame
            XCTAssertGreaterThan(n.height, 0)
            XCTAssertGreaterThanOrEqual(l.height / n.height, 1.8, text)
        }
        _ = try capture(notes.view, "A04-notes-normal")
        _ = try capture(notesLarge.view, "A04-notes-accessibility5")
        let segment = TranscriptSegment(startTime: 10, endTime: 20, english: "El agua está fría.", chinese: "合成公式：$x^2 + H_2O$", sourceLanguage: "es")
        let small = try await host(TranscriptCaptionRow(segment: segment, textSize: 18, stream: FinalCaptionState())
            .background(Color.white), width: 820, height: 220)
        let large = try await host(TranscriptCaptionRow(segment: segment, textSize: 36, stream: FinalCaptionState())
            .background(Color.white), width: 820, height: 220)
        for text in ["00:10", "语种：西班牙语"] {
            let n = try textNode(text, in: small.view).frame
            let l = try textNode(text, in: large.view).frame
            XCTAssertGreaterThan(n.height, 0)
            XCTAssertGreaterThanOrEqual(l.height / n.height, 1.8, text)
        }
        _ = try capture(small.view, "A04-caption-normal")
        _ = try capture(large.view, "A04-caption-twofold")
        measurements.append(["normal_script_ink_height_px": first, "twofold_script_ink_height_px": second])
    }

    func testA04FloatingRespondsToSharedAndDynamicReadingSizesWithoutReplacingScrollViews() async throws {
        let (model, store) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: [
            .init(startTime: 0, endTime: 2, english: "El agua está fría.", chinese: "水很冷。", sourceLanguage: "es")])
        let floatingWindow = FloatingSubtitleWindowController(defaults: store)
        func root(_ dynamic: DynamicTypeSize) -> AnyView {
            AnyView(FloatingSubtitleView(windowController: floatingWindow).environmentObject(model)
                .defaultAppStorage(store).environment(\.dynamicTypeSize, dynamic))
        }
        let controller = try await host(root(.large), height: 380, dark: true)
        let original = try textNode("语种：西班牙语", in: controller.view).frame.height
        let scrolls = descendants(controller.view).compactMap { $0 as? NSScrollView }
        store.set(36.0, forKey: "transcriptTextSize")
        try await settle(controller.view)
        let shared = try textNode("语种：西班牙语", in: controller.view).frame.height
        XCTAssertGreaterThan(original, 0)
        XCTAssertGreaterThanOrEqual(shared / original, 1.8)
        let current = descendants(controller.view).compactMap { $0 as? NSScrollView }
        XCTAssertEqual(current.count, scrolls.count)
        for (index, scroll) in current.enumerated() where scrolls.indices.contains(index) { XCTAssertTrue(scroll === scrolls[index]) }
        _ = try capture(controller.view, "A04-floating-twofold")
        store.set(18.0, forKey: "transcriptTextSize")
        controller.rootView = root(.accessibility5)
        try await settle(controller.view)
        let dynamic = try textNode("语种：西班牙语", in: controller.view).frame.height
        XCTAssertGreaterThanOrEqual(dynamic / original, 1.8)
        _ = try capture(controller.view, "A04-floating-accessibility5")
    }

    func testA04FullClassroomKeepsReadingContentWithinWindowAtTwofold() async throws {
        let (model, store) = try fixture()
        let caption = TranscriptSegment(startTime: 10, endTime: 20, english: "El agua está fría.",
            chinese: "合成公式：$x^2 + H_2O$", sourceLanguage: "es")
        var notebook = LearningNotebook()
        try notebook.append(evidence: [caption], note: LearningNote(topic: "合成课程要点", points: [
            .init(kind: "核心结论", text: "合成公式：$x^2 + H_2O$。")]))
        model.loadPresentationForTesting(phase: .recording, evidence: [caption], notebook: notebook)
        store.set(36.0, forKey: "transcriptTextSize")
        for dark in [false, true] {
            let controller = try await host(ContentView().environmentObject(model).defaultAppStorage(store),
                                             width: 1440, height: 900, dark: dark)
            _ = try capture(controller.view, "A04-classroom-twofold-\(dark ? "dark" : "light")")
            let tree = nodes(controller.view)
            let heading = try XCTUnwrap(tree.first { node in
                node.value("accessibilityRole") as? String == "AXHeading"
                    && node.strings.contains { $0.contains("合成课程要点") }
            })
            let language = try textNode("语种：西班牙语", in: controller.view)
            XCTAssertGreaterThanOrEqual(heading.frame.height, 36)
            XCTAssertGreaterThanOrEqual(language.frame.height, 26)
            for node in [heading, language] {
                XCTAssertGreaterThanOrEqual(node.frame.minX, 0)
                XCTAssertLessThanOrEqual(node.frame.maxX, controller.view.bounds.width)
            }
            _ = try capture(controller.view, "A04-classroom-twofold-\(dark ? "dark" : "light")")
        }
    }

    func testA05MarkdownHeadingExposesARealHeadingRole() async throws {
        let controller = try await host(SummaryMarkdownView(text: "## 合成课程要点\n正文保持可读。")
            .padding(16).background(Color.white))
        let heading = try XCTUnwrap(nodes(controller.view).first {
            $0.strings.contains("合成课程要点") && $0.value("accessibilityRole") as? String == "AXHeading"
        }, "The actual AX tree must contain a heading for the Markdown title")
        XCTAssertEqual(heading.value("accessibilityRole") as? String, "AXHeading")
        _ = try textNode("正文保持可读。", in: controller.view)
        _ = try capture(controller.view, "A05-markdown-heading")
    }

    func testA06WaveformHasImageRoleAndDistinctNormalizedValues() async throws {
        for (samples, active, receiving, expected) in [
            ([Float](repeating: 0.02, count: 12), true, true, "平均强度 2%，短时峰值 2%"),
            ([Float](repeating: 0.9, count: 12), true, true, "平均强度 90%，短时峰值 90%"),
            ([Float](repeating: 0.9, count: 12), false, true, "已暂停"),
            ([Float](repeating: 0.9, count: 12), true, false, "暂无输入")
        ] {
            let controller = try await host(RecordingWaveform(samples: samples, active: active, receiving: receiving)
                .frame(width: 160, height: 40).background(Color(nsColor: .windowBackgroundColor)), width: 180, height: 60)
            let label = !active ? "音量显示已暂停" : receiving ? "正在接收音频" : "等待音频输入"
            let image = try textNode(label, in: controller.view)
            XCTAssertEqual(image.value("accessibilityRole") as? String, "AXImage")
            XCTAssertEqual(image.value("accessibilityValue") as? String, expected)
            _ = try capture(controller.view, "A06-waveform-\(active)-\(receiving)-\(samples[0])")
        }
        let stats = WaveformAccessibility(samples: [-1, 0.5, 2, .nan, .infinity])
        XCTAssertEqual(stats.mean, 0.3, accuracy: 0.00001)
        XCTAssertEqual(stats.peak, 1)
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, repeatKey: Bool = false) throws -> NSEvent {
        let chars = code == 51 ? "\u{7f}" : "\r"
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: repeatKey, keyCode: code))
    }

    func testA07CommandDeleteUsesNativeEditingUndoAndReadOnlyCancel() throws {
        let original = "Synthetic editable text"
        for custom in [false, true] {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 420, height: 120),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            let editor: NSTextView = custom ? TranslationInputTextView(frame: window.contentLayoutRect) : NSTextView(frame: window.contentLayoutRect)
            editor.isRichText = false
            editor.allowsUndo = true
            editor.string = original
            editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
            window.contentView = editor
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.keyDown(with: try key(51, .command))
            XCTAssertEqual(editor.string, "", "Custom and native editors must both delete to line start")
            editor.undoManager?.undo()
            XCTAssertEqual(editor.string, original)
            XCTAssertFalse(window.isVisible)
            if let custom = editor as? TranslationInputTextView {
                var cancelled = 0
                custom.onCancel = { cancelled += 1 }
                custom.isEditable = false
                XCTAssertTrue(custom.performKeyEquivalent(with: try key(51, .command)))
                XCTAssertEqual(custom.string, original)
                XCTAssertEqual(cancelled, 1)
                XCTAssertTrue(custom.performKeyEquivalent(with: try key(51, .command, repeatKey: true)))
                XCTAssertEqual(cancelled, 1)
            }
        }
    }

    func testA07EditingShortcutsKeepInputCompositionAndSubmitBehavior() throws {
        let editor = TranslationInputTextView(frame: .init(x: 0, y: 0, width: 420, height: 120))
        var submitted: [Bool] = [], cleared = 0
        editor.onSubmit = { submitted.append($0) }
        editor.onCancelAndClear = { cleared += 1 }
        editor.setMarkedText("合成", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.keyDown(with: try key(36, .command))
        XCTAssertTrue(submitted.isEmpty)
        editor.keyDown(with: try key(51, [.command, .shift]))
        XCTAssertEqual(cleared, 0)
        editor.unmarkText()
        editor.keyDown(with: try key(36, .command))
        editor.keyDown(with: try key(36, [.command, .shift]))
        editor.keyDown(with: try key(36, .command, repeatKey: true))
        XCTAssertEqual(submitted, [false, true])
    }

    func testA08AndU03ExportExplainsIndependentReviewScopeAndReplacement() async throws {
        let (model, _) = try fixture()
        model.exportScope = .latest
        model.exportIncludesReviewAdvice = true
        var exports = 0
        for dark in [false, true] {
            let controller = try await host(NotesExportOptions(model: model) { exports += 1 }
                .background(Color(nsColor: .windowBackgroundColor)), width: 380, height: 440, dark: dark)
            _ = try textNode(NotesExportDisclosure.scopeTitle, in: controller.view)
            _ = try textNode(NotesExportDisclosure.reviewHelp, in: controller.view)
            _ = try textNode(NotesExportDisclosure.fileHelp, in: controller.view)
            let toggle = try node("notes-export-review", in: controller.view)
            XCTAssertEqual(toggle.value("accessibilityHelp") as? String, NotesExportDisclosure.reviewHelp)
            XCTAssertFalse(nodes(controller.view).flatMap(\.strings).contains { $0.contains("不改动录音或已保存文件") })
            try press(node("notes-export-save", in: controller.view))
            try await settle(controller.view)
            _ = try capture(controller.view, "A08-U03-export-\(dark ? "dark" : "light")")
        }
        XCTAssertEqual(exports, 2)
    }

    private func candidate(_ text: String = "First candidate", id: UUID = UUID(), session: UUID = UUID(), start: Double = 10) -> TranscriptionCandidate {
        .init(id: id, sessionID: session, originalText: "Synthetic original", text: text,
              start: start, end: start + 10, audioURL: TestFixtureDirectory.root.appendingPathComponent("synthetic-unopened.wav"), origin: "context")
    }

    func testU01DirtyDraftKeepsItsSourceBindingUntilExplicitAcknowledgement() {
        let first = candidate()
        let initial = CandidateEditSource(candidate: first, revision: 1)
        let update = CandidateEditSource(candidate: candidate("Updated candidate", id: first.id, session: first.sessionID), revision: 2)
        var draft = CandidateEditDraft(source: initial)
        draft.text = "User draft"
        draft.receive(update)
        XCTAssertEqual(draft.text, "User draft")
        XCTAssertEqual(draft.source, initial, "Stale edits must keep their old session/revision/source binding")
        XCTAssertTrue(draft.hasConflict)
        draft.acknowledge(update)
        XCTAssertEqual(draft.source, update)
        XCTAssertEqual(draft.text, "User draft")
        XCTAssertFalse(draft.hasConflict)
        var untouched = CandidateEditDraft(source: initial)
        untouched.receive(update)
        XCTAssertEqual(untouched.text, "Updated candidate")
        XCTAssertFalse(untouched.hasConflict)
    }

    func testU01MountedEditorPreservesDirtyTextAndFocusAcrossCandidateUpdates() async throws {
        let (model, _) = try fixture()
        let first = candidate()
        func root(_ source: TranscriptionCandidate, _ revision: Int) -> AnyView {
            AnyView(TranscriptionCandidateEditor(model: model, candidate: source, revision: revision)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        let controller = try await host(root(first, 1), width: 820, height: 520)
        let editor = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(try XCTUnwrap(controller.view.window).makeFirstResponder(editor))
        editor.insertText("User draft", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try await settle(controller.view)
        XCTAssertEqual(editor.string, "User draft")
        let update = candidate("Updated candidate", id: first.id, session: first.sessionID)
        controller.rootView = AnyView(root(update, 2).environment(\.colorScheme, .light))
        try await settle(controller.view)
        let after = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(editor === after, "A source update must retain the native editor")
        XCTAssertTrue(controller.view.window?.firstResponder === editor)
        XCTAssertEqual(after.string, "User draft")
        _ = try node("candidate-source-conflict-\(first.id)", in: controller.view)
        let accept = try node("candidate-accept-\(first.id)", in: controller.view)
        XCTAssertEqual(accept.value("accessibilityEnabled") as? Bool, false)
        try press(node("candidate-acknowledge-\(first.id)", in: controller.view))
        try await settle(controller.view)
        XCTAssertEqual(editor.string, "User draft")
        XCTAssertEqual(try node("candidate-accept-\(first.id)", in: controller.view).value("accessibilityEnabled") as? Bool, true)
        _ = try capture(controller.view, "U01-preserved-candidate-draft")
    }

    func testU02RemovalConfirmationCannotDriftToTheNextFailedJob() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent("a11y-removal-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let batch = LearningNoteBatch(id: UUID(), evidence: [.init(startTime: 0, endTime: 8, english: "Synthetic evidence", chinese: "合成证据")],
            note: LearningNote(topic: "合成课程", points: [.init(kind: "核心结论", text: "合成要点。")]))
        var first = LearningReviewQueue.Job(directory: root.appendingPathComponent("Course A"), batches: [batch], original: "Synthetic A")
        var second = LearningReviewQueue.Job(directory: root.appendingPathComponent("Course B"), batches: [batch], original: "Synthetic B")
        first.failure = "Synthetic failure A"
        second.failure = "Synthetic failure B"
        for job in [first, second] { try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true) }
        let journal = root.appendingPathComponent("queue.json")
        try JSONEncoder().encode(LearningReviewQueue.Journal(jobs: [first, second], userPaused: true, version: LearningReviewQueue.journalVersion)).write(to: journal)
        let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
            XCTFail("Removal tests must never generate"); throw CancellationError()
        }
        addTeardownBlock { await queue.shutdownForTesting() }
        try await queue.waitForPendingStorage()
        let (_, store) = try fixture()
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: store)
        let manager = try await host(LearningReviewControls(model: model, showingQueueManager: .constant(true)),
                                     width: 700, height: 720)
        for job in [first, second] {
            for action in ["重试", "移到最后", "移出队列"] {
                _ = try textNode(ContextualActionName.review(action, name: job.directory.lastPathComponent, scope: job.scope), in: manager.view)
            }
        }
        _ = try capture(manager.view, "A09-U02-contextual-review-tasks")
        let target = try XCTUnwrap(queue.failedRemovalTarget)
        XCTAssertEqual(target.id, first.id)
        XCTAssertEqual(target.name, "Course A")
        XCTAssertEqual(target.scopeLabel, "整课")
        queue.removeJob(first.id)
        try await queue.waitForPendingStorage()
        try await Task.sleep(for: .milliseconds(180))
        queue.removeFailedJob(expected: target)
        XCTAssertEqual(queue.items.map(\.id), [second.id])
        XCTAssertEqual(queue.managementError, "确认的复查任务已变化，未移除任何任务；请重新查看队列。")
        XCTAssertEqual(try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal)).jobs.map(\.id), [second.id])
        let replacementTarget = try XCTUnwrap(queue.failedRemovalTarget)
        queue.removeFailedJob(expected: replacementTarget)
        try await queue.waitForPendingStorage()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal)).jobs.isEmpty)
    }

    func testA09CandidateActionsIncludeTimeRangeAndKeepAXReadingOrder() async throws {
        let (model, _) = try fixture()
        let one = candidate(start: 10), two = candidate(start: 30)
        let controller = try await host(VStack {
            TranscriptionCandidateEditor(model: model, candidate: one, revision: 1)
            TranscriptionCandidateEditor(model: model, candidate: two, revision: 1)
        }.background(Color(nsColor: .windowBackgroundColor)), width: 820, height: 920)
        for candidate in [one, two] {
            let orderedIDs = ["candidate-play-\(candidate.id)", "candidate-editor-\(candidate.id)", "candidate-accept-\(candidate.id)"]
            let actual = nodes(controller.view).compactMap(\.id).filter { orderedIDs.contains($0) }
            XCTAssertEqual(actual, orderedIDs)
            for action in ["回听", "保留原文", "确认采用编辑后的文字"] {
                _ = try textNode(ContextualActionName.candidate(action, start: candidate.start, end: candidate.end), in: controller.view)
            }
        }
        XCTAssertNotEqual(ContextualActionName.review("重试", name: "Course A", scope: nil),
                          ContextualActionName.review("重试", name: "Course B", scope: nil))
        _ = try capture(controller.view, "A09-contextual-candidate-actions")
    }

    func testKeyboardFocusCanMoveBetweenMountedCandidateEditorsAndReturn() async throws {
        let (model, _) = try fixture()
        let controller = try await host(VStack {
            TranscriptionCandidateEditor(model: model, candidate: candidate(start: 10), revision: 1)
            TranscriptionCandidateEditor(model: model, candidate: candidate(start: 30), revision: 1)
        }.background(Color(nsColor: .windowBackgroundColor)), width: 820, height: 920)
        let window = try XCTUnwrap(controller.view.window)
        let editors = descendants(controller.view).compactMap { $0 as? NSTextView }
        XCTAssertEqual(editors.count, 2)
        guard editors.count == 2 else { return }
        window.recalculateKeyViewLoop()
        XCTAssertTrue(window.makeFirstResponder(editors[0]))
        var route: [NSView] = []
        var current: NSView? = editors[0]
        while let view = current, route.count < 30, !route.contains(where: { $0 === view }) {
            route.append(view)
            current = view.nextValidKeyView
        }
        XCTAssertTrue(route.contains { $0 === editors[1] }, "The forward key-view loop must include the second real editor")
        for _ in 0..<30 {
            window.selectNextKeyView(nil)
            if window.firstResponder === editors[1] { break }
        }
        XCTAssertTrue(window.firstResponder === editors[1], "Native forward focus movement must reach the second editor")
        var reverse: [NSView] = []
        current = editors[1]
        while let view = current, reverse.count < 30, !reverse.contains(where: { $0 === view }) {
            reverse.append(view)
            current = view.previousValidKeyView
        }
        XCTAssertTrue(reverse.contains { $0 === editors[0] }, "The reverse key-view loop must include the first real editor")
        for _ in 0..<30 {
            window.selectPreviousKeyView(nil)
            if window.firstResponder === editors[0] { break }
        }
        XCTAssertTrue(window.firstResponder === editors[0], "Native reverse focus movement must return to the first editor")
        measurements.append(["forward_classes": route.map { String(describing: type(of: $0)) },
                             "reverse_classes": reverse.map { String(describing: type(of: $0)) }])
        _ = try capture(controller.view, "keyboard-candidate-focus-route")
    }
}
