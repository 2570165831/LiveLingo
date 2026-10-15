import Combine
import Darwin
import Foundation

enum ChineseRecognitionStatus: Equatable, Sendable {
    case waitingForRealtime, pending, recognizing, saving, cancelled, failed(String), completed
}

struct ChineseRecognitionAvailability: Equatable, Sendable {
    var isAvailable: Bool
    var reason: String?

    static let available = Self(isAvailable: true, reason: nil)
    static func unavailable(_ reason: String) -> Self { .init(isAvailable: false, reason: reason) }
}

@MainActor
final class ChineseRecognitionPresentationState: ObservableObject {
    @Published var statuses: [UUID: ChineseRecognitionStatus] = [:]
    @Published var courseActionsAvailability = ChineseRecognitionAvailability.unavailable(
        "当前课程暂不能修改字幕，请在课堂中或打开已保存课程后操作。")
}

@MainActor
struct ChineseRecognitionDependencies {
    var recognize: (URL, String) async throws -> ASRTranscription
    var waitForInference: () async throws -> Void

    init(recognize: @escaping (URL, String) async throws -> ASRTranscription) {
        self.recognize = recognize
        self.waitForInference = {}
    }

    init(waitForInference: @escaping () async throws -> Void,
         recognize: @escaping (URL, String) async throws -> ASRTranscription) {
        self.recognize = recognize
        self.waitForInference = waitForInference
    }

    static var live: Self {
        Self(waitForInference: {
            try await ASRRequestCoordinator.shared.waitForChineseInferenceCompletion()
        }) { audio, requestID in
            try await QwenASRClient.transcribe(audioURL: audio, modelKey: "1.7b",
                enhanceSpeech: true, language: .chinese, requestID: requestID)
        }
    }
    static let unavailable = Self { _, _ in throw QwenRuntimeError.runtimeUnavailable }
}

/// Resolve only the caption's complete recorded range. Never silently submit
/// a neighbouring caption, partial recording, or the first 90 seconds of it.
enum ChineseRecognitionAudio {
    #if DEBUG
    @TaskLocal static var inspectionForTesting: (@Sendable () -> Void)?
    #endif
    struct Slice: Sendable {
        let recording: URL
        let frames: Range<Int>
        let duration: TimeInterval
        let layout: WAVContextClip.Layout
        let identity: SensitiveFileIO.Identity

        func extract(to directory: URL) throws -> URL {
            try SensitiveFileIO.withoutDatalessMaterialization {
                let parent = try SensitiveFileIO.Directory.open(at: recording.deletingLastPathComponent(), create: false, tighten: false)
                try parent.rejectDatalessIfPresent(named: recording.lastPathComponent)
                try SessionArchiveCoding.requireRegularFileIfPresent(recording)
                guard try fileIdentity(recording) == identity else { throw Failure.unsafe }
                let current = try WAVContextClip.readLayout(at: recording)
                guard current.formatTag == layout.formatTag, current.channelCount == layout.channelCount,
                      current.sampleRate == layout.sampleRate, current.bitsPerSample == layout.bitsPerSample,
                      current.blockAlign == layout.blockAlign, current.dataOffset == layout.dataOffset,
                      current.frameCount >= frames.upperBound else { throw Failure.incomplete }
                let clip = try WAVContextClip.extract(from: recording, start: 0, end: duration,
                    padding: 0, destinationDirectory: directory, frameRange: frames)
                guard try WAVContextClip.readLayout(at: clip).frameCount == frames.count else {
                    try? FileManager.default.removeItem(at: clip)
                    throw Failure.incomplete
                }
                guard try fileIdentity(recording) == identity else {
                    try? FileManager.default.removeItem(at: clip)
                    throw Failure.unsafe
                }
                return clip
            }
        }
    }

    enum Failure: LocalizedError {
        case unavailable, incomplete, tooLong, unsafe
        var errorDescription: String? {
            switch self {
            case .unavailable: return "本句录音已不存在，无法重新识别。实时模式未保留录音时不可用。"
            case .incomplete: return "本句录音尚未完整写入，暂时无法重新识别。"
            case .tooLong: return "本句录音超过单次重识别范围，原句已保留。"
            case .unsafe: return "本句录音路径无法安全读取，原句已保留。"
            }
        }
    }

