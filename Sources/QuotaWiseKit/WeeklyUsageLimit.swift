import AppKit
import Darwin
import Foundation
import UserNotifications

enum WeeklyLimitSeverity: Int, CaseIterable, Codable, Identifiable, Sendable {
    case notification = 0
    case persistentNotification = 1
    case pauseThreads = 2
    case quitProvider = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .notification: "Notification"
        case .persistentNotification: "Persistent notification"
        case .pauseThreads: "Pause active threads"
        case .quitProvider: "Quit provider"
        }
    }

    var systemImage: String {
        switch self {
        case .notification: "bell"
        case .persistentNotification: "bell.badge"
        case .pauseThreads: "pause.fill"
        case .quitProvider: "power"
        }
    }

    func title(for provider: AIProvider) -> String {
        switch self {
        case .quitProvider: "Quit \(provider.displayName)"
        default: title
        }
    }

    func detail(for provider: AIProvider) -> String {
        switch self {
        case .notification:
            "Send a standard notification."
        case .persistentNotification:
            "Keep an alert visible until you dismiss it."
        case .pauseThreads:
            "Pause active \(provider.displayName) work. The panel can resume exactly the work it paused."
        case .quitProvider:
            "Force quit \(provider.displayName) and its active work."
        }
    }
}

struct WeeklyUsageLimit: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let provider: AIProvider
    var remainingPercent: Int
    var severity: WeeklyLimitSeverity

    init(id: UUID = UUID(), provider: AIProvider, remainingPercent: Int, severity: WeeklyLimitSeverity) {
        self.id = id
        self.provider = provider
        self.remainingPercent = min(100, max(1, remainingPercent))
        self.severity = severity
    }

    /// Highest remaining-percent threshold first; thresholds at the same
    /// percent are ordered from the mildest response to the most severe.
    static func displayOrder(_ lhs: WeeklyUsageLimit, _ rhs: WeeklyUsageLimit) -> Bool {
        if lhs.remainingPercent != rhs.remainingPercent {
            return lhs.remainingPercent > rhs.remainingPercent
        }
        return lhs.severity.rawValue < rhs.severity.rawValue
    }
}

struct WeeklyUsageLimitRecord: Codable, Equatable, Sendable {
    var limit: WeeklyUsageLimit
    var hasFired: Bool
}

enum WeeklyUsageLimitTriggerDecision: Equatable, Sendable {
    case none
    case rearm
    case trigger
}

enum WeeklyUsageLimitEvaluator {
    /// Fires once per crossing from above the threshold to at/below it; rearms
    /// only once usage climbs back above the threshold. No reset-window
    /// bookkeeping is involved.
    static func decision(
        record: WeeklyUsageLimitRecord,
        remainingPercent: Double
    ) -> WeeklyUsageLimitTriggerDecision {
        if remainingPercent > Double(record.limit.remainingPercent) {
            return record.hasFired ? .rearm : .none
        }
        return record.hasFired ? .none : .trigger
    }
}

