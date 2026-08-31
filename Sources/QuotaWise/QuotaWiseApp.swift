import AppKit
import Combine
import QuotaWiseKit
import ServiceManagement
import SwiftUI

@main
@MainActor
enum QuotaWiseMain {
    // NSApplication holds its delegate weakly. Keep the manually managed
    // delegate alive for the entire AppKit run loop rather than relying on a
    // local startup variable whose lifetime is not part of that contract.
    private static let appDelegate = AppDelegate()

    static func main() {
        // A native AppKit lifecycle is intentional here. On macOS 26 a signed
        // LSUIElement bundle driven by SwiftUI.App could retain a live process
        // while its otherwise valid NSStatusItem was never composed. The same
        // bundle reliably registers the item when AppKit owns application.run().
        // QuotaWise's visible UI remains SwiftUI hosted inside AppKit windows.
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var studioWindow: NSWindow?
    private var qaControlWindow: NSWindow?
    private var qaMenuPreviewWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var firstRunSetupWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private lazy var statusPopover = NSPopover()
    private var statusObservers = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var outsideClickMonitors: [Any] = []
    private var statusImageRefreshScheduled = false
    private var statusItemRecoveryAttempt = 0
    private var didSimulateStatusItemLossForQA = false
    private var didEvaluateFirstRunSetup = false
    private var pulseAnimationTimer: Timer?
    private var pulseAnimationStartedAt: Date?
    private static let pulseCycleDuration: TimeInterval = 1.5
    private static let pulseSweepDuration: TimeInterval = 1.0
    private static let pulseFrameInterval: TimeInterval = 1.0 / 30.0
    private static let reopenRequestNotification = Notification.Name(
        "com.jakemawson.quotawise.menuagent4.request-studio-reopen"
    )
    private static let launchAtLoginService = SMAppService.loginItem(
        identifier: "com.jakemawson.quotawise.menuagent4"
    )
    private static let legacyLaunchAtLoginServices = [
        SMAppService.loginItem(identifier: "com.jakemawson.quotawise.menuagent3"),
        SMAppService.loginItem(identifier: "com.jakemawson.quotawise.menuagent2"),
        SMAppService.loginItem(identifier: "com.jakemawson.quotawise.menuagent"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        logStatusItemLifecycle("application did finish launching")
        if CommandLine.arguments.contains("--maintenance-unregister-login-item") {
            try? Self.launchAtLoginService.unregister()
            NSApplication.shared.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--maintenance-register-login-item") {
            try? Self.launchAtLoginService.register()
            NSApplication.shared.terminate(nil)
            return
        }
        for service in Self.legacyLaunchAtLoginServices {
            try? service.unregister()
        }
        if handOffToExistingInstanceIfNeeded() {
            return
        }
        let diagnosticLaunch = CommandLine.arguments.contains { $0.hasPrefix("--diagnostic-") }
        // QuotaWise is always an accessory application. QA windows and Studio
        // can become key without temporarily publishing a Dock icon.
        NSApplication.shared.setActivationPolicy(.accessory)
        if diagnosticLaunch {
            installStatusItem()
            return
        }
        configureUsageModel(diagnosticLaunch: diagnosticLaunch)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributedReopenRequest(_:)),
            name: Self.reopenRequestNotification,
            object: nil
        )
        installStatusItem()
        installStudioCloseShortcutMonitor()
        if CommandLine.arguments.contains("--qa-control") {
            Task { @MainActor [weak self] in
                self?.presentQAControlWindow()
            }
        } else if CommandLine.arguments.contains("--qa-menu") {
            Task { @MainActor [weak self] in
                self?.presentQAMenuPreview()
            }
        } else if CommandLine.arguments.contains("--qa-studio") {
            Task { @MainActor [weak self] in
                self?.presentQAStudio()
            }
        }
        if !diagnosticLaunch {
            Task { @MainActor in
                await UsageApplicationModel.shared.refreshIfNeeded()
            }
        }
    }

