import Foundation

enum SessionWorkspaceError: LocalizedError {
    case invalidTemporarySession
    case recordingMissing
    case promotionFailed(source: URL, destination: URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidTemporarySession:
            return "临时录音目录不属于 LiveLingo，已停止文件操作。"
        case .recordingMissing:
            return "临时录音文件不存在。"
        case let .promotionFailed(source, destination, reason):
            return "录音迁移失败；临时录音仍保留在 \(source.path)，目标为 \(destination.path)。\(reason)"
        }
    }
}

enum SessionWorkspace {
    static let temporaryPrefix = "LiveLingo-Live-"
    static let recordingFileName = "recording.wav"

    static func makeTemporarySessionDirectory(
        fileManager: FileManager = .default,
        identifier: UUID = UUID()
    ) throws -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            temporaryPrefix + identifier.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    static func uniqueFinalDirectory(
        in outputRoot: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) -> URL {
        var candidate = outputRoot.appendingPathComponent(preferredName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = outputRoot.appendingPathComponent("\(preferredName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    static func promoteTemporarySession(
        from temporaryDirectory: URL,
        to outputRoot: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try validateTemporarySession(temporaryDirectory, fileManager: fileManager)
        let sourceRecording = temporaryDirectory.appendingPathComponent(recordingFileName)
        guard fileManager.fileExists(atPath: sourceRecording.path) else {
            throw SessionWorkspaceError.recordingMissing
        }

        let destination = uniqueFinalDirectory(
            in: outputRoot,
            preferredName: preferredName,
            fileManager: fileManager
        )

        do {
            try fileManager.moveItem(at: temporaryDirectory, to: destination)
            return destination
        } catch {
            let moveError = error
            do {
                // Cross-volume moves can fail. Copy only into a newly-created,
                // collision-free directory and remove the source only after a
                // byte-count check proves the copy completed.
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
                let destinationRecording = destination.appendingPathComponent(recordingFileName)
                try fileManager.copyItem(at: sourceRecording, to: destinationRecording)
                let sourceSize = try fileSize(at: sourceRecording, fileManager: fileManager)
                let destinationSize = try fileSize(at: destinationRecording, fileManager: fileManager)
                guard sourceSize == destinationSize else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try? fileManager.removeItem(at: temporaryDirectory)
                return destination
            } catch {
                // Keep both the source and any partial, uniquely named target.
                // Never remove a destination after a failed copy.
                throw SessionWorkspaceError.promotionFailed(
                    source: temporaryDirectory,
                    destination: destination,
                    reason: "移动错误：\(moveError.localizedDescription)；复制错误：\(error.localizedDescription)"
                )
            }
        }
    }

    static func discardTemporarySession(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try validateTemporarySession(directory, fileManager: fileManager)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private static func validateTemporarySession(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedDirectory.deletingLastPathComponent() == resolvedRoot,
              resolvedDirectory.lastPathComponent.hasPrefix(temporaryPrefix)
        else {
            throw SessionWorkspaceError.invalidTemporarySession
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> UInt64 {
        let values = try fileManager.attributesOfItem(atPath: url.path)
        return (values[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

enum SessionExporter {
    struct Manifest: Codable, Equatable {
        let createdAt: Date
        let sourceLocale: String
        let targetLocale: String
        let recordingFile: String
        let segmentCount: Int
    }

    static func export(
        segments: [TranscriptSegment],
        sessionDirectory: URL,
        recordingFileName: String = "recording.wav",
        summary: String = "",
        createdAt: Date = Date()
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let english = segments.map(\.english).joined(separator: "\n")
        let chinese = segments.map(\.chinese).joined(separator: "\n")
        try english.appending("\n").write(
            to: sessionDirectory.appendingPathComponent("transcript-en.txt"),
            atomically: true,
            encoding: .utf8
        )
        try chinese.appending("\n").write(
            to: sessionDirectory.appendingPathComponent("transcript-zh-Hans.txt"),
            atomically: true,
            encoding: .utf8
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let jsonl = try segments.map { segment -> String in
            let data = try encoder.encode(segment)
            guard let line = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return line
        }.joined(separator: "\n") + "\n"
        try jsonl.write(
            to: sessionDirectory.appendingPathComponent("bilingual.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let srt = segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))
            \(segment.english)
            \(segment.chinese)
            """
        }.joined(separator: "\n\n") + "\n"
        try srt.write(
            to: sessionDirectory.appendingPathComponent("bilingual.srt"),
            atomically: true,
            encoding: .utf8
        )

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            try (trimmedSummary + "\n").write(
                to: sessionDirectory.appendingPathComponent("summary-zh-Hans.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let manifest = Manifest(
            createdAt: createdAt,
            sourceLocale: "en-US",
            targetLocale: "zh-Hans",
            recordingFile: recordingFileName,
            segmentCount: segments.count
        )
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(
            to: sessionDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    static func srtTimestamp(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, Int((interval * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }
}