final class WeeklyUsageLimitStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        key: String = "weekly-usage-limits-v2",
        legacyKey: String = "weekly-usage-limits-v1"
    ) {
        self.defaults = defaults
        self.key = key
        self.legacyKey = legacyKey
    }

    func records() -> [AIProvider: [WeeklyUsageLimitRecord]] {
        lock.lock()
        defer { lock.unlock() }
        return readLocked()
    }

    func limits(for provider: AIProvider) -> [WeeklyUsageLimit] {
        (records()[provider] ?? []).map(\.limit)
    }

    func save(_ limit: WeeklyUsageLimit, resetTrigger: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        var values = readLocked()
        var providerRecords = values[limit.provider] ?? []
        if let index = providerRecords.firstIndex(where: { $0.limit.id == limit.id }) {
            let priorHasFired = resetTrigger ? false : providerRecords[index].hasFired
            providerRecords[index] = WeeklyUsageLimitRecord(limit: limit, hasFired: priorHasFired)
        } else {
            providerRecords.append(WeeklyUsageLimitRecord(limit: limit, hasFired: false))
        }
        values[limit.provider] = providerRecords
        writeLocked(values)
    }

    func delete(id: UUID, for provider: AIProvider) {
        lock.lock()
        defer { lock.unlock() }
        var values = readLocked()
        values[provider]?.removeAll { $0.limit.id == id }
        if values[provider]?.isEmpty == true {
            values.removeValue(forKey: provider)
        }
        writeLocked(values)
    }

    func setFired(_ fired: Bool, id: UUID, for provider: AIProvider) {
        lock.lock()
        defer { lock.unlock() }
        var values = readLocked()
        guard var providerRecords = values[provider],
              let index = providerRecords.firstIndex(where: { $0.limit.id == id }) else { return }
        providerRecords[index].hasFired = fired
        values[provider] = providerRecords
        writeLocked(values)
    }

    private func readLocked() -> [AIProvider: [WeeklyUsageLimitRecord]] {
        if let data = defaults.data(forKey: key),
           let raw = try? JSONDecoder().decode([String: [WeeklyUsageLimitRecord]].self, from: data) {
            return Dictionary(uniqueKeysWithValues: raw.compactMap { rawProvider, records in
                AIProvider(rawValue: rawProvider).map { ($0, records) }
            })
        }
        return migrateLegacyIfNeeded()
    }

    private struct LegacyLimit: Codable {
        var provider: AIProvider
        var remainingPercent: Int
        var severity: WeeklyLimitSeverity
    }

    private struct LegacyRecord: Codable {
        var limit: LegacyLimit
        var triggeredWindowKey: String?
    }

    private func migrateLegacyIfNeeded() -> [AIProvider: [WeeklyUsageLimitRecord]] {
        guard let data = defaults.data(forKey: legacyKey),
              let raw = try? JSONDecoder().decode([String: LegacyRecord].self, from: data) else {
            return [:]
        }
        var migrated: [AIProvider: [WeeklyUsageLimitRecord]] = [:]
        for (rawProvider, legacy) in raw {
            guard let provider = AIProvider(rawValue: rawProvider) else { continue }
            let limit = WeeklyUsageLimit(
                provider: provider,
                remainingPercent: legacy.limit.remainingPercent,
                severity: legacy.limit.severity
            )
            migrated[provider] = [WeeklyUsageLimitRecord(limit: limit, hasFired: legacy.triggeredWindowKey != nil)]
        }
        writeLocked(migrated)
        defaults.removeObject(forKey: legacyKey)
        return migrated
    }

    private func writeLocked(_ values: [AIProvider: [WeeklyUsageLimitRecord]]) {
        let raw = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: key)
    }
}

protocol ProviderProcessDiscovering: Sendable {
    func processIDs(for provider: AIProvider, includeApplication: Bool) -> Set<pid_t>
}

struct PausedProviderTask: Codable, Equatable, Sendable {
    let processID: pid_t
    let startIdentity: String
}

protocol ProviderProcessInspecting: Sendable {
    func activeIdentity(for processID: pid_t) -> String?
    func matches(_ pausedTask: PausedProviderTask) -> Bool
}

struct SystemProviderProcessInspector: ProviderProcessInspecting {
    func activeIdentity(for processID: pid_t) -> String? {
        guard let sample = sample(for: processID),
              !sample.state.contains("T"),
              !sample.state.contains("Z") else { return nil }
        return sample.startIdentity
    }

    func matches(_ pausedTask: PausedProviderTask) -> Bool {
        sample(for: pausedTask.processID)?.startIdentity == pausedTask.startIdentity
    }

    private func sample(for processID: pid_t) -> (state: String, startIdentity: String)? {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-o", "lstart=", "-p", "\(processID)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let line = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard fields.count == 2 else { return nil }
        return (String(fields[0]), String(fields[1]))
    }
}

