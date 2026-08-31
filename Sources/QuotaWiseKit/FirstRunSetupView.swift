import AppKit
import SwiftUI

public enum FirstRunSetupPresentation {
    public static let currentVersion = 1

    public static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        FirstRunSetupStore(defaults: defaults).shouldPresent
    }
}

struct FirstRunSetupStore {
    static let defaultKey = "first-run-setup-version"

    let defaults: UserDefaults
    let key: String
    let currentVersion: Int

    init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey,
        currentVersion: Int = FirstRunSetupPresentation.currentVersion
    ) {
        self.defaults = defaults
        self.key = key
        self.currentVersion = currentVersion
    }

    var shouldPresent: Bool {
        defaults.integer(forKey: key) < currentVersion
    }

    func markCompleted() {
        defaults.set(currentVersion, forKey: key)
    }
}

enum FirstRunSetupPage: Int, CaseIterable, Identifiable {
    case appearance
    case codexAlert
    case claudeAlert
    case resetNotifications
    case review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .codexAlert: "Codex"
        case .claudeAlert: "Claude"
        case .resetNotifications: "Usage resets"
        case .review: "Review"
        }
    }
}

struct FirstRunSetupDraft: Equatable {
    static let quotaResetSettingsKey = "quota-reset-notification-mode-v1"

    var iconConfiguration: MenuBarIconConfiguration
    var quotaResetMode: QuotaResetNotificationMode
    var alertDrafts: [AIProvider: WeeklyUsageLimit]
    var editedAlertProviders = Set<AIProvider>()
    var deferredResetAuthorization = false
    var authorizationRequestIssued = false

    init(
        iconConfiguration: MenuBarIconConfiguration,
        quotaResetMode: QuotaResetNotificationMode,
        existingLimits: [AIProvider: [WeeklyUsageLimit]]
    ) {
        self.iconConfiguration = iconConfiguration
        self.quotaResetMode = quotaResetMode
        alertDrafts = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { provider in
            let existing = existingLimits[provider]?.sorted(by: WeeklyUsageLimit.displayOrder).first
            return (
                provider,
                existing ?? WeeklyUsageLimit(
                    provider: provider,
                    remainingPercent: 25,
                    severity: .notification
                )
            )
        })
    }

    static func initialQuotaResetMode(
        currentMode: QuotaResetNotificationMode,
        defaults: UserDefaults = .standard
    ) -> QuotaResetNotificationMode {
        // Preserve a choice someone has already made, but make the new visual
        // setup page start on its persistent notification option for fresh installs.
        defaults.object(forKey: quotaResetSettingsKey) == nil ? .persistentNotification : currentMode
    }

    var requiresNotificationAuthorization: Bool {
        quotaResetMode.isEnabled || !editedAlertProviders.isEmpty
    }

    var editedLimits: [WeeklyUsageLimit] {
        editedAlertProviders.compactMap { alertDrafts[$0] }
    }

    mutating func stageResetMode(_ mode: QuotaResetNotificationMode, requestAuthorization: Bool) {
        quotaResetMode = mode
        deferredResetAuthorization = false
        authorizationRequestIssued = authorizationRequestIssued || requestAuthorization
    }

    mutating func stageDeferredStandardNotifications() {
        quotaResetMode = .notification
        deferredResetAuthorization = true
    }

    mutating func includeAlert(for provider: AIProvider) {
        editedAlertProviders.insert(provider)
    }
}

struct FirstRunSetupProgressStore {
    static let defaultKey = "first-run-setup-draft-v1"

    private struct PersistedProgress: Codable {
        let flowVersion: Int?
        let pageRawValue: Int
        let iconConfiguration: MenuBarIconConfiguration
        let quotaResetMode: QuotaResetNotificationMode
        let alertDrafts: [WeeklyUsageLimit]
        let editedAlertProviders: [AIProvider]
        let deferredResetAuthorization: Bool
        let authorizationRequestIssued: Bool
    }

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = Self.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load(fallback: FirstRunSetupDraft) -> (page: FirstRunSetupPage, draft: FirstRunSetupDraft)? {
        guard let data = defaults.data(forKey: key),
              let persisted = try? JSONDecoder().decode(PersistedProgress.self, from: data),
              let page = page(for: persisted)
        else {
            return nil
        }

        var draft = fallback
        draft.iconConfiguration = persisted.iconConfiguration
        draft.quotaResetMode = persisted.quotaResetMode
        for limit in persisted.alertDrafts {
            draft.alertDrafts[limit.provider] = limit
        }
        draft.editedAlertProviders = Set(persisted.editedAlertProviders)
        draft.deferredResetAuthorization = persisted.deferredResetAuthorization
        draft.authorizationRequestIssued = persisted.authorizationRequestIssued
        return (page, draft)
    }

