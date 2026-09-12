import Foundation

enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }
}

enum DataConfidence: String, Codable, Sendable {
    case exact
    case estimated
    case unavailable
}

struct TokenUsage: Codable, Hashable, Sendable {
    var input: Int64 = 0
    var cachedInput: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheWriteFiveMinute: Int64 = 0
    var cacheWriteOneHour: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0

    var total: Int64 {
        max(0, input) + max(0, cachedInput) + max(0, cacheWrite) + max(0, output)
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheWriteFiveMinute: lhs.cacheWriteFiveMinute + rhs.cacheWriteFiveMinute,
            cacheWriteOneHour: lhs.cacheWriteOneHour + rhs.cacheWriteOneHour,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    func nonnegativeDelta(from previous: TokenUsage?) -> TokenUsage {
        guard let previous else { return self }

        func delta(_ current: Int64, _ old: Int64) -> Int64 {
            max(0, current - old)
        }

        return TokenUsage(
            input: delta(input, previous.input),
            cachedInput: delta(cachedInput, previous.cachedInput),
            cacheWrite: delta(cacheWrite, previous.cacheWrite),
            cacheWriteFiveMinute: delta(cacheWriteFiveMinute, previous.cacheWriteFiveMinute),
            cacheWriteOneHour: delta(cacheWriteOneHour, previous.cacheWriteOneHour),
            output: delta(output, previous.output),
            reasoning: delta(reasoning, previous.reasoning)
        )
    }

    func componentwiseMaximum(with previous: TokenUsage?) -> TokenUsage {
        guard let previous else { return self }
        return TokenUsage(
            input: max(input, previous.input),
            cachedInput: max(cachedInput, previous.cachedInput),
            cacheWrite: max(cacheWrite, previous.cacheWrite),
            cacheWriteFiveMinute: max(cacheWriteFiveMinute, previous.cacheWriteFiveMinute),
            cacheWriteOneHour: max(cacheWriteOneHour, previous.cacheWriteOneHour),
            output: max(output, previous.output),
            reasoning: max(reasoning, previous.reasoning)
        )
    }
}

struct UsageEvent: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: AIProvider
    let timestamp: Date
    let model: String
    let projectPath: String
    let projectName: String
    let tokens: TokenUsage
    let apiEquivalentUSD: Double
    let pricingWasEstimated: Bool
    let serviceTier: String?

    var credits: Double { apiEquivalentUSD * 100 }
}

enum ResetKind: String, Codable, Sendable {
    case session
    case weekly
    case unknown
}

/// Why a reset is known to have occurred. Older persisted events omit this
/// field and deliberately resolve to `.observed` rather than being relabelled.
enum ResetOrigin: String, Codable, Sendable {
    /// QuotaWise saw the usage window change but the provider did not expose a
    /// more specific cause.
    case observed
    /// A user-confirmed reset action, persisted against the exact reset event.
    case manual
    /// A provider-issued reset that has explicit provider provenance.
    case issued
}

/// The evidence behind a reset origin. The origin controls graph treatment;
/// this value keeps independently verifiable user confirmation separate from
/// a bounded correlation with an earned reset credit.
enum ResetOriginEvidence: String, Codable, Sendable {
    case userConfirmed
    case resetCreditConsumed
    case providerReported
}

struct ResetEvent: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: AIProvider
    let date: Date
    let detectedAt: Date
    let kind: ResetKind
    let bucketID: String
    let label: String
    let confidence: DataConfidence
    /// Optional for backward-compatible decoding of reset history written by
    /// QuotaWise versions before reset provenance existed.
    var origin: ResetOrigin? = .observed
    /// Optional for backward-compatible decoding of reset history written
    /// before QuotaWise recorded the evidence behind an origin.
    var originEvidence: ResetOriginEvidence?
    /// Kept only in local persistence for a credit-correlated manual reset.
    /// This opaque provider identifier is never displayed in QuotaWise.
    var originCreditID: String?

    var resolvedOrigin: ResetOrigin { origin ?? .observed }

    /// Older manual records were created only by the explicit user-confirmed
    /// maintenance action, so their missing evidence remains user-confirmed.
    var resolvedOriginEvidence: ResetOriginEvidence? {
        if let originEvidence { return originEvidence }
        switch resolvedOrigin {
        case .manual: return .userConfirmed
        case .issued: return .providerReported
        case .observed: return nil
        }
    }

    var isManualReset: Bool { resolvedOrigin == .manual }

    var isIssuedReset: Bool { resolvedOrigin == .issued }

    var isCreditConsumedManualReset: Bool {
        isManualReset && resolvedOriginEvidence == .resetCreditConsumed
    }

    var manualResetEvidenceText: String? {
        guard isManualReset else { return nil }
        switch resolvedOriginEvidence {
        case .userConfirmed:
            return "Manual reset · user-confirmed"
        case .resetCreditConsumed:
            return "Manual reset · reset credit consumed"
        case .providerReported, .none:
            return "Manual reset"
        }
    }

    /// Spark may be reported by the app-server under its public model name or
    /// its internal Bengalfox bucket identifier. This stays derived from the
    /// persisted bucket identity, so older reset records remain compatible.
    var isSparkModelReset: Bool {
        let normalizedBucketID = bucketID.lowercased()
        return normalizedBucketID.contains("spark") || normalizedBucketID.contains("bengalfox")
    }

    /// The reserve allowance can still contribute to limit and reset state, but
    /// its reset is not a usage-chart seam.
    var isGPTReserveReset: Bool {
        bucketID.caseInsensitiveCompare("gpt-reserve") == .orderedSame
    }
}