struct PauseThreadsResult: Equatable, Sendable {
    let pausedTasks: [PausedProviderTask]
    let failedProcessIDs: [pid_t]

    var succeeded: Bool { failedProcessIDs.isEmpty }
}

struct ResumeThreadsResult: Equatable, Sendable {
    let resumedTasks: [PausedProviderTask]
    let staleTasks: [PausedProviderTask]
    let failedTasks: [PausedProviderTask]
}

struct SystemProviderProcessDiscovery: ProviderProcessDiscovering {
    func processIDs(for provider: AIProvider, includeApplication: Bool) -> Set<pid_t> {
        var result = Set<pid_t>()
        if includeApplication {
            for bundleID in provider.bundleIdentifiers {
                result.formUnion(
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                        .map(\.processIdentifier)
                )
            }
        }
        for processName in provider.executableNames {
            result.formUnion(exactProcessIDs(named: processName))
        }
        result.remove(getpid())
        return result
    }

    private func exactProcessIDs(named name: String) -> Set<pid_t> {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return Set(text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) })
    }
}

extension AIProvider {
    fileprivate var bundleIdentifiers: [String] {
        switch self {
        case .codex: ["com.openai.codex"]
        case .claude: ["com.anthropic.claudefordesktop"]
        }
    }

    fileprivate var executableNames: [String] {
        switch self {
        case .codex: ["codex"]
        case .claude: ["claude"]
        }
    }
}

struct ProviderProcessController: Sendable {
    private let discovery: any ProviderProcessDiscovering
    private let inspector: any ProviderProcessInspecting
    private let signal: @Sendable (pid_t, Int32) -> Int32
    private let wait: @Sendable (TimeInterval) -> Void

    init(
        discovery: any ProviderProcessDiscovering = SystemProviderProcessDiscovery(),
        inspector: any ProviderProcessInspecting = SystemProviderProcessInspector(),
        signal: @escaping @Sendable (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) },
        wait: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.discovery = discovery
        self.inspector = inspector
        self.signal = signal
        self.wait = wait
    }

    func pauseThreads(for provider: AIProvider) -> PauseThreadsResult {
        let processIDs = discovery.processIDs(for: provider, includeApplication: false)
        var pausedTasks: [PausedProviderTask] = []
        var failedProcessIDs: [pid_t] = []
        for processID in processIDs.sorted() {
            guard let startIdentity = inspector.activeIdentity(for: processID) else { continue }
            if signal(processID, SIGSTOP) == 0 {
                pausedTasks.append(PausedProviderTask(processID: processID, startIdentity: startIdentity))
            } else {
                failedProcessIDs.append(processID)
            }
        }
        return PauseThreadsResult(pausedTasks: pausedTasks, failedProcessIDs: failedProcessIDs)
    }

    func resumeThreads(_ pausedTasks: [PausedProviderTask]) -> ResumeThreadsResult {
        var resumedTasks: [PausedProviderTask] = []
        var staleTasks: [PausedProviderTask] = []
        var failedTasks: [PausedProviderTask] = []
        for task in pausedTasks {
            guard inspector.matches(task) else {
                staleTasks.append(task)
                continue
            }
            if signal(task.processID, SIGCONT) == 0 {
                resumedTasks.append(task)
            } else {
                failedTasks.append(task)
            }
        }
        return ResumeThreadsResult(
            resumedTasks: resumedTasks,
            staleTasks: staleTasks,
            failedTasks: failedTasks
        )
    }

    func forceQuit(_ provider: AIProvider, attempts: Int = 4) -> Bool {
        for _ in 0..<max(1, attempts) {
            let processIDs = discovery.processIDs(for: provider, includeApplication: true)
            guard !processIDs.isEmpty else { return true }
            for processID in processIDs {
                _ = signal(processID, SIGKILL)
            }
            wait(0.15)
        }
        return discovery.processIDs(for: provider, includeApplication: true).isEmpty
    }
}

