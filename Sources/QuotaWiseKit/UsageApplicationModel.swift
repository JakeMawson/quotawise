import Combine
import Foundation

@MainActor
public final class UsageApplicationModel: ObservableObject {
    enum RefreshWork: Equatable {
        case none
        case limitsOnly
        case limitsAndHistory
    }

    public static let shared = UsageApplicationModel()

    @Published var selectedProvider: AIProvider {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selected-provider")
            if let selectedProjectPath,
               !projects.contains(where: { $0.provider == selectedProvider && $0.path == selectedProjectPath }) {
                self.selectedProjectPath = nil
            }
        }
    }
    @Published var selectedProjectPath: String?
    @Published var selectedRange: UsageTimeRange = .thirtyDays
    @Published var studioPercentagePrecision: PercentageDisplayPrecision {
        didSet {
            studioDisplaySettings.save(studioPercentagePrecision)
        }
    }
    @Published private(set) var selectedHistoricalDay: Date?
    @Published private(set) var loadState: UsageLoadState = .idle
    @Published private(set) var events: [UsageEvent] = []
    @Published private(set) var resetEvents: [ResetEvent] = []
    @Published private(set) var codexLimits: [LimitBucket] = []
    @Published private(set) var claudeLimits: [LimitBucket] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var weeklyUsageLimits: [AIProvider: [WeeklyUsageLimit]] = [:]
    @Published private(set) var pausedProviderTasks: [AIProvider: [PausedProviderTask]] = [:]
    @Published private(set) var claudeUsageSource: ClaudeUsageDataSource?
    @Published private(set) var claudeUsageObservedAt: Date?
    @Published private(set) var quotaResetNotificationMode: QuotaResetNotificationMode
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var indexingFileCount: Int?

    private let scanner: LocalUsageScanner
    private let codexClient: CodexAppServerClient
    private let claudeUsageReader: ClaudeUsageReader
    private let snapshotStore: LimitSnapshotStore
    private let weeklyLimitStore: WeeklyUsageLimitStore
    private let pausedProviderTaskStore: PausedProviderTaskStore
    private let weeklyLimitActions: any UsageLimitActionHandling
    private let quotaResetNotificationSettings: QuotaResetNotificationSettingsStore
    private let quotaResetTracker: QuotaResetTracker
    private let quotaResetNotifications: any QuotaResetNotificationHandling
    private let notificationAuthorization: any NotificationAuthorizationProviding
    private let launchAtLoginSettings: LaunchAtLoginSettingsStore
    private let studioDisplaySettings: StudioDisplaySettingsStore
    private var lastHistoryUpdated: Date?
    private var automaticRefreshTask: Task<Void, Never>?
    private var hasClaudeHistory = false

    static let indexingFileThreshold = 100
    private static let bundleIdentityMigrationMarker = "bundle-identity-migration-v6"
    private static let currentBundleIdentifier = "com.jakemawson.quotawise.menuagent3"
    private static let legacyBundleIdentifiers = [
        "com.jakemawson.quotawise.menuagent2",
        "com.jakemawson.quotawise.menuagent",
        "com.jakemawson.quotawise.statusitem",
        "com.jakemawson.quotawise.app",
        "com.jakemawson.quotawise.menubar",
        "com.jakemawson.quotawise",
        "com.jakemawson.ai-usage-bar",
    ]
    private static let migratedDefaultsKeys = [
        "selected-provider",
        "studio-percentage-precision-v1",
        "weekly-usage-limits-v1",
        "weekly-usage-limits-v2",
        "weekly-usage-paused-tasks-v1",
        "quota-reset-notification-mode-v1",
        "quota-reset-observations-v1",
        "launch-at-login-requested-v1",
        "menu-bar-icon-configuration-v1",
        "first-run-setup-version",
    ]

    public init() {
        Self.migrateDefaultsForFreshBundleIdentityIfNeeded()
        let saved = UserDefaults.standard.string(forKey: "selected-provider")
        selectedProvider = AIProvider(rawValue: saved ?? "") ?? .codex
        let displaySettings = StudioDisplaySettingsStore()
        studioDisplaySettings = displaySettings
        studioPercentagePrecision = .wholeNumber
        displaySettings.save(.wholeNumber)
        scanner = LocalUsageScanner()
        codexClient = CodexAppServerClient()
        claudeUsageReader = ClaudeUsageReader()
        snapshotStore = LimitSnapshotStore()
        weeklyLimitStore = WeeklyUsageLimitStore()
        pausedProviderTaskStore = PausedProviderTaskStore()
        weeklyLimitActions = SystemUsageLimitActionHandler()
        quotaResetNotificationSettings = QuotaResetNotificationSettingsStore()
        quotaResetTracker = QuotaResetTracker()
        quotaResetNotifications = QuotaResetNotificationHandler()
        notificationAuthorization = SystemNotificationAuthorizationProvider()
        launchAtLoginSettings = LaunchAtLoginSettingsStore()
        weeklyUsageLimits = weeklyLimitStore.records().mapValues { $0.map(\.limit) }
        pausedProviderTasks = pausedProviderTaskStore.all()
        quotaResetNotificationMode = quotaResetNotificationSettings.load()
        launchAtLoginEnabled = LaunchAtLoginService.isEnabled()
        indexingFileCount = nil
    }

    private static func migrateDefaultsForFreshBundleIdentityIfNeeded() {
        guard Bundle.main.bundleIdentifier == currentBundleIdentifier else { return }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: bundleIdentityMigrationMarker) else { return }

        var migratedValues: [String: Any] = [:]
        for legacyBundleIdentifier in legacyBundleIdentifiers {
            guard let legacyDomain = defaults.persistentDomain(forName: legacyBundleIdentifier) else { continue }
            for key in migratedDefaultsKeys where migratedValues[key] == nil {
                migratedValues[key] = legacyDomain[key]
            }
        }
        for (key, value) in migratedValues {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: bundleIdentityMigrationMarker)
    }

    var isRefreshing: Bool {
        if case .loading = loadState { return true }
        return false
    }

    var isIndexingHistory: Bool { indexingFileCount != nil }

    public func showIndexingForQA() {
        indexingFileCount = Self.indexingFileThreshold
        loadState = .loading("Indexing local history")
    }

    public var menuBarLabel: String {
        let value = headlineRemaining
        guard let value, value.isFinite else { return "AI" }
        let prefix = headlineConfidence == .estimated ? "~" : ""
        return "\(prefix)\(UsageFormat.percentage(value, precision: .wholeNumber))"
    }

    var headlineRemaining: Double? {
        let buckets = limits(for: selectedProvider)
        let preferred = buckets.first { $0.id == "codex" } ?? buckets.first
        let window = preferred?.windows.max { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }
        return window?.remainingPercent
    }

    var headlineConfidence: DataConfidence {
        let buckets = limits(for: selectedProvider)
        return buckets.first { $0.id == "codex" }?.confidence ?? buckets.first?.confidence ?? .unavailable
    }

    var headlineSubtitle: String {
        if selectedProvider == .claude,
           headlineConfidence == .exact,
           let observedAt = claudeUsageObservedAt {
            let age = Date().timeIntervalSince(observedAt)
            if age > 15 * 60 {
                let minutes = max(1, Int(age / 60))
                return "Exact Claude data from \(minutes)m ago"
            }
        }
        return switch headlineConfidence {
        case .exact: "Live account limit"
        case .estimated: "Estimated from local history"
        case .unavailable: "Limit data unavailable"
        }
    }

    var headlineConfidenceLabel: String? {
        guard selectedProvider == .claude, headlineConfidence == .exact else { return nil }
        guard let source = claudeUsageSource else { return nil }
        let age = claudeUsageObservedAt.map { Date().timeIntervalSince($0) } ?? 0
        switch source {
        case .oauthLive:
            return "LIVE · EXACT"
        case .exactCache, .claudeDesktopHistory:
            return age <= 15 * 60 ? "LIVE · EXACT" : "EXACT · CACHED"
        }
    }

    var projects: [ProjectSummary] {
        let grouped = Dictionary(grouping: events, by: { "\($0.provider.rawValue):\($0.projectPath)" })
        return grouped.compactMap { _, values in
            guard let latest = values.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            return ProjectSummary(
                path: latest.projectPath,
                name: latest.projectName,
                provider: latest.provider,
                credits: values.reduce(0) { $0 + $1.credits },
                lastUsed: latest.timestamp
            )
        }.sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.lastUsed > $1.lastUsed
        }
    }

    public func refreshIfNeeded() async {
        switch Self.refreshWork(
            lastUpdated: lastUpdated,
            lastHistoryUpdated: lastHistoryUpdated,
            now: Date(),
            hasAnyLimitData: !(codexLimits.isEmpty && claudeLimits.isEmpty)
        ) {
        case .none:
            return
        case .limitsOnly:
            await refresh(includeHistory: false)
        case .limitsAndHistory:
            await refresh(includeHistory: true)
        }
    }

    public func startAutomaticRefresh() {
        guard automaticRefreshTask == nil else { return }
        automaticRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                await self.refreshIfNeeded()
            }
        }
    }

    nonisolated static func refreshWork(
        lastUpdated: Date?,
        lastHistoryUpdated: Date?,
        now: Date,
        hasAnyLimitData: Bool = true
    ) -> RefreshWork {
        // The 60s cadence exists to avoid re-spawning the Codex app-server needlessly once we
        // already have something to show. If the last attempt came back with no limit data at all
        // for either provider, don't let that cooldown block a retry — every popover open should
        // get a fresh attempt instead of sitting on a stale "unavailable" state for up to a minute.
        if let lastUpdated, now.timeIntervalSince(lastUpdated) < 60, hasAnyLimitData {
            return .none
        }
        let historyIsStale = lastHistoryUpdated.map { now.timeIntervalSince($0) >= 15 * 60 } ?? true
        return historyIsStale ? .limitsAndHistory : .limitsOnly
    }

    public func selectProviderForQA(_ rawValue: String) {
        guard let provider = AIProvider(rawValue: rawValue) else { return }
        selectedProvider = provider
    }

    public func setWeeklyLimitForQA(remainingPercent: Int, severityRawValue: Int = 0) {
        guard CommandLine.arguments.contains("--qa-limit-configured"),
              let severity = WeeklyLimitSeverity(rawValue: severityRawValue) else { return }
        let limit = WeeklyUsageLimit(
            provider: selectedProvider,
            remainingPercent: remainingPercent,
            severity: severity
        )
        weeklyUsageLimits[selectedProvider] = [limit]
    }

    func selectRange(_ range: UsageTimeRange) {
        selectedHistoricalDay = nil
        selectedRange = range
    }

    func selectHistoricalDay(_ date: Date, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        if selectedRange == .oneDay,
           let selectedHistoricalDay,
           calendar.isDate(selectedHistoricalDay, inSameDayAs: day) {
            return
        }
        selectedHistoricalDay = day
        selectedRange = .oneDay
    }

    func clearHistoricalDay() {
        selectedHistoricalDay = nil
        selectedRange = .oneDay
    }

    func refresh() async {
        await refresh(includeHistory: true)
    }

    private func performHistoryScan() async -> ScanResult {
        let initialIndexRequired = await scanner.needsInitialIndex
        let largeHistoryFileCount = initialIndexRequired
            ? await scanner.historyFileCount(atLeast: Self.indexingFileThreshold)
            : nil
        if let largeHistoryFileCount {
            indexingFileCount = largeHistoryFileCount
            loadState = .loading("Indexing local history")
        }
        let scan = await scanner.scanAll()
        indexingFileCount = nil
        return scan
    }

    private func refresh(includeHistory: Bool) async {
        guard !isRefreshing else { return }
        Self.runtimeLog("refresh started")
        loadState = .loading(events.isEmpty ? "Reading local usage" : "Refreshing")

        // Start the (often much slower) history scan concurrently with the live-limit fetch below,
        // rather than only after it resolves. Live limits — and the reset/weekly-backfill data
        // derived from them a few lines down — can then populate as soon as they're ready, without
        // waiting on the full history index that only the historical graphs actually need.
        async let claudeUsage = claudeUsageReader.read()
        async let historyScan: ScanResult? = includeHistory ? await performHistoryScan() : nil

        let live = try? await codexClient.fetchLimits()

        if let live {
            Self.runtimeLog("live Codex limits loaded")
            codexLimits = live
            // When `includeHistory` is true, the history scan below recomputes
            // codexLimits/resetEvents from the same `live` buckets and calls
            // snapshotStore.observe/seedWeeklyBackfill again — skip the
            // duplicate call here so a single refresh doesn't record the same
            // observation twice.
            if !includeHistory {
                let persisted = await snapshotStore.observe(live)
                resetEvents = await snapshotStore.seedWeeklyBackfill(
                    from: live,
                    observedResets: persisted
                )
            }
            lastUpdated = Date()
        } else {
            warnings = ["Live Codex limits were unavailable; the newest local snapshot will be used after history indexing."]
        }

        // Do not let a stalled Claude OAuth call keep a completed Codex
        // app-server result hidden from the menu bar. Claude's bounded request
        // can finish independently while the Codex limit is already visible.
        let exactClaudeUsage = await claudeUsage
        if let exactClaudeUsage {
            claudeLimits = [exactClaudeUsage.limitBucket]
            claudeUsageSource = exactClaudeUsage.source
            claudeUsageObservedAt = exactClaudeUsage.observedAt
        } else if hasClaudeHistory {
            claudeLimits = EstimatedLimitBuilder.claudeLimits(events: events, resets: resetEvents)
            claudeUsageSource = nil
            claudeUsageObservedAt = nil
        } else {
            claudeLimits = []
            claudeUsageSource = nil
            claudeUsageObservedAt = nil
        }

        guard includeHistory, let scan = await historyScan else {
            lastUpdated = Date()
            loadState = codexLimits.isEmpty && events.isEmpty
                ? .failed("No Codex or Claude usage data was found on this Mac.")
                : .ready
            await evaluateQuotaResetNotifications()
            await evaluateWeeklyUsageLimits()
            Self.runtimeLog("live refresh complete")
            return
        }

        Self.runtimeLog("local history index loaded: \(scan.events.count) events")

        events = scan.events
        hasClaudeHistory = events.contains(where: { $0.provider == .claude })
        warnings = scan.warnings
        codexLimits = live ?? Self.limitsFromObservations(scan.observations)
        if live == nil {
            warnings.append("Live Codex limits were unavailable; showing the newest local snapshot where possible.")
        }

        let persisted = await snapshotStore.observe(codexLimits)
        let exactAndProviderWrittenResets = scan.resetEvents + persisted
        let estimatedClaudeLimits = EstimatedLimitBuilder.claudeLimits(
            events: events,
            resets: exactAndProviderWrittenResets
        )
        if let exactClaudeUsage {
            claudeLimits = [exactClaudeUsage.limitBucket]
            claudeUsageSource = exactClaudeUsage.source
            claudeUsageObservedAt = exactClaudeUsage.observedAt
        } else {
            claudeLimits = estimatedClaudeLimits
            claudeUsageSource = nil
            claudeUsageObservedAt = nil
        }
        let stored = await snapshotStore.seedWeeklyBackfill(
            from: codexLimits + claudeLimits,
            observedResets: exactAndProviderWrittenResets
        )
        var combinedResets = scan.resetEvents + stored
        combinedResets = Array(Dictionary(grouping: combinedResets, by: \.id).compactMap { $0.value.first })
            .sorted { $0.date < $1.date }
        resetEvents = combinedResets
        lastHistoryUpdated = Date()
        lastUpdated = Date()
        loadState = events.isEmpty && codexLimits.isEmpty
            ? .failed("No Codex or Claude usage data was found on this Mac.")
            : .ready
        await evaluateQuotaResetNotifications()
        await evaluateWeeklyUsageLimits()
        Self.runtimeLog("refresh complete")
    }

    func limits(for provider: AIProvider) -> [LimitBucket] {
        provider == .codex ? codexLimits : claudeLimits
    }

    func weeklyUsageLimits(for provider: AIProvider) -> [WeeklyUsageLimit] {
        (weeklyUsageLimits[provider] ?? []).sorted(by: WeeklyUsageLimit.displayOrder)
    }

    func setWeeklyUsageLimit(_ limit: WeeklyUsageLimit) {
        weeklyLimitStore.save(limit)
        weeklyUsageLimits = weeklyLimitStore.records().mapValues { $0.map(\.limit) }
        Task { @MainActor [weak self] in
            await self?.weeklyLimitActions.prepareNotifications()
            await self?.evaluateWeeklyUsageLimits()
        }
    }

    func deleteWeeklyUsageLimit(id: UUID, for provider: AIProvider) {
        weeklyLimitStore.delete(id: id, for: provider)
        weeklyUsageLimits = weeklyLimitStore.records().mapValues { $0.map(\.limit) }
    }

    func setQuotaResetNotificationMode(_ mode: QuotaResetNotificationMode) {
        quotaResetNotificationSettings.save(mode)
        quotaResetNotificationMode = mode
        guard mode.isEnabled else { return }
        Task { [quotaResetNotifications] in
            await quotaResetNotifications.prepare()
        }
    }

    func notificationAuthorizationState() async -> NotificationAuthorizationState {
        await notificationAuthorization.currentState()
    }

    func requestNotificationAuthorization() async -> NotificationAuthorizationState {
        await notificationAuthorization.request()
    }

    /// Applies the first-run draft as one settings transaction. Existing
    /// Preferences setters keep their established prompt behavior; onboarding
    /// uses this dedicated path so its Skip choice can persist standard reset
    /// notifications without requesting authorization until first delivery.
    func applyFirstRunSetup(
        iconConfiguration: MenuBarIconConfiguration,
        quotaResetMode: QuotaResetNotificationMode,
        editedLimits: [WeeklyUsageLimit],
        requestAuthorization: Bool
    ) async -> NotificationAuthorizationState {
        MenuBarIconPreferences.shared.configuration = iconConfiguration
        quotaResetNotificationSettings.save(quotaResetMode)
        quotaResetNotificationMode = quotaResetMode

        for limit in editedLimits {
            weeklyLimitStore.save(limit)
        }
        weeklyUsageLimits = weeklyLimitStore.records().mapValues { $0.map(\.limit) }

        if requestAuthorization {
            await quotaResetNotifications.prepare()
        }
        if !editedLimits.isEmpty {
            await evaluateWeeklyUsageLimits()
        }
        return await notificationAuthorization.currentState()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        LaunchAtLoginService.setEnabled(enabled)
        launchAtLoginEnabled = LaunchAtLoginService.isEnabled()
    }

    /// Keep the main menu-bar app registered for login startup. Rechecking on
    /// every ordinary cold launch repairs a stale or lost registration instead
    /// of trusting the historical first-run marker alone.
    public func ensureLaunchAtLoginEnabled() {
        launchAtLoginSettings.markAutoEnableRequested()
        setLaunchAtLoginEnabled(true)
    }

    func isProviderPaused(_ provider: AIProvider) -> Bool {
        !(pausedProviderTasks[provider] ?? []).isEmpty
    }

    func resumePausedTasks(for provider: AIProvider) {
        guard let pausedTasks = pausedProviderTasks[provider], !pausedTasks.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            let result = await weeklyLimitActions.resumePausedThreads(pausedTasks)
            pausedProviderTaskStore.set(result.failedTasks, for: provider)
            pausedProviderTasks = pausedProviderTaskStore.all()
        }
    }

    func weeklyWindow(for provider: AIProvider) -> RateLimitWindow? {
        let buckets = limits(for: provider)
        let preferredBucket = buckets.first { $0.id == provider.rawValue } ?? buckets.first
        return preferredBucket?.windows
            .filter { $0.kind == .weekly }
            .max { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }
    }

    private func evaluateWeeklyUsageLimits() async {
        var records = weeklyLimitStore.records()
        for provider in AIProvider.allCases {
            guard let providerRecords = records[provider],
                  let window = weeklyWindow(for: provider) else { continue }

            let remaining = window.remainingPercent
            for record in providerRecords {
                switch WeeklyUsageLimitEvaluator.decision(record: record, remainingPercent: remaining) {
                case .none:
                    continue
                case .rearm:
                    weeklyLimitStore.setFired(false, id: record.limit.id, for: provider)
                    records = weeklyLimitStore.records()
                case .trigger:
                    weeklyLimitStore.setFired(true, id: record.limit.id, for: provider)
                    records = weeklyLimitStore.records()
                    if let pauseResult = await weeklyLimitActions.perform(
                        limit: record.limit,
                        remainingPercent: remaining
                    ), !pauseResult.pausedTasks.isEmpty {
                        pausedProviderTaskStore.set(pauseResult.pausedTasks, for: provider)
                        pausedProviderTasks = pausedProviderTaskStore.all()
                    }
                }
            }
        }
        weeklyUsageLimits = records.mapValues { $0.map(\.limit) }
    }

    private func evaluateQuotaResetNotifications() async {
        let events = quotaResetTracker.observe(codexLimits + claudeLimits)
        await quotaResetNotifications.deliver(
            events: events,
            mode: quotaResetNotificationMode
        )
    }

    func filteredEvents(
        provider: AIProvider? = nil,
        range: UsageTimeRange? = nil,
        projectPath: String? = nil,
        now: Date = Date()
    ) -> [UsageEvent] {
        let provider = provider ?? selectedProvider
        let range = range ?? selectedRange
        let projectPath = projectPath ?? selectedProjectPath
        let period = usagePeriod(range: range, now: now)
        return Self.filterEvents(
            events,
            provider: provider,
            projectPath: projectPath,
            period: period
        )
    }

    func usagePeriod(
        range: UsageTimeRange? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsagePeriod {
        let range = range ?? selectedRange
        return UsagePeriod.resolve(
            range: range,
            historicalDay: range == .oneDay ? selectedHistoricalDay : nil,
            now: now,
            calendar: calendar
        )
    }

    nonisolated static func filterEvents(
        _ events: [UsageEvent],
        provider: AIProvider,
        projectPath: String?,
        period: UsagePeriod
    ) -> [UsageEvent] {
        events.filter { event in
            event.provider == provider
                && period.contains(event.timestamp)
                && (projectPath == nil || event.projectPath == projectPath)
        }
    }

    func chartPoints(
        provider: AIProvider? = nil,
        range: UsageTimeRange? = nil,
        projectPath: String? = nil,
        now: Date = Date()
    ) -> [UsageChartPoint] {
        let range = range ?? selectedRange
        let period = usagePeriod(range: range, now: now)
        let filtered = filteredEvents(provider: provider, range: range, projectPath: projectPath, now: now)
        var grouped: [Date: (credits: Double, usd: Double, tokens: Int64)] = [:]
        for event in filtered {
            let date = Self.bucketDate(event.timestamp, range: range)
            grouped[date, default: (0, 0, 0)].credits += event.credits
            grouped[date, default: (0, 0, 0)].usd += event.apiEquivalentUSD
            grouped[date, default: (0, 0, 0)].tokens += event.tokens.total
        }
        let points = grouped.map {
            UsageChartPoint(date: $0.key, credits: $0.value.credits, apiEquivalentUSD: $0.value.usd, tokens: $0.value.tokens)
        }.sorted { $0.date < $1.date }

        return Self.fillGaps(points, range: range, period: period)
    }

    func visibleResets(
        provider: AIProvider? = nil,
        range: UsageTimeRange? = nil,
        now: Date = Date()
    ) -> [ResetEvent] {
        let provider = provider ?? selectedProvider
        let range = range ?? selectedRange
        let period = usagePeriod(range: range, now: now)
        let relevantKind: ResetKind = switch range {
        case .fiveHours, .oneDay: .session
        case .sevenDays, .thirtyDays: .weekly
        }
        let observed = Self.observedResetMarkers(
            from: resetEvents,
            provider: provider,
            kind: relevantKind,
            period: period,
            now: now
        )
        guard relevantKind == .session else { return observed }

        let scheduled = Self.sessionResetSchedule(
            from: limits(for: provider),
            provider: provider,
            period: period,
            now: now
        )
        return Self.deduplicateVisibleResets(observed + scheduled, kind: .session)
    }

    /// Chart seams include both observed resets and the app's known reset
    /// schedule. Scheduled session seams remain visibly distinguished by their
    /// estimated confidence, so the 1d chart can show every expected rolling
    /// reset without presenting it as directly observed evidence.
    nonisolated static func observedResetMarkers(
        from resetEvents: [ResetEvent],
        provider: AIProvider,
        kind: ResetKind,
        period: UsagePeriod,
        now: Date
    ) -> [ResetEvent] {
        let observed = resetEvents.filter {
            $0.provider == provider
                && $0.kind == kind
                && period.contains($0.date)
                && $0.date <= now
        }
        return deduplicateVisibleResets(observed, kind: kind)
    }

    /// A live `resetsAt` timestamp gives us a concrete rolling-window cadence.
    /// Reconstruct just the visible past boundaries from it; do not persist
    /// them, because the next live limit response remains authoritative.
    nonisolated static func sessionResetSchedule(
        from buckets: [LimitBucket],
        provider: AIProvider,
        period: UsagePeriod,
        now: Date
    ) -> [ResetEvent] {
        buckets.flatMap { bucket in
            bucket.windows.compactMap { window -> [ResetEvent]? in
                guard window.kind == .session,
                      let resetAt = window.resetsAt,
                      let durationMinutes = window.durationMinutes,
                      durationMinutes > 0 else {
                    return nil
                }

                let interval = TimeInterval(durationMinutes * 60)
                var date = resetAt
                while date > now {
                    date = date.addingTimeInterval(-interval)
                }
                while date.addingTimeInterval(interval) <= now {
                    date = date.addingTimeInterval(interval)
                }

                var markers: [ResetEvent] = []
                while date >= period.start {
                    if period.contains(date) {
                        markers.append(
                            ResetEvent(
                                id: "schedule:\(provider.rawValue):\(bucket.id):\(durationMinutes):\(Int(date.timeIntervalSince1970))",
                                provider: provider,
                                date: date,
                                detectedAt: now,
                                kind: .session,
                                bucketID: bucket.id,
                                label: "\(bucket.displayName) session reset (estimated schedule)",
                                confidence: .estimated
                            )
                        )
                    }
                    date = date.addingTimeInterval(-interval)
                }
                return markers
            }.flatMap { $0 }
        }
    }

    nonisolated static func deduplicateVisibleResets(
        _ resets: [ResetEvent],
        kind: ResetKind
    ) -> [ResetEvent] {
        let tolerance: TimeInterval = kind == .weekly ? 12 * 3_600 : 120
        var result: [ResetEvent] = []
        for candidate in resets.sorted(by: { $0.date < $1.date }) {
            let index = result.firstIndex {
                return $0.provider == candidate.provider
                    && $0.kind == candidate.kind
                    && $0.bucketID == candidate.bucketID
                    && abs($0.date.timeIntervalSince(candidate.date)) <= tolerance
            }
            if let index {
                if candidate.confidence == .exact, result[index].confidence != .exact {
                    result[index] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    func modelSummaries() -> [ModelCostSummary] {
        let grouped = Dictionary(grouping: filteredEvents(), by: \.model)
        return grouped.map { model, values in
            ModelCostSummary(
                model: model,
                credits: values.reduce(0) { $0 + $1.credits },
                apiEquivalentUSD: values.reduce(0) { $0 + $1.apiEquivalentUSD },
                tokens: values.reduce(TokenUsage()) { $0 + $1.tokens },
                isEstimate: values.contains(where: \.pricingWasEstimated)
            )
        }.sorted { $0.apiEquivalentUSD > $1.apiEquivalentUSD }
    }

    func projectCreditSeries(
        maxNamedProjects: Int = 7,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ProjectCreditSeries] {
        let range = selectedRange
        let period = usagePeriod(range: range, now: now, calendar: calendar)
        return Self.buildProjectCreditSeries(
            events: filteredEvents(now: now),
            bucketDates: Self.bucketDates(range: range, period: period, calendar: calendar),
            range: range,
            calendar: calendar,
            maxNamedProjects: maxNamedProjects
        )
    }

    nonisolated static func buildProjectCreditSeries(
        events: [UsageEvent],
        bucketDates: [Date],
        range: UsageTimeRange,
        calendar: Calendar,
        maxNamedProjects: Int = 7
    ) -> [ProjectCreditSeries] {
        guard !events.isEmpty, !bucketDates.isEmpty, maxNamedProjects > 0 else { return [] }

        let byPath = Dictionary(grouping: events, by: \.projectPath)
        let totalsByPath = byPath.mapValues { $0.reduce(0) { $0 + $1.credits } }
        let namesByPath = byPath.compactMapValues { values in
            values.max(by: { $0.timestamp < $1.timestamp })?.projectName
        }
        let rankedPaths = totalsByPath.keys.sorted {
            let lhs = totalsByPath[$0, default: 0]
            let rhs = totalsByPath[$1, default: 0]
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        let namedPaths = Array(rankedPaths.prefix(maxNamedProjects))
        let namedPathSet = Set(namedPaths)
        let remainingPaths = rankedPaths.filter { !namedPathSet.contains($0) }
        let otherID = "__other_projects__"

        let duplicateCounts = Dictionary(grouping: namedPaths, by: { namesByPath[$0, default: $0] })
            .mapValues(\.count)
        var names: [String: String] = [:]
        for path in namedPaths {
            let base = namesByPath[path, default: URL(filePath: path).lastPathComponent]
            if duplicateCounts[base, default: 0] > 1 {
                let parent = URL(filePath: path).deletingLastPathComponent().lastPathComponent
                names[path] = parent.isEmpty ? base : "\(base) · \(parent)"
            } else {
                names[path] = base
            }
        }

        var descriptors = namedPaths.map {
            (id: $0, name: names[$0, default: $0], total: totalsByPath[$0, default: 0], isOther: false)
        }
        if !remainingPaths.isEmpty {
            descriptors.append(
                (
                    id: otherID,
                    name: "Other",
                    total: remainingPaths.reduce(0) { $0 + totalsByPath[$1, default: 0] },
                    isOther: true
                )
            )
        }
        descriptors.sort {
            if $0.total != $1.total { return $0.total > $1.total }
            if $0.isOther != $1.isOther { return !$0.isOther }
            return $0.name < $1.name
        }

        let bucketSet = Set(bucketDates)
        var creditsBySeries: [String: [Date: Double]] = [:]
        for event in events {
            let seriesID = namedPathSet.contains(event.projectPath) ? event.projectPath : otherID
            guard descriptors.contains(where: { $0.id == seriesID }) else { continue }
            let bucket = bucketDate(event.timestamp, range: range, calendar: calendar)
            guard bucketSet.contains(bucket) else { continue }
            creditsBySeries[seriesID, default: [:]][bucket, default: 0] += event.credits
        }

        var pointsBySeries: [String: [ProjectCreditPoint]] = [:]
        for date in bucketDates {
            var cumulative = 0.0
            for descriptor in descriptors {
                let credits = creditsBySeries[descriptor.id]?[date, default: 0] ?? 0
                let lower = cumulative
                cumulative += credits
                pointsBySeries[descriptor.id, default: []].append(
                    ProjectCreditPoint(
                        date: date,
                        seriesID: descriptor.id,
                        seriesName: descriptor.name,
                        credits: credits,
                        lowerCredits: lower,
                        upperCredits: cumulative
                    )
                )
            }
        }

        return descriptors.map { descriptor in
            ProjectCreditSeries(
                id: descriptor.id,
                name: descriptor.name,
                totalCredits: descriptor.total,
                isOther: descriptor.isOther,
                points: pointsBySeries[descriptor.id, default: []]
            )
        }
    }

    func dailyRows(limit: Int = 200) -> [DailyUsageRow] {
        let grouped = Dictionary(grouping: filteredEvents()) { event in
            let day = Calendar.current.startOfDay(for: event.timestamp)
            return "\(day.timeIntervalSince1970):\(event.model):\(event.projectPath)"
        }
        return grouped.compactMap { id, values in
            guard let first = values.first else { return nil }
            return DailyUsageRow(
                id: id,
                date: Calendar.current.startOfDay(for: first.timestamp),
                model: first.model,
                projectName: first.projectName,
                tokens: values.reduce(TokenUsage()) { $0 + $1.tokens },
                credits: values.reduce(0) { $0 + $1.credits },
                apiEquivalentUSD: values.reduce(0) { $0 + $1.apiEquivalentUSD },
                isEstimate: values.contains(where: \.pricingWasEstimated)
            )
        }.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.apiEquivalentUSD > rhs.apiEquivalentUSD
        }.prefix(limit).map { $0 }
    }

    func totalCredits(range: UsageTimeRange? = nil) -> Double {
        filteredEvents(range: range).reduce(0) { $0 + $1.credits }
    }

    func totalUSD(range: UsageTimeRange? = nil) -> Double {
        filteredEvents(range: range).reduce(0) { $0 + $1.apiEquivalentUSD }
    }

    func totalTokens(range: UsageTimeRange? = nil) -> Int64 {
        filteredEvents(range: range).reduce(0) { $0 + $1.tokens.total }
    }

    private static func limitsFromObservations(_ observations: [RateObservation]) -> [LimitBucket] {
        let latestByWindow = Dictionary(grouping: observations, by: {
            "\($0.bucketID):\($0.durationMinutes ?? -1)"
        }).compactMapValues { $0.max(by: { $0.observedAt < $1.observedAt }) }
        let grouped = Dictionary(grouping: Array(latestByWindow.values), by: \.bucketID)
        return grouped.map { id, values in
            LimitBucket(
                id: id,
                provider: .codex,
                displayName: values.first?.bucketName ?? id,
                planType: nil,
                windows: values.map {
                    RateLimitWindow(
                        usedPercent: $0.usedPercent,
                        durationMinutes: $0.durationMinutes,
                        resetsAt: $0.resetsAt,
                        confidence: .exact,
                        estimateBasis: nil
                    )
                }.sorted { ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max) },
                confidence: .exact,
                sourceDescription: "Newest Codex session snapshot"
            )
        }.sorted { $0.id == "codex" && $1.id != "codex" }
    }

    nonisolated private static func bucketDate(
        _ date: Date,
        range: UsageTimeRange,
        calendar: Calendar = .current
    ) -> Date {
        switch range {
        case .fiveHours:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .oneDay:
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            var rounded = components
            rounded.hour = (components.hour ?? 0) / 2 * 2
            return calendar.date(from: rounded) ?? date
        case .sevenDays, .thirtyDays:
            return calendar.startOfDay(for: date)
        }
    }

    private static func fillGaps(
        _ points: [UsageChartPoint],
        range: UsageTimeRange,
        period: UsagePeriod,
        calendar: Calendar = .current
    ) -> [UsageChartPoint] {
        let byDate = Dictionary(uniqueKeysWithValues: points.map { ($0.date, $0) })
        return bucketDates(range: range, period: period, calendar: calendar).map { date in
            byDate[date] ?? UsageChartPoint(date: date, credits: 0, apiEquivalentUSD: 0, tokens: 0)
        }
    }

    private static func bucketDates(
        range: UsageTimeRange,
        period: UsagePeriod,
        calendar: Calendar
    ) -> [Date] {
        let finalMoment = max(period.start, period.end.addingTimeInterval(-0.001))
        let finalBucket = bucketDate(finalMoment, range: range, calendar: calendar)
        var date = bucketDate(period.start, range: range, calendar: calendar)
        var result: [Date] = []

        while date <= finalBucket {
            result.append(date)
            let next: Date? = switch range {
            case .fiveHours:
                calendar.date(byAdding: .hour, value: 1, to: date)
            case .oneDay:
                calendar.date(byAdding: .hour, value: 2, to: date)
            case .sevenDays, .thirtyDays:
                calendar.date(byAdding: .day, value: 1, to: date)
            }
            guard let next, next > date else { break }
            date = next
        }

        return result
    }

    private static func runtimeLog(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("[QuotaWise] \(message)\n".utf8))
    }
}
