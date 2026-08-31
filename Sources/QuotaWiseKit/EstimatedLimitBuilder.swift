import Foundation

enum EstimatedLimitBuilder {
    static func claudeLimits(events: [UsageEvent], resets: [ResetEvent], now: Date = Date()) -> [LimitBucket] {
        let claudeEvents = events.filter { $0.provider == .claude && $0.timestamp <= now }
        guard !claudeEvents.isEmpty else { return [] }

        let windows = [
            estimatedSession(events: claudeEvents, resets: resets, now: now),
            estimatedWeek(events: claudeEvents, resets: resets, now: now),
        ].compactMap { $0 }
        guard !windows.isEmpty else { return [] }
        return [
            LimitBucket(
                id: "claude-estimated",
                provider: .claude,
                displayName: "Claude Code",
                planType: nil,
                windows: windows,
                confidence: .estimated,
                sourceDescription: "Estimated from local Claude usage and detected reset events"
            ),
        ]
    }

    private static func estimatedSession(events: [UsageEvent], resets: [ResetEvent], now: Date) -> RateLimitWindow? {
        let explicit = resets
            .filter { $0.provider == .claude && $0.kind == .session }
            .sorted { $0.date < $1.date }
        let recentReset = explicit.last { $0.date <= now }
        let nextKnownReset = explicit.first { $0.date > now }

        let start: Date
        let resetAt: Date
        if let recentReset, now.timeIntervalSince(recentReset.date) <= 5 * 3_600 {
            start = recentReset.date
            resetAt = recentReset.date.addingTimeInterval(5 * 3_600)
        } else if let nextKnownReset, nextKnownReset.date.timeIntervalSince(now) <= 5 * 3_600 {
            start = nextKnownReset.date.addingTimeInterval(-5 * 3_600)
            resetAt = nextKnownReset.date
        } else {
            start = now.addingTimeInterval(-5 * 3_600)
            let oldestActive = events
                .filter { $0.timestamp >= start && $0.timestamp <= now }
                .map(\.timestamp)
                .min()
            resetAt = (oldestActive ?? now).addingTimeInterval(5 * 3_600)
        }

        let currentCredits = events
            .filter { $0.timestamp >= start && $0.timestamp <= now }
            .reduce(0) { $0 + $1.credits }
        let fullSamples = explicit.filter { $0.date <= now }.compactMap { reset -> Double? in
            let windowStart = reset.date.addingTimeInterval(-5 * 3_600)
            let value = events
                .filter { $0.timestamp >= windowStart && $0.timestamp < reset.date }
                .reduce(0) { $0 + $1.credits }
            return value > 0 ? value : nil
        }
        guard let baseline = percentile(fullSamples, fraction: 0.5)
            ?? percentile(rollingWindowCredits(events: events, duration: 5 * 3_600, before: start), fraction: 0.9)
        else { return nil }
        let used = max(0, min(100, currentCredits / max(0.01, baseline) * 100))

        return RateLimitWindow(
            usedPercent: used,
            durationMinutes: 300,
            resetsAt: resetAt,
            confidence: .estimated,
            estimateBasis: fullSamples.isEmpty
                ? "Compared with the 90th percentile of prior 5-hour activity"
                : "Calibrated from \(fullSamples.count) detected session-limit reset\(fullSamples.count == 1 ? "" : "s")"
        )
    }

    private static func estimatedWeek(events: [UsageEvent], resets: [ResetEvent], now: Date) -> RateLimitWindow? {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let explicitWeekly = resets
            .filter { $0.provider == .claude && $0.kind == .weekly }
            .sorted { $0.date < $1.date }
        let lastExact = explicitWeekly.last { $0.confidence == .exact && $0.date <= now }

        let start: Date
        let resetAt: Date
        let anchoredToExactReset = lastExact.map { now.timeIntervalSince($0.date) <= 7 * 86_400 } ?? false
        if let lastExact, anchoredToExactReset {
            start = lastExact.date
            resetAt = lastExact.date.addingTimeInterval(7 * 86_400)
        } else {
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? now.addingTimeInterval(-7 * 86_400)
            resetAt = calendar.date(byAdding: .day, value: 7, to: start)
                ?? start.addingTimeInterval(7 * 86_400)
        }

        let currentCredits = events
            .filter { $0.timestamp >= start && $0.timestamp <= now }
            .reduce(0) { $0 + $1.credits }
        var weeklySamples: [Double] = []
        for weeksBack in 1...8 {
            guard let sampleStart = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: start),
                  let sampleEnd = calendar.date(byAdding: .day, value: 7, to: sampleStart) else { continue }
            let value = events
                .filter { $0.timestamp >= sampleStart && $0.timestamp < sampleEnd }
                .reduce(0) { $0 + $1.credits }
            if value > 0 { weeklySamples.append(value) }
        }
        guard let baseline = percentile(weeklySamples, fraction: 0.9) else { return nil }
        let used = max(0, min(100, currentCredits / max(0.01, baseline) * 100))

        return RateLimitWindow(
            usedPercent: used,
            durationMinutes: 10_080,
            resetsAt: resetAt,
            confidence: .estimated,
            estimateBasis: anchoredToExactReset
                ? "Anchored to a detected weekly reset"
                : "Calendar-week usage compared with the 90th percentile of prior active weeks"
        )
    }

    private static func rollingWindowCredits(
        events: [UsageEvent],
        duration: TimeInterval,
        before cutoff: Date
    ) -> [Double] {
        let historical = events.filter { $0.timestamp < cutoff }.sorted { $0.timestamp < $1.timestamp }
        guard let first = historical.first?.timestamp else { return [] }
        var values: [Double] = []
        var cursor = first
        while cursor.addingTimeInterval(duration) <= cutoff {
            let end = cursor.addingTimeInterval(duration)
            let value = historical
                .filter { $0.timestamp >= cursor && $0.timestamp < end }
                .reduce(0) { $0 + $1.credits }
            if value > 0 { values.append(value) }
            cursor = end
        }
        return values
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}
