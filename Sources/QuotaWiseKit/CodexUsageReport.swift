import Foundation

public struct CodexDailyUsageRow: Codable, Equatable, Sendable {
    public let date: String
    public let models: [String]
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let totalTokens: Int64
    public let costUSD: Double
}

public struct CodexDailyUsageReport: Codable, Equatable, Sendable {
    public let data: [CodexDailyUsageRow]
}

public enum CodexUsageReporter {
    public static func daily(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"),
        calendar: Calendar = .current,
        lookbackDays: Int? = 35,
        project query: String? = nil
    ) async -> CodexDailyUsageReport {
        struct Accumulator {
            var models = Set<String>()
            var tokens = TokenUsage()
            var costUSD = 0.0
        }

        let defaultCodexHome = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex")
            .standardizedFileURL
        let cacheURL: URL
        if codexHome.standardizedFileURL == defaultCodexHome {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appending(path: "QuotaWise", directoryHint: .isDirectory)
            cacheURL = base.appending(path: "codexusage-index-v4.json")
        } else {
            cacheURL = codexHome.appending(path: ".codexusage-index-v4.json")
        }

        let scanner = LocalUsageScanner(
            codexHome: codexHome,
            claudeHome: codexHome.appending(path: ".no-claude-history"),
            codexLookbackDays: lookbackDays,
            cacheURL: cacheURL
        )
        let result = await scanner.scanAll()
        var daily: [Date: Accumulator] = [:]
        let cutoff = lookbackDays.flatMap {
            calendar.date(byAdding: .day, value: -$0, to: Date())
        } ?? .distantPast

        for event in result.events
        where event.provider == .codex
            && event.timestamp >= cutoff
            && matchesProject(event, query: query) {
            let day = calendar.startOfDay(for: event.timestamp)
            var value = daily[day, default: Accumulator()]
            value.models.insert(event.model)
            value.tokens = value.tokens + event.tokens
            value.costUSD += event.apiEquivalentUSD
            daily[day] = value
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let rows = daily.keys.sorted().map { day in
            let value = daily[day]!
            return CodexDailyUsageRow(
                date: formatter.string(from: day),
                models: value.models.sorted(),
                inputTokens: value.tokens.input,
                outputTokens: value.tokens.output,
                reasoningOutputTokens: value.tokens.reasoning,
                cachedInputTokens: value.tokens.cachedInput,
                cacheWriteInputTokens: value.tokens.cacheWrite,
                totalTokens: value.tokens.total,
                costUSD: value.costUSD
            )
        }

        return CodexDailyUsageReport(data: rows)
    }

    private static func matchesProject(_ event: UsageEvent, query: String?) -> Bool {
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if event.projectName.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
        if URL(filePath: event.projectPath).lastPathComponent.compare(
            trimmed,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame {
            return true
        }

        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return false }
        let root = URL(
            filePath: NSString(string: trimmed).expandingTildeInPath,
            directoryHint: .isDirectory
        ).standardizedFileURL.path
        let candidate = URL(filePath: event.projectPath, directoryHint: .isDirectory)
            .standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
