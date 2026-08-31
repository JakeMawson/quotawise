import AppKit
import Foundation
import ServiceManagement

@main
enum QuotaWiseLauncher {
    private static let menuAgentBundleIdentifier = "com.jakemawson.quotawise.menuagent3"
    private static let launchAtLoginChoiceKey = "launch-at-login-user-enabled-v2"
    private static let launchAtLoginMigrationKey = "launch-at-login-main-app-migrated-v1"
    private static let legacyLaunchAtLoginRequestedKey = "launch-at-login-requested-v1"
    private static let reopenRequestNotification = Notification.Name(
        "com.jakemawson.quotawise.menuagent3.request-studio-reopen"
    )

    @MainActor
    static func main() {
        let mainAppService = SMAppService.mainApp
        if handleLaunchAtLoginMaintenanceIfRequested(mainAppService) {
            return
        }

        if let agent = NSRunningApplication.runningApplications(
            withBundleIdentifier: menuAgentBundleIdentifier
        ).first {
            DistributedNotificationCenter.default().postNotificationName(
                reopenRequestNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            agent.activate(options: [.activateAllWindows])
            return
        }

        migrateLaunchAtLoginIfNeeded(mainAppService)

        // The launcher owns login startup. The menu agent itself is opened as
        // ordinary accessory UI so changing the launch-at-login preference can
        // never terminate the process that owns the status item and windows.
        let agentURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/QuotaWiseMenuAgent.app")
        guard FileManager.default.fileExists(atPath: agentURL.path) else {
            return
        }

        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-g", agentURL.path]
        try? openProcess.run()
        openProcess.waitUntilExit()
    }

    @MainActor
    private static func handleLaunchAtLoginMaintenanceIfRequested(_ mainAppService: SMAppService) -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--maintenance-launch-at-login-status") {
            print(mainAppService.status == .enabled ? "enabled" : "disabled")
            return true
        }

        if arguments.contains("--maintenance-enable-login-item") {
            let enabled = setMainAppLaunchAtLogin(true, service: mainAppService)
            saveLaunchAtLoginChoice(enabled)
            print(enabled ? "enabled" : "disabled")
            return true
        }

        if arguments.contains("--maintenance-disable-login-item") {
            let disabled = setMainAppLaunchAtLogin(false, service: mainAppService)
            if disabled {
                saveLaunchAtLoginChoice(false)
            }
            print(mainAppService.status == .enabled ? "enabled" : "disabled")
            return true
        }

        return false
    }

    @MainActor
    private static func migrateLaunchAtLoginIfNeeded(_ mainAppService: SMAppService) {
        let defaults = UserDefaults(suiteName: menuAgentBundleIdentifier)
        guard defaults?.bool(forKey: launchAtLoginMigrationKey) != true else { return }

        let legacyLoginItem = SMAppService.loginItem(identifier: menuAgentBundleIdentifier)
        let desiredState: Bool
        if let savedChoice = defaults?.object(forKey: launchAtLoginChoiceKey) as? Bool {
            desiredState = savedChoice
        } else if defaults?.bool(forKey: legacyLaunchAtLoginRequestedKey) == true {
            // An existing installation already made its choice through the old
            // helper registration. Preserve that current state during migration.
            desiredState = legacyLoginItem.status == .enabled
        } else {
            // Preserve QuotaWise's existing fresh-install default.
            desiredState = true
        }

        guard setMainAppLaunchAtLogin(desiredState, service: mainAppService) else {
            return
        }

        if legacyLoginItem.status == .enabled {
            do {
                try legacyLoginItem.unregister()
            } catch {
                NSLog("QuotaWise launcher could not unregister the legacy menu-agent login item: \(error)")
                return
            }
        }

        saveLaunchAtLoginChoice(desiredState)
        defaults?.set(true, forKey: launchAtLoginMigrationKey)
    }

    @MainActor
    private static func setMainAppLaunchAtLogin(_ enabled: Bool, service: SMAppService) -> Bool {
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
                return service.status == .enabled
            }

            if service.status == .enabled {
                try service.unregister()
            }
            return service.status != .enabled
        } catch {
            NSLog("QuotaWise launcher could not set launch at login to \(enabled): \(error)")
            return false
        }
    }

    private static func saveLaunchAtLoginChoice(_ enabled: Bool) {
        UserDefaults(suiteName: menuAgentBundleIdentifier)?
            .set(enabled, forKey: launchAtLoginChoiceKey)
    }
}