    static func slice(segment: TranscriptSegment, directory: URL?, ranges: [SessionAudioRange],
                      retainedChunks: [TranscriptionWorkRecord] = []) throws -> Slice {
        #if DEBUG
        inspectionForTesting?()
        #endif
        return try SensitiveFileIO.withoutDatalessMaterialization {
            do { return try localSlice(segment: segment, directory: directory, ranges: ranges) }
            catch Failure.unavailable {
                guard let chunk = retainedChunks.first(where: {
                    $0.id == segment.id && $0.start == segment.startTime && $0.end == segment.endTime
                        && $0.startFrame >= 0 && $0.endFrame > $0.startFrame
                        && (segment.sessionID == nil || $0.sessionID == segment.sessionID)
                }) else { throw Failure.unavailable }
                try SessionArchiveCoding.validateRelativePath(chunk.audioFile)
                guard !chunk.audioFile.contains("/") else { throw Failure.unsafe }
                let range = SessionAudioRange(segmentID: segment.id,
                    filePath: DurableTranscriptionJournal.directoryName + "/" + chunk.audioFile,
                    startFrame: 0, frameCount: chunk.endFrame - chunk.startFrame,
                    captureStart: segment.startTime, captureEnd: segment.endTime)
                let slice = try localSlice(segment: segment, directory: directory, ranges: [range])
                guard slice.layout.sampleRate == chunk.sampleRate else { throw Failure.unsafe }
                return slice
            }
        }
    }

    private static func localSlice(segment: TranscriptSegment, directory: URL?, ranges: [SessionAudioRange]) throws -> Slice {
        guard let directory else { throw Failure.unavailable }
        let range = ranges.first { $0.segmentID == segment.id && $0.frameCount > 0 && $0.interruptionReason == nil }
        let relative = range?.filePath ?? SessionWorkspace.recordingFileName
        try SessionArchiveCoding.validateRelativePath(relative)
        let recording = directory.appendingPathComponent(relative)
        guard recording.standardizedFileURL == recording.resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure.unsafe
        }
        let parent = try SensitiveFileIO.Directory.open(at: recording.deletingLastPathComponent(), create: false, tighten: false)
        try parent.rejectDatalessIfPresent(named: recording.lastPathComponent)
        try SessionArchiveCoding.requireRegularFileIfPresent(recording)
        guard FileManager.default.fileExists(atPath: recording.path) else { throw Failure.unavailable }
        let identity = try fileIdentity(recording)
        let layout = try WAVContextClip.readLayout(at: recording)
        let first: Int, last: Int
        if let range {
            try range.validate()
            guard range.startFrame <= Int64(Int.max), range.frameCount <= Int64(Int.max) - range.startFrame else {
                throw Failure.unsafe
            }
            first = Int(range.startFrame)
            last = first + Int(range.frameCount)
        } else {
            let start = (segment.startTime * layout.sampleRate).rounded(.down)
            let end = (segment.endTime * layout.sampleRate).rounded(.up)
            guard start.isFinite, end.isFinite, start >= 0, end < Double(Int.max) else { throw Failure.unsafe }
            first = Int(start); last = Int(end)
        }
        guard first >= 0, last > first, last <= layout.frameCount else { throw Failure.incomplete }
        let duration = Double(last - first) / layout.sampleRate
        guard duration <= WAVContextClip.maximumClipSeconds,
              last - first <= WAVContextClip.maximumClipBytes / layout.blockAlign else { throw Failure.tooLong }
        guard try fileIdentity(recording) == identity else { throw Failure.unsafe }
        return Slice(recording: recording, frames: first..<last, duration: duration, layout: layout, identity: identity)
    }

    private static func fileIdentity(_ url: URL) throws -> SensitiveFileIO.Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafe }
        return SensitiveFileIO.Identity(info)
    }
}
