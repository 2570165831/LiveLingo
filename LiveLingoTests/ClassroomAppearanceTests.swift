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
                XCTAssertEqual(contentBefore.width, contentAfter.width, name)
                XCTAssertEqual(contentBefore.height, contentAfter.height, name)
                XCTAssertEqual(contentBefore.rgba, contentAfter.rgba, "Content pixels changed: \(name)")
                XCTAssertEqual(frameBefore.width, frameAfter.width, name)
                XCTAssertEqual(frameBefore.height, frameAfter.height, name)
                XCTAssertEqual(frameBefore.rgba, frameAfter.rgba, "Toolbar pixels changed: \(name)")
                print("APPEARANCE_PIXEL_MATCH \(name) content=\(contentAfter.width)x\(contentAfter.height) toolbar=\(frameAfter.width)x\(frameAfter.height)")
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
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = makeWindow(controller: controller, dark: dark)
            defer { window.close() }
            try await settle(controller.view)
            let image = try pixels(controller.view)
            var matchingPixels = 0
            for index in stride(from: 0, to: image.rgba.count, by: 4) {
                let hex = Int(image.rgba[index]) << 16 | Int(image.rgba[index + 1]) << 8 | Int(image.rgba[index + 2])
                if hex == expected && image.rgba[index + 3] == 255 { matchingPixels += 1 }
            }
            XCTAssertGreaterThan(matchingPixels, 500, "The primary control needs a solid graphite interior")
            attach(image, name: "legacy-primary-\(dark ? "dark" : "light")")
        }
    }

    func testLegacyPrimaryButtonPreservesItsActionAndDisabledState() async throws {
        var actions = 0
        func root(enabled: Bool) -> some View {
            Button("开始记录") { actions += 1 }
                .classroomToolbarPrimaryStyle(on: sonoma)
                .disabled(!enabled)
                .frame(width: 200, height: 80)
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
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 460, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ view: NSView) async throws {
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
    }

    private func pixels(_ view: NSView) throws -> Pixels {
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

/// The original arm spells out the pre-fix modifier chains. Compare it with
/// the production compatibility helpers in the same active native window.
private struct AppearanceFixture: View {
    let updated: Bool
    let enabled: Bool
    let dark: Bool

    private var controls: some View {
        VStack(spacing: 14) {
            if updated {
                Toggle("跟随最新", isOn: .constant(true))
                    .toggleStyle(.button).controlSize(.small)
                    .classroomTint(.gray, legacyColor: ClassroomPalette.accent)
                Toggle("跟随最新", isOn: .constant(false))
                    .toggleStyle(.button).controlSize(.small)
                    .classroomTint(.gray, legacyColor: ClassroomPalette.accent)
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
            if updated { controls.classroomTint(ClassroomPalette.accent) }
            else { controls.tint(ClassroomPalette.accent) }
        }
        .padding(24)
        .frame(width: 460, height: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        .navigationTitle("实时课堂")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if updated {
                    primaryButton.classroomToolbarPrimaryStyle().classroomTint(ClassroomPalette.accent)
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
