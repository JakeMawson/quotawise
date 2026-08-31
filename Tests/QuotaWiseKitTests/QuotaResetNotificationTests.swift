import SwiftUI
import XCTest
@testable import QuotaWiseKit

final class QuotaResetNotificationTests: XCTestCase {
    func testFirstFullObservationCreatesBaselineWithoutNotification() throws {
        let suiteName = "QuotaWiseKitTests.quota-reset-first-full.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tracker = QuotaResetTracker(defaults: defaults, key: "observations")

        XCTAssertTrue(tracker.observe([Self.bucket(usedPercent: 0)]).isEmpty)
        XCTAssertTrue(tracker.observe([Self.bucket(usedPercent: 0)]).isEmpty)
    }

    func testBelowFullToDisplayedFullTransitionNotifiesOnceAndRearms() throws {
        let suiteName = "QuotaWiseKitTests.quota-reset-transition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tracker = QuotaResetTracker(defaults: defaults, key: "observations")

        XCTAssertTrue(tracker.observe([Self.bucket(usedPercent: 38)]).isEmpty)
        let firstReset = tracker.observe([Self.bucket(usedPercent: 0.4)])
        XCTAssertEqual(firstReset.count, 1)
        XCTAssertEqual(firstReset.first?.provider, .codex)
        XCTAssertEqual(firstReset.first?.windowLabel, "5-hour")
        XCTAssertTrue(tracker.observe([Self.bucket(usedPercent: 0)]).isEmpty)

        XCTAssertTrue(tracker.observe([Self.bucket(usedPercent: 12)]).isEmpty)
        XCTAssertEqual(tracker.observe([Self.bucket(usedPercent: 0)]).count, 1)
    }

    func testValueThatDoesNotDisplayAsFullDoesNotNotify() throws {
        let suiteName = "QuotaWiseKitTests.quota-reset-threshold.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tracker = QuotaResetTracker(defaults: defaults, key: "observations")

        _ = tracker.observe([Self.bucket(usedPercent: 25)])
        XCTAssertTrue(tracker.observe([Self.bucket(usedPercent: 0.51)]).isEmpty)
        XCTAssertEqual(tracker.observe([Self.bucket(usedPercent: 0.5)]).count, 1)
    }

    func testObservationStateSurvivesTrackerRecreation() throws {
        let suiteName = "QuotaWiseKitTests.quota-reset-persistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = QuotaResetTracker(defaults: defaults, key: "observations")
        XCTAssertTrue(first.observe([Self.bucket(usedPercent: 44)]).isEmpty)

        let recreated = QuotaResetTracker(defaults: defaults, key: "observations")
        XCTAssertEqual(recreated.observe([Self.bucket(usedPercent: 0)]).count, 1)
        XCTAssertTrue(recreated.observe([Self.bucket(usedPercent: 0)]).isEmpty)
    }

    func testNotificationModeDefaultsPersistsAndMapsPersistenceBehavior() throws {
        let suiteName = "QuotaWiseKitTests.quota-reset-mode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QuotaResetNotificationSettingsStore(defaults: defaults, key: "mode")

        XCTAssertEqual(store.load(), .off)
        XCTAssertFalse(QuotaResetNotificationMode.notification.isPersistent)
        XCTAssertTrue(QuotaResetNotificationMode.persistentNotification.isPersistent)

        store.save(.notification)
        XCTAssertEqual(QuotaResetNotificationSettingsStore(defaults: defaults, key: "mode").load(), .notification)
        store.save(.persistentNotification)
        XCTAssertEqual(QuotaResetNotificationSettingsStore(defaults: defaults, key: "mode").load(), .persistentNotification)
    }

    func testNotificationHandlerPreparesPermissionAndUsesSelectedPersistence() async {
        let notifier = TestQuotaResetNotifier()
        let handler = QuotaResetNotificationHandler(notifier: notifier)
        let event = QuotaResetNotificationEvent(
            provider: .codex,
            bucketID: "codex",
            bucketName: "Codex",
            windowLabel: "5-hour"
        )

        await handler.prepare()
        await handler.deliver(events: [event], mode: .off)
        await handler.deliver(events: [event], mode: .notification)
        await handler.deliver(events: [event], mode: .persistentNotification)

        let preparedCount = await notifier.preparedCount
        let deliveries = await notifier.deliveries
        XCTAssertEqual(preparedCount, 1)
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertFalse(deliveries[0].persistent)
        XCTAssertTrue(deliveries[1].persistent)
    }

    @MainActor
    func testQuotaResetNotificationSettingsRenderForQA() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["AI_USAGE_QA_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:)) else { return }

        let sheet = VStack(alignment: .leading, spacing: 24) {
            ForEach(QuotaResetNotificationMode.allCases) { mode in
                QuotaResetNotificationSettingsContent(mode: .constant(mode))
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Color.white)
        .environment(\.colorScheme, .light)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.nsImage)
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode quota-reset notification settings render")
        }
        try png.write(to: outputDirectory.appending(path: "quota-reset-notification-settings@4x.png"))
    }

    private static func bucket(usedPercent: Double) -> LimitBucket {
        LimitBucket(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            planType: nil,
            windows: [
                RateLimitWindow(
                    usedPercent: usedPercent,
                    durationMinutes: 300,
                    resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                    confidence: .exact,
                    estimateBasis: nil
                )
            ],
            confidence: .exact,
            sourceDescription: "fixture"
        )
    }
}

private actor TestQuotaResetNotifier: QuotaResetNotifying {
    struct Delivery: Sendable {
        let event: QuotaResetNotificationEvent
        let persistent: Bool
    }

    private(set) var preparedCount = 0
    private(set) var deliveries: [Delivery] = []

    func prepare() async {
        preparedCount += 1
    }

    func notify(event: QuotaResetNotificationEvent, persistent: Bool) async {
        deliveries.append(Delivery(event: event, persistent: persistent))
    }
}