    func save(page: FirstRunSetupPage, draft: FirstRunSetupDraft) {
        let progress = PersistedProgress(
            flowVersion: 2,
            pageRawValue: page.rawValue,
            iconConfiguration: draft.iconConfiguration,
            quotaResetMode: draft.quotaResetMode,
            alertDrafts: AIProvider.allCases.compactMap { draft.alertDrafts[$0] },
            editedAlertProviders: Array(draft.editedAlertProviders),
            deferredResetAuthorization: draft.deferredResetAuthorization,
            authorizationRequestIssued: draft.authorizationRequestIssued
        )
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    private func page(for progress: PersistedProgress) -> FirstRunSetupPage? {
        // Version 1 placed Resets before the provider pages. Preserve an
        // incomplete user's exact step when their saved draft is reopened.
        guard (progress.flowVersion ?? 1) < 2 else {
            return FirstRunSetupPage(rawValue: progress.pageRawValue)
        }
        switch progress.pageRawValue {
        case 0: return .appearance
        case 1: return .resetNotifications
        case 2: return .codexAlert
        case 3: return .claudeAlert
        case 4: return .review
        default: return nil
        }
    }
}

public struct FirstRunSetupView: View {
    @ObservedObject private var model: UsageApplicationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let qaMode: Bool
    private let forceReducedMotionForQA: Bool
    private let onFinished: () -> Void
    private let onDismiss: () -> Void
    private let completionStore: FirstRunSetupStore
    private let progressStore: FirstRunSetupProgressStore

    @State private var page: FirstRunSetupPage
    @State private var navigationDirection: NavigationDirection = .forward
    @State private var draft: FirstRunSetupDraft
    @State private var authorizationState: NotificationAuthorizationState
    @State private var isFinishing = false

    public init(
        model: UsageApplicationModel,
        qaPage: String? = nil,
        onDismiss: @escaping () -> Void = {},
        onFinished: @escaping () -> Void
    ) {
        self.model = model
        self.onFinished = onFinished
        self.onDismiss = onDismiss
        qaMode = qaPage != nil
        forceReducedMotionForQA = qaPage == "review-reduced-motion"
        completionStore = FirstRunSetupStore()
        progressStore = FirstRunSetupProgressStore()

        let existingLimits = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map {
            ($0, model.weeklyUsageLimits(for: $0))
        })
        var initialDraft = FirstRunSetupDraft(
            iconConfiguration: MenuBarIconPreferences.shared.configuration,
            quotaResetMode: FirstRunSetupDraft.initialQuotaResetMode(
                currentMode: model.quotaResetNotificationMode
            ),
            existingLimits: existingLimits
        )
        if qaPage == "review-denied" {
            initialDraft.quotaResetMode = .notification
        }
        if qaPage == "appearance-claude" {
            initialDraft.iconConfiguration.top.provider = .claude
            initialDraft.iconConfiguration.bottom.provider = .claude
        }
        if qaPage == "appearance-mixed" {
            initialDraft.iconConfiguration.bottom.provider = .claude
        }
        if qaPage == nil, let saved = progressStore.load(fallback: initialDraft) {
            initialDraft = saved.draft
            _page = State(initialValue: saved.page)
        } else {
            _page = State(initialValue: Self.page(for: qaPage))
        }
        _draft = State(initialValue: initialDraft)
        _authorizationState = State(
            initialValue: qaPage == "review-denied" ? .denied : .notDetermined
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            setupHeader

            stageStrip

            Rectangle()
                .fill(UsagePalette.hairline)
                .frame(height: 1)

            ZStack {
                pageContent
                    .id(page)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Rectangle()
                .fill(UsagePalette.hairline)
                .frame(height: 1)

            navigationFooter
        }
        .frame(width: 760, height: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(UsagePalette.nightInk)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(.dark)
        .onAppear {
            guard qaPageAuthorizationIsFixed == false else { return }
            Task {
                authorizationState = await model.notificationAuthorizationState()
            }
        }
        .onChange(of: page) { _, _ in persistProgress() }
        .onChange(of: draft) { _, _ in persistProgress() }
    }

    private var setupHeader: some View {
        ZStack {
            // Keep the drag target behind the interactive header content, so
            // the empty top area moves the window without swallowing Close.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)

            HStack(spacing: 12) {
                Text("QuotaWise")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)

                Rectangle()
                    .fill(UsagePalette.hairline)
                    .frame(width: 1, height: 16)

                Text("First-time setup")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(UsagePalette.secondaryText)

                Spacer()

                Button("Close") { onDismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(UsagePalette.secondaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.045)))
                    .overlay(Capsule().stroke(UsagePalette.hairline))
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 52)
    }

