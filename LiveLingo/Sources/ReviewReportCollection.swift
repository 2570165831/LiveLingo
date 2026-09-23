import Foundation

/// One frozen scope/version. Markdown is retained in the manifest, so replacing
/// the convenient latest-report file never erases an earlier report.
struct ReviewReportEntry: Codable, Equatable, Sendable {
    var jobID: UUID
    var identity: ReviewIdentity?
    var scope: LearningReviewScope
    var inputDigest: String?
    var completed: Int
    var total: Int
    var supersededByRevision: Int?
    var updatedAt: Date
    var fileName: String
    var markdown: String
    /// Older valid latest-file bodies, for an interrupted manifest/alias write.
    var recognizedFileDigests: [String]? = nil

    var key: String {
        if let identity { return identity.key }
        let version = total == 0 ? "/unversioned-\(jobID.uuidString)" : ""
        return "legacy/\(scope.stableKey)" + version
    }

    var isComplete: Bool { total > 0 && completed == total && supersededByRevision == nil }

    func validate() throws {
        guard completed >= 0, total >= 0, completed <= total,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              updatedAt.timeIntervalSince1970.isFinite,
              fileName == scope.reportFileName,
              supersededByRevision == nil || supersededByRevision! >= 0 else {
            throw ReviewIdentityError.unreadable("报告的范围、进度或文件名无效")
        }
        if let identity {
            guard identity == (try ReviewIdentity(sessionID: identity.sessionID, scope: scope,
                                                   inputRevision: identity.inputRevision,
                                                   notebookRevision: identity.notebookRevision)),
                  let inputDigest, inputDigest.count == 64,
                  inputDigest.allSatisfy({ $0.isHexDigit }) else {
                throw ReviewIdentityError.unreadable("报告身份与范围或输入校验值不一致")
            }
        }
    }
}

enum ReviewReportCollection {
    static let manifestFileName = "summary-review-index.json"
    private struct Manifest: Codable {
        var version = 1
        var entries: [ReviewReportEntry]
    }

