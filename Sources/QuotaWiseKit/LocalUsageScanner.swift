import Foundation

actor LocalUsageScanner {
    private struct FileSignature: Hashable, Codable {
        let size: Int64
        let modified: TimeInterval
    }

    private struct CachedFile: Codable, Equatable {
        let signature: FileSignature
        let parsed: ParsedFile
        let codexCheckpoint: CodexCheckpoint?
        let claudeResumeOffset: UInt64?

        init(
            signature: FileSignature,
            parsed: ParsedFile,
            codexCheckpoint: CodexCheckpoint?,
            claudeResumeOffset: UInt64? = nil
        ) {
            self.signature = signature
            self.parsed = parsed
            self.codexCheckpoint = codexCheckpoint
            self.claudeResumeOffset = claudeResumeOffset
        }
    }

    private struct ParsedFile: Sendable, Codable, Equatable {
        var events: [UsageEvent] = []
        var resetEvents: [ResetEvent] = []
        var observations: [RateObservation] = []
        var warnings: [String] = []
    }

    private struct CodexCheckpoint: Codable, Equatable {
        var sessionID: String
        var projectPath: String
        var model: String
        var serviceTier: String?
        var previousTotal: TokenUsage?
        /// Byte offset immediately after the last confirmed-complete ('\n'-terminated) line
        /// consumed. Optional only so old on-disk caches without this field decode cleanly;
        /// falls back to the cached file size (the old, less safe assumption) when absent.
        var resumeOffset: UInt64?
    }

    private struct CodexParseResult {
        let parsed: ParsedFile
        let checkpoint: CodexCheckpoint
    }

    private struct AggregateKey: Hashable {
        let provider: AIProvider
        let timestamp: Date
        let model: String
        let projectPath: String
        let serviceTier: String?
        let pricingWasEstimated: Bool
    }

    private final class CodexFileState {
        var parsed = ParsedFile()
        var sessionID: String
        var projectPath = "Unassigned"
        var model = "unknown-codex"
        var serviceTier: String?
        var previousTotal: TokenUsage?

        init(sessionID: String) {
            self.sessionID = sessionID
        }
    }

    private let codexHome: URL
    private let claudeHome: URL
    private let codexLookbackDays: Int?
    private let claudeLookbackDays: Int?
    private let cacheURL: URL
    private var cache: [String: CachedFile]
    private var cacheDirty = false

    private static let recentDetailWindow: TimeInterval = 36 * 3_600
    private static let maximumDetailedEventsPerFile = 64

    init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex"),
        claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"),
        codexLookbackDays: Int? = 35,
        claudeLookbackDays: Int? = 63,
        cacheURL explicitCacheURL: URL? = nil
    ) {
        self.codexHome = codexHome
        self.claudeHome = claudeHome
        self.codexLookbackDays = codexLookbackDays
        self.claudeLookbackDays = claudeLookbackDays
        if let explicitCacheURL {
            cacheURL = explicitCacheURL
        } else {
            let defaultCodex = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex")
                .standardizedFileURL
            if codexHome.standardizedFileURL == defaultCodex {
                let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appending(path: "QuotaWise", directoryHint: .isDirectory)
                cacheURL = base.appending(path: "usage-index-v5.json")
            } else {
                cacheURL = codexHome.deletingLastPathComponent().appending(path: ".quotawise-test-index-v5.json")
            }
        }
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder.usageDecoder.decode([String: CachedFile].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    var needsInitialIndex: Bool { cache.isEmpty }

    func scanAll() -> ScanResult {
        let now = Date()
        let codexCutoff = codexLookbackDays.flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: now)
        } ?? .distantPast
        let claudeCutoff = claudeLookbackDays.flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: now)
        } ?? .distantPast
        let recentDetailCutoff = now.addingTimeInterval(-Self.recentDetailWindow)
        let codexFiles = Self.jsonlFiles(in: [
            codexHome.appending(path: "sessions"),
            codexHome.appending(path: "archived_sessions"),
        ])
        .filter {
            Self.sessionDate(for: $0) >= codexCutoff
                || Self.contentModificationDate(for: $0) >= codexCutoff
        }
        .sorted { Self.sessionDate(for: $0) > Self.sessionDate(for: $1) }
        let claudeFiles = Self.jsonlFiles(in: [claudeHome.appending(path: "projects")])
            .filter {
                Self.sessionDate(for: $0) >= claudeCutoff
                    || Self.contentModificationDate(for: $0) >= claudeCutoff
            }
        let knownPaths = Set((codexFiles + claudeFiles).map(\.path))
        let retainedCache = cache.filter { knownPaths.contains($0.key) }
        if retainedCache.count != cache.count {
            cache = retainedCache
            cacheDirty = true
        }

        var parsedFiles: [ParsedFile] = []
        parsedFiles.reserveCapacity(codexFiles.count + claudeFiles.count)

        for file in codexFiles {
            guard let signature = fileSignature(file) else {
                parsedFiles.append(ParsedFile(warnings: ["Could not inspect \(file.lastPathComponent)"]))
                continue
            }
            if let cached = cache[file.path], cached.signature == signature {
                let value = Self.compacted(
                    cached.parsed,
                    sourceKey: file.path,
                    eventCutoff: codexCutoff,
                    recentDetailCutoff: recentDetailCutoff
                )
                if value != cached.parsed {
                    cache[file.path] = CachedFile(
                        signature: signature,
                        parsed: value,
                        codexCheckpoint: cached.codexCheckpoint
                    )
                    cacheDirty = true
                }
                parsedFiles.append(value)
            } else if let cached = cache[file.path], signature.size > cached.signature.size {
                // Resume from the checkpoint's confirmed-safe line boundary, not the raw cached
                // file size: if the file was captured mid-write last time (a partial trailing
                // line with no newline yet), the safe offset sits before that line so it gets
                // fully reconstructed and reprocessed now instead of silently losing its prefix.
                let resumeFrom = cached.codexCheckpoint?.resumeOffset ?? UInt64(cached.signature.size)
                let parsed = Self.parseCodexAppend(
                    file,
                    startingAt: resumeFrom,
                    cached: cached.parsed,
                    checkpoint: cached.codexCheckpoint,
                    eventCutoff: codexCutoff
                )
                let value = Self.compacted(
                    parsed.parsed,
                    sourceKey: file.path,
                    eventCutoff: codexCutoff,
                    recentDetailCutoff: recentDetailCutoff
                )
                if parsed.parsed.warnings.isEmpty {
                    cache[file.path] = CachedFile(
                        signature: signature,
                        parsed: value,
                        codexCheckpoint: parsed.checkpoint
                    )
                    cacheDirty = true
                }
                parsedFiles.append(value)
            } else {
                let parsed = Self.parseCodexFile(file, eventCutoff: codexCutoff)
                let value = Self.compacted(
                    parsed.parsed,
                    sourceKey: file.path,
                    eventCutoff: codexCutoff,
                    recentDetailCutoff: recentDetailCutoff
                )
                if parsed.parsed.warnings.isEmpty {
                    cache[file.path] = CachedFile(
                        signature: signature,
                        parsed: value,
                        codexCheckpoint: parsed.checkpoint
                    )
                    cacheDirty = true
                }
                parsedFiles.append(value)
            }
        }
        for file in claudeFiles {
            guard let signature = fileSignature(file) else {
                parsedFiles.append(ParsedFile(warnings: ["Could not inspect \(file.lastPathComponent)"]))
                continue
            }
            if let cached = cache[file.path], cached.signature == signature {
                let value = Self.compacted(
                    cached.parsed,
                    sourceKey: file.path,
                    eventCutoff: claudeCutoff,
                    recentDetailCutoff: recentDetailCutoff
                )
                if value != cached.parsed {
                    cache[file.path] = CachedFile(
                        signature: signature,
                        parsed: value,
                        codexCheckpoint: nil,
                        claudeResumeOffset: cached.claudeResumeOffset
                    )
                    cacheDirty = true
                }
                parsedFiles.append(value)
            } else if let cached = cache[file.path], signature.size > cached.signature.size {
                // Claude events are stateless per line, so the same safe-boundary resume offset
                // used for Codex is all that's needed here — no running totals to reconstruct.
                let resumeFrom = cached.claudeResumeOffset ?? UInt64(cached.signature.size)
                let parsed = Self.parseClaudeAppend(
                    file,
                    startingAt: resumeFrom,
                    cached: cached.parsed,
                    eventCutoff: claudeCutoff
                )
                let value = Self.compacted(
                    parsed.parsed,
                    sourceKey: file.path,
                    eventCutoff: claudeCutoff,
                    recentDetailCutoff: recentDetailCutoff
                )
                if parsed.parsed.warnings.isEmpty {
                    cache[file.path] = CachedFile(
                        signature: signature,
                        parsed: value,
                        codexCheckpoint: nil,
                        claudeResumeOffset: parsed.resumeOffset
                    )
                    cacheDirty = true
                }
                parsedFiles.append(value)
            } else {
                let parsed = Self.parseClaudeFile(file, eventCutoff: claudeCutoff)
                let value = Self.compacted(
                    parsed.parsed,
                    sourceKey: file.path,
                    eventCutoff: claudeCutoff,
                    recentDetailCutoff: recentDetailCutoff
                )
                // Only cache a clean parse. Caching a failed/partial read against the current
                // signature would permanently hide this file's data until it changes again, since
                // the next scan would otherwise treat the failed result as authoritative.
                if parsed.parsed.warnings.isEmpty {
                    cache[file.path] = CachedFile(
                        signature: signature,
                        parsed: value,
                        codexCheckpoint: nil,
                        claudeResumeOffset: parsed.resumeOffset
                    )
                    cacheDirty = true
                }
                parsedFiles.append(value)
            }
        }

        let labels = Self.codexProjectLabels(at: codexHome)
        var result = ScanResult()
        var seenEventIDs = Set<String>()
        var seenResetIDs = Set<String>()
        var hourlyEvents: [AggregateKey: UsageEvent] = [:]

        for parsed in parsedFiles {
            for event in parsed.events {
                let name = Self.projectName(for: event.projectPath, labels: labels, fallback: event.projectName)
                let normalized = UsageEvent(
                    id: event.id,
                    provider: event.provider,
                    timestamp: event.timestamp,
                    model: event.model,
                    projectPath: event.projectPath,
                    projectName: name,
                    tokens: event.tokens,
                    apiEquivalentUSD: event.apiEquivalentUSD,
                    pricingWasEstimated: event.pricingWasEstimated,
                    serviceTier: event.serviceTier
                )
                if Self.isHourlyAggregate(normalized) {
                    let key = Self.aggregateKey(for: normalized)
                    hourlyEvents[key] = Self.merge(hourlyEvents[key], with: normalized, id: Self.hourlyID(for: key))
                } else if seenEventIDs.insert(normalized.id).inserted {
                    result.events.append(normalized)
                }
            }
            for reset in parsed.resetEvents where seenResetIDs.insert(reset.id).inserted {
                result.resetEvents.append(reset)
            }
            result.observations.append(contentsOf: parsed.observations)
            result.warnings.append(contentsOf: parsed.warnings)
        }

        result.events.append(contentsOf: hourlyEvents.values)

        let observationResets = Self.detectResets(in: result.observations)
        for reset in observationResets where seenResetIDs.insert(reset.id).inserted {
            result.resetEvents.append(reset)
        }

        result.events.sort { $0.timestamp < $1.timestamp }
        result.resetEvents.sort { $0.date < $1.date }
        result.observations.sort { $0.observedAt < $1.observedAt }
        saveCacheIfNeeded()
        return result
    }

    func historyFileCount(atLeast threshold: Int) -> Int? {
        let now = Date()
        let codexCutoff = codexLookbackDays.flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: now)
        } ?? .distantPast
        let claudeCutoff = claudeLookbackDays.flatMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: now)
        } ?? .distantPast
        var count = 0
        for file in Self.jsonlFiles(in: [
            codexHome.appending(path: "sessions"),
            codexHome.appending(path: "archived_sessions"),
        ]) where Self.sessionDate(for: file) >= codexCutoff || Self.contentModificationDate(for: file) >= codexCutoff {
            count += 1
            if count >= threshold { return count }
        }
        for file in Self.jsonlFiles(in: [claudeHome.appending(path: "projects")])
        where Self.sessionDate(for: file) >= claudeCutoff || Self.contentModificationDate(for: file) >= claudeCutoff {
            count += 1
            if count >= threshold { return count }
        }
        return nil
    }

    private func fileSignature(_ url: URL) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return nil
        }
        return FileSignature(size: size, modified: modified)
    }

    private static func processCodexJSON(
        _ data: Data,
        state: CodexFileState,
        eventCutoff: Date = .distantPast
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return }

        if type == "session_meta" {
            state.sessionID = string(payload["id"]) ?? string(payload["session_id"]) ?? state.sessionID
            state.projectPath = string(payload["cwd"]) ?? state.projectPath
            return
        }

        if type == "turn_context" {
            state.model = string(payload["model"]) ?? state.model
            state.projectPath = string(payload["cwd"]) ?? state.projectPath
            state.serviceTier = recordedServiceTier(in: payload) ?? state.serviceTier
            return
        }

        if type == "event_msg", string(payload["type"]) == "thread_settings_applied" {
            state.serviceTier = recordedServiceTier(in: payload) ?? state.serviceTier
            return
        }

        guard type == "event_msg", string(payload["type"]) == "token_count" else { return }
        let timestamp = Date.parseUsageTimestamp(object["timestamp"] ?? payload["timestamp"]) ?? .distantPast

        if let info = payload["info"] as? [String: Any],
           let totalDictionary = info["total_token_usage"] as? [String: Any] {
            let rawInput = int64(totalDictionary["input_tokens"])
            let cached = int64(totalDictionary["cached_input_tokens"])
            let writes = int64(totalDictionary["cache_write_input_tokens"])
            let total = TokenUsage(
                input: max(0, rawInput - cached - writes),
                cachedInput: cached,
                cacheWrite: writes,
                output: int64(totalDictionary["output_tokens"]),
                reasoning: int64(totalDictionary["reasoning_output_tokens"])
            )
            let delta = total.nonnegativeDelta(from: state.previousTotal)
            state.previousTotal = total.componentwiseMaximum(with: state.previousTotal)

            if delta.total > 0, timestamp >= eventCutoff {
                let pricing = PricingCatalog.cost(
                    provider: .codex,
                    model: state.model,
                    tokens: delta,
                    at: timestamp,
                    serviceTier: state.serviceTier
                )
                let stableID = "codex:\(state.sessionID):\(Int(timestamp.timeIntervalSince1970 * 1_000)):\(total.total):\(state.model)"
                let normalizedPath = normalizedProjectPath(state.projectPath)
                state.parsed.events.append(
                    UsageEvent(
                        id: stableID,
                        provider: .codex,
                        timestamp: timestamp,
                        model: state.model,
                        projectPath: normalizedPath,
                        projectName: URL(filePath: normalizedPath).displayProjectName,
                        tokens: delta,
                        apiEquivalentUSD: pricing.usd,
                        pricingWasEstimated: pricing.estimated || state.serviceTier == nil,
                        serviceTier: state.serviceTier
                    )
                )
            }
        }

        if timestamp >= eventCutoff, let limits = payload["rate_limits"] as? [String: Any] {
            state.parsed.observations.append(contentsOf: codexObservations(limits, observedAt: timestamp))
        }
    }

    private static func parseCodexAppend(
        _ url: URL,
        startingAt offset: UInt64,
        cached: ParsedFile,
        checkpoint: CodexCheckpoint?,
        eventCutoff: Date
    ) -> CodexParseResult {
        let state = CodexFileState(sessionID: url.deletingPathExtension().lastPathComponent)
        state.parsed = cached
        if let checkpoint {
            state.sessionID = checkpoint.sessionID
            state.projectPath = checkpoint.projectPath
            state.model = checkpoint.model
            state.serviceTier = checkpoint.serviceTier
            state.previousTotal = checkpoint.previousTotal
        } else if let latest = cached.events.max(by: { $0.timestamp < $1.timestamp }) {
            state.projectPath = latest.projectPath
            state.model = latest.model
            state.serviceTier = latest.serviceTier
            state.previousTotal = cached.events.reduce(TokenUsage()) { $0 + $1.tokens }
        }

        let markers = [
            Data(#""session_meta""#.utf8),
            Data(#""turn_context""#.utf8),
            Data(#""token_count""#.utf8),
            Data(#""thread_settings_applied""#.utf8),
        ]
        var resumeOffset = offset
        do {
            resumeOffset = try forEachLine(at: url, startingAt: offset) { data in
                guard markers.contains(where: { data.range(of: $0) != nil }) else { return }
                processCodexJSON(data, state: state, eventCutoff: eventCutoff)
            }
        } catch {
            state.parsed.warnings.append("Could not read appended Codex usage from \(url.lastPathComponent)")
        }
        return CodexParseResult(
            parsed: state.parsed,
            checkpoint: CodexCheckpoint(
                sessionID: state.sessionID,
                projectPath: state.projectPath,
                model: state.model,
                serviceTier: state.serviceTier,
                previousTotal: state.previousTotal,
                resumeOffset: resumeOffset
            )
        )
    }

    private static func parseCodexFile(_ url: URL, eventCutoff: Date) -> CodexParseResult {
        var result = ParsedFile()
        var sessionID = url.deletingPathExtension().lastPathComponent
        var projectPath = "Unassigned"
        var model = "unknown-codex"
        var serviceTier: String?
        var previousTotal: TokenUsage?
        var resumeOffset: UInt64 = 0
        let markers = [
            Data(#""session_meta""#.utf8),
            Data(#""turn_context""#.utf8),
            Data(#""token_count""#.utf8),
            Data(#""thread_settings_applied""#.utf8),
        ]

        do {
            resumeOffset = try forEachLine(at: url) { data in
                guard markers.contains(where: { data.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return }

                if type == "session_meta" {
                    sessionID = Self.string(payload["id"]) ?? Self.string(payload["session_id"]) ?? sessionID
                    projectPath = Self.string(payload["cwd"]) ?? projectPath
                    return
                }

                if type == "turn_context" {
                    model = Self.string(payload["model"]) ?? model
                    projectPath = Self.string(payload["cwd"]) ?? projectPath
                    serviceTier = Self.recordedServiceTier(in: payload) ?? serviceTier
                    return
                }

                if type == "event_msg", Self.string(payload["type"]) == "thread_settings_applied" {
                    serviceTier = Self.recordedServiceTier(in: payload) ?? serviceTier
                    return
                }

                guard type == "event_msg", Self.string(payload["type"]) == "token_count" else { return }
                let timestamp = Date.parseUsageTimestamp(object["timestamp"] ?? payload["timestamp"]) ?? .distantPast

                if let info = payload["info"] as? [String: Any],
                   let totalDictionary = info["total_token_usage"] as? [String: Any] {
                    let rawInput = Self.int64(totalDictionary["input_tokens"])
                    let cached = Self.int64(totalDictionary["cached_input_tokens"])
                    let writes = Self.int64(totalDictionary["cache_write_input_tokens"])
                    let total = TokenUsage(
                        input: max(0, rawInput - cached - writes),
                        cachedInput: cached,
                        cacheWrite: writes,
                        output: Self.int64(totalDictionary["output_tokens"]),
                        reasoning: Self.int64(totalDictionary["reasoning_output_tokens"])
                    )
                    let delta = total.nonnegativeDelta(from: previousTotal)
                    previousTotal = total.componentwiseMaximum(with: previousTotal)

                    if delta.total > 0, timestamp >= eventCutoff {
                        let pricing = PricingCatalog.cost(
                            provider: .codex,
                            model: model,
                            tokens: delta,
                            at: timestamp,
                            serviceTier: serviceTier
                        )
                        let stableID = "codex:\(sessionID):\(Int(timestamp.timeIntervalSince1970 * 1_000)):\(total.total):\(model)"
                        let normalizedPath = Self.normalizedProjectPath(projectPath)
                        result.events.append(
                            UsageEvent(
                                id: stableID,
                                provider: .codex,
                                timestamp: timestamp,
                                model: model,
                                projectPath: normalizedPath,
                                projectName: URL(filePath: normalizedPath).displayProjectName,
                                tokens: delta,
                                apiEquivalentUSD: pricing.usd,
                                pricingWasEstimated: pricing.estimated || serviceTier == nil,
                                serviceTier: serviceTier
                            )
                        )
                    }
                }

                if timestamp >= eventCutoff, let limits = payload["rate_limits"] as? [String: Any] {
                    result.observations.append(contentsOf: Self.codexObservations(limits, observedAt: timestamp))
                }
            }
        } catch {
            result.warnings.append("Could not stream Codex session \(url.lastPathComponent)")
        }

        return CodexParseResult(
            parsed: result,
            checkpoint: CodexCheckpoint(
                sessionID: sessionID,
                projectPath: projectPath,
                model: model,
                serviceTier: serviceTier,
                previousTotal: previousTotal,
                resumeOffset: resumeOffset
            )
        )
    }

    private struct ClaudeParseResult {
        let parsed: ParsedFile
        let resumeOffset: UInt64
    }

    /// Claude events are stateless per line (each message carries its own usage figures, unlike
    /// Codex's cumulative counters), so — unlike Codex — no cross-line checkpoint is needed beyond
    /// the resume byte offset itself. A full parse and an appended-tail parse share this one
    /// implementation, seeded with an empty vs. the previously cached `ParsedFile`.
    private static func parseClaudeFile(_ url: URL, eventCutoff: Date) -> ClaudeParseResult {
        Self.parseClaudeLines(url, startingAt: 0, seed: ParsedFile(), eventCutoff: eventCutoff)
    }

    private static func parseClaudeAppend(
        _ url: URL,
        startingAt offset: UInt64,
        cached: ParsedFile,
        eventCutoff: Date
    ) -> ClaudeParseResult {
        Self.parseClaudeLines(url, startingAt: offset, seed: cached, eventCutoff: eventCutoff)
    }

    private static func parseClaudeLines(
        _ url: URL,
        startingAt offset: UInt64,
        seed: ParsedFile,
        eventCutoff: Date
    ) -> ClaudeParseResult {
        var result = seed
        let assistantMarker = Data(#""type":"assistant""#.utf8)
        let assistantSpacedMarker = Data(#""type": "assistant""#.utf8)
        var resumeOffset = offset

        do {
            resumeOffset = try forEachLine(at: url, startingAt: offset) { data in
                guard data.range(of: assistantMarker) != nil || data.range(of: assistantSpacedMarker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.string(object["type"]) == "assistant",
                  let message = object["message"] as? [String: Any] else { return }

            let timestamp = Date.parseUsageTimestamp(object["timestamp"]) ?? .distantPast
            let messageID = Self.string(message["id"]) ?? Self.string(object["uuid"]) ?? UUID().uuidString
            let model = Self.string(message["model"]) ?? "unknown-claude"
            let projectPath = Self.normalizedProjectPath(Self.string(object["cwd"]) ?? "Unassigned")

                if timestamp >= eventCutoff, model != "<synthetic>", let usage = message["usage"] as? [String: Any] {
                let creation = usage["cache_creation"] as? [String: Any]
                let fiveMinute = Self.int64(creation?["ephemeral_5m_input_tokens"])
                let oneHour = Self.int64(creation?["ephemeral_1h_input_tokens"])
                let genericWrite = Self.int64(usage["cache_creation_input_tokens"])
                let tokens = TokenUsage(
                    input: Self.int64(usage["input_tokens"]),
                    cachedInput: Self.int64(usage["cache_read_input_tokens"]),
                    cacheWrite: genericWrite,
                    cacheWriteFiveMinute: fiveMinute,
                    cacheWriteOneHour: oneHour,
                    output: Self.int64(usage["output_tokens"]),
                    reasoning: 0
                )
                let serviceTier = Self.string(usage["speed"]) ?? Self.string(usage["service_tier"])
                let pricing = PricingCatalog.cost(
                    provider: .claude,
                    model: model,
                    tokens: tokens,
                    at: timestamp,
                    serviceTier: serviceTier
                )
                    result.events.append(
                    UsageEvent(
                        id: "claude:\(messageID)",
                        provider: .claude,
                        timestamp: timestamp,
                        model: model,
                        projectPath: projectPath,
                        projectName: URL(filePath: projectPath).displayProjectName,
                        tokens: tokens,
                        apiEquivalentUSD: pricing.usd,
                        pricingWasEstimated: pricing.estimated,
                        serviceTier: serviceTier
                    )
                )
                }

                let error = Self.string(object["error"])
                if timestamp >= eventCutoff, model == "<synthetic>" || error == "rate_limit" {
                    let text = Self.messageText(message)
                    if let reset = Self.claudeResetEvent(
                        messageID: messageID,
                        text: text,
                        observedAt: timestamp
                    ) {
                        result.resetEvents.append(reset)
                    }
                }
            }
        } catch {
            result.warnings.append("Could not stream Claude session \(url.lastPathComponent)")
        }

        return ClaudeParseResult(parsed: result, resumeOffset: resumeOffset)
    }

    private static func codexObservations(_ limits: [String: Any], observedAt: Date) -> [RateObservation] {
        let bucketID = string(limits["limit_id"] ?? limits["limitId"]) ?? "codex"
        let bucketName = string(limits["limit_name"] ?? limits["limitName"])
            ?? (bucketID == "codex" ? "Codex" : bucketID)

        return ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any] else { return nil }
            let used = double(window["used_percent"] ?? window["usedPercent"])
            let duration = optionalInt(window["window_minutes"] ?? window["windowDurationMins"])
            let resetSeconds = optionalInt64(window["resets_at"] ?? window["resetsAt"])
            return RateObservation(
                provider: .codex,
                bucketID: bucketID,
                bucketName: bucketName,
                observedAt: observedAt,
                usedPercent: used,
                durationMinutes: duration,
                resetsAt: resetSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    private static func compacted(
        _ parsed: ParsedFile,
        sourceKey _: String,
        eventCutoff: Date,
        recentDetailCutoff: Date
    ) -> ParsedFile {
        var recent: [String: UsageEvent] = [:]
        var hourly: [AggregateKey: UsageEvent] = [:]

        let rawEventCount = parsed.events.reduce(into: 0) { count, event in
            if event.timestamp >= eventCutoff, !isHourlyAggregate(event) { count += 1 }
        }
        let shouldCompactOlderEvents = rawEventCount > maximumDetailedEventsPerFile
            || parsed.events.contains(where: isHourlyAggregate)

        for event in parsed.events where event.timestamp >= eventCutoff {
            if isHourlyAggregate(event) || (shouldCompactOlderEvents && event.timestamp < recentDetailCutoff) {
                let key = aggregateKey(for: event, hour: hourlyStart(for: event.timestamp))
                hourly[key] = merge(hourly[key], with: event, id: hourlyID(for: key))
            } else {
                recent[event.id] = event
            }
        }

        var lastObservation: [String: RateObservation] = [:]
        var observations: [RateObservation] = []
        for observation in parsed.observations.sorted(by: { $0.observedAt < $1.observedAt }) {
            let key = "\(observation.provider.rawValue):\(observation.bucketID):\(observation.durationMinutes ?? -1)"
            let previous = lastObservation[key]
            if previous?.usedPercent != observation.usedPercent || previous?.resetsAt != observation.resetsAt {
                observations.append(observation)
                lastObservation[key] = observation
            }
        }

        return ParsedFile(
            events: (Array(recent.values) + Array(hourly.values)).sorted { $0.timestamp < $1.timestamp },
            resetEvents: Array(Dictionary(grouping: parsed.resetEvents, by: \.id).compactMap { $0.value.first })
                .sorted { $0.date < $1.date },
            observations: observations,
            warnings: Array(Set(parsed.warnings)).sorted()
        )
    }

    private static func hourlyStart(for date: Date) -> Date {
        Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
    }

    private static func aggregateKey(for event: UsageEvent, hour: Date? = nil) -> AggregateKey {
        AggregateKey(
            provider: event.provider,
            timestamp: hour ?? event.timestamp,
            model: event.model,
            projectPath: event.projectPath,
            serviceTier: event.serviceTier,
            pricingWasEstimated: event.pricingWasEstimated
        )
    }

    private static func hourlyID(for key: AggregateKey) -> String {
        let tier = key.serviceTier ?? "default"
        return "hour:\(key.provider.rawValue):\(Int(key.timestamp.timeIntervalSince1970)):\(key.model):\(key.projectPath):\(tier):\(key.pricingWasEstimated)"
    }

    private static func isHourlyAggregate(_ event: UsageEvent) -> Bool {
        event.id.hasPrefix("hour:")
    }

    private static func merge(_ existing: UsageEvent?, with incoming: UsageEvent, id: String) -> UsageEvent {
        guard let existing else {
            return UsageEvent(
                id: id,
                provider: incoming.provider,
                timestamp: incoming.timestamp,
                model: incoming.model,
                projectPath: incoming.projectPath,
                projectName: incoming.projectName,
                tokens: incoming.tokens,
                apiEquivalentUSD: incoming.apiEquivalentUSD,
                pricingWasEstimated: incoming.pricingWasEstimated,
                serviceTier: incoming.serviceTier
            )
        }
        return UsageEvent(
            id: id,
            provider: existing.provider,
            timestamp: existing.timestamp,
            model: existing.model,
            projectPath: existing.projectPath,
            projectName: incoming.projectName,
            tokens: existing.tokens + incoming.tokens,
            apiEquivalentUSD: existing.apiEquivalentUSD + incoming.apiEquivalentUSD,
            pricingWasEstimated: existing.pricingWasEstimated || incoming.pricingWasEstimated,
            serviceTier: existing.serviceTier
        )
    }

    static func detectResets(in observations: [RateObservation]) -> [ResetEvent] {
        let grouped = Dictionary(grouping: observations) {
            "\($0.provider.rawValue):\($0.bucketID):\($0.durationMinutes ?? -1)"
        }
        var resets: [ResetEvent] = []

        for (_, values) in grouped {
            let hourly = Dictionary(grouping: values.filter { $0.observedAt > .distantPast }, by: {
                Int($0.observedAt.timeIntervalSince1970 / 3_600)
            })
            let sorted = hourly.compactMap { _, observations in
                observations.max {
                    if $0.usedPercent != $1.usedPercent { return $0.usedPercent < $1.usedPercent }
                    return $0.observedAt < $1.observedAt
                }
            }.sorted { $0.observedAt < $1.observedAt }
            guard var previous = sorted.first else { continue }

            for current in sorted.dropFirst() {
                let usageDropped = current.usedPercent + 0.5 < previous.usedPercent
                let resetBoundaryAdvanced = previous.resetsAt != nil
                    && current.resetsAt != nil
                    && previous.resetsAt! >= current.observedAt.addingTimeInterval(-2 * 3_600)
                    && previous.resetsAt! <= current.observedAt.addingTimeInterval(120)
                    && current.resetsAt!.timeIntervalSince(previous.resetsAt!) > 6 * 3_600

                if usageDropped && resetBoundaryAdvanced {
                    let date = previous.resetsAt.flatMap {
                        $0 >= previous.observedAt.addingTimeInterval(-120) && $0 <= current.observedAt.addingTimeInterval(120)
                            ? $0
                            : nil
                    } ?? current.observedAt
                    let duration = current.durationMinutes
                    let kind: ResetKind = duration.map { $0 <= 1_440 ? .session : ($0 <= 11_520 ? .weekly : .unknown) } ?? .unknown
                    let id = "history:\(current.provider.rawValue):\(current.bucketID):\(duration ?? -1):\(Int(date.timeIntervalSince1970))"
                    resets.append(
                        ResetEvent(
                            id: id,
                            provider: current.provider,
                            date: date,
                            detectedAt: current.observedAt,
                            kind: kind,
                            bucketID: current.bucketID,
                            label: "\(current.bucketName) \(kind == .weekly ? "weekly" : "session") reset",
                            confidence: .exact
                        )
                    )
                }
                previous = current
            }
        }

        return deduplicateResets(resets, tolerance: 120)
    }

    static func deduplicateResets(_ resets: [ResetEvent], tolerance: TimeInterval) -> [ResetEvent] {
        var result: [ResetEvent] = []
        for reset in resets.sorted(by: { $0.date < $1.date }) {
            let duplicate = result.contains {
                $0.provider == reset.provider
                    && $0.bucketID == reset.bucketID
                    && $0.kind == reset.kind
                    && abs($0.date.timeIntervalSince(reset.date)) <= tolerance
            }
            if !duplicate { result.append(reset) }
        }
        return result
    }

    private static func claudeResetEvent(messageID: String, text: String, observedAt: Date) -> ResetEvent? {
        let normalized = text.lowercased()
        guard normalized.contains("limit"), normalized.contains("resets") else { return nil }

        let kind: ResetKind
        if normalized.contains("weekly") { kind = .weekly }
        else if normalized.contains("session") { kind = .session }
        else { kind = .unknown }

        guard let resetDate = parseClaudeResetDate(text: text, observedAt: observedAt) else { return nil }
        return ResetEvent(
            id: "claude-limit:\(messageID)",
            provider: .claude,
            date: resetDate,
            detectedAt: observedAt,
            kind: kind,
            bucketID: kind == .weekly ? "claude-weekly" : "claude-session",
            label: kind == .weekly ? "Claude weekly reset" : "Claude session reset",
            confidence: .exact
        )
    }

    static func parseClaudeResetDate(text: String, observedAt: Date) -> Date? {
        guard let range = text.range(of: "resets", options: .caseInsensitive) else { return nil }
        var tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let timeZone: TimeZone
        if let open = tail.firstIndex(of: "("), let close = tail[open...].firstIndex(of: ")") {
            let identifier = String(tail[tail.index(after: open)..<close])
            timeZone = TimeZone(identifier: identifier) ?? .current
            tail = String(tail[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            timeZone = .current
        }

        let normalizedTime = tail
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(whereSeparator: { $0 == "·" || $0 == "," })
            .first
            .map(String.init) ?? tail

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = normalizedTime.contains(":") ? "h:mma" : "ha"
        guard let clock = formatter.date(from: normalizedTime) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: observedAt)
        let time = calendar.dateComponents([.hour, .minute], from: clock)
        var components = day
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate <= observedAt {
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private static func messageText(_ message: [String: Any]) -> String {
        guard let content = message["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { string($0["text"]) }.joined(separator: " ")
    }

    private static func jsonlFiles(in roots: [URL]) -> [URL] {
        roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            var files: [URL] = []
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                files.append(url)
            }
            return files
        }
    }

    private static func sessionDate(for url: URL) -> Date {
        let pathComponents = url.pathComponents
        for index in 0..<(max(0, pathComponents.count - 2)) {
            guard pathComponents[index].count == 4,
                  let year = Int(pathComponents[index]),
                  let month = Int(pathComponents[index + 1]),
                  let day = Int(pathComponents[index + 2]) else { continue }
            if let date = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: year, month: month, day: day)
            ) {
                return date
            }
        }

        let name = url.lastPathComponent
        let pattern = #"rollout-(\d{4})-(\d{2})-(\d{2})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let yearRange = Range(match.range(at: 1), in: name),
           let monthRange = Range(match.range(at: 2), in: name),
           let dayRange = Range(match.range(at: 3), in: name),
           let year = Int(name[yearRange]),
           let month = Int(name[monthRange]),
           let day = Int(name[dayRange]),
           let date = Calendar(identifier: .gregorian).date(
               from: DateComponents(year: year, month: month, day: day)
           ) {
            return date
        }

        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func contentModificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func saveCacheIfNeeded() {
        guard cacheDirty else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: cacheURL, options: .atomic)
            cacheDirty = false
        } catch {
            // The in-memory index remains usable for this app launch.
        }
    }

    /// Streams complete '\n'-terminated lines to `body`, and returns the byte offset immediately
    /// after the last one consumed. A trailing chunk with no terminating newline (the file's last
    /// line, or a line still being written) is still passed to `body` for a full parse's benefit,
    /// but is deliberately excluded from the returned offset: resuming a later scan from a
    /// mid-line position would silently lose the missing prefix, since the append path only reads
    /// bytes after its start offset rather than reconstructing a line from two separate reads.
    @discardableResult
    private static func forEachLine(at url: URL, startingAt offset: UInt64 = 0, body: (Data) -> Void) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: offset) }
        var pending = Data()
        var consumedOffset = offset

        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)

            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                if newline > lineStart {
                    body(Data(pending[lineStart..<newline]))
                }
                lineStart = pending.index(after: newline)
                if lineStart == pending.endIndex { break }
            }
            if lineStart > pending.startIndex {
                consumedOffset += UInt64(pending.distance(from: pending.startIndex, to: lineStart))
                pending.removeSubrange(pending.startIndex..<lineStart)
            }
        }

        if !pending.isEmpty { body(pending) }
        return consumedOffset
    }

    private static func recordedServiceTier(in payload: [String: Any]) -> String? {
        let direct = string(payload["service_tier"] ?? payload["serviceTier"] ?? payload["speed"])
        let settings = payload["thread_settings"] as? [String: Any]
        let nested = string(settings?["service_tier"] ?? settings?["serviceTier"] ?? settings?["speed"])
        guard let value = (direct ?? nested)?.lowercased(),
              value == "default" || value == "priority" || value == "fast" else { return nil }
        return value
    }

    private static func codexProjectLabels(at home: URL) -> [String: String] {
        let stateURL = home.appending(path: ".codex-global-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = object["electron-workspace-root-labels"] as? [String: Any] else { return [:] }
        return labels.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String {
                result[normalizedProjectPath(entry.key)] = value
            }
        }
    }

    private static func projectName(for path: String, labels: [String: String], fallback: String) -> String {
        let normalized = normalizedProjectPath(path)
        let best = labels
            .filter { normalized == $0.key || normalized.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }
        return best?.value ?? fallback
    }

    private static func normalizedProjectPath(_ value: String) -> String {
        guard value != "Unassigned" else { return value }
        return URL(filePath: NSString(string: value).expandingTildeInPath)
            .standardizedFileURL.path
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    private static func optionalInt64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}