/// A display-only seam that can represent one reset or several plan resets
/// observed as one moment. Individual `ResetEvent` records remain intact for
/// persistence and history processing.
struct ResetSeam: Identifiable, Hashable, Sendable {
    let events: [ResetEvent]

    init(events: [ResetEvent]) {
        self.events = events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.isManualReset != $1.isManualReset { return $0.isManualReset }
            if $0.isSparkModelReset != $1.isSparkModelReset { return !$0.isSparkModelReset }
            return $0.id < $1.id
        }
    }

    var id: String { events.map(\.id).joined(separator: "+") }

    /// The primary plan anchors a shared seam so its established marker
    /// colour and position take precedence over a Spark companion event.
    var date: Date { primaryReset?.date ?? events.first?.date ?? .distantPast }

    var primaryReset: ResetEvent? {
        events.first { !$0.isSparkModelReset }
    }

    var containsPrimaryReset: Bool { primaryReset != nil }

    var containsManualReset: Bool {
        events.contains(where: \.isManualReset)
    }

    var containsIssuedReset: Bool {
        events.contains(where: \.isIssuedReset)
    }

    var confidence: DataConfidence {
        if events.contains(where: { $0.confidence == .exact }) { return .exact }
        if events.contains(where: { $0.confidence == .estimated }) { return .estimated }
        return .unavailable
    }

    static func group(_ resets: [ResetEvent], tolerance: TimeInterval = 120) -> [ResetSeam] {
        var groups: [[ResetEvent]] = []

        for reset in resets.sorted(by: { $0.date < $1.date }) {
            if let index = groups.indices.reversed().first(where: { index in
                guard let anchor = groups[index].first else { return false }
                return anchor.provider == reset.provider
                    && anchor.kind == reset.kind
                    && abs(anchor.date.timeIntervalSince(reset.date)) <= tolerance
            }) {
                groups[index].append(reset)
            } else {
                groups.append([reset])
            }
        }

        return groups.map(ResetSeam.init(events:))
    }
}

struct RateLimitWindow: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(durationMinutes ?? -1)-\(resetsAt?.timeIntervalSince1970 ?? -1)" }

    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?
    let confidence: DataConfidence
    let estimateBasis: String?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var kind: ResetKind {
        guard let durationMinutes else { return .unknown }
        if durationMinutes <= 24 * 60 { return .session }
        if durationMinutes <= 8 * 24 * 60 { return .weekly }
        return .unknown
    }

    var durationLabel: String {
        guard let durationMinutes else { return "Usage window" }
        if durationMinutes % 10_080 == 0 {
            let weeks = durationMinutes / 10_080
            return weeks == 1 ? "Weekly" : "\(weeks)-week"
        }
        if durationMinutes % 1_440 == 0 {
            let days = durationMinutes / 1_440
            return days == 1 ? "Daily" : "\(days)-day"
        }
        if durationMinutes % 60 == 0 {
            return "\(durationMinutes / 60)-hour"
        }
        return "\(durationMinutes)-minute"
    }
}

struct LimitBucket: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: AIProvider
    let displayName: String
    let planType: String?
    let windows: [RateLimitWindow]
    let confidence: DataConfidence
    let sourceDescription: String
}

