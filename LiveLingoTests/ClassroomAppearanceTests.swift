import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

/// Hosted controls only: no AppModel, model loading, microphone or system settings.
@MainActor
final class ClassroomAppearanceTests: XCTestCase {
    private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)

    func testCompatibilityIsLimitedToMacOS14() {
        for minor in [0, 6, 7] {
            for patch in [0, 1, 6] {
                XCTAssertTrue(ClassroomAppearanceCompatibility.needsLegacyControls(on:
                    .init(majorVersion: 14, minorVersion: minor, patchVersion: patch)))
            }
        }
        for major in [13, 15, 16, 26, 27, 28] {
            XCTAssertFalse(ClassroomAppearanceCompatibility.needsLegacyControls(on:
                .init(majorVersion: major, minorVersion: 0, patchVersion: 0)))
        }
        XCTAssertEqual(ClassroomAppearanceCompatibility.needsLegacyControls(on:
            ProcessInfo.processInfo.operatingSystemVersion),
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 14)
    }

    func testGraphitePaletteMatchesTheDesignInBothAppearances() throws {
        for (name, expected) in [(NSAppearance.Name.aqua, 0x636366), (.darkAqua, 0x747479)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(ClassroomPalette.accent).usingColorSpace(.sRGB)
            }
            let color = try XCTUnwrap(resolved)
            let hex = Int((color.redComponent * 255).rounded()) << 16
                | Int((color.greenComponent * 255).rounded()) << 8
                | Int((color.blueComponent * 255).rounded())
            XCTAssertEqual(hex, expected)
            XCTAssertEqual(color.alphaComponent, 1)
        }
    }

    func testModernHostedControlsAndToolbarKeepIdenticalPixels() async throws {
        guard !ClassroomAppearanceCompatibility.needsLegacyControls(on:
            ProcessInfo.processInfo.operatingSystemVersion) else {
            throw XCTSkip("The unchanged modern rendering path requires macOS 15 or newer")
        }
        for dark in [false, true] {
            for enabled in [true, false] {
                let controller = NSHostingController(rootView:
                    AppearanceFixture(updated: false, enabled: enabled, dark: dark))
                controller.sceneBridgingOptions = [.toolbars, .title]
                let window = makeWindow(controller: controller, dark: dark)
                defer { window.close() }
                try await settle(controller.view)
                let contentBefore = try pixels(controller.view)
                let frameBefore = try pixels(try XCTUnwrap(window.contentView?.superview))
                controller.rootView = AppearanceFixture(updated: true, enabled: enabled, dark: dark)
                try await settle(controller.view)
                let contentAfter = try pixels(controller.view)
                let frameAfter = try pixels(try XCTUnwrap(window.contentView?.superview))
                let name = "modern-\(dark ? "dark" : "light")-\(enabled ? "enabled" : "disabled")"
                attach(contentBefore, name: name + "-original-content")
                attach(contentAfter, name: name + "-updated-content")
                attach(frameBefore, name: name + "-original-toolbar")
                attach(frameAfter, name: name + "-updated-toolbar")
                assertPixelMatch(contentBefore, contentAfter, name: name + " content")
                assertPixelMatch(frameBefore, frameAfter, name: name + " toolbar")
                if enabled {
                    XCTAssertGreaterThan(contentAfter.count(hex: dark ? 0x747479 : 0x636366, tolerance: 8), 500,
                        "The active prominent control must actually render graphite, not inactive gray")
                }
                print("APPEARANCE_PIXEL_MATCH \(name) content=\(contentAfter.width)x\(contentAfter.height) toolbar=\(frameAfter.width)x\(frameAfter.height)")
            }
        }
    }

    func testModernPixelComparisonRejectsARedTintMutation() async throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
            throw XCTSkip("The native modern tint mutation requires macOS 15 or newer")
        }
        for dark in [false, true] {
            let controller = NSHostingController(rootView:
                AppearanceFixture(updated: false, enabled: true, dark: dark))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = makeWindow(controller: controller, dark: dark)
            defer { window.close() }
            try await settle(controller.view)
            let original = try pixels(controller.view)
            controller.rootView = AppearanceFixture(updated: true, enabled: true, dark: dark, tint: .red)
            try await settle(controller.view)
            let mutated = try pixels(controller.view)
            let changed = zip(original.rgba, mutated.rgba).filter { $0 != $1 }.count
            XCTAssertGreaterThan(changed, 500, "An inactive or blank capture cannot detect a tint regression")
            // Strict expected failure: if the equality assertion accepts red,
            // this test fails because the deliberately broken tint went undetected.
            XCTExpectFailure("A red tint must fail the same pixel assertion used by the modern regression test") {
                assertPixelMatch(original, mutated, name: "deliberate red tint mutation")
            }
            attach(mutated, name: "modern-\(dark ? "dark" : "light")-red-mutation")
            print("APPEARANCE_TINT_MUTATION_REJECTED dark=\(dark) changedChannels=\(changed)")
        }
    }

    func testFollowLatestUsesTheSameGrayInBothCompatibilityPaths() async throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
            throw XCTSkip("Compare both modifier chains using the same modern native renderer")
        }
        for dark in [false, true] {
            for selected in [false, true] {
                func root(version: OperatingSystemVersion) -> some View {
                    Toggle("跟随最新", isOn: .constant(selected))
                        .toggleStyle(.button).controlSize(.small)
                        .classroomTint(.gray, on: version)
                        .padding(24)
                        .frame(width: 200, height: 80)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.controlActiveState, .key)
                }
                let controller = NSHostingController(rootView:
                    root(version: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
                let window = makeWindow(controller: controller, dark: dark)
                defer { window.close() }
                try await settle(controller.view)
                let modern = try pixels(controller.view)
                controller.rootView = root(version: sonoma)
                try await settle(controller.view)
                assertPixelMatch(modern, try pixels(controller.view),
                    name: "follow latest dark=\(dark) selected=\(selected)")
            }
        }
    }

    func testLegacyPrimaryButtonHasAnOpaqueGraphiteFill() async throws {
        for (dark, expected) in [(false, 0x636366), (true, 0x747479)] {
            let controller = NSHostingController(rootView: Button("开始记录") {}
                .classroomToolbarPrimaryStyle(on: sonoma)
                .classroomTint(ClassroomPalette.accent, on: sonoma)
                .frame(width: 200, height: 80)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key))
            let window = makeWindow(controller: controller, dark: dark)
            defer { window.close() }
            try await settle(controller.view)
            let image = try pixels(controller.view)
            XCTAssertGreaterThan(image.count(hex: UInt32(expected)), 500, "The primary control needs a solid graphite interior")
            attach(image, name: "legacy-primary-\(dark ? "dark" : "light")")
        }
    }

    func testLegacyPrimaryButtonRespondsToContrastAndInactiveState() async throws {
        for dark in [false, true] {
            func root(active: ControlActiveState, contrast: ColorSchemeContrast) -> some View {
                Button("开始记录") {}
                    .buttonStyle(ClassroomLegacyPrimaryButtonStyle(contrastForTesting: contrast))
                    .frame(width: 200, height: 80)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, active)
            }
            let controller = NSHostingController(rootView: root(active: .key, contrast: .standard))
            let window = makeWindow(controller: controller, dark: dark)
            defer { window.close() }
            try await settle(controller.view)
            let active = try pixels(controller.view)
            let graphite: UInt32 = dark ? 0x747479 : 0x636366
            XCTAssertGreaterThan(active.count(hex: graphite), 500)
            controller.rootView = root(active: .key, contrast: .increased)
            try await settle(controller.view)
            let outlined = try pixels(controller.view)
            XCTAssertNotEqual(active.rgba, outlined.rgba, "Increase Contrast must add a visible outline")
            let outline = try compositedOutlineHex(against: graphite, appearance: XCTUnwrap(window.appearance))
            XCTAssertGreaterThan(outlined.count(hex: outline, tolerance: 8),
                                 active.count(hex: outline, tolerance: 8) + 100,
                                 "The high-contrast outline must use the semantic label color")
            controller.rootView = root(active: .inactive, contrast: .standard)
            try await settle(controller.view)
            let inactive = try pixels(controller.view)
            XCTAssertNotEqual(active.rgba, inactive.rgba, "Inactive must use the unemphasized semantic colors")
            XCTAssertEqual(inactive.count(hex: graphite), 0, "Inactive must not retain the active graphite fill")
            controller.rootView = root(active: .key, contrast: .standard)
            try await settle(controller.view)
            assertPixelMatch(active, try pixels(controller.view), name: "reactivated legacy primary")
            attach(outlined, name: "legacy-primary-\(dark ? "dark" : "light")-increased-contrast")
            attach(inactive, name: "legacy-primary-\(dark ? "dark" : "light")-inactive-environment")
        }
    }

    func testLegacyPrimaryButtonPreservesItsActionAndDisabledState() async throws {
        var actions = 0
        func root(enabled: Bool) -> some View {
            Button("开始记录") { actions += 1 }
                .classroomToolbarPrimaryStyle(on: sonoma)
                .disabled(!enabled)
                .frame(width: 200, height: 80)
                .environment(\.controlActiveState, .key)
        }
        let controller = NSHostingController(rootView: root(enabled: true))
        let window = makeWindow(controller: controller, dark: false)
        defer { window.close() }
        try await settle(controller.view)
        let enabledPixels = try pixels(controller.view)
        try clickCenter(of: controller.view, in: window)
        XCTAssertEqual(actions, 1)
        controller.rootView = root(enabled: false)
        try await settle(controller.view)
        let disabledPixels = try pixels(controller.view)
        XCTAssertNotEqual(enabledPixels.rgba, disabledPixels.rgba, "Disabled must have visible feedback")
        try clickCenter(of: controller.view, in: window)
        XCTAssertEqual(actions, 1, "Disabled must not run the recording action")
    }

    private func makeWindow<V: View>(controller: NSHostingController<V>, dark: Bool) -> NSWindow {
        let window = AppearanceTestWindow(contentRect: NSRect(x: 100, y: 100, width: 460, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ view: NSView) async throws {
        let window = try XCTUnwrap(view.window)
        XCTAssertTrue(window.isKeyWindow, "Tint evidence requires a key window")
        XCTAssertTrue(window.isMainWindow, "Tint evidence requires a main window")
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let rgba: Data
        let png: Data

        func count(hex: UInt32, tolerance: Int = 0) -> Int {
            let expected = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
            return stride(from: 0, to: rgba.count, by: 4).filter { index in
                rgba[index + 3] == 255 && (0..<3).allSatisfy {
                    abs(Int(rgba[index + $0]) - expected[$0]) <= tolerance
                }
            }.count
        }
    }

    private func pixels(_ view: NSView) throws -> Pixels {
        XCTAssertTrue(try XCTUnwrap(view.window).isKeyWindow, "The window must remain key at capture time")
        XCTAssertTrue(try XCTUnwrap(view.window).isMainWindow, "The window must remain main at capture time")
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let width = image.width
        let height = image.height
        var rgba = Data(count: width * height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        XCTAssertGreaterThan(Set(rgba).count, 4, "A blank host is not pixel evidence")
        return Pixels(width: width, height: height, rgba: rgba,
                      png: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
    }

    private func assertPixelMatch(_ original: Pixels, _ updated: Pixels, name: String) {
        XCTAssertEqual(original.width, updated.width, name)
        XCTAssertEqual(original.height, updated.height, name)
        XCTAssertEqual(original.rgba, updated.rgba, "Pixels changed: \(name)")
    }

    private func compositedOutlineHex(against background: UInt32, appearance: NSAppearance) throws -> UInt32 {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.usingColorSpace(.sRGB)
        }
        let color = try XCTUnwrap(resolved)
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        let base = [background >> 16 & 0xFF, background >> 8 & 0xFF, background & 0xFF]
        let blended = zip(components, base).map {
            UInt32(($0 * color.alphaComponent * 255 + CGFloat($1) * (1 - color.alphaComponent)).rounded())
        }
        return blended[0] << 16 | blended[1] << 8 | blended[2]
    }

    private func attach(_ pixels: Pixels, name: String) {
        let attachment = XCTAttachment(data: pixels.png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func clickCenter(of view: NSView, in window: NSWindow) throws {
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }
}

/// Force native key/main queries for deterministic hosted rendering. This is
/// test evidence, not a claim that the host became the foreground application.
private final class AppearanceTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// The original arm spells out the pre-fix modifier chains. Compare it with
/// the production compatibility helpers in the same forced-key/main host.
private struct AppearanceFixture: View {
    let updated: Bool
    let enabled: Bool
    let dark: Bool
    var tint: Color = ClassroomPalette.accent

    private var controls: some View {
        VStack(spacing: 14) {
            if updated {
                Toggle("跟随最新", isOn: .constant(true))
                    .toggleStyle(.button).controlSize(.small)
                    .classroomTint(.gray)
                Toggle("跟随最新", isOn: .constant(false))
                    .toggleStyle(.button).controlSize(.small)
                    .classroomTint(.gray)
            } else {
                Toggle("跟随最新", isOn: .constant(true))
                    .toggleStyle(.button).controlSize(.small).tint(.gray)
                Toggle("跟随最新", isOn: .constant(false))
                    .toggleStyle(.button).controlSize(.small).tint(.gray)
            }
            Toggle("专注模式", isOn: .constant(true))
            Picker("阅读内容", selection: .constant(0)) {
                Text("字幕").tag(0)
                Text("笔记").tag(1)
            }
            .pickerStyle(.segmented)
            Button("翻译") {}.buttonStyle(.borderedProminent)
        }
        .disabled(!enabled)
    }

    var body: some View {
        Group {
            if updated { controls.classroomTint(tint) }
            else { controls.tint(ClassroomPalette.accent) }
        }
        .padding(24)
        .frame(width: 460, height: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.controlActiveState, .key)
        .navigationTitle("实时课堂")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if updated {
                    primaryButton.classroomToolbarPrimaryStyle().classroomTint(tint)
                        .disabled(!enabled)
                } else {
                    primaryButton.buttonStyle(.borderedProminent).tint(ClassroomPalette.accent)
                        .disabled(!enabled)
                }
            }
        }
    }

    private var primaryButton: some View {
        Button {} label: {
            Label("开始记录", systemImage: "record.circle").labelStyle(.titleAndIcon)
        }
    }
}
