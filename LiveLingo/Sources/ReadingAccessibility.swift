import AppKit
import SwiftUI

/// Explicit sRGB text colors keep small explanatory text readable on both
/// window and card surfaces. Decorative strokes still use semantic secondary.
enum ReadingAccessibility {
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(srgbRed: dark ? 0.72 : 0.40,
                       green: dark ? 0.72 : 0.40, blue: dark ? 0.72 : 0.40, alpha: 1)
    })
    static let proposedText = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(Color.teal)
        }
        return NSColor(srgbRed: 0, green: 0.43, blue: 0.46, alpha: 1)
    })
}

private struct ClassroomReadingScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var classroomReadingScale: Double {
        get { self[ClassroomReadingScaleKey.self] }
        set { self[ClassroomReadingScaleKey.self] = newValue }
    }
}

enum ReadingTypography {
    static func scale(textSize: Double, dynamicType: DynamicTypeSize = .large) -> Double {
        max(textSize.isFinite ? min(2, max(1, textSize / 18)) : 1, dynamicScale(dynamicType))
    }

    static func dynamicScale(_ size: DynamicTypeSize) -> Double {
        switch size {
        case .xLarge: 1.12
        case .xxLarge: 1.24
        case .xxxLarge: 1.36
        case .accessibility1: 1.4
        case .accessibility2: 1.55
        case .accessibility3: 1.7
        case .accessibility4: 1.85
        case .accessibility5: 2
        default: 1
        }
    }

    static func scriptSize(bodySize: Double, baseBodySize: Double = 18) -> Double { bodySize * 10 / baseBodySize }
    static func scriptOffset(script: Int, bodySize: Double, baseBodySize: Double = 18) -> Double {
        bodySize * (script < 0 ? -3 : 5) / baseBodySize
    }
}

/// The legacy key and all three existing presets remain readable by old apps.
struct ReadingSizePicker: View {
    @Binding var size: Double
    var title = "阅读字号"

    var body: some View {
        Picker(selection: $size) {
            Text("标准").tag(18.0)
            Text("大").tag(21.0)
            Text("特大").tag(24.0)
            Text("两倍").tag(36.0)
        } label: {
            Label(title, systemImage: "textformat.size")
        }
        .help("同步放大字幕、笔记、时间戳与公式；悬浮字幕在独立字号基础上缩放")
    }
}

enum NotesExportDisclosure {
    static let scopeTitle = "笔记与字幕范围"
    static let reviewHelp = "核对意见包含本课其他范围和历史版本的已保存报告，不受笔记与字幕范围限制。"
    static let fileHelp = "导出只读取当前笔记与复查记录，不调用模型、不会自动改动录音或课程文件；所选已有导出目标可能被替换。默认文件名包含课堂日期与内容范围。"
}

enum ContextualActionName {
    static func review(_ action: String, name: String, scope: LearningReviewScope?) -> String {
        "\(action)：\(name)，\(scope?.label ?? "整课复查")"
    }
    static func candidate(_ action: String, start: TimeInterval, end: TimeInterval) -> String {
        "\(action)：\(LearningTimeLabel.stamp(start)) 至 \(LearningTimeLabel.stamp(end)) 的候选"
    }
}

struct WaveformAccessibility {
    let mean: Double
    let peak: Double

    static func normalized(_ sample: Float) -> Float {
        sample.isFinite ? min(1, max(0, sample)) : 0
    }

    init(samples: [Float]) {
        let levels = samples.map { Double(Self.normalized($0)) }
        mean = levels.isEmpty ? 0 : levels.reduce(0, +) / Double(levels.count)
        peak = levels.max() ?? 0
    }

    func value(active: Bool, receiving: Bool) -> String {
        guard active else { return "已暂停" }
        guard receiving else { return "暂无输入" }
        return "平均强度 \(Int((mean * 100).rounded()))%，短时峰值 \(Int((peak * 100).rounded()))%"
    }
}
