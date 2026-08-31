import AppKit
import SwiftUI
import XCTest
@testable import QuotaWiseKit

final class FirstRunSetupTests: XCTestCase {
    func testFirstRunStoreIsEligibleUntilCurrentVersionIsCompleted() throws {
        let suite = "first-run-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FirstRunSetupStore(defaults: defaults, key: "setup", currentVersion: 1)

        XCTAssertTrue(store.shouldPresent)
        defaults.set(0, forKey: "setup")
        XCTAssertTrue(store.shouldPresent)

        store.markCompleted()
        XCTAssertFalse(store.shouldPresent)
        XCTAssertEqual(defaults.integer(forKey: "setup"), 1)
    }

    func testReadingOrClosingIncompleteSetupDoesNotMarkItComplete() throws {
        let suite = "first-run-incomplete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FirstRunSetupStore(defaults: defaults, key: "setup", currentVersion: 1)

        _ = store.shouldPresent

        XCTAssertNil(defaults.object(forKey: "setup"))
        XCTAssertTrue(store.shouldPresent)
    }

    @MainActor
    func testDraftKeepsAppearanceStagedUntilCommit() throws {
        let suite = "first-run-staging-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MenuBarIconPreferences(defaults: defaults, key: "icon")
        let original = preferences.configuration
        var draft = FirstRunSetupDraft(
            iconConfiguration: original,
            quotaResetMode: .off,
            existingLimits: [:]
        )

        draft.iconConfiguration.top.provider = .claude
        draft.iconConfiguration.bottom.period = .fiveHours

        XCTAssertEqual(preferences.configuration, original)
        XCTAssertNotEqual(draft.iconConfiguration, original)
    }

    func testNotificationSkipStagesStandardModeWithoutAuthorizationRequest() {
        var draft = FirstRunSetupDraft(
            iconConfiguration: .default,
            quotaResetMode: .off,
            existingLimits: [:]
        )

        draft.stageDeferredStandardNotifications()

        XCTAssertEqual(draft.quotaResetMode, .notification)
        XCTAssertTrue(draft.deferredResetAuthorization)
        XCTAssertFalse(draft.authorizationRequestIssued)
    }

    func testResetChoiceDefersAuthorizationUntilTheEndOfTheAlertFlow() {
        var draft = FirstRunSetupDraft(
            iconConfiguration: .default,
            quotaResetMode: .off,
            existingLimits: [:]
        )

        draft.stageResetMode(.persistentNotification, requestAuthorization: false)

        XCTAssertEqual(draft.quotaResetMode, .persistentNotification)
        XCTAssertFalse(draft.deferredResetAuthorization)
        XCTAssertFalse(draft.authorizationRequestIssued)
        XCTAssertTrue(draft.requiresNotificationAuthorization)
    }

    func testFreshSetupDefaultsUsageResetChoiceToPersistentButPreservesSavedChoice() throws {
        let suite = "first-run-reset-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            FirstRunSetupDraft.initialQuotaResetMode(currentMode: .off, defaults: defaults),
            .persistentNotification
        )

        defaults.set(QuotaResetNotificationMode.off.rawValue, forKey: FirstRunSetupDraft.quotaResetSettingsKey)
        XCTAssertEqual(
            FirstRunSetupDraft.initialQuotaResetMode(currentMode: .off, defaults: defaults),
            .off
        )
    }

    func testAnyConfiguredAlertMakesPermissionRelevantAtTheEndOfTheFlow() {
        var draft = FirstRunSetupDraft(
            iconConfiguration: .default,
            quotaResetMode: .off,
            existingLimits: [:]
        )
        XCTAssertFalse(draft.requiresNotificationAuthorization)

        draft.includeAlert(for: .codex)
        XCTAssertTrue(draft.requiresNotificationAuthorization)
    }

    func testIncompleteProgressRestoresPageAndStagedChoicesWithoutApplyingThem() throws {
        let suite = "first-run-progress-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FirstRunSetupProgressStore(defaults: defaults, key: "draft")
        var draft = FirstRunSetupDraft(
            iconConfiguration: .default,
            quotaResetMode: .off,
            existingLimits: [:]
        )
        draft.iconConfiguration.top.provider = .claude
        draft.stageDeferredStandardNotifications()
        draft.alertDrafts[.codex]?.remainingPercent = 31
        draft.includeAlert(for: .codex)

        store.save(page: .claudeAlert, draft: draft)
        let restored = try XCTUnwrap(store.load(fallback: FirstRunSetupDraft(
            iconConfiguration: .default,
            quotaResetMode: .off,
            existingLimits: [:]
        )))

        XCTAssertEqual(restored.page, .claudeAlert)
        XCTAssertEqual(restored.draft, draft)

        store.clear()
        XCTAssertNil(store.load(fallback: draft))
    }

    func testEditingFirstAlertPreservesItsIdentityAndAdditionalAlerts() throws {
        let suite = "first-run-alerts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WeeklyUsageLimitStore(defaults: defaults, key: "limits", legacyKey: "legacy")
        let first = WeeklyUsageLimit(
            provider: .codex,
            remainingPercent: 40,
            severity: .notification
        )
        let second = WeeklyUsageLimit(
            provider: .codex,
            remainingPercent: 15,
            severity: .pauseThreads
        )
        store.save(first)
        store.save(second)

        var draft = FirstRunSetupDraft(
            iconConfiguration: .default,
            quotaResetMode: .off,
            existingLimits: [.codex: store.limits(for: .codex)]
        )
        draft.alertDrafts[.codex]?.remainingPercent = 35
        draft.includeAlert(for: .codex)
        let edited = try XCTUnwrap(draft.editedLimits.first)
        store.save(edited)

        let saved = store.limits(for: .codex)
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.contains { $0.id == first.id && $0.remainingPercent == 35 })
        XCTAssertTrue(saved.contains { $0 == second })
    }

    func testNotificationAuthorizationAbstractionRepresentsEveryPermissionState() async {
        for state in [
            NotificationAuthorizationState.notDetermined,
            .allowed,
            .denied,
        ] {
            let provider = StubNotificationAuthorizationProvider(state: state)
            let current = await provider.currentState()
            let requested = await provider.request()
            XCTAssertEqual(current, state)
            XCTAssertEqual(requested, state)
        }
    }

    @MainActor
    func testEveryFirstRunPageRendersForQA() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["AI_USAGE_QA_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:)) else { return }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let model = UsageApplicationModel()
        for page in ["appearance", "appearance-claude", "appearance-mixed", "notifications", "usage-resets", "codex", "claude", "review", "review-denied", "review-reduced-motion"] {
            let view = FirstRunSetupView(model: model, qaPage: page, onFinished: {})
            try Self.writeRenderedPNG(view, named: "first-run-\(page).png", to: outputDirectory)
        }
    }

    @MainActor
    private static func writeRenderedPNG<V: View>(_ view: V, named name: String, to directory: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            XCTFail("Could not render \(name)")
            return
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: directory.appending(path: name), options: .atomic)
    }
}

private actor StubNotificationAuthorizationProvider: NotificationAuthorizationProviding {
    let state: NotificationAuthorizationState

    init(state: NotificationAuthorizationState) {
        self.state = state
    }

    func currentState() async -> NotificationAuthorizationState { state }
    func request() async -> NotificationAuthorizationState { state }
}
