import Foundation
import CryptoKit

/// Directory URLs locate files. These values identify the frozen content.
struct ReviewIdentity: Codable, Hashable, Sendable {
    enum Scope: Codable, Hashable, Sendable {
        case wholeLesson
        case batch(UUID)
    }

    let sessionID: UUID
    let scope: Scope
    let inputRevision: Int
    /// Appended notes advance independently of corrections to source captions.
    /// Nil preserves the identity of reports written by earlier builds.
    let notebookRevision: Int?

    init(sessionID: UUID, scope: LearningReviewScope, inputRevision: Int,
         notebookRevision: Int? = nil) throws {
        guard inputRevision >= 0, inputRevision < Int.max,
              notebookRevision.map({ $0 >= 0 && $0 < Int.max }) ?? true else {
            throw ReviewIdentityError.conflict("复查输入版本无效")
        }
        self.sessionID = sessionID
        self.inputRevision = inputRevision
        self.notebookRevision = notebookRevision
        if scope.isWholeLesson {
            guard scope.batchID == nil else { throw ReviewIdentityError.conflict("整课范围含有批次 ID") }
            self.scope = .wholeLesson
        } else {
            guard let id = scope.batchID else { throw ReviewIdentityError.conflict("局部复查缺少稳定批次 ID") }
            self.scope = .batch(id)
        }
    }

    var scopeKey: String {
        switch scope {
        case .wholeLesson: return "whole"
        case .batch(let id): return "batch-" + id.uuidString.lowercased()
        }
    }

    var key: String {
        "\(sessionID.uuidString.lowercased())/\(scopeKey)/\(inputRevision)"
            + (notebookRevision.map { "/notes-\($0)" } ?? "")
    }

    func hasSameScope(as other: Self) -> Bool {
        sessionID == other.sessionID && scope == other.scope
    }

    func validate(scope: LearningReviewScope, batches: [LearningNoteBatch]) throws {
        guard self == (try Self(sessionID: sessionID, scope: scope, inputRevision: inputRevision,
                               notebookRevision: notebookRevision)),
              !batches.isEmpty, Set(batches.map(\.id)).count == batches.count else {
            throw ReviewIdentityError.conflict("复查身份或批次表损坏")
        }
        if case .batch(let id) = self.scope {
            guard batches.count == 1, batches[0].id == id else {
                throw ReviewIdentityError.conflict("局部范围与保存的批次 ID 不一致")
            }
        }
    }
}

enum ReviewIdentityError: LocalizedError {
    case conflict(String)
    case staleInput
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .conflict(let detail): return "复查内容冲突：\(detail)；已保留原任务与报告"
        case .staleInput: return "课程内容已有新修订；旧报告保留，未完成复查需要重新选择范围"
        case .unreadable(let detail): return "复查报告读取失败，未导出：\(detail)"
        }
    }
}

enum ReviewInputBinding {
    static func digest(_ batches: [LearningNoteBatch]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(batches))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Loading a snapshot is read-only; old Markdown never invents batch IDs.
    static func snapshot(in directory: URL) throws -> SessionSnapshot? {
        let result = try SessionStore(directory: directory).loadDetailed()
        guard result.origin == .snapshot else { return nil }
        guard result.incompleteTailBytes == 0 else {
            throw SessionStoreError.incompleteJournalTail(bytes: result.incompleteTailBytes)
        }
        return result.snapshot
    }

    static func selected(_ batches: [LearningNoteBatch], scope: LearningReviewScope) throws -> [LearningNoteBatch] {
        let available = batches.filter { !$0.note.points.isEmpty }
        guard Set(available.map(\.id)).count == available.count else {
            throw ReviewIdentityError.conflict("笔记有重复的批次 ID")
        }
        if scope.isWholeLesson { return available }
        if let id = scope.batchID {
            guard let batch = available.first(where: { $0.id == id }) else {
                throw ReviewIdentityError.conflict("所选批次已修订或不在这份课程中")
            }
            return [batch]
        }
        guard let number = scope.batchNumber, number > 0, number <= available.count else {
            throw ReviewIdentityError.conflict("所选批次不存在")
        }
        return [available[number - 1]]
    }

    /// A revised directory can still hold historical reports, but cannot resume
    /// generation against the old input. Retained batches prove old provenance.
    static func validate(identity: ReviewIdentity?, scope: LearningReviewScope,
                         batches: [LearningNoteBatch], digest expectedDigest: String?,
                         original: String, in directory: URL,
                         allowHistorical: Bool) throws {
        let actualDigest = try digest(batches)
        guard expectedDigest == nil || expectedDigest == actualDigest else {
            throw ReviewIdentityError.conflict("任务内的冻结输入与校验值不一致")
        }
        if let identity { try identity.validate(scope: scope, batches: batches) }
        if let snapshot = try snapshot(in: directory) {
            if let identity {
                guard snapshot.sessionID == identity.sessionID else {
                    throw ReviewIdentityError.conflict("所选目录属于另一份课程")
                }
                guard snapshot.inputRevision >= identity.inputRevision else {
                    throw ReviewIdentityError.conflict("所选目录是早于本次复查的副本")
                }
                if let revision = identity.notebookRevision, snapshot.notebookRevision < revision {
                    throw ReviewIdentityError.conflict("所选目录缺少本次复查所用的笔记版本")
                }
                if snapshot.inputRevision > identity.inputRevision {
                    // A local frozen batch is still valid after an unrelated
                    // source edit. Whole-course context changes invalidate it.
                    if case .batch = identity.scope,
                       batches.allSatisfy({ snapshot.batches.contains($0) }) { return }
                    guard allowHistorical else { throw ReviewIdentityError.staleInput }
                    let candidates = snapshot.batches + snapshot.revisionHistory.flatMap(\.retainedBatches)
                    guard batches.allSatisfy({ batch in candidates.contains(batch) }) else {
                        throw ReviewIdentityError.conflict("目录没有保留这份旧复查的批次依据")
                    }
                    return
                }
                if let revision = identity.notebookRevision, snapshot.notebookRevision > revision {
                    // Normal append-only growth leaves this frozen scope valid.
                    // Edits to any of its existing batches are still conflicts.
                    guard batches.allSatisfy({ snapshot.batches.contains($0) }) else {
                        throw ReviewIdentityError.conflict("后续笔记改变了已冻结的复查依据")
                    }
                    return
                }
            }
            let selected = try selected(snapshot.batches, scope: scope)
            guard try digest(selected) == actualDigest else {
                throw ReviewIdentityError.conflict("同一课程 ID 与版本对应了不同笔记或证据")
            }
            return
        }
        // Legacy jobs continue to work without claiming a session identity.
        // A bound job must retain its snapshot; deleting it cannot downgrade
        // identity checking to a comparison of human-readable text.
        guard identity == nil else {
            throw ReviewIdentityError.conflict("课程身份快照缺失，请恢复完整课程目录")
        }
        let summary = directory.appendingPathComponent("summary-zh-Hans.md")
        if FileManager.default.fileExists(atPath: summary.path) {
            guard try String(contentsOf: summary, encoding: .utf8) == original + "\n" else {
                throw ReviewIdentityError.conflict("所选目录的笔记与复查原文不同")
            }
        }
    }
}
