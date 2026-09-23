import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    enum TranslationState: String, Codable, Sendable {
        case pending, translating, completed, failed
    }

    let id: UUID
    let sessionID: UUID?
    var inputRevision: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let english: String
    var chinese: String {
        didSet { reconcileLegacyTranslation() }
    }
    private(set) var translationState: TranslationState
    private(set) var translationError: String?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        english: String,
        chinese: String = "",
        sessionID: UUID? = nil,
        inputRevision: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.inputRevision = max(0, inputRevision)
        self.startTime = max(0, startTime)
        self.endTime = max(startTime, endTime)
        self.english = english
        self.chinese = chinese
        self.translationState = .pending
        self.translationError = nil
        reconcileLegacyTranslation()
    }

    var hasUsableTranslation: Bool {
        translationState == .completed && !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One rendering rule for saved transcripts, the classroom and all exports.
    /// The floating window continues to use its separate initial translation.
    var displayChinese: String {
        switch translationState {
        case .completed: return chinese
        case .failed: return "（本段翻译未完成，可对照英文）"
        case .pending, .translating: return "（本段暂无译文）"
        }
    }

    mutating func beginTranslation() {
        translationState = .translating
        translationError = nil
    }

    mutating func completeTranslation(_ text: String) {
        chinese = text
    }

    mutating func failTranslation(_ error: String) {
        chinese = ""
        translationState = .failed
        translationError = error
    }

    mutating func deferTranslation() {
        guard translationState == .translating else { return }
        translationState = .pending
    }

    // This is the only compatibility boundary that interprets the old marker.
    // New failures store diagnostics separately from translated content.
    private mutating func reconcileLegacyTranslation() {
        let text = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[翻译失败：") {
            translationState = .failed
            translationError = String(text.dropFirst("[翻译失败：".count).dropLast(text.hasSuffix("]") ? 1 : 0))
        } else {
            translationState = text.isEmpty ? .pending : .completed
            translationError = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, inputRevision, startTime, endTime, english, chinese, translationState, translationError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID)
        inputRevision = try values.decodeIfPresent(Int.self, forKey: .inputRevision) ?? 0
        startTime = try values.decode(TimeInterval.self, forKey: .startTime)
        endTime = try values.decode(TimeInterval.self, forKey: .endTime)
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime >= startTime, inputRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .startTime, in: values,
                                                   debugDescription: "Invalid transcript time range or revision")
        }
        english = try values.decode(String.self, forKey: .english)
        chinese = try values.decodeIfPresent(String.self, forKey: .chinese) ?? ""
        translationState = .pending
        translationError = nil
        reconcileLegacyTranslation()
        if let storedState = try values.decodeIfPresent(TranslationState.self, forKey: .translationState) {
            guard storedState != .completed || hasUsableTranslation else {
                throw DecodingError.dataCorruptedError(forKey: .translationState, in: values,
                                                       debugDescription: "Completed translation has no usable content")
            }
            translationState = storedState
            translationError = try values.decodeIfPresent(String.self, forKey: .translationError)
        }
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