    /// Saves history first. A crash before the latest-file refresh leaves a
    /// readable committed manifest and an older, verifiable convenience file.
    static func save(_ entry: ReviewReportEntry, in directory: URL) throws {
        try entry.validate()
        var entry = entry
        var entries = try read(in: directory)
        if let index = entries.firstIndex(where: { $0.jobID == entry.jobID }) {
            let prior = entries[index]
            guard prior.identity == entry.identity, prior.inputDigest == entry.inputDigest,
                  prior.scope.stableKey == entry.scope.stableKey,
                  entry.completed >= prior.completed else {
                throw ReviewIdentityError.conflict("报告写入改变了已有任务的身份或完成进度")
            }
            let previous = ReviewInputBinding.digest(Data(prior.markdown.trimmingCharacters(in: .newlines).utf8))
            entry.recognizedFileDigests = Array(Set((prior.recognizedFileDigests ?? []) + [previous])).sorted()
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try checkConflicts(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Manifest(entries: entries)).write(
            to: directory.appendingPathComponent(manifestFileName), options: .atomic)
        try (entry.markdown + "\n").write(to: directory.appendingPathComponent(entry.fileName),
                                           atomically: true, encoding: .utf8)
    }

    static func markdown(in directory: URL, queueReports: [ReviewReportEntry],
                         sessionID: UUID? = nil, inputRevision: Int? = nil) throws -> String? {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let snapshot = try ReviewInputBinding.snapshot(in: directory)
        if let sessionID, let snapshot, snapshot.sessionID != sessionID {
            throw ReviewIdentityError.conflict("导出目录的课程 ID 与当前课程不同")
        }
        let expectedID = sessionID ?? snapshot?.sessionID
        let expectedRevision = inputRevision ?? snapshot?.inputRevision
        let saved = try read(in: directory)
        let entries = saved + queueReports
        for entry in entries {
            try entry.validate()
            if let expectedID, let actualID = entry.identity?.sessionID, actualID != expectedID {
                throw ReviewIdentityError.conflict("报告属于其他课程，未导出")
            }
            if let expectedRevision, let revision = entry.identity?.inputRevision, revision > expectedRevision {
                throw ReviewIdentityError.conflict("报告版本比当前课程更新，未导出")
            }
        }
        return try render(entries, currentRevision: expectedRevision)
    }

    /// Same range/version is deduplicated. Completion beats an unfinished retry;
    /// unrelated ranges and prior versions remain present.
    static func render(_ entries: [ReviewReportEntry], currentRevision: Int? = nil) throws -> String? {
        try checkConflicts(entries)
        var chosen: [String: ReviewReportEntry] = [:]
        for entry in entries {
            try entry.validate()
            guard let old = chosen[entry.key] else { chosen[entry.key] = entry; continue }
            if entry.completed > old.completed ||
                (entry.completed == old.completed && entry.updatedAt >= old.updatedAt) {
                chosen[entry.key] = entry
            }
        }
        let ordered = chosen.values.sorted { lhs, rhs in
            if lhs.scope.isWholeLesson != rhs.scope.isWholeLesson { return lhs.scope.isWholeLesson }
            if lhs.scope.stableKey != rhs.scope.stableKey {
                if lhs.scope.batchNumber != rhs.scope.batchNumber {
                    return (lhs.scope.batchNumber ?? 0) < (rhs.scope.batchNumber ?? 0)
                }
                return lhs.scope.stableKey < rhs.scope.stableKey
            }
            let left = (lhs.identity?.inputRevision ?? -1, lhs.identity?.notebookRevision ?? -1)
            let right = (rhs.identity?.inputRevision ?? -1, rhs.identity?.notebookRevision ?? -1)
            return left < right
        }
        guard !ordered.isEmpty else { return nil }
        return ordered.map { entry in
            var range = "范围：\(entry.scope.label)"
            if let revision = entry.identity?.inputRevision {
                range += "；输入版本 \(revision)"
                if let notes = entry.identity?.notebookRevision { range += "，笔记版本 \(notes)" }
                if let currentRevision, revision < currentRevision {
                    range += "（历史版本，当前为 \(currentRevision)）"
                } else if entry.supersededByRevision != nil {
                    range += "（历史版本）"
                }
            } else {
                range += "；旧格式未记录输入版本"
            }
            return "> \(range)\n\n" + entry.markdown.trimmingCharacters(in: .newlines)
        }.joined(separator: "\n\n---\n\n")
    }

    static func read(in directory: URL) throws -> [ReviewReportEntry] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch { throw ReviewIdentityError.unreadable("无法列出课程目录（\(error.localizedDescription)）") }
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        var entries: [ReviewReportEntry] = []
        if files.contains(where: { $0.lastPathComponent == manifestFileName }) {
            do {
                let bytes = try data(at: manifestURL)
                let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
                guard manifest.version == 1,
                      Set(manifest.entries.map(\.jobID)).count == manifest.entries.count else {
                    throw ReviewIdentityError.unreadable("报告索引版本无效或任务 ID 重复")
                }
                entries = manifest.entries
                for entry in entries { try entry.validate() }
            } catch {
                throw ReviewIdentityError.unreadable("\(manifestFileName)（\(error.localizedDescription)）")
            }
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let scope = LearningReviewScope.reportScope(file.lastPathComponent) else { continue }
            let bytes = try data(at: file)
            guard let text = String(data: bytes, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReviewIdentityError.unreadable("\(file.lastPathComponent) 为空或不是 UTF-8")
            }
            let indexed = entries.filter { $0.fileName == file.lastPathComponent }
            if !indexed.isEmpty {
                guard indexed.contains(where: {
                    $0.markdown.trimmingCharacters(in: .newlines) == text.trimmingCharacters(in: .newlines)
                        || ($0.recognizedFileDigests ?? []).contains(
                            ReviewInputBinding.digest(Data(text.trimmingCharacters(in: .newlines).utf8)))
                }) else {
                    throw ReviewIdentityError.unreadable("\(file.lastPathComponent) 与保存的报告记录不一致")
                }
                continue
            }
            // No index exists for an old file. Retain it verbatim when a new
            // report later takes over the same latest-report filename.
            let digest = ReviewInputBinding.digest(Data((file.lastPathComponent + "\n" + text).utf8))
            let uuidText = "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-\(digest.dropFirst(12).prefix(4))-\(digest.dropFirst(16).prefix(4))-\(digest.dropFirst(20).prefix(12))"
            guard let id = UUID(uuidString: uuidText) else { throw ReviewIdentityError.unreadable(file.lastPathComponent) }
            entries.append(ReviewReportEntry(jobID: id, identity: nil, scope: scope,
                inputDigest: nil, completed: 0, total: 0, supersededByRevision: nil,
                updatedAt: Date(timeIntervalSince1970: 0), fileName: file.lastPathComponent, markdown: text))
        }
        try checkConflicts(entries)
        return entries
    }

    private static func data(at url: URL) throws -> Data {
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else {
                throw ReviewIdentityError.unreadable("\(url.lastPathComponent) 不是普通报告文件")
            }
            return try Data(contentsOf: url)
        } catch { throw ReviewIdentityError.unreadable("\(url.lastPathComponent)（\(error.localizedDescription)）") }
    }

    private static func checkConflicts(_ entries: [ReviewReportEntry]) throws {
        var digests: [String: String] = [:]
        let sessions = Set(entries.compactMap { $0.identity?.sessionID })
        guard sessions.count <= 1 else { throw ReviewIdentityError.conflict("同一目录出现多个课程 ID") }
        for entry in entries {
            guard entry.identity != nil, let digest = entry.inputDigest else { continue }
            if let existing = digests[entry.key], existing != digest {
                throw ReviewIdentityError.conflict("同一范围和输入版本对应不同内容")
            }
            digests[entry.key] = digest
        }
    }
}
