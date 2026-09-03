import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let english: String
    var chinese: String

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        english: String,
        chinese: String = ""
    ) {
        self.id = id
        self.startTime = max(0, startTime)
        self.endTime = max(startTime, endTime)
        self.english = english
        self.chinese = chinese
    }
}

enum SessionStorageMode: String, CaseIterable, Identifiable, Sendable {
    case saveSession
    case liveOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saveSession: return "录音"
        case .liveOnly: return "实时"
        }
    }

    var persistsSession: Bool { self == .saveSession }
    var clearsHistoryWhenStopped: Bool { self == .liveOnly }
    var requiresOutputDirectoryBeforeStart: Bool { self == .saveSession }
    var usesTemporaryRecording: Bool { self == .liveOnly }
}

enum AudioInputMode: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统音频（内录）"
        }
    }

    var activeTitle: String {
        switch self {
        case .microphone: return "录音中"
        case .systemAudio: return "内录中"
        }
    }

    var statusIcon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.2.fill"
        }
    }
}

enum AppPhase: Equatable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case saved(URL)
    case liveEnded
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .paused, .stopping:
            return true
        default:
            return false
        }
    }
}
