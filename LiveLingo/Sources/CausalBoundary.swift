import Foundation

/// Production form of the E2-frozen semantic chunking policy.
///
/// All times are on the captured-audio timeline (pauses therefore do not
/// advance the policy).  The policy is deliberately pure so the exact
/// thresholds can be regression-tested without opening an audio device.
struct CausalBoundaryConfiguration: Equatable, Sendable {
    let minimumDuration: TimeInterval = 2
    let clauseSearchDuration: TimeInterval = 6
    let pauseSearchDuration: TimeInterval = 8
    let maximumDuration: TimeInterval = 10
    let pauseDuration: TimeInterval = 0.5
    let previewStabilityDuration: TimeInterval = 0.3
    let activityFreshnessDuration: TimeInterval = 0.35
    let boundarySlackDuration: TimeInterval = 0.15
    let policyVersion = "causal-pause-boundary-dev-v1"
}

struct CausalBoundaryDecision: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let reason: String
}

struct CausalBoundaryPolicy: Sendable {
    private struct Preview: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let arrival: TimeInterval
    }

    private struct Activity: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let speech: Bool
    }

    let configuration = CausalBoundaryConfiguration()
    private(set) var committedTime: TimeInterval = 0
    private var previews: [Preview] = []
    private var activities: [Activity] = []
    private var fingerprint: String?
    private var unchangedSince: TimeInterval = 0

    mutating func observePreview(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        arrival: TimeInterval
    ) {
        guard start.isFinite, end.isFinite, arrival.isFinite,
              start >= 0, end >= start, arrival >= end
        else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let row = Preview(start: start, end: end, text: normalized, arrival: arrival)
        if let index = previews.lastIndex(where: { abs($0.start - start) < 0.05 }) {
            previews[index] = row
        } else {
            previews.append(row)
        }
    }

    mutating func observeActivity(
        speech: Bool,
        start: TimeInterval,
        end: TimeInterval
    ) {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return }
        let row = Activity(start: start, end: end, speech: speech)
        if let index = activities.lastIndex(where: { abs($0.start - start) < 0.000_1 }) {
            activities[index] = row
        } else {
            activities.append(row)
        }
    }

    mutating func decision(at now: TimeInterval) -> CausalBoundaryDecision? {
        guard now.isFinite, now > committedTime else { return nil }
        let duration = now - committedTime
        if duration >= configuration.maximumDuration {
            return commit(at: now, reason: "maximum_wait")
        }
        if duration >= configuration.pauseSearchDuration,
           quietTail(at: now) != nil,
           activities.contains(where: { $0.speech && $0.end > committedTime }) {
            return commit(at: now, reason: "approaching_limit_pause")
        }
        guard duration >= configuration.minimumDuration,
              let latest = previews
                .filter({ $0.end > committedTime && $0.arrival <= now })
                .max(by: { $0.end < $1.end }),
              isBoundaryText(
                latest.text,
                allowClausePunctuation: duration >= configuration.clauseSearchDuration
              )
        else {
            fingerprint = nil
            unchangedSince = now
            return nil
        }

        let key = "\(latest.start):\(latest.end):\(latest.text)"
        if key != fingerprint {
            fingerprint = key
            unchangedSince = latest.arrival
        }
        guard now - unchangedSince >= configuration.previewStabilityDuration,
              let quiet = quietTail(at: now),
              latest.end <= quiet.start + configuration.boundarySlackDuration,
              activities.contains(where: { $0.speech && $0.end > committedTime })
        else { return nil }

        return commit(
            at: now,
            reason: duration < configuration.clauseSearchDuration
                ? "stable_sentence_pause"
                : "stable_clause_pause"
        )
    }

    mutating func finish(at now: TimeInterval) -> CausalBoundaryDecision? {
        guard now.isFinite, now > committedTime else { return nil }
        return commit(at: now, reason: "end_of_input")
    }

    private func quietTail(at now: TimeInterval) -> (start: TimeInterval, end: TimeInterval)? {
        guard let latest = activities.map(\.end).max(),
              now - latest <= configuration.activityFreshnessDuration
        else { return nil }
        let lastSpeech = activities
            .filter(\.speech)
            .map(\.end)
            .max() ?? committedTime
        var left = latest
        for row in activities.filter({ !$0.speech }).sorted(by: { $0.end > $1.end }) {
            if row.end < left { break }
            if row.start <= left { left = min(left, row.start) }
        }
        left = max(left, lastSpeech, committedTime)
        guard latest - left >= configuration.pauseDuration else { return nil }
        return (left, latest)
    }

    private func isBoundaryText(_ text: String, allowClausePunctuation: Bool) -> Bool {
        let stripped = text.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'’”)]}")
        )
        guard let last = stripped.last else { return false }
        let punctuation: Set<Character> = allowClausePunctuation
            ? [".", "?", "!", ";", ":", ","]
            : [".", "?", "!"]
        guard punctuation.contains(last),
              !stripped.hasSuffix("..."),
              !stripped.hasSuffix("…")
        else { return false }
        let token = stripped.split(whereSeparator: \.isWhitespace)
            .last.map(String.init)?.lowercased() ?? ""
        if ["dr.", "mr.", "mrs.", "ms.", "prof.", "e.g.", "i.e.", "vs.", "etc."].contains(token) {
            return false
        }
        if token.count == 2, token.first?.isLetter == true { return false }
        return true
    }

    private mutating func commit(
        at now: TimeInterval,
        reason: String
    ) -> CausalBoundaryDecision {
        let result = CausalBoundaryDecision(start: committedTime, end: now, reason: reason)
        committedTime = now
        fingerprint = nil
        unchangedSince = now
        previews.removeAll { $0.end <= now }
        activities.removeAll { $0.end < now - 1 }
        return result
    }
}
