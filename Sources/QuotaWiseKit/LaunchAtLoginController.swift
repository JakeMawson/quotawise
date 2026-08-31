import Foundation

enum LaunchAtLoginService {
    private static var launcherExecutableURL: URL? {
        let contentsURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = contentsURL.appendingPathComponent("MacOS/QuotaWiseLauncher")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    static func isEnabled() -> Bool {
        runLauncherMaintenance("--maintenance-launch-at-login-status") ?? false
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let command = enabled
            ? "--maintenance-enable-login-item"
            : "--maintenance-disable-login-item"
        if let resultingState = runLauncherMaintenance(command) {
            return resultingState == enabled
        }
        return false
    }

    private static func runLauncherMaintenance(_ argument: String) -> Bool? {
        guard let launcherExecutableURL else { return nil }

        let process = Process()
        let output = Pipe()
        process.executableURL = launcherExecutableURL
        process.arguments = [argument]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let state = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case "enabled":
            return true
        case "disabled":
            return false
        default:
            return nil
        }
    }
}

final class LaunchAtLoginSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let requestedKey: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, requestedKey: String = "launch-at-login-requested-v1") {
        self.defaults = defaults
        self.requestedKey = requestedKey
    }

    var hasRequestedAutoEnable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.bool(forKey: requestedKey)
    }

    func markAutoEnableRequested() {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(true, forKey: requestedKey)
    }
}
