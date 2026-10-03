import Foundation

/// Bounded admission of mutable caption evidence; no task or persistence ownership.
/// `now` is a monotonic host clock, never the caption's media timestamp.
struct CaptionNoteGate {
    struct Caption: Equatable {
        var id: UUID
        var revision: Int
        var start: Double
        var end: Double
        var english: String
        var chinese: String
        var usable: Bool = true
    }

    struct Context {
        /// In timeline order, including untranslated/failed captions.
        var captions: [Caption]
        var covered: Set<UUID> = []
        /// All queued, in-flight and retryable successor translations.
        var unsettledSuccessors: Set<UUID> = []
        /// Register BEFORE awaiting an adjacent call. Includes deferred queued/in-flight jobs.
        var repairTargets: Set<UUID> = []
        /// True only after the source producer and all caption/repair writers have drained.
        /// `.saved`, `.stopping`, a capture failure, and an empty queue alone do not prove this.
        var producerDrained = false
        var enabled = true
        var paused = false
    }

    struct Decision: Equatable {
        var eligible: Set<UUID>
        /// Eligible by a deadline, NOT a claim that the caption can never change again.
        var admittedAtLimit: Set<UUID>
        var held: Set<UUID>
        var nextWake: Double?
        var oldestUncoveredDeadline: Double?
        var sealed: Bool
    }

    let maximumHold: Double
    private var waitingSince: [UUID: Double] = [:]

    init(maximumHold: Double = 20) {
        precondition(maximumHold.isFinite && maximumHold > 0)
        self.maximumHold = maximumHold
    }

    static func risks(_ c: Context) -> Set<UUID> {
        var result = c.repairTargets
        for index in c.captions.indices {
            let caption = c.captions[index]
            guard caption.usable else { continue }
            if index == c.captions.count - 1 {
                if !c.producerDrained { result.insert(caption.id) }
            } else {
                let successor = c.captions[index + 1]
                // Mirrors AppModel's <= 2s adjacency rule. End punctuation does not seal a tail.
                if successor.start - caption.end <= 2,
                   c.unsettledSuccessors.contains(successor.id) {
                    result.insert(caption.id)
                }
            }
        }
        return result
    }

    mutating func evaluate(_ c: Context, now: Double) -> Decision {
        precondition(now.isFinite)
        precondition(Set(c.captions.map(\.id)).count == c.captions.count)
        let usable = Set(c.captions.filter { $0.usable && !$0.english.isEmpty }.map(\.id))
        let risks = Self.risks(c)
        // Also track a covered source used by a pending-point dependency while it is at risk.
        let tracked = usable.subtracting(c.covered).union(usable.intersection(risks))
        waitingSince = waitingSince.filter { tracked.contains($0.key) }
        for id in tracked where waitingSince[id] == nil { waitingSince[id] = now }
        let sealed = c.producerDrained && c.unsettledSuccessors.isEmpty && c.repairTargets.isEmpty
        let bootstrapDeadline = usable.subtracting(c.covered).compactMap { waitingSince[$0] }.min().map { $0 + maximumHold }
        guard c.enabled, !c.paused else {
            return .init(eligible: [], admittedAtLimit: [], held: tracked, nextWake: nil,
                         oldestUncoveredDeadline: bootstrapDeadline, sealed: sealed)
        }
        let unresolved = sealed ? Set<UUID>() : usable.intersection(risks)
        let expired = Set(unresolved.filter { now >= (waitingSince[$0] ?? now) + maximumHold })
        let held = unresolved.subtracting(expired)
        let wake = held.compactMap { waitingSince[$0].map { $0 + maximumHold } }.min()
        return .init(eligible: usable.subtracting(held), admittedAtLimit: expired,
                     held: held, nextWake: wake, oldestUncoveredDeadline: bootstrapDeadline, sealed: sealed)
    }
}