/// The live App Server result is intentionally separate from `LimitBucket` so
/// current earned-reset-credit state can be persisted without turning it into
/// a chart-visible usage limit.
struct CodexLiveLimits: Sendable {
    let limits: [LimitBucket]
    let earnedResetCredits: CodexEarnedResetCreditAvailability?
}

/// Current availability only. App Server does not expose a historical list of
/// consumed credits, so QuotaWise observes this value over time locally.
struct CodexEarnedResetCreditAvailability: Codable, Hashable, Sendable {
    let availableCount: Int
    /// `nil` means the provider supplied only the authoritative count. An
    /// empty array means it did query details and found none.
    let credits: [CodexEarnedResetCredit]?
}

struct CodexEarnedResetCredit: Identifiable, Codable, Hashable, Sendable {
    /// Opaque provider identifier. It remains local-only and is never rendered.
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?
    let description: String?
}

enum EarnedResetCreditLifecycle: String, Codable, Sendable {
    case available
    case consumed
    case expired
    case unattributed
}

/// Local audit record for a detailed earned reset credit. This is deliberately
/// not fed to the presentation model; it exists solely to make future reset
/// attribution inspectable and conservative.
struct CodexEarnedResetCreditRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var resetType: String
    var providerStatus: String
    var grantedAt: Date?
    var expiresAt: Date?
    var title: String?
    var description: String?
    var firstObservedAt: Date
    var lastObservedAt: Date
    var lifecycle: EarnedResetCreditLifecycle
    var disappearedAt: Date?
    var associatedResetID: String?
}

struct RateObservation: Codable, Hashable, Sendable {
    let provider: AIProvider
    let bucketID: String
    let bucketName: String
    let observedAt: Date
    let usedPercent: Double
    let durationMinutes: Int?
    let resetsAt: Date?
}

struct ProjectSummary: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let provider: AIProvider
    let credits: Double
    let lastUsed: Date
}

enum UsageTimeRange: String, CaseIterable, Identifiable, Sendable {
    case fiveHours = "5h"
    case oneDay = "1d"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    var id: String { rawValue }

    func cutoff(relativeTo now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .fiveHours: calendar.date(byAdding: .hour, value: -5, to: now)
        case .oneDay: calendar.date(byAdding: .day, value: -1, to: now)
        case .sevenDays: calendar.date(byAdding: .day, value: -7, to: now)
        case .thirtyDays: calendar.date(byAdding: .day, value: -30, to: now)
        }
    }
}

struct UsagePeriod: Equatable, Sendable {
    let start: Date
    let end: Date

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    static func resolve(
        range: UsageTimeRange,
        historicalDay: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> UsagePeriod {
        if range == .oneDay,
           let historicalDay,
           let interval = calendar.dateInterval(of: .day, for: historicalDay) {
            return UsagePeriod(start: interval.start, end: interval.end)
        }

        return UsagePeriod(
            start: range.cutoff(relativeTo: now, calendar: calendar) ?? .distantPast,
            end: now
        )
    }
}

struct UsageChartPoint: Identifiable, Hashable, Sendable {
    var id: Date { date }
    let date: Date
    let credits: Double
    let apiEquivalentUSD: Double
    let tokens: Int64
}

struct ModelCostSummary: Identifiable, Hashable, Sendable {
    var id: String { model }
    let model: String
    let credits: Double
    let apiEquivalentUSD: Double
    let tokens: TokenUsage
    let isEstimate: Bool
}

struct ProjectCreditPoint: Identifiable, Hashable, Sendable {
    var id: String { "\(seriesID):\(date.timeIntervalSince1970)" }
    let date: Date
    let seriesID: String
    let seriesName: String
    let credits: Double
    let lowerCredits: Double
    let upperCredits: Double
}

struct ProjectCreditSeries: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let totalCredits: Double
    let isOther: Bool
    let points: [ProjectCreditPoint]
}

struct DailyUsageRow: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let model: String
    let projectName: String
    let tokens: TokenUsage
    let credits: Double
    let apiEquivalentUSD: Double
    let isEstimate: Bool
}

struct ScanResult: Sendable {
    var events: [UsageEvent] = []
    var resetEvents: [ResetEvent] = []
    var observations: [RateObservation] = []
    var warnings: [String] = []
}

enum UsageLoadState: Equatable, Sendable {
    case idle
    case loading(String)
    case ready
    case failed(String)
}

extension Date {
    static func parseUsageTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }
}

extension URL {
    var displayProjectName: String {
        let value = lastPathComponent.removingPercentEncoding ?? lastPathComponent
        return value.isEmpty ? path : value
    }
}
