import AppKit
import Foundation
import UserNotifications

enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case allowed
    case denied
}

protocol NotificationAuthorizationProviding: Sendable {
    func currentState() async -> NotificationAuthorizationState
    func request() async -> NotificationAuthorizationState
}

struct SystemNotificationAuthorizationProvider: NotificationAuthorizationProviding {
    func currentState() async -> NotificationAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.state(for: settings.authorizationStatus)
    }

    func request() async -> NotificationAuthorizationState {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await currentState()
    }

    private static func state(for status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized, .provisional, .ephemeral:
            .allowed
        @unknown default:
            .denied
        }
    }
}

enum QuotaResetNotificationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case notification
    case persistentNotification

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .notification: "Notification"
        case .persistentNotification: "Persistent"
        }
    }

    var detail: String {
        switch self {
        case .off:
            "QuotaWise will keep tracking quota resets without alerting you."
        case .notification:
            "Send a standard macOS notification when a tracked quota returns to 100% remaining."
        case .persistentNotification:
            "Show an alert that stays visible until you dismiss it when a tracked quota returns to 100% remaining."
        }
    }

    var isEnabled: Bool { self != .off }
    var isPersistent: Bool { self == .persistentNotification }
}

final class QuotaResetNotificationSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "quota-reset-notification-mode-v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> QuotaResetNotificationMode {
        lock.lock()
        defer { lock.unlock() }
        guard let rawValue = defaults.string(forKey: key) else { return .off }
        return QuotaResetNotificationMode(rawValue: rawValue) ?? .off
    }

    func save(_ mode: QuotaResetNotificationMode) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(mode.rawValue, forKey: key)
    }
}

struct QuotaResetWindowObservation: Codable, Equatable, Sendable {
    let remainingPercent: Double
    let resetsAt: Date?
}

struct QuotaResetNotificationEvent: Equatable, Sendable {
    let provider: AIProvider
    let bucketID: String
    let bucketName: String
    let windowLabel: String
}

final class QuotaResetTracker: @unchecked Sendable {
    static let displayedFullThreshold = 99.5

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "quota-reset-observations-v1") {
        self.defaults = defaults
        self.key = key
    }

    func observe(_ limits: [LimitBucket]) -> [QuotaResetNotificationEvent] {
        lock.lock()
        defer { lock.unlock() }

        var observations = readLocked()
        var events: [QuotaResetNotificationEvent] = []

        for bucket in Self.primaryBuckets(from: limits) {
            for window in bucket.windows {
                let observationKey = Self.observationKey(bucket: bucket, window: window)
                let current = QuotaResetWindowObservation(
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt
                )

                if let previous = observations[observationKey],
                   previous.remainingPercent < Self.displayedFullThreshold,
                   current.remainingPercent >= Self.displayedFullThreshold {
                    events.append(
                        QuotaResetNotificationEvent(
                            provider: bucket.provider,
                            bucketID: bucket.id,
                            bucketName: bucket.displayName,
                            windowLabel: window.durationLabel
                        )
                    )
                }
                observations[observationKey] = current
            }
        }

        writeLocked(observations)
        return events
    }

    private static func primaryBuckets(from limits: [LimitBucket]) -> [LimitBucket] {
        AIProvider.allCases.compactMap { provider in
            let providerBuckets = limits.filter { $0.provider == provider }
            return providerBuckets.first { $0.id == provider.rawValue } ?? providerBuckets.first
        }
    }

    private static func observationKey(bucket: LimitBucket, window: RateLimitWindow) -> String {
        "\(bucket.provider.rawValue)|\(bucket.id)|\(window.durationMinutes ?? -1)"
    }

    private func readLocked() -> [String: QuotaResetWindowObservation] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: QuotaResetWindowObservation].self, from: data) else {
            return [:]
        }
        return values
    }

    private func writeLocked(_ values: [String: QuotaResetWindowObservation]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }
}

protocol QuotaResetNotifying: Sendable {
    func prepare() async
    func notify(event: QuotaResetNotificationEvent, persistent: Bool) async
}

protocol QuotaResetNotificationHandling: Sendable {
    func prepare() async
    func deliver(events: [QuotaResetNotificationEvent], mode: QuotaResetNotificationMode) async
}

actor QuotaResetNotificationHandler: QuotaResetNotificationHandling {
    private let notifier: any QuotaResetNotifying

    init(notifier: any QuotaResetNotifying = SystemQuotaResetNotifier()) {
        self.notifier = notifier
    }

    func prepare() async {
        await notifier.prepare()
    }

    func deliver(events: [QuotaResetNotificationEvent], mode: QuotaResetNotificationMode) async {
        guard mode.isEnabled else { return }
        for event in events {
            await notifier.notify(event: event, persistent: mode.isPersistent)
        }
    }
}

final class SystemQuotaResetNotifier: QuotaResetNotifying, @unchecked Sendable {
    func prepare() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func notify(event: QuotaResetNotificationEvent, persistent: Bool) async {
        let title = "\(event.provider.displayName) quota reset"
        let bucketPrefix = event.bucketName == event.provider.displayName ? "" : "\(event.bucketName) "
        let message = "\(bucketPrefix)\(event.windowLabel) quota is back to 100% remaining."
        let center = UNUserNotificationCenter.current()

        if (try? await center.requestAuthorization(options: [.alert, .sound])) == true {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            content.threadIdentifier = "quota-reset-\(event.provider.rawValue)"
            let request = UNNotificationRequest(
                identifier: "quota-reset-\(event.provider.rawValue)-\(event.bucketID)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }

        guard persistent else { return }
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .informational
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
