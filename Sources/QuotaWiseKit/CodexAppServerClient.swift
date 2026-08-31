import Darwin
import Foundation

enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case timedOut(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found."
        case let .launchFailed(message):
            "Codex App Server could not start: \(message)"
        case let .timedOut(stage):
            "Codex App Server timed out during \(stage)."
        case let .protocolError(message):
            "Codex App Server returned an unexpected response: \(message)"
        }
    }
}

struct CodexAppServerClient: Sendable {
    private let executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    func fetchLimits() async throws -> [LimitBucket] {
        let executableURL = executableURL
        return try await Task.detached(priority: .utility) {
            try Self.fetchLimitsBlocking(executableURL: executableURL)
        }.value
    }

    private static func fetchLimitsBlocking(executableURL: URL?) throws -> [LimitBucket] {
        guard let executable = executableURL ?? locateCodexExecutable() else {
            throw CodexAppServerError.executableNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        defer {
            try? standardInput.fileHandleForWriting.close()
            if process.isRunning {
                _ = terminate(process)
            }
        }

        var reader = JSONLineReader(handle: standardOutput.fileHandleForReading)
        try send(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "quotawise",
                        "title": "QuotaWise",
                        "version": "1.1.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ],
            ],
            to: standardInput.fileHandleForWriting
        )

        guard let initialization = try response(id: 1, reader: &reader, timeout: 5) else {
            throw CodexAppServerError.timedOut("initialization")
        }
        if let error = initialization["error"] {
            throw CodexAppServerError.protocolError(String(describing: error))
        }

        try send(["method": "initialized", "params": [:]], to: standardInput.fileHandleForWriting)
        try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()], to: standardInput.fileHandleForWriting)

        guard let limitResponse = try response(id: 2, reader: &reader, timeout: 8) else {
            throw CodexAppServerError.timedOut("rate-limit read")
        }
        return try decodeLimitResponse(limitResponse)
    }

    @discardableResult
    static func terminate(
        _ process: Process,
        gracePeriod: TimeInterval = 0.5,
        killPeriod: TimeInterval = 0.5
    ) -> Bool {
        guard process.isRunning else {
            process.waitUntilExit()
            return true
        }

        process.terminate()
        if waitForExit(process, timeout: gracePeriod) {
            process.waitUntilExit()
            return true
        }

        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        if waitForExit(process, timeout: killPeriod) {
            process.waitUntilExit()
            return true
        }
        return false
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        return !process.isRunning
    }

    static func decodeLimitResponse(_ response: [String: Any]) throws -> [LimitBucket] {
        guard response["error"] == nil,
              let result = response["result"] as? [String: Any] else {
            throw CodexAppServerError.protocolError(String(describing: response["error"] ?? "missing result"))
        }

        var rawBuckets: [(String, [String: Any])] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            for (id, value) in byID {
                if let dictionary = value as? [String: Any] {
                    rawBuckets.append((id, dictionary))
                }
            }
        }

        if rawBuckets.isEmpty, let legacy = result["rateLimits"] as? [String: Any] {
            rawBuckets.append((string(legacy["limitId"] ?? legacy["limit_id"]) ?? "codex", legacy))
        }

        return rawBuckets.map { fallbackID, raw in
            let id = string(raw["limitId"] ?? raw["limit_id"]) ?? fallbackID
            let explicitName = string(raw["limitName"] ?? raw["limit_name"])
            let displayName: String
            if let explicitName, !explicitName.isEmpty {
                displayName = explicitName.contains("Spark") ? "Spark" : explicitName
            } else if id == "codex" {
                displayName = "Codex"
            } else if id.lowercased().contains("bengalfox") || id.lowercased().contains("spark") {
                displayName = "Spark"
            } else {
                displayName = id
            }

            let windows = ["primary", "secondary"].compactMap { key -> RateLimitWindow? in
                guard let window = raw[key] as? [String: Any] else { return nil }
                let seconds = optionalInt64(window["resetsAt"] ?? window["resets_at"])
                return RateLimitWindow(
                    usedPercent: double(window["usedPercent"] ?? window["used_percent"]),
                    durationMinutes: optionalInt(window["windowDurationMins"] ?? window["window_minutes"]),
                    resetsAt: seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    confidence: .exact,
                    estimateBasis: nil
                )
            }.sorted { ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max) }

            return LimitBucket(
                id: id,
                provider: .codex,
                displayName: displayName,
                planType: string(raw["planType"] ?? raw["plan_type"]),
                windows: windows,
                confidence: .exact,
                sourceDescription: "Live Codex account limits"
            )
        }.sorted { lhs, rhs in
            if lhs.id == "codex" { return true }
            if rhs.id == "codex" { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func response(
        id: Int,
        reader: inout JSONLineReader,
        timeout: TimeInterval
    ) throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let object = try reader.nextObject(timeout: max(0.05, deadline.timeIntervalSinceNow)) else {
                return nil
            }
            if (object["id"] as? NSNumber)?.intValue == id {
                return object
            }
        }
        return nil
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func locateCodexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/codex"),
            home.appending(path: "bin/codex"),
            URL(filePath: "/opt/homebrew/bin/codex"),
            URL(filePath: "/usr/local/bin/codex"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func string(_ value: Any?) -> String? { value as? String }
    private static func double(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private static func optionalInt(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private static func optionalInt64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
}

private struct JSONLineReader {
    let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func nextObject(timeout: TimeInterval) throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                return try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }

            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let ready = poll(&descriptor, 1, remaining)
            if ready == 0 { return nil }
            if ready < 0 { throw CodexAppServerError.protocolError("stdout poll failed") }

            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CodexAppServerError.protocolError("stdout read failed: \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        return nil
    }
}