    private func configureUsageModel(diagnosticLaunch: Bool) {
        guard !diagnosticLaunch else { return }

        let model = UsageApplicationModel.shared
        model.startAutomaticRefresh()
        if CommandLine.arguments.contains("--qa-claude") {
            model.selectProviderForQA("claude")
        } else if CommandLine.arguments.contains("--qa-codex") {
            model.selectProviderForQA("codex")
        }
        if CommandLine.arguments.contains("--qa-indexing") {
            model.showIndexingForQA()
        }
        if CommandLine.arguments.contains("--qa-limit-configured") {
            model.setWeeklyLimitForQA(remainingPercent: 20)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if CommandLine.arguments.contains("--diagnostic-status-title"), let button = item.button {
            button.image = nil
            button.title = "QWTEST"
            button.imagePosition = .noImage
            logStatusItemLifecycle("minimal title status item installed")
            return
        }
        // Let AppKit publish the newly retained item before attaching SwiftUI,
        // event monitors, and dynamic artwork. Doing all of that synchronously
        // inside applicationDidFinishLaunching raced status-item composition on
        // macOS 26, producing the intermittent live-process/no-item state.
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, let item, self.statusItem === item else { return }
            self.configureStatusItem(item)
        }
    }

    private func configureStatusItem(_ item: NSStatusItem) {
        if CommandLine.arguments.contains("--qa-status-item-registration-failure") {
            recoverOrTerminateStatusItem(item)
            return
        }
        guard let button = item.button else {
            recoverOrTerminateStatusItem(item)
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.toolTip = "QuotaWise"
        button.setAccessibilityLabel("QuotaWise")

        // Let AppKit own the standard click-away and Escape dismissal paths.
        // The event monitors below preserve the app's sheet-aware handling.
        statusPopover.behavior = .transient
        statusPopover.animates = false
        installStatusItemBindingsIfNeeded()

        refreshStatusImage()
        scheduleFirstRunSetupPresentationIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak item] in
            guard let self, let item, self.statusItem === item else { return }
            guard item.button != nil else {
                self.recoverOrTerminateStatusItem(item)
                return
            }
            self.statusItemRecoveryAttempt = 0
            self.logStatusItemLifecycle("status item registered")
            self.simulatePostRegistrationStatusItemLossForQAIfNeeded(item)
        }
    }

    private func installStatusItemBindingsIfNeeded() {
        if statusObservers.isEmpty {
            UsageApplicationModel.shared.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.scheduleStatusImageRefresh()
                }
                .store(in: &statusObservers)
        }

        if notificationObservers.isEmpty {
            let center = NotificationCenter.default
            notificationObservers = [
                center.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: UserDefaults.standard,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.scheduleStatusImageRefresh()
                    }
                }
            ]
        }

        guard outsideClickMonitors.isEmpty else { return }
        installOutsideClickMonitors()
        installEscapeKeyMonitor()
    }

    /// A missing AppKit button is a definite startup registration failure. Give
    /// it one fresh attempt, then quit rather than leaving an unusable process
    /// behind. This is deliberately not used as runtime "self-healing": a
    /// healthy retained item must never be removed during normal operation.
    private func recoverOrTerminateStatusItem(_ item: NSStatusItem) {
        guard statusItem === item else { return }

        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        statusPopover.close()

        guard statusItemRecoveryAttempt == 0 else {
            logStatusItemLifecycle("status item registration failed after retry; terminating")
            NSApplication.shared.terminate(nil)
            return
        }

        statusItemRecoveryAttempt += 1
        logStatusItemLifecycle("status item registration failed; retrying once")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.installStatusItem()
        }
    }

    private func simulatePostRegistrationStatusItemLossForQAIfNeeded(_ item: NSStatusItem) {
        let recoversImmediately = CommandLine.arguments.contains("--qa-status-item-loss")
        let awaitsStudioRecovery = CommandLine.arguments.contains("--qa-status-item-loss-await-studio")
        guard recoversImmediately || awaitsStudioRecovery, !didSimulateStatusItemLossForQA else {
            return
        }

        didSimulateStatusItemLossForQA = true
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, let item, self.statusItem === item else { return }
            self.logStatusItemLifecycle("simulating status item loss for QA")
            if awaitsStudioRecovery {
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            } else {
                self.recoverOrTerminateStatusItem(item)
            }
        }
    }

    private func logStatusItemLifecycle(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("[QuotaWise] \(message)\n".utf8))
    }

    private func handOffToExistingInstanceIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != currentPID })
        else {
            return false
        }

        DistributedNotificationCenter.default().postNotificationName(
            Self.reopenRequestNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        application.activate(options: [.activateAllWindows])
        NSApplication.shared.terminate(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        pulseAnimationTimer?.invalidate()
        statusPopover.close()

        for monitor in outsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitors.removeAll()

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        statusObservers.removeAll()
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: Self.reopenRequestNotification,
            object: nil
        )

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        self.statusItem = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logStatusItemLifecycle("reopen requested; hasVisibleWindows=\(flag)")
        // Interacting with an NSStatusItem can reactivate this accessory app
        // and deliver the same callback. That interaction is only meant to
        // toggle the anchored usage popover; it must not restore Studio after
        // deactivation closed it. Explicit Studio paths
        // (the popover action, context-menu action, and distributed second
        // launch handoff) call scheduleUsageStudioPresentation directly.
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        logStatusItemLifecycle("application became active")
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Studio is intentionally transient: moving to another application
        // removes it from the window server instead of relying on AppKit's
        // automatic hiding. A hidden NSWindow with
        // `hidesOnDeactivate` is restored by a later menu-bar activation,
        // which made a closed Studio unexpectedly reappear on the next click.
        // AppKit can deliver deactivation while it is closing Studio. Deferring
        // the lookup lets windowWillClose clear that reference first, while
        // retaining the normal click-away behavior for a still-live Studio.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !NSApplication.shared.isActive,
                  let window = self.studioWindow,
                  window.isVisible
            else {
                return
            }

            self.logStatusItemLifecycle("application resigned active; ordering out Studio")
            window.orderOut(nil)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !NSApplication.shared.isActive,
                  let window = self.preferencesWindow,
                  window.isVisible
            else {
                return
            }

            self.logStatusItemLifecycle("application resigned active; ordering out Preferences")
            window.orderOut(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Studio is optional UI for a resident menu-bar accessory. Closing its
        // last window must never terminate and recreate the status item.
        false
    }

    @objc private func handleDistributedReopenRequest(_ notification: Notification) {
        if FirstRunSetupPresentation.shouldPresent() {
            DispatchQueue.main.async { [weak self] in
                self?.presentFirstRunSetup(qaPage: nil)
            }
            return
        }
        scheduleUsageStudioPresentation()
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        if NSApplication.shared.currentEvent?.type == .rightMouseDown {
            showStatusItemMenu()
        } else if FirstRunSetupPresentation.shouldPresent() {
            statusPopover.close()
            DispatchQueue.main.async { [weak self] in
                self?.presentFirstRunSetup(qaPage: nil)
            }
        } else {
            toggleStatusPopover(sender)
        }
    }

    private func showStatusItemMenu() {
        guard let button = statusItem?.button else { return }
        statusPopover.close()

        let menu = NSMenu()
        let openStudioItem = NSMenuItem(
            title: "Open QuotaWise Studio",
            action: #selector(openUsageStudio(_:)),
            keyEquivalent: ""
        )
        openStudioItem.target = self
        menu.addItem(openStudioItem)

        let openPreferencesItem = NSMenuItem(
            title: "Open Preferences",
            action: #selector(openPreferences(_:)),
            keyEquivalent: ","
        )
        openPreferencesItem.keyEquivalentModifierMask = .command
        openPreferencesItem.target = self
        menu.addItem(openPreferencesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit QuotaWise",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func openUsageStudio(_ sender: Any?) {
        scheduleUsageStudioPresentation()
    }

    @objc private func openPreferences(_ sender: Any?) {
        schedulePreferencesPresentation()
    }

    @objc private func quitApplication(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }

    private func toggleStatusPopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if statusPopover.isShown {
            statusPopover.close()
        } else {
            // A popover can be dismissed while a SwiftUI sheet is being torn
            // down. Rehosting makes every new opening start without stale
            // sheet-presentation state, so the pencil action always presents.
            resetStatusPopoverContent()
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in
                NSApplication.shared.activate(ignoringOtherApps: true)
                self?.statusPopover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func resetStatusPopoverContent() {
        let hostingController = NSHostingController(
            rootView: MenuBarPanel(model: UsageApplicationModel.shared) { [weak self] in
                self?.statusPopover.close()
                self?.scheduleUsageStudioPresentation()
            }
        )
        // Publish the SwiftUI root's ideal size through preferredContentSize.
        // NSPopover observes that value and follows provider-specific content
        // in both directions instead of retaining the tallest size it has seen.
        hostingController.sizingOptions = [.preferredContentSize]
        statusPopover.contentViewController = hostingController
        _ = hostingController.view
    }

    /// The menu panel is a SwiftUI button hosted in an NSPopover. Presenting a
    /// new NSWindow synchronously from that action re-entered AppKit while the
    /// popover's view graph was being torn down, which is the path recorded in
    /// the historical EXC_BAD_ACCESS reports. Defer the window handoff by one
    /// main-loop turn so the button action and popover close complete first.
    private func scheduleUsageStudioPresentation() {
        DispatchQueue.main.async { [weak self] in
            self?.presentUsageStudio()
        }
    }

    private func schedulePreferencesPresentation() {
        statusPopover.close()
        DispatchQueue.main.async { [weak self] in
            self?.presentPreferences()
        }
    }

    private func installOutsideClickMonitors() {
        let closeForLocalEvent: (NSEvent) -> Void = { [weak self] event in
            guard let self, self.statusPopover.isShown else { return }
            guard let eventWindow = event.window else { return }
            guard !self.isInsideStatusUI(eventWindow) else { return }
            self.statusPopover.close()
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { event in
            closeForLocalEvent(event)
            return event
        }) {
            outsideClickMonitors.append(localMonitor)
        }
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
            // Global monitor events originate outside this app and do not carry
            // a usable local window. They are always click-offs for the status
            // popover, including clicks in another app's window or popup.
            guard let self, self.statusPopover.isShown else { return }
            self.statusPopover.close()
        }) {
            outsideClickMonitors.append(globalMonitor)
        }
    }

    private func installEscapeKeyMonitor() {
        if let escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                guard let self, event.keyCode == 53, self.statusPopover.isShown else {
                    return event
                }

                // Let the attached editor sheet receive Escape first. Its
                // Cancel button owns the cancellation shortcut, leaving the
                // popover open for a second Escape to dismiss.
                if self.statusPopover.contentViewController?.view.window?.attachedSheet != nil {
                    return event
                }

                self.statusPopover.close()
                return nil
            }
        ) {
            outsideClickMonitors.append(escapeMonitor)
        }
    }

    /// Studio, Preferences, and the status popover are independently managed
    /// by AppKit, so keep their scoped shortcuts with the AppKit host.
    private func installStudioCloseShortcutMonitor() {
        if let commandMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] event in
                guard let self else { return event }
                if self.shouldOpenPreferences(for: event) {
                    self.schedulePreferencesPresentation()
                    return nil
                }
                if let studioWindow = self.studioWindowToClose(for: event) {
                    self.scheduleStudioDismissal(studioWindow)
                    return nil
                }
                if let preferencesWindow = self.preferencesWindowToDismiss(for: event) {
                    self.schedulePreferencesDismissal(preferencesWindow)
                    return nil
                }
                if let setupWindow = self.firstRunSetupWindowToDismiss(for: event) {
                    self.scheduleFirstRunSetupDismissal(setupWindow)
                    return nil
                }
                if self.shouldQuitApplicationFromFirstRunSetup(for: event) {
                    self.quitApplication(nil)
                    return nil
                }

                guard !self.shouldQuitApplicationFromStatusPopover(for: event) else {
                    self.quitApplication(nil)
                    return nil
                }

                return event
            }
        ) {
            outsideClickMonitors.append(commandMonitor)
        }
    }

    private func shouldOpenPreferences(for event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown,
              modifiers == [.command],
              event.charactersIgnoringModifiers == ","
        else {
            return false
        }

        if statusPopover.isShown {
            return true
        }

        let window = event.window ?? NSApplication.shared.keyWindow
        return window?.title == "QuotaWise Studio"
    }

    private func studioWindowToClose(for event: NSEvent) -> NSWindow? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard event.type == .keyDown,
              modifiers == [.command],
              key == "q" || key == "w",
              let window = event.window ?? NSApplication.shared.keyWindow,
              window.title == "QuotaWise Studio"
        else {
            return nil
        }

        return window
    }

    private func scheduleStudioDismissal(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  self.studioWindow === window,
                  window.isVisible
            else {
                return
            }

            window.orderOut(nil)
        }
    }

    private func preferencesWindowToDismiss(for event: NSEvent) -> NSWindow? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard event.type == .keyDown,
              modifiers == [.command],
              key == "q" || key == "w",
              let window = event.window ?? NSApplication.shared.keyWindow,
              window === preferencesWindow
        else {
            return nil
        }

        return window
    }

    private func schedulePreferencesDismissal(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  self.preferencesWindow === window,
                  window.isVisible
            else {
                return
            }

            window.orderOut(nil)
        }
    }

    private func firstRunSetupWindowToDismiss(for event: NSEvent) -> NSWindow? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown,
              modifiers == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "w",
              let window = event.window ?? NSApplication.shared.keyWindow,
              window === firstRunSetupWindow
        else {
            return nil
        }
        return window
    }

    private func shouldQuitApplicationFromFirstRunSetup(for event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown,
              modifiers == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "q",
              let window = event.window ?? NSApplication.shared.keyWindow,
              window === firstRunSetupWindow
        else {
            return false
        }
        return true
    }

    private func scheduleFirstRunSetupDismissal(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  self.firstRunSetupWindow === window,
                  window.isVisible
            else {
                return
            }
            window.orderOut(nil)
        }
    }

    private func shouldQuitApplicationFromStatusPopover(for event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown,
              modifiers == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "q",
              statusPopover.isShown,
              studioWindow?.isVisible != true,
              preferencesWindow?.isVisible != true
        else {
            return false
        }

        return true
    }

    private func isInsideStatusUI(_ window: NSWindow) -> Bool {
        guard let popoverWindow = statusPopover.contentViewController?.view.window else {
            return window === statusItem?.button?.window
        }

        if window === popoverWindow || window === statusItem?.button?.window {
            return true
        }

        // SwiftUI presents the limit editor as a sheet with its own NSWindow.
        // Keep the parent popover alive while that sheet, or any nested sheet,
        // is receiving the interaction.
        var candidate: NSWindow? = window
        while let current = candidate {
            if current === popoverWindow {
                return true
            }
            candidate = current.sheetParent
        }

        return popoverWindow.sheets.contains { $0 === window }
            || popoverWindow.childWindows?.contains { $0 === window } == true
    }

    private func scheduleStatusImageRefresh() {
        guard !statusImageRefreshScheduled else { return }
        statusImageRefreshScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.statusImageRefreshScheduled = false
            self.refreshStatusImage()
        }
    }

    private func refreshStatusImage() {
        guard let item = statusItem, let button = item.button else { return }

        if CommandLine.arguments.contains("--qa-status-title")
            || CommandLine.arguments.contains("--diagnostic-status-title") {
            button.image = nil
            button.title = "QWTEST"
            button.imagePosition = .noImage
            item.length = NSStatusItem.variableLength
            return
        }

        updatePulseAnimationState()

        let scheme: ColorScheme = NSApplication.shared.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua ? .dark : .light
        let renderer = ImageRenderer(
            content: MenuBarUsageIndicator(
                model: UsageApplicationModel.shared,
                pulseProgress: currentPulseProgress()
            )
                .fixedSize(horizontal: true, vertical: true)
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        if let renderedImage = renderer.cgImage {
            // ImageRenderer's platform NSImage can retain a lazy SwiftUI-backed
            // representation. NSStatusBar may accept that object while never
            // composing visible pixels. Materialize the bitmap and publish an
            // explicit logical size so AppKit receives stable menu-bar artwork.
            let image = NSImage(
                cgImage: renderedImage,
                size: NSSize(width: 36, height: 20)
            )
            image.isTemplate = false
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = nil
            item.length = 44
        } else if let fallback = NSImage(
            systemSymbolName: "chart.line.uptrend.xyaxis",
            accessibilityDescription: "QuotaWise"
        ) {
            fallback.isTemplate = true
            button.image = fallback
            button.title = "QW"
            button.imagePosition = .imageLeading
            button.contentTintColor = .labelColor
            item.length = NSStatusItem.variableLength
        } else {
            button.image = nil
            button.title = "QW"
            button.imagePosition = .noImage
            item.length = NSStatusItem.variableLength
        }
    }

    private func updatePulseAnimationState() {
        let needsPulse = menuBarIconHasFlatlinedGraphLayer(model: UsageApplicationModel.shared)
        if needsPulse, pulseAnimationTimer == nil {
            pulseAnimationStartedAt = Date()
            let timer = Timer(timeInterval: Self.pulseFrameInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshStatusImage()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pulseAnimationTimer = timer
        } else if !needsPulse, let timer = pulseAnimationTimer {
            timer.invalidate()
            pulseAnimationTimer = nil
            pulseAnimationStartedAt = nil
        }
    }

    private func currentPulseProgress() -> Double? {
        guard let startedAt = pulseAnimationStartedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt).truncatingRemainder(dividingBy: Self.pulseCycleDuration)
        return min(1, elapsed / Self.pulseSweepDuration)
    }

    @MainActor
    private func presentQAStudio() {
        presentUsageStudio()
    }

    @MainActor
    private func presentQAMenuPreview() {
        if let window = qaMenuPreviewWindow {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: MenuBarPanel(
                model: UsageApplicationModel.shared,
                onOpenStudio: { [weak self] in
                    self?.qaMenuPreviewWindow?.close()
                    self?.scheduleUsageStudioPresentation()
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuotaWise Menu Preview"
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        qaMenuPreviewWindow = window
    }

    @MainActor
    private func presentUsageStudio() {
        if let window = studioWindow {
            configureStudioWindow(window)
            applyStudioDefaultFrame(window)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            resizeStudioForQAIfRequested(window)
            return
        }

        let hostingController = NSHostingController(
            rootView: UsageStudioView(model: UsageApplicationModel.shared)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuotaWise Studio"
        window.contentViewController = hostingController
        configureStudioWindow(window)
        applyStudioDefaultFrame(window)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        studioWindow = window
        resizeStudioForQAIfRequested(window)
    }

    private func scheduleFirstRunSetupPresentationIfNeeded() {
        guard !didEvaluateFirstRunSetup else { return }
        didEvaluateFirstRunSetup = true

        let qaArgument = CommandLine.arguments.first { $0 == "--qa-onboarding" || $0.hasPrefix("--qa-onboarding=") }
        guard qaArgument != nil || FirstRunSetupPresentation.shouldPresent() else { return }
        let qaPage = qaArgument.flatMap { argument -> String in
            guard let separator = argument.firstIndex(of: "=") else { return "appearance" }
            return String(argument[argument.index(after: separator)...])
        }

        DispatchQueue.main.async { [weak self] in
            self?.presentFirstRunSetup(qaPage: qaPage)
        }
    }

    @MainActor
    private func presentFirstRunSetup(qaPage: String?) {
        if let window = firstRunSetupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: FirstRunSetupView(
                model: UsageApplicationModel.shared,
                qaPage: qaPage,
                onDismiss: { [weak self] in
                    guard let self, let window = self.firstRunSetupWindow else { return }
                    self.scheduleFirstRunSetupDismissal(window)
                },
                onFinished: { [weak self] in
                    guard let self, let window = self.firstRunSetupWindow else { return }
                    self.scheduleFirstRunSetupDismissal(window)
                }
            )
        )
        let window = FirstRunSetupWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up QuotaWise"
        window.contentViewController = hostingController
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        // The custom borderless window uses SwiftUI's WindowDragGesture only
        // in its header. Letting AppKit move the window from every background
        // click would otherwise steal slider drags from the setup controls.
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        centerFirstRunSetupWindow(window)
        firstRunSetupWindow = window
        window.makeKeyAndOrderFront(nil)
        centerFirstRunSetupWindow(window)
        // The hosted SwiftUI view can finish publishing its intrinsic size on
        // the next AppKit turn. Reapply the explicit centre after that pass so
        // it cannot restore the old right-hand placement.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.firstRunSetupWindow === window else { return }
            self.centerFirstRunSetupWindow(window)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func centerFirstRunSetupWindow(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2)
        )
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true)
    }

    @MainActor
    private func presentPreferences() {
        if let window = preferencesWindow {
            configurePreferencesWindow(window)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: UsageSettingsView(model: UsageApplicationModel.shared)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuotaWise Preferences"
        window.contentViewController = hostingController
        configurePreferencesWindow(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferencesWindow = window
    }

    private func configurePreferencesWindow(_ window: NSWindow) {
        window.hidesOnDeactivate = false
        window.delegate = self
    }

    /// Keep the split view inside the window's content layout rect. This
    /// prevents AppKit from extending the sidebar underneath the titlebar when
    /// the resizable Studio window recomputes its layout after a drag resize.
    private func configureStudioWindow(_ window: NSWindow) {
        window.styleMask.remove(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.hidesOnDeactivate = false
        window.delegate = self
        applyStudioContentLayout(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.applyStudioContentLayout(window)
        }
    }

    /// Positions the Studio like the approved reference: horizontally centred
    /// with a comfortable gap below the menu bar.
    /// Applying it on each explicit “Open QuotaWise Studio” action gives that
    /// command a dependable default while the window remains freely resizable
    /// and movable after it has opened.
    private func applyStudioDefaultFrame(_ window: NSWindow) {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = StudioWindowDefaults.frame(in: screen.visibleFrame)
        window.setFrame(frame, display: true)
        // SwiftUI finishes publishing its intrinsic size on the next run-loop
        // pass. Reapply the already-valid exterior frame afterward so an
        // explicit Open action is stable across fresh and reused windows.
        DispatchQueue.main.async {
            window.setFrame(frame, display: true)
        }
    }

    private func applyStudioContentLayout(_ window: NSWindow) {
        window.contentViewController?.view.frame = window.contentLayoutRect
        window.contentViewController?.view.autoresizingMask = [.width, .height]
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.title == "QuotaWise Studio" else {
            return
        }

        applyStudioContentLayout(window)
        // SwiftUI can finish its own split-view layout after AppKit publishes
        // the resize notification. Reapply on the next main-loop pass so the
        // content cannot settle underneath the titlebar.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.applyStudioContentLayout(window)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === firstRunSetupWindow {
            scheduleFirstRunSetupDismissal(sender)
            return false
        }

        if sender === preferencesWindow {
            schedulePreferencesDismissal(sender)
            return false
        }

        guard sender === studioWindow else { return true }

        // Studio is reusable accessory UI. Hiding it matches the stable
        // click-away lifecycle and avoids tearing down its SwiftUI/AppKit
        // hierarchy while the resident menu-bar process remains active.
        scheduleStudioDismissal(sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === studioWindow
        else {
            return
        }

        let closingWindowIdentifier = ObjectIdentifier(window)
        // Releasing the last strong Studio reference from inside AppKit's
        // windowWillClose notification can deallocate the window re-entrantly.
        // Clear it only after the close transaction has returned to the run
        // loop, and only if no replacement Studio has been opened meanwhile.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let currentWindow = self.studioWindow,
                  ObjectIdentifier(currentWindow) == closingWindowIdentifier
            else {
                return
            }

            self.studioWindow = nil
        }
    }

    private func resizeStudioForQAIfRequested(_ window: NSWindow) {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--qa-studio-resize=") }) else {
            return
        }

        let value = argument.dropFirst("--qa-studio-resize=".count)
        let dimensions = value.split(separator: "x", maxSplits: 1).compactMap { CGFloat(Double($0) ?? 0) }
        guard dimensions.count == 2, dimensions.allSatisfy({ $0 > 0 }) else { return }

        // Apply after presentation so QA exercises AppKit's real resize-layout
        // pass rather than only constructing the window at its final size.
        DispatchQueue.main.async {
            window.setContentSize(NSSize(width: dimensions[0], height: dimensions[1]))
        }
    }

    @MainActor
    private func presentQAControlWindow() {
        let label = NSTextField(labelWithString: "QuotaWise QA control is ready")
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.alignment = .center
        label.setAccessibilityLabel("QuotaWise QA control ready")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuotaWise QA Control"
        window.contentView = label
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        qaControlWindow = window
    }
}

@MainActor
private final class FirstRunSetupWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private enum StudioWindowDefaults {
    /// The supplied 2× screenshot shows an approximately 1,180 × 770-point
    /// exterior Studio window centred across the 1,512-point display.
    static let referenceFrameSize = NSSize(width: 1_180, height: 770)
    static let referenceContentSize = NSSize(width: 1_180, height: 718)
    static let topInset: CGFloat = 56

    static func frame(in visibleFrame: NSRect) -> NSRect {
        let width = min(referenceFrameSize.width, visibleFrame.width)
        let height = min(referenceFrameSize.height, visibleFrame.height)
        let x = min(max(visibleFrame.midX - (width / 2), visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(visibleFrame.maxY - topInset - height, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