protocol UsageLimitNotifying: Sendable {
    func prepare() async
    func notify(provider: AIProvider, title: String, message: String, persistent: Bool) async
}

final class SystemUsageLimitNotifier: UsageLimitNotifying, @unchecked Sendable {
    func prepare() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func notify(provider: AIProvider, title: String, message: String, persistent: Bool) async {
        let center = UNUserNotificationCenter.current()
        if (try? await center.requestAuthorization(options: [.alert, .sound])) == true {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            content.threadIdentifier = "weekly-limit-\(provider.rawValue)"
            let request = UNNotificationRequest(
                identifier: "weekly-limit-\(provider.rawValue)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }

        guard persistent else { return }
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Dismiss")
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

protocol UsageLimitActionHandling: Sendable {
    func prepareNotifications() async
    func perform(limit: WeeklyUsageLimit, remainingPercent: Double) async -> PauseThreadsResult?
    func resumePausedThreads(_ pausedTasks: [PausedProviderTask]) async -> ResumeThreadsResult
}

actor SystemUsageLimitActionHandler: UsageLimitActionHandling {
    private let processes: ProviderProcessController
    private let notifier: any UsageLimitNotifying

    init(
        processes: ProviderProcessController = ProviderProcessController(),
        notifier: any UsageLimitNotifying = SystemUsageLimitNotifier()
    ) {
        self.processes = processes
        self.notifier = notifier
    }

    func prepareNotifications() async {
        await notifier.prepare()
    }

    func perform(limit: WeeklyUsageLimit, remainingPercent: Double) async -> PauseThreadsResult? {
        let provider = limit.provider
        let thresholdMessage = "Weekly usage has \(Int(remainingPercent.rounded()))% remaining."
        let title = "\(provider.displayName) limit reached"

        switch limit.severity {
        case .notification:
            await notifier.notify(provider: provider, title: title, message: thresholdMessage, persistent: false)
            return nil
        case .persistentNotification:
            await notifier.notify(provider: provider, title: title, message: thresholdMessage, persistent: true)
            return nil
        case .pauseThreads:
            let result = processes.pauseThreads(for: provider)
            let message = result.succeeded
                ? "\(thresholdMessage) Active \(provider.displayName) work was paused."
                : "\(thresholdMessage) Active \(provider.displayName) work could not be paused."
            await notifier.notify(provider: provider, title: title, message: message, persistent: !result.succeeded)
            return result
        case .quitProvider:
            let succeeded = processes.forceQuit(provider)
            let message = succeeded
                ? "\(thresholdMessage) \(provider.displayName) was quit."
                : "\(thresholdMessage) \(provider.displayName) could not be quit."
            await notifier.notify(provider: provider, title: title, message: message, persistent: !succeeded)
            return nil
        }
    }

    func resumePausedThreads(_ pausedTasks: [PausedProviderTask]) async -> ResumeThreadsResult {
        processes.resumeThreads(pausedTasks)
    }
}

final class PausedProviderTaskStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "weekly-usage-paused-tasks-v1") {
        self.defaults = defaults
        self.key = key
    }

    func all() -> [AIProvider: [PausedProviderTask]] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: [PausedProviderTask]].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { provider, tasks in
            AIProvider(rawValue: provider).map { ($0, tasks) }
        })
    }

    func set(_ tasks: [PausedProviderTask], for provider: AIProvider) {
        lock.lock()
        defer { lock.unlock() }
        var values = allLocked()
        if tasks.isEmpty {
            values.removeValue(forKey: provider)
        } else {
            values[provider] = tasks
        }
        let raw = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: key)
    }

    private func allLocked() -> [AIProvider: [PausedProviderTask]] {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: [PausedProviderTask]].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { provider, tasks in
            AIProvider(rawValue: provider).map { ($0, tasks) }
        })
    }
}