    private var appearanceMenuBarPreview: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("LIVE PREVIEW")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(UsagePalette.secondaryText)

            HStack(spacing: 10) {
                Circle()
                    .fill(Color.white.opacity(0.38))
                    .frame(width: 5, height: 5)

                if draft.iconConfiguration.isEnabled {
                    MenuBarUsageGlyph(
                        top: model.menuBarIconSnapshot(for: draft.iconConfiguration.top),
                        bottom: model.menuBarIconSnapshot(for: draft.iconConfiguration.bottom)
                    )
                    .environment(\.colorScheme, .dark)
                    .scaleEffect(1.2)
                    .frame(width: 43, height: 25)
                } else {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.black.opacity(0.38))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.12))
                    )
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar preview")
    }

    private var stageStrip: some View {
        HStack(spacing: 8) {
            ForEach(FirstRunSetupPage.allCases) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Text("\(item.rawValue + 1)")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(stageColor(for: item).opacity(0.8))
                        Text(item.title)
                            .font(.system(size: 10, weight: item == page ? .bold : .medium, design: .rounded))
                            .foregroundStyle(item == page ? UsagePalette.porcelain : UsagePalette.secondaryText)
                    }

                    Capsule()
                        .fill(stageColor(for: item).opacity(item.rawValue <= page.rawValue ? 1 : 0.13))
                        .frame(height: 2)
                }
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(item == page ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Color.white.opacity(0.018))
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .appearance:
            appearancePage
        case .resetNotifications:
            resetNotificationsPage
        case .codexAlert:
            alertPage(for: .codex)
        case .claudeAlert:
            alertPage(for: .claude)
        case .review:
            reviewPage
        }
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What should your menu bar show?")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(UsagePalette.porcelain)
                    Text("Stack two live signals. You can change every choice later in Preferences.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(UsagePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
                appearanceMenuBarPreview
            }

            OnboardingMenuBarIconEditor(configuration: $draft.iconConfiguration)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var resetNotificationsPage: some View {
        setupPage(
            title: "Alert on usage resets",
            detail: "Choose how QuotaWise should let you know when a tracked usage window returns to 100% remaining."
        ) {
            HStack(alignment: .top, spacing: 12) {
                resetModePreviewCard(.persistentNotification)
                resetModePreviewCard(.notification)
                resetModePreviewCard(.off)
            }

            Text("If any alert is enabled, QuotaWise asks for notification permission when you continue.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(UsagePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func resetModePreviewCard(_ mode: QuotaResetNotificationMode) -> some View {
        let selected = draft.quotaResetMode == mode
        let accent: Color = mode == .off ? UsagePalette.secondaryText : UsagePalette.mineralTeal
        return Button {
            draft.stageResetMode(mode, requestAuthorization: false)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: mode == .notification ? .topTrailing : .center) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.26))

                    if mode.isEnabled {
                        resetNotificationPreview(persistent: mode == .persistentNotification)
                            .padding(mode == .notification ? 11 : 18)
                    } else {
                        Text("None")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(UsagePalette.secondaryText)
                    }
                }
                .frame(height: 142)

                Spacer()

                Text(resetModeDisplayName(mode))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 208, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(selected ? accent.opacity(0.09) : UsagePalette.slateGlass)
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(selected ? accent.opacity(0.7) : UsagePalette.hairline, lineWidth: selected ? 1.5 : 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func resetNotificationPreview(persistent: Bool) -> some View {
        VStack(alignment: .leading, spacing: persistent ? 3 : 1) {
            Text("QuotaWise")
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundStyle(UsagePalette.secondaryText)
            Text("Usage reset")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(UsagePalette.porcelain)
            Text(persistent ? "Stays until dismissed" : "Quota is back to 100%")
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .foregroundStyle(UsagePalette.secondaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, persistent ? 9 : 6)
        .frame(maxWidth: persistent ? .infinity : 128, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.16))
                )
        )
    }

    private func resetModeDisplayName(_ mode: QuotaResetNotificationMode) -> String {
        switch mode {
        case .persistentNotification: "Persistent Notification"
        case .notification: "Temporary Notification"
        case .off: "No Notification"
        }
    }

    private func alertPage(for provider: AIProvider) -> some View {
        let limit = alertBinding(for: provider)
        let accent = UsagePalette.accent(for: provider)
        return setupPage(
            title: "Add a \(provider.displayName) guardrail?",
            detail: "Optional. Trigger one action when weekly usage reaches your chosen remaining level."
        ) {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("TRIGGER AT")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(UsagePalette.secondaryText)
                            Text("\(limit.wrappedValue.remainingPercent)% remaining")
                                .font(.system(size: 27, weight: .bold, design: .rounded))
                                .foregroundStyle(UsagePalette.porcelain)
                                .contentTransition(.numericText())
                        }
                        Spacer()
                        Text(provider.displayName.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.9)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(accent.opacity(0.1)))
                    }

                    Slider(
                        value: Binding(
                            get: { Double(limit.wrappedValue.remainingPercent) },
                            set: { limit.wrappedValue.remainingPercent = Int($0.rounded()) }
                        ),
                        in: 1...100,
                        step: 1
                    )
                    .tint(accent)

                    HStack {
                        Text("1%")
                        Spacer()
                        Text("Weekly usage remaining")
                        Spacer()
                        Text("100%")
                    }
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
                }
                .padding(16)
                .background(setupPanel)

                VStack(alignment: .leading, spacing: 9) {
                    Text("WHEN IT REACHES THE LIMIT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(UsagePalette.secondaryText)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(WeeklyLimitSeverity.allCases) { severity in
                            alertActionCard(severity, provider: provider, limit: limit)
                        }
                    }
                }
                .padding(16)
                .background(setupPanel)

                Text("Keep QuotaWise running so it can watch the provider and trigger this alert.")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(UsagePalette.secondaryText)
            }
        }
    }

    private func alertActionCard(
        _ severity: WeeklyLimitSeverity,
        provider: AIProvider,
        limit: Binding<WeeklyUsageLimit>
    ) -> some View {
        let selected = limit.wrappedValue.severity == severity
        let accent = severity == .quitProvider ? UsagePalette.danger : UsagePalette.accent(for: provider)
        return Button {
            limit.wrappedValue.severity = severity
        } label: {
            HStack(spacing: 9) {
                Text(severity.title(for: provider))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? accent : UsagePalette.secondaryText.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? accent.opacity(0.08) : Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(selected ? accent.opacity(0.38) : UsagePalette.hairline)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var reviewPage: some View {
        setupPage(title: "Your setup at a glance", detail: "") {
            VStack(spacing: 9) {
                reviewMenuBarRow
                reviewAlertRow(for: .codex)
                reviewAlertRow(for: .claude)
                reviewRow(
                    color: UsagePalette.mineralTeal,
                    title: "Usage resets",
                    value: resetNotificationSummary,
                    showsSettingsAction: authorizationState == .denied
                )
            }
        }
    }

    private func reviewAlertRow(for provider: AIProvider) -> some View {
        let wasEdited = draft.editedAlertProviders.contains(provider)
        let existing = model.weeklyUsageLimits(for: provider).first
        let limit = wasEdited ? draft.alertDrafts[provider] : existing
        let value: String
        if let limit {
            value = "At \(limit.remainingPercent)% · \(limit.severity.title(for: provider))"
        } else {
            value = "No custom alert"
        }
        return reviewRow(
            color: UsagePalette.accent(for: provider),
            title: provider.displayName,
            value: value,
            trailingValue: limit.map { "\($0.remainingPercent)%" }
        )
    }

    private var reviewMenuBarRow: some View {
        HStack(spacing: 13) {
            Capsule()
                .fill(UsagePalette.signalBlue)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Menu bar")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                Text(appearanceSummary)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(UsagePalette.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            reviewCodexMenuBarPreview
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 76)
        .background(setupPanel)
    }

    private var reviewCodexMenuBarPreview: some View {
        let top = MenuBarIconLayer(
            provider: .codex,
            display: draft.iconConfiguration.top.display,
            period: draft.iconConfiguration.top.period,
            color: draft.iconConfiguration.top.color,
            showPercentage: draft.iconConfiguration.top.showPercentage
        )
        let bottom = MenuBarIconLayer(
            provider: .codex,
            display: draft.iconConfiguration.bottom.display,
            period: draft.iconConfiguration.bottom.period,
            color: draft.iconConfiguration.bottom.color,
            showPercentage: draft.iconConfiguration.bottom.showPercentage
        )
        return VStack(alignment: .trailing, spacing: 4) {
            Text("CODEX PREVIEW")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(UsagePalette.secondaryText)

            HStack(spacing: 7) {
                Circle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 3, height: 3)
                MenuBarUsageGlyph(
                    top: model.menuBarIconSnapshot(for: top),
                    bottom: model.menuBarIconSnapshot(for: bottom)
                )
                .environment(\.colorScheme, .dark)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.36))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.12))
                    )
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex menu bar preview")
    }

    private func reviewRow(
        color: Color,
        title: String,
        value: String,
        trailingValue: String? = nil,
        showsSettingsAction: Bool = false
    ) -> some View {
        HStack(spacing: 13) {
            Capsule()
                .fill(color)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                Text(value)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(authorizationState == .denied && title == "Quota resets" ? UsagePalette.danger : UsagePalette.secondaryText)
            }

            Spacer()

            if showsSettingsAction {
                Button("Open Settings") { openNotificationSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.signalBlue)
            } else if let trailingValue {
                Text(trailingValue)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(color.opacity(0.11)))
            }
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 66)
        .background(setupPanel)
    }

    private func setupPage<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(UsagePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var navigationFooter: some View {
        HStack(spacing: 10) {
            if page != .appearance {
                Button { goBack() } label: {
                    Text("Back").setupSecondaryPill()
                }
                .buttonStyle(.plain)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }

            Spacer()

            switch page {
            case .appearance:
                Button { advance(to: .codexAlert) } label: {
                    Text("Next").setupPrimaryPill(color: UsagePalette.signalBlue)
                }
                .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
            case .resetNotifications:
                Button { advanceAfterResetChoice() } label: {
                    Text("Next").setupPrimaryPill(color: UsagePalette.mineralTeal)
                }
                .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
            case .codexAlert:
                alertFooter(for: .codex, next: .claudeAlert)
            case .claudeAlert:
                alertFooter(for: .claude, next: .resetNotifications)
            case .review:
                Button {
                    finishSetup()
                } label: {
                    Group {
                        if isFinishing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Finish setup")
                        }
                    }
                    .setupPrimaryPill(color: UsagePalette.mineralTeal)
                }
                .buttonStyle(.plain)
                .disabled(isFinishing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    @ViewBuilder
    private func alertFooter(for provider: AIProvider, next: FirstRunSetupPage) -> some View {
        Button { advance(to: next) } label: {
            Text("Skip").setupSecondaryPill()
        }
        .buttonStyle(.plain)

        Button {
            draft.includeAlert(for: provider)
            advance(to: next)
        } label: {
            Text(model.weeklyUsageLimits(for: provider).isEmpty ? "Add and continue" : "Save and continue")
                .setupPrimaryPill(color: UsagePalette.accent(for: provider))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private var setupPanel: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(UsagePalette.slateGlass)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(UsagePalette.hairline)
            )
    }

    private var pageTransition: AnyTransition {
        guard !(reduceMotion || forceReducedMotionForQA) else { return .opacity }
        let insertionEdge: Edge = navigationDirection == .forward ? .trailing : .leading
        let removalEdge: Edge = navigationDirection == .forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }

    private func stageColor(for item: FirstRunSetupPage) -> Color {
        switch item {
        case .codexAlert: UsagePalette.accent(for: .codex)
        case .claudeAlert: UsagePalette.accent(for: .claude)
        case .review: UsagePalette.mineralTeal
        default: UsagePalette.signalBlue
        }
    }

    private func alertBinding(for provider: AIProvider) -> Binding<WeeklyUsageLimit> {
        Binding(
            get: {
                draft.alertDrafts[provider] ?? WeeklyUsageLimit(
                    provider: provider,
                    remainingPercent: 25,
                    severity: .notification
                )
            },
            set: { draft.alertDrafts[provider] = $0 }
        )
    }

    private var appearanceSummary: String {
        guard draft.iconConfiguration.isEnabled else { return "Standard QuotaWise icon" }
        let top = draft.iconConfiguration.top
        let bottom = draft.iconConfiguration.bottom
        return "\(top.provider.displayName) \(top.display.displayName) above \(bottom.provider.displayName) \(bottom.display.displayName)"
    }

    private var resetNotificationSummary: String {
        guard draft.quotaResetMode.isEnabled else { return "Off · no permission needed" }
        switch authorizationState {
        case .allowed:
            return "\(draft.quotaResetMode.title) · Allowed by macOS"
        case .denied:
            return "\(draft.quotaResetMode.title) · Blocked in macOS Settings"
        case .notDetermined:
            return draft.deferredResetAuthorization
                ? "Notification · Permission deferred until first reset"
                : "\(draft.quotaResetMode.title) · Waiting for macOS permission"
        }
    }

    private var qaPageAuthorizationIsFixed: Bool {
        qaMode && authorizationState == .denied
    }

    private func persistProgress() {
        guard !qaMode else { return }
        progressStore.save(page: page, draft: draft)
    }

    private func advance(to nextPage: FirstRunSetupPage) {
        navigationDirection = .forward
        let shouldReduceMotion = reduceMotion || forceReducedMotionForQA
        withAnimation(shouldReduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.28)) {
            page = nextPage
        }
    }

    private func goBack() {
        guard let previous = FirstRunSetupPage(rawValue: page.rawValue - 1) else { return }
        navigationDirection = .backward
        let shouldReduceMotion = reduceMotion || forceReducedMotionForQA
        withAnimation(shouldReduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.28)) {
            page = previous
        }
    }

    private func finishSetup() {
        guard !isFinishing else { return }
        if qaMode {
            onFinished()
            return
        }

        isFinishing = true
        let shouldRequestAuthorization = draft.requiresNotificationAuthorization
            && authorizationState == .notDetermined
        Task {
            authorizationState = await model.applyFirstRunSetup(
                iconConfiguration: draft.iconConfiguration,
                quotaResetMode: draft.quotaResetMode,
                editedLimits: draft.editedLimits,
                requestAuthorization: shouldRequestAuthorization
            )
            completionStore.markCompleted()
            progressStore.clear()
            onFinished()
        }
    }

    private func advanceAfterResetChoice() {
        let shouldRequestAuthorization = draft.requiresNotificationAuthorization
            && authorizationState == .notDetermined

        if shouldRequestAuthorization {
            Task {
                authorizationState = await model.requestNotificationAuthorization()
                advance(to: .review)
            }
        } else {
            advance(to: .review)
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func page(for qaPage: String?) -> FirstRunSetupPage {
        switch qaPage {
        case "notifications", "usage-resets": .resetNotifications
        case "appearance-claude", "appearance-mixed": .appearance
        case "codex": .codexAlert
        case "claude": .claudeAlert
        case "review", "review-denied", "review-reduced-motion": .review
        default: .appearance
        }
    }
}

private enum NavigationDirection {
    case forward
    case backward
}

private struct OnboardingMenuBarIconEditor: View {
    @Binding var configuration: MenuBarIconConfiguration

    var body: some View {
        VStack(spacing: 10) {
            Button {
                configuration.isEnabled.toggle()
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        Capsule()
                            .fill(configuration.isEnabled ? UsagePalette.signalBlue : Color.white.opacity(0.12))
                        Circle()
                            .fill(.white)
                            .padding(2)
                            .offset(x: configuration.isEnabled ? 8 : -8)
                    }
                    .frame(width: 36, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use live usage icon")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(UsagePalette.porcelain)
                        Text("Two independently configured signals in one menu-bar mark.")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(UsagePalette.secondaryText)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(setupPanel)
                .contentShape(RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain)

            VStack(spacing: 10) {
                CompactIconLayerEditor(title: "TOP SIGNAL", layer: $configuration.top)
                CompactIconLayerEditor(title: "BOTTOM SIGNAL", layer: $configuration.bottom)
            }
            .disabled(!configuration.isEnabled)
            .opacity(configuration.isEnabled ? 1 : 0.58)
        }
    }

    private var setupPanel: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(UsagePalette.slateGlass)
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(UsagePalette.hairline))
    }
}

private struct CompactIconLayerEditor: View {
    let title: String
    @Binding var layer: MenuBarIconLayer

    var body: some View {
        let accent = UsagePalette.accent(for: layer.provider)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(UsagePalette.accent(for: layer.provider))
                Spacer()
                Text("\(layer.provider.displayName) · \(layer.display.displayName) · \(layer.period.displayName)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }

            HStack(spacing: 8) {
                CompactIconChoiceGroup(
                    caption: "PROVIDER",
                    values: AIProvider.allCases,
                    selection: $layer.provider,
                    accent: accent,
                    label: { $0.displayName }
                )
                CompactIconChoiceGroup(
                    caption: "VISUAL",
                    values: MenuBarIconDisplay.allCases,
                    selection: $layer.display,
                    accent: accent,
                    label: { $0.displayName }
                )
            }

            HStack(spacing: 8) {
                CompactIconChoiceGroup(
                    caption: "PERIOD",
                    values: MenuBarIconPeriod.allCases,
                    selection: $layer.period,
                    accent: accent,
                    label: { $0.displayName }
                )
                CompactIconChoiceGroup(
                    caption: "COLOR",
                    values: MenuBarIconColor.allCases,
                    selection: $layer.color,
                    accent: accent,
                    label: { $0.displayName(for: layer.provider) }
                )
            }

            if layer.display == .bar {
                Button {
                    layer.showPercentage.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: layer.showPercentage ? "checkmark.square.fill" : "square")
                            .foregroundStyle(layer.showPercentage ? UsagePalette.accent(for: layer.provider) : UsagePalette.secondaryText)
                        Text("Show remaining percentage beside the bar")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(UsagePalette.secondaryText)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(13)
        .frame(minHeight: 108)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(UsagePalette.slateGlass)
                .overlay(RoundedRectangle(cornerRadius: 15).fill(accent.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(accent.opacity(0.3)))
        )
    }

}

private struct CompactIconChoiceGroup<Value: Hashable & Identifiable>: View {
    let caption: String
    let values: [Value]
    @Binding var selection: Value
    let accent: Color
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 4) {
            Text(caption)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(UsagePalette.secondaryText)
                .frame(width: 47, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(values) { value in
                    let selected = selection == value
                    Button {
                        selection = value
                    } label: {
                        Text(label(value))
                            .font(.system(size: 8, weight: selected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(selected ? UsagePalette.porcelain : UsagePalette.secondaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? accent.opacity(0.16) : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(selected ? accent.opacity(0.42) : Color.clear)
                                    )
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    func setupPrimaryPill(color: Color) -> some View {
        self
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(UsagePalette.nightInk)
            .padding(.horizontal, 17)
            .frame(minWidth: 86, minHeight: 34)
            .background(Capsule().fill(color))
            .contentShape(Capsule())
    }

    func setupSecondaryPill() -> some View {
        self
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(UsagePalette.secondaryText)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(Color.white.opacity(0.045)))
            .overlay(Capsule().stroke(UsagePalette.hairline))
            .contentShape(Capsule())
    }
}
