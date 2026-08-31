import Foundation

actor LimitSnapshotStore {
    private static let weeklyInterval = TimeInterval(7 * 24 * 3_600)
    // Keep persistence aligned with ResetSeam.group, so a scheduled record
    // never creates a second visible vertical line beside an existing seam.
    private static let weeklySeamTolerance: TimeInterval = 120

    private struct PersistedState: Codable {
        var snapshots: [Snapshot] = []
        var resets: [ResetEvent] = []
        // An anchor is written only once: when this provider first gains an
        // actual weekly reset. Keeping it optional preserves older snapshot
        // files during app updates.
        var weeklyBackfillAnchors: [String: Date]?
    }

    private struct Snapshot: Codable {
        let provider: AIProvider
        let bucketID: String
        let bucketName: String
        let durationMinutes: Int?
        let usedPercent: Double
        let resetsAt: Date?
        let observedAt: Date
    }

    private let fileURL: URL
    private var state: PersistedState

    init(fileURL: URL? = nil, legacyFileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "QuotaWise", directoryHint: .isDirectory)
        let targetURL = fileURL ?? base.appending(path: "limit-snapshots.json")
        self.fileURL = targetURL
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder.usageDecoder.decode(PersistedState.self, from: data) {
            state = decoded
        } else if let legacyURL = legacyFileURL ?? Self.defaultLegacyFileURL(whenTargetIsDefault: fileURL == nil),
                  !FileManager.default.fileExists(atPath: targetURL.path),
                  let legacyData = try? Data(contentsOf: legacyURL),
                  let decoded = try? JSONDecoder.usageDecoder.decode(PersistedState.self, from: legacyData) {
            // The bundle rename also changed the Application Support directory.
            // Keep existing reset history and frozen weekly anchors instead of
            // making an upgrade look like a brand-new installation.
            state = decoded
            Self.save(decoded, to: targetURL)
        } else {
            state = PersistedState()
        }
    }

    private static func defaultLegacyFileURL(whenTargetIsDefault: Bool) -> URL? {
        guard whenTargetIsDefault else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "AI Usage Bar", directoryHint: .isDirectory)
            .appending(path: "limit-snapshots.json")
    }

    func observe(_ buckets: [LimitBucket], at observedAt: Date = Date()) -> [ResetEvent] {
        for bucket in buckets {
            for window in bucket.windows {
                let previous = state.snapshots.last {
                    $0.provider == bucket.provider
                        && $0.bucketID == bucket.id
                        && $0.durationMinutes == window.durationMinutes
                }

                if let previous {
                    // A remaining-credit increase is a reset signal. The
                    // snapshots are persisted, so this also detects a reset
                    // that happened while QuotaWise was not running.
                    let remainingIncreased = window.usedPercent + 0.5 < previous.usedPercent
                    if remainingIncreased, window.kind != .unknown {
                        let resetDate = previous.observedAt.addingTimeInterval(
                            observedAt.timeIntervalSince(previous.observedAt) / 2
                        )
                        let id = "snapshot:\(bucket.provider.rawValue):\(bucket.id):\(window.durationMinutes ?? -1):\(Int(resetDate.timeIntervalSince1970))"
                        if !state.resets.contains(where: { $0.id == id }) {
                            state.resets.append(
                                ResetEvent(
                                    id: id,
                                    provider: bucket.provider,
                                    date: resetDate,
                                    detectedAt: observedAt,
                                    kind: window.kind,
                                    bucketID: bucket.id,
                                    label: "\(bucket.displayName) \(window.kind == .weekly ? "weekly" : "session") reset",
                                    confidence: .exact
                                )
                            )
                        }
                    }
                }

                state.snapshots.append(
                    Snapshot(
                        provider: bucket.provider,
                        bucketID: bucket.id,
                        bucketName: bucket.displayName,
                        durationMinutes: window.durationMinutes,
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt,
                        observedAt: observedAt
                    )
                )
            }
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: observedAt) ?? .distantPast
        state.snapshots = Array(state.snapshots.filter { $0.observedAt >= cutoff }.suffix(2_000))
        state.resets = state.resets.filter { $0.date >= cutoff }
        save()
        return state.resets
    }

    func storedResets() -> [ResetEvent] {
        state.resets
    }

    func seedWeeklyBackfill(
        from buckets: [LimitBucket],
        observedResets: [ResetEvent],
        at observedAt: Date = Date(),
        cutoff: Date? = nil
    ) -> [ResetEvent] {
        let cutoff = cutoff ?? Calendar.current.date(byAdding: .day, value: -90, to: observedAt) ?? .distantPast
        let week = Self.weeklyInterval

        var anchors = state.weeklyBackfillAnchors ?? [:]

        for (provider, providerBuckets) in Dictionary(grouping: buckets, by: \.provider) {
            let preferredBucket = providerBuckets.first { $0.id == provider.rawValue }
                ?? providerBuckets.sorted { $0.id < $1.id }.first
            let primaryBucketID = preferredBucket?.id ?? provider.rawValue

            // Once we have anchored historical estimates to the first actual
            // seam, never rewrite that provider's backfill again. Forward
            // schedule filling below deliberately remains active after this
            // historical branch has frozen.
            if anchors[provider.rawValue] == nil {
                // Historical weekly seams deliberately belong to the primary
                // bucket only. A Spark reset is retained as its own observed
                // event, but it must not retroactively re-anchor (or invent)
                // Spark history or move the established primary seams.
                let earliestExact = (observedResets + state.resets)
                    .filter {
                        $0.provider == provider
                            && $0.kind == .weekly
                            && $0.confidence == .exact
                            && $0.bucketID == primaryBucketID
                            && $0.date <= observedAt
                    }
                    .map(\.date)
                    .min()

                let currentAnchor = preferredBucket?.windows
                    .filter { $0.kind == .weekly }
                    .sorted { ($0.durationMinutes ?? .max) < ($1.durationMinutes ?? .max) }
                    .first?.resetsAt

                if let earliestExact {
                    // Replace provisional seams with seven-day estimates leading
                    // up to the first observed reset, then freeze this history.
                    state.resets.removeAll {
                        $0.provider == provider
                            && $0.kind == .weekly
                            && $0.confidence == .estimated
                    }
                    anchors[provider.rawValue] = earliestExact
                    var date = earliestExact.addingTimeInterval(-week)
                    appendEstimatedWeeklyBackfill(
                        provider: provider,
                        bucketID: primaryBucketID,
                        from: &date,
                        cutoff: cutoff,
                        detectedAt: observedAt,
                        into: &state.resets
                    )
                } else if !state.resets.contains(where: {
                    $0.provider == provider && $0.kind == .weekly && $0.confidence == .estimated
                }), var date = currentAnchor {
                    // Without an actual reset, preserve the first provisional
                    // backfill rather than making chart history drift with a
                    // future reset schedule.
                    while date > observedAt { date = date.addingTimeInterval(-week) }

                    appendEstimatedWeeklyBackfill(
                        provider: provider,
                        bucketID: primaryBucketID,
                        from: &date,
                        cutoff: cutoff,
                        detectedAt: observedAt,
                        into: &state.resets
                    )
                }
            }

            replaceScheduledWeeklySeamsWithObservedResets(
                for: provider,
                observedResets: observedResets
            )
            appendEstimatedWeeklySchedule(
                for: provider,
                primaryBucketID: primaryBucketID,
                observedResets: observedResets,
                observedAt: observedAt
            )
        }

        state.weeklyBackfillAnchors = anchors.isEmpty ? nil : anchors
        state.resets.sort { $0.date < $1.date }
        save()
        return state.resets
    }

    private func appendEstimatedWeeklyBackfill(
        provider: AIProvider,
        bucketID: String,
        from date: inout Date,
        cutoff: Date,
        detectedAt: Date,
        into resets: inout [ResetEvent]
    ) {
        let week = Self.weeklyInterval
        while date >= cutoff {
            resets.append(
                ResetEvent(
                    id: "backfill:\(provider.rawValue):\(Int(date.timeIntervalSince1970))",
                    provider: provider,
                    date: date,
                    detectedAt: detectedAt,
                    kind: .weekly,
                    bucketID: bucketID,
                    label: "Weekly reset (estimated historical backfill)",
                    confidence: .estimated
                )
            )
            date = date.addingTimeInterval(-week)
        }
    }

    /// Extends the newest known primary weekly seam through the current
    /// observation. Unlike historical backfill, this only moves forward and
    /// never changes the dates that were already frozen into chart history.
    private func appendEstimatedWeeklySchedule(
        for provider: AIProvider,
        primaryBucketID: String,
        observedResets: [ResetEvent],
        observedAt: Date
    ) {
        var knownResets = state.resets + observedResets
        let primaryWeeklyDates = knownResets
            .filter {
                $0.provider == provider
                    && $0.kind == .weekly
                    && $0.bucketID == primaryBucketID
                    && $0.date <= observedAt
            }
            .map(\.date)
        guard let latestPrimaryDate = primaryWeeklyDates.max() else { return }

        var date = latestPrimaryDate.addingTimeInterval(Self.weeklyInterval)
        while date <= observedAt {
            // A reset from any bucket represents an already-visible weekly
            // seam. Do not create a parallel primary marker beside it.
            let hasExistingSeam = knownResets.contains {
                $0.provider == provider
                    && $0.kind == .weekly
                    && abs($0.date.timeIntervalSince(date)) <= Self.weeklySeamTolerance
            }
            if !hasExistingSeam {
                let scheduled = ResetEvent(
                    id: "schedule:\(provider.rawValue):\(Int(date.timeIntervalSince1970))",
                    provider: provider,
                    date: date,
                    detectedAt: observedAt,
                    kind: .weekly,
                    bucketID: primaryBucketID,
                    label: "Weekly reset (estimated schedule)",
                    confidence: .estimated
                )
                state.resets.append(scheduled)
                knownResets.append(scheduled)
            }
            date = date.addingTimeInterval(Self.weeklyInterval)
        }
    }

    /// Exact observations supersede only the matching forward forecast. The
    /// historical backfill stays immutable even when a later reset arrives.
    private func replaceScheduledWeeklySeamsWithObservedResets(
        for provider: AIProvider,
        observedResets: [ResetEvent]
    ) {
        let exactDates = (state.resets + observedResets)
            .filter {
                $0.provider == provider
                    && $0.kind == .weekly
                    && $0.confidence == .exact
            }
            .map(\.date)
        guard !exactDates.isEmpty else { return }

        state.resets.removeAll { reset in
            reset.provider == provider
                && reset.kind == .weekly
                && reset.id.hasPrefix("schedule:")
                && exactDates.contains { exactDate in
                    abs(exactDate.timeIntervalSince(reset.date)) <= Self.weeklySeamTolerance
                }
        }
    }

    private func save() {
        Self.save(state, to: fileURL)
    }

    private static func save(_ state: PersistedState, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.usageEncoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Runtime persistence is best-effort; in-memory values remain valid for this launch.
        }
    }
}

extension JSONEncoder {
    static var usageEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var usageDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
