import Foundation

enum ClaudeUsageDataSource: String, Codable, Sendable {
    case oauthLive
    case exactCache
    case claudeDesktopHistory
}

struct ClaudeUsageSnapshot: Equatable, Sendable {
    let source: ClaudeUsageDataSource
    let observedAt: Date
    let fiveHour: ClaudeUsageWindowSnapshot?
    let sevenDay: ClaudeUsageWindowSnapshot?

    var limitBucket: LimitBucket {
        let windows = [fiveHour, sevenDay].compactMap { $0 }.map(\.rateLimitWindow)
        return LimitBucket(
            id: "claude-live",
            provider: .claude,
            displayName: "Claude Code",
            planType: nil,
            windows: windows,
            confidence: .exact,
            sourceDescription: source.description
        )
    }
}

private extension ClaudeUsageDataSource {
    var description: String {
        switch self {
        case .oauthLive: "Live Claude OAuth usage endpoint"
        case .exactCache: "Exact Claude usage cache"
        case .claudeDesktopHistory: "Claude Desktop plan usage history"
        }
    }
}

struct ClaudeUsageWindowSnapshot: Equatable, Sendable {
    let usedPercent: Double
    let durationMinutes: Int
    let resetsAt: Date?

    var rateLimitWindow: RateLimitWindow {
        RateLimitWindow(
            usedPercent: usedPercent,
            durationMinutes: durationMinutes,
            resetsAt: resetsAt,
            confidence: .exact,
            estimateBasis: nil
        )
    }
}

enum ClaudeUsageSnapshotParser {
    static func parse(
        data: Data,
        source: ClaudeUsageDataSource,
        observedAt: Date
    ) -> ClaudeUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parse(root: root, source: source, observedAt: observedAt)
    }

    static func parse(
        root: [String: Any],
        source: ClaudeUsageDataSource,
        observedAt: Date
    ) -> ClaudeUsageSnapshot? {
        if let samples = root["samples"] as? [[String: Any]],
           let sample = samples.last,
           let timestamp = number(sample["t"]),
           let usage = sample["u"] as? [String: Any] {
            let sampleDate = Date(timeIntervalSince1970: timestamp / 1_000)
            return snapshot(
                source: source,
                observedAt: sampleDate,
                fiveHour: usage["fh"].flatMap(number).map {
                    ClaudeUsageWindowSnapshot(usedPercent: $0, durationMinutes: 300, resetsAt: nil)
                },
                sevenDay: usage["sd"].flatMap(number).map {
                    ClaudeUsageWindowSnapshot(usedPercent: $0, durationMinutes: 10_080, resetsAt: nil)
                }
            )
        }

        let limits = (root["rate_limits"] as? [String: Any]) ?? root
        return snapshot(
            source: source,
            observedAt: observedAt,
            fiveHour: window(limits["five_hour"], durationMinutes: 300),
            sevenDay: window(limits["seven_day"], durationMinutes: 10_080)
        )
    }

    private static func snapshot(
        source: ClaudeUsageDataSource,
        observedAt: Date,
        fiveHour: ClaudeUsageWindowSnapshot?,
        sevenDay: ClaudeUsageWindowSnapshot?
    ) -> ClaudeUsageSnapshot? {
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeUsageSnapshot(
            source: source,
            observedAt: observedAt,
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    private static func window(_ value: Any?, durationMinutes: Int) -> ClaudeUsageWindowSnapshot? {
        guard let value = value as? [String: Any],
              let usedPercent = number(value["used_percentage"]) ?? number(value["utilization"]),
              (0...100).contains(usedPercent) else {
            return nil
        }
        return ClaudeUsageWindowSnapshot(
            usedPercent: usedPercent,
            durationMinutes: durationMinutes,
            resetsAt: date(value["resets_at"])
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            let divisor: Double = seconds > 10_000_000_000 ? 1_000 : 1
            return Date(timeIntervalSince1970: seconds / divisor)
        }
        return Date.parseUsageTimestamp(value)
    }
}

actor ClaudeUsageReader {
    private static let exactFallbackMaximumAge: TimeInterval = 24 * 60 * 60
    static let oauthRequestTimeout: TimeInterval = 8
    private let homeDirectory: URL
    private let applicationSupportDirectory: URL
    private let urlSession: URLSession
    private let now: () -> Date
    private var lastOAuthAttemptAt: Date?
    private var cachedOAuthSnapshot: ClaudeUsageSnapshot?

    init(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        applicationSupportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        urlSession: URLSession = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.homeDirectory = homeDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.urlSession = urlSession
        self.now = now
    }

    func read() async -> ClaudeUsageSnapshot? {
        let current = now()
        if let live = await readOAuthUsage(now: current) {
            return live
        }
        if let cached = readExactCache(now: current) {
            return cached
        }
        return readClaudeDesktopHistory(now: current)
    }

    private func readOAuthUsage(now: Date) async -> ClaudeUsageSnapshot? {
        if let cachedOAuthSnapshot,
           now.timeIntervalSince(cachedOAuthSnapshot.observedAt) < 240 {
            return cachedOAuthSnapshot
        }
        if let lastOAuthAttemptAt,
           now.timeIntervalSince(lastOAuthAttemptAt) < 240 {
            return nil
        }
        guard let token = credential() else { return nil }
        lastOAuthAttemptAt = now

        let request = Self.oauthUsageRequest(token: token)
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let snapshot = ClaudeUsageSnapshotParser.parse(
                    data: data,
                    source: .oauthLive,
                    observedAt: now
                  ) else { return nil }
            cachedOAuthSnapshot = snapshot
            return snapshot
        } catch {
            return nil
        }
    }

    static func oauthUsageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = oauthRequestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func readExactCache(now: Date) -> ClaudeUsageSnapshot? {
        let candidates = [
            homeDirectory.appending(path: ".claude/usage-exact.json"),
            homeDirectory.appending(path: ".claude/usage-api-cache.json"),
        ]
        for url in candidates {
            guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = values[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) <= Self.exactFallbackMaximumAge,
                  let data = try? Data(contentsOf: url),
                  let snapshot = ClaudeUsageSnapshotParser.parse(
                    data: data,
                    source: .exactCache,
                    observedAt: modified
                  ) else { continue }
            return snapshot
        }
        return nil
    }

    private func readClaudeDesktopHistory(now: Date) -> ClaudeUsageSnapshot? {
        let url = applicationSupportDirectory
            .appending(path: "Claude/plan-usage-history.json")
        // The "samples" JSON shape carries its own per-sample timestamp, which
        // ClaudeUsageSnapshotParser uses as observedAt regardless of what's
        // passed here. Older payloads have no embedded timestamp at all, so
        // fall back to the file's real modification date rather than `now` -
        // otherwise the freshness check below always compares `now` to
        // itself and never rejects a stale file.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let data = try? Data(contentsOf: url),
              let snapshot = ClaudeUsageSnapshotParser.parse(
                data: data,
                source: .claudeDesktopHistory,
                observedAt: modified ?? now
              ),
              now.timeIntervalSince(snapshot.observedAt) <= Self.exactFallbackMaximumAge else {
            return nil
        }
        return snapshot
    }

    private func credential() -> String? {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return token
        }

        let file = homeDirectory.appending(path: ".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            return token
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
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
        let token = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
