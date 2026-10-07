import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    enum TranslationState: String, Codable, Sendable {
        case pending, translating, completed, failed
    }

    /// Metadata only. Never derive a category from an error's free-form text.
    enum TranslationFailureReason: String, Codable, CaseIterable, Sendable {
        case processExited, requestTimedOut, outputLimitReached, translationRejected
        case cancelled, interrupted, runtimeUnavailable, invalidResponse
        case generationInterrupted, requestFailed, unknown
        case dependencyCancelled

        static func category(for error: Error) -> Self {
            if error is CancellationError { return .dependencyCancelled }
            if error is DecodingError { return .invalidResponse }
            if let error = error as? URLError {
                if error.code == .timedOut { return .requestTimedOut }
                if error.code == .cancelled { return .dependencyCancelled }
            }
            if let error = error as? POSIXError, error.code == .EPIPE { return .processExited }
            guard let error = error as? QwenRuntimeError else { return .unknown }
            switch error {
            case .processExited: return .processExited
            case .transcriptionTimedOut, .requestTimedOut: return .requestTimedOut
            case .outputLimitReached: return .outputLimitReached
            case .translationRejected: return .translationRejected
            case .serviceUnavailable, .lmStudioUnavailable, .modelUnavailable, .runtimeUnavailable:
                return .runtimeUnavailable
            case .invalidResponse: return .invalidResponse
            case .generationInterrupted: return .generationInterrupted
            case .requestFailed: return .requestFailed
            }
        }
    }

    struct TranslationFailure: Codable, Equatable, Sendable {
        let reason: TranslationFailureReason
        var count: Int

        private enum CodingKeys: String, CodingKey { case reason, count }

        init(reason: TranslationFailureReason, count: Int) {
            self.reason = reason
            self.count = count
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            reason = TranslationFailureReason(rawValue: try values.decode(String.self, forKey: .reason)) ?? .unknown
            count = try values.decode(Int.self, forKey: .count)
            guard count > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .count, in: values,
                    debugDescription: "Invalid translation failure count")
            }
        }
    }

    let id: UUID
    let sessionID: UUID?
    var inputRevision: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Original source text; the legacy `english` key stays readable by 0.2.0.
    let english: String
    /// Nil is the existing English path. Only supported non-English codes persist.
    private(set) var sourceLanguage: String?
    /// In-memory provenance only. A 0.2.0 predecessor has no marker, even when
    /// its Chinese content lets the new decoder infer zh (including old yue).
    private var sourceLanguageWasInferred = false
    var chinese: String {
        didSet { reconcileLegacyTranslation() }
    }
    private(set) var translationState: TranslationState
    private(set) var translationError: String?
    /// Absent on the normal path and ignored by 0.2.0. Successful retries keep
    /// the trail, so intermittent failures remain diagnosable after saving.
    private(set) var translationFailures: [TranslationFailure] = []

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        english: String,
        chinese: String = "",
        sessionID: UUID? = nil,
        inputRevision: Int = 0,
        sourceLanguage: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.inputRevision = max(0, inputRevision)
        self.startTime = max(0, startTime)
        self.endTime = max(startTime, endTime)
        self.english = english
        self.sourceLanguage = SpokenLanguage.nonEnglishCode(sourceLanguage)
        self.chinese = chinese
        self.translationState = .pending
        self.translationError = nil
        reconcileLegacyTranslation()
    }

    var hasUsableTranslation: Bool {
        translationState == .completed && !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An inferred 0.2.0 marker is not evidence of an explicit language choice.
    /// This is in-memory provenance, never an additional persisted field.
    var hasExplicitSourceLanguage: Bool { sourceLanguage != nil && !sourceLanguageWasInferred }

    /// Diagnostics belong to the transcript archive, never to frozen learning
    /// evidence or its digest. Preserve every content and provenance field.
    var withoutTranslationFailures: Self {
        var evidence = self
        evidence.translationFailures = []
        return evidence
    }

    /// Old builds omit language metadata when writing an inputRevision. The
    /// predecessor must still match every content, identity and translation field.
    func sameContent(as other: Self) -> Bool {
        var left = self, right = other
        if left.sourceLanguage == nil || right.sourceLanguage == nil
            || left.sourceLanguageWasInferred || right.sourceLanguageWasInferred {
            left.sourceLanguage = nil
            right.sourceLanguage = nil
        }
        // A 0.2.0 revision cannot carry the optional diagnostic trail.
        if left.translationFailures.isEmpty || right.translationFailures.isEmpty {
            left.translationFailures = []
            right.translationFailures = []
        }
        return left == right
    }

    static func == (left: Self, right: Self) -> Bool {
        left.id == right.id && left.sessionID == right.sessionID && left.inputRevision == right.inputRevision
            && left.startTime == right.startTime && left.endTime == right.endTime
            && left.english == right.english && left.chinese == right.chinese
            && left.translationState == right.translationState && left.translationError == right.translationError
            && left.translationFailures == right.translationFailures
            && left.sourceLanguage == right.sourceLanguage
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

    mutating func recordTranslationFailure(_ reason: TranslationFailureReason) {
        addTranslationFailure(reason, count: 1)
        translationError = nil
    }

    /// Called only after recording all failed attempts. New failures never
    /// persist an arbitrary runtime message in translationError or Chinese.
    mutating func finishFailedTranslation() {
        precondition(!translationFailures.isEmpty)
        chinese = ""
        translationState = .failed
        translationError = nil
    }

    private mutating func addTranslationFailure(_ reason: TranslationFailureReason, count: Int) {
        let index = translationFailures.firstIndex { $0.reason == reason }
        let previous = index.map { translationFailures.remove(at: $0).count } ?? 0
        let (sum, overflow) = previous.addingReportingOverflow(count)
        translationFailures.append(.init(reason: reason, count: overflow ? Int.max : sum))
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
        case id, sessionID, inputRevision, startTime, endTime, english, chinese, translationState, translationError, sourceLanguage
        case translationFailures
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(sessionID, forKey: .sessionID)
        try values.encode(inputRevision, forKey: .inputRevision)
        try values.encode(startTime, forKey: .startTime)
        try values.encode(endTime, forKey: .endTime)
        try values.encode(english, forKey: .english)
        try values.encode(chinese, forKey: .chinese)
        try values.encode(translationState, forKey: .translationState)
        try values.encodeIfPresent(translationError, forKey: .translationError)
        if !translationFailures.isEmpty { try values.encode(translationFailures, forKey: .translationFailures) }
        // Preserve marker absence across the journal's encode/decode boundary;
        // otherwise an inferred zh becomes explicit and rejects an old yue revision.
        if !sourceLanguageWasInferred { try values.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage) }
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
        let storedLanguage = try values.decodeIfPresent(String.self, forKey: .sourceLanguage)
        sourceLanguage = SpokenLanguage.nonEnglishCode(storedLanguage)
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
        // This optional trail cannot make otherwise valid course content
        // unreadable. Consume entries independently so a bad one does not
        // discard its valid neighbours; core segment fields remain strict.
        if var failures = try? values.nestedUnkeyedContainer(forKey: .translationFailures) {
            while !failures.isAtEnd {
                guard let entry = try? failures.superDecoder() else { break }
                guard let failure = try? TranslationFailure(from: entry) else { continue }
                addTranslationFailure(failure.reason, count: failure.count)
            }
        }
        if storedLanguage == nil, translationState == .completed, english == chinese,
           EnglishTranscriptGate.verdict(english) == .hanDominant {
            sourceLanguage = "zh"
            sourceLanguageWasInferred = true
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
