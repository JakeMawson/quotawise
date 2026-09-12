import Foundation

actor LimitSnapshotStore {
    private static let weeklyInterval = TimeInterval(7 * 24 * 3_600)
    /// A timestamp correction shortly after a real reset must not become a
    /// second seam. Longer windows retain a conservative six-hour allowance;
    /// shorter session windows use half of their own duration.
    private static let maximumResetBoundaryCorrection = TimeInterval(6 * 3_600)
    // Keep persistence aligned with ResetSeam.group, so a scheduled record
    // never creates a second visible vertical line beside an existing seam.
    private static let weeklySeamTolerance: TimeInterval = 120
    /// The normal live refresh occurs every minute. Allow a small amount of
    /// scheduling jitter, but never bridge an offline or stale observation.
    private static let maximumCreditCorrelationInterval: TimeInterval = 3 * 60
    /// Keep local credit evidence alongside the existing 90-day snapshot and
    /// reset investigation history. Available credits are never pruned.
    private static let resetCreditJournalRetention: TimeInterval = 90 * 24 * 3_600

    private struct PersistedState: Codable {
        var snapshots: [Snapshot] = []
        var resets: [ResetEvent] = []
        // An anchor is written only once: when this provider first gains an
        // actual weekly reset. Keeping it optional preserves older snapshot
        // files during app updates.
        var weeklyBackfillAnchors: [String: Date]?
        // Optional fields preserve snapshot files written before earned-reset
        // credit monitoring existed.
        var resetCredits: [CodexEarnedResetCreditRecord]?
        var lastResetCreditAvailability: ResetCreditAvailabilitySnapshot?
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

    /// A complete detailed set is required before an ID disappearance can be
    /// trusted. The provider may return a capped subset while `availableCount`
    /// remains authoritative, so a partial set is intentionally a correlation
    /// barrier rather than an inference opportunity.
    private struct ResetCreditAvailabilitySnapshot: Codable {
        let observedAt: Date
        let availableCount: Int
        let detailedCreditIDs: [String]
        let hasCompleteDetailedCreditSet: Bool
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
                    let resetBoundaryAdvanced = Self.resetBoundaryAdvanced(
                        from: previous.resetsAt,
                        to: window.resetsAt
                    )
                    let isDuplicateCorrection = isLikelyDuplicateSnapshotCorrection(
                        provider: bucket.provider,
                        bucketID: bucket.id,
                        durationMinutes: window.durationMinutes,
                        observedAt: observedAt,
                        previousBoundary: previous.resetsAt,
                        currentBoundary: window.resetsAt
                    )
                    if remainingIncreased, resetBoundaryAdvanced, !isDuplicateCorrection, window.kind != .unknown {
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
        pruneResetCreditJournal(at: observedAt)
        _ = reconcileSnapshotResetEvidence()
        save()
        return state.resets
    }

    func storedResets() -> [ResetEvent] {
        if reconcileSnapshotResetEvidence() {
            save()
        }
        return state.resets
    }

    /// Records current earned reset-credit availability without exposing it to
    /// any QuotaWise view. A reset is upgraded only under a bounded, complete,
    /// one-credit/one-reset correlation; all other disappearances remain local
    /// journal evidence and leave the graph's reset observed.
    @discardableResult
    func observeResetCredits(
        _ availability: CodexEarnedResetCreditAvailability?,
        at observedAt: Date = Date()
    ) -> [ResetEvent] {
        guard let availability else {
            // A successful live rate-limit response can omit this optional
            // field. Clear the baseline so a later detailed response begins a
            // fresh observation rather than bridging unknown provider state.
            state.lastResetCreditAvailability = nil
            pruneResetCreditJournal(at: observedAt)
            save()
            return state.resets
        }

        let currentCredits = availability.credits
        let currentIDs = Set(currentCredits?.map(\.id) ?? [])
        let currentDetailsAreComplete = Self.isCompleteDetailedCreditSet(
            currentCredits,
            availableCount: availability.availableCount
        )
        let previousAvailability = state.lastResetCreditAvailability
        var records = state.resetCredits ?? []

        for credit in currentCredits ?? [] {
            let lifecycle = Self.lifecycleForVisibleCredit(credit, at: observedAt)
            if let index = records.firstIndex(where: { $0.id == credit.id }) {
                records[index].resetType = credit.resetType
                records[index].providerStatus = credit.status
                records[index].grantedAt = credit.grantedAt ?? records[index].grantedAt
                records[index].expiresAt = credit.expiresAt ?? records[index].expiresAt
                records[index].title = credit.title ?? records[index].title
                records[index].description = credit.description ?? records[index].description
                records[index].lastObservedAt = observedAt
                records[index].lifecycle = lifecycle
                records[index].disappearedAt = nil
                records[index].associatedResetID = nil
            } else {
                records.append(
                    CodexEarnedResetCreditRecord(
                        id: credit.id,
                        resetType: credit.resetType,
                        providerStatus: credit.status,
                        grantedAt: credit.grantedAt,
                        expiresAt: credit.expiresAt,
                        title: credit.title,
                        description: credit.description,
                        firstObservedAt: observedAt,
                        lastObservedAt: observedAt,
                        lifecycle: lifecycle,
                        disappearedAt: nil,
                        associatedResetID: nil
                    )
                )
            }
        }

        if let previousAvailability,
           previousAvailability.hasCompleteDetailedCreditSet,
           currentDetailsAreComplete {
            let previousIDs = Set(previousAvailability.detailedCreditIDs)
            let disappearedIDs = previousIDs.subtracting(currentIDs)
            let unexpectedCurrentIDs = currentIDs.subtracting(previousIDs)
            let interval = observedAt.timeIntervalSince(previousAvailability.observedAt)
            let correlationIntervalIsFresh = interval > 0
                && interval <= Self.maximumCreditCorrelationInterval
            let candidateResetIndexes = qualifyingPrimaryResetIndexes(
                from: previousAvailability.observedAt,
                through: observedAt
            )

            let qualifyingCreditID: String?
            if disappearedIDs.count == 1,
               unexpectedCurrentIDs.isEmpty,
               previousAvailability.availableCount == availability.availableCount + 1,
               correlationIntervalIsFresh,
               candidateResetIndexes.count == 1,
               let disappearedID = disappearedIDs.first,
               let record = records.first(where: { $0.id == disappearedID }),
               record.providerStatus.caseInsensitiveCompare("available") == .orderedSame,
               record.expiresAt.map({ $0 > observedAt }) ?? true {
                qualifyingCreditID = disappearedID
            } else {
                qualifyingCreditID = nil
            }

            // A complete detailed set makes every missing ID a real local
            // lifecycle transition. Only the singular fully-qualified case
            // may change a graph reset from observed to manual.
            for creditID in disappearedIDs {
                guard let index = records.firstIndex(where: { $0.id == creditID }) else { continue }
                records[index].disappearedAt = observedAt
                if creditID == qualifyingCreditID,
                   let resetIndex = candidateResetIndexes.first {
                    records[index].lifecycle = .consumed
                    records[index].associatedResetID = state.resets[resetIndex].id
                    state.resets[resetIndex].origin = .manual
                    state.resets[resetIndex].originEvidence = .resetCreditConsumed
                    state.resets[resetIndex].originCreditID = creditID
                } else {
                    records[index].lifecycle = Self.terminalLifecycle(for: records[index], at: observedAt)
                    records[index].associatedResetID = nil
                }
            }
        }

        state.resetCredits = records.isEmpty ? nil : records
        state.lastResetCreditAvailability = ResetCreditAvailabilitySnapshot(
            observedAt: observedAt,
            availableCount: availability.availableCount,
            detailedCreditIDs: currentIDs.sorted(),
            hasCompleteDetailedCreditSet: currentDetailsAreComplete
        )
        pruneResetCreditJournal(at: observedAt)
        _ = reconcileSnapshotResetEvidence()
        save()
        return state.resets
    }

    /// Internal inspection path for regression coverage and future diagnostics.
    /// The app deliberately has no chart, panel, or notification that consumes
    /// this private journal.
    func storedResetCredits() -> [CodexEarnedResetCreditRecord] {
        (state.resetCredits ?? []).sorted {
            if $0.firstObservedAt != $1.firstObservedAt {
                return $0.firstObservedAt < $1.firstObservedAt
            }
            return $0.id < $1.id
        }
    }

    /// Persists a user-confirmed manual origin against an existing observed
    /// reset. The exact event ID prevents a confirmation from accidentally
    /// colouring another weekly seam.
    @discardableResult
    func markManualReset(forID id: String) -> Bool {
        guard let index = state.resets.firstIndex(where: { $0.id == id }) else {
            return false
        }

        state.resets[index].origin = .manual
        state.resets[index].originEvidence = .userConfirmed
        state.resets[index].originCreditID = nil
        _ = reconcileSnapshotResetEvidence()
        save()
        return state.resets.contains { $0.id == id && $0.isManualReset }
    }

    func seedWeeklyBackfill(
        from buckets: [LimitBucket],
        observedResets: [ResetEvent],
        at observedAt: Date = Date(),
        cutoff: Date? = nil
    ) -> [ResetEvent] {
        _ = reconcileSnapshotResetEvidence()
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

    private static func isCompleteDetailedCreditSet(
        _ credits: [CodexEarnedResetCredit]?,
        availableCount: Int
    ) -> Bool {
        guard let credits, credits.count == availableCount else { return false }
        return Set(credits.map(\.id)).count == credits.count
    }

    private static func lifecycleForVisibleCredit(
        _ credit: CodexEarnedResetCredit,
        at observedAt: Date
    ) -> EarnedResetCreditLifecycle {
        if let expiresAt = credit.expiresAt, expiresAt <= observedAt {
            return .expired
        }
        return credit.status.caseInsensitiveCompare("available") == .orderedSame
            ? .available
            : .unattributed
    }

    private static func terminalLifecycle(
        for record: CodexEarnedResetCreditRecord,
        at observedAt: Date
    ) -> EarnedResetCreditLifecycle {
        if let expiresAt = record.expiresAt, expiresAt <= observedAt {
            return .expired
        }
        return .unattributed
    }

    private func qualifyingPrimaryResetIndexes(from previousObservation: Date, through observedAt: Date) -> [Int] {
        state.resets.indices.filter { index in
            let reset = state.resets[index]
            return reset.id.hasPrefix("snapshot:")
                && reset.provider == .codex
                && reset.bucketID.caseInsensitiveCompare("codex") == .orderedSame
                && reset.confidence == .exact
                && reset.resolvedOrigin == .observed
                && reset.detectedAt > previousObservation
                && reset.detectedAt <= observedAt
                && reset.date >= previousObservation
                && reset.date <= observedAt
        }
    }

    private func pruneResetCreditJournal(at observedAt: Date) {
        guard var records = state.resetCredits else { return }
        let cutoff = observedAt.addingTimeInterval(-Self.resetCreditJournalRetention)
        records.removeAll { record in
            guard record.lifecycle != .available else { return false }
            let lastRelevantDate = [
                record.disappearedAt,
                record.lastObservedAt,
                record.expiresAt,
                record.grantedAt,
                record.firstObservedAt,
            ].compactMap { $0 }.max() ?? record.firstObservedAt
            return lastRelevantDate < cutoff
        }
        state.resetCredits = records.isEmpty ? nil : records
    }

    private static func resetBoundaryAdvanced(
        from previous: Date?,
        to current: Date?
    ) -> Bool {
        guard let previous, let current else { return false }
        return current > previous
    }

    private static func correctionThreshold(for durationMinutes: Int?) -> TimeInterval {
        let windowDuration = durationMinutes.map { TimeInterval($0) * 60 }
        return min(
            maximumResetBoundaryCorrection,
            windowDuration.map { $0 / 2 } ?? maximumResetBoundaryCorrection
        )
    }

    /// A usage drop can happen again while the provider is correcting the
    /// just-created reset deadline. Keep the first reset and suppress only a
    /// same-window follow-up whose short deadline movement is close in time.
    private func isLikelyDuplicateSnapshotCorrection(
        provider: AIProvider,
        bucketID: String,
        durationMinutes: Int?,
        observedAt: Date,
        previousBoundary: Date?,
        currentBoundary: Date?
    ) -> Bool {
        guard let previousBoundary, let currentBoundary else { return false }
        let threshold = Self.correctionThreshold(for: durationMinutes)
        let boundaryAdvance = currentBoundary.timeIntervalSince(previousBoundary)
        let mostRecentReset = state.resets
            .filter {
                $0.id.hasPrefix("snapshot:")
                    && $0.provider == provider
                    && $0.bucketID == bucketID
                    && snapshotDurationMinutes(for: $0) == durationMinutes
            }
            .max(by: { $0.detectedAt < $1.detectedAt })
        guard boundaryAdvance > 0, boundaryAdvance < threshold,
              let mostRecentReset
        else {
            return false
        }
        let timeSinceReset = observedAt.timeIntervalSince(mostRecentReset.detectedAt)
        return timeSinceReset > 0 && timeSinceReset < threshold
    }

    /// Removes only legacy snapshot reset records whose own persisted
    /// before/after samples prove they were a short deadline correction soon
    /// after the preceding snapshot reset. User-confirmed manual resets are
    /// always retained.
    @discardableResult
    private func reconcileSnapshotResetEvidence() -> Bool {
        let snapshotResets = state.resets.filter { $0.id.hasPrefix("snapshot:") }
        let staleIDs = Set(snapshotResets.compactMap { reset -> String? in
            guard reset.id.hasPrefix("snapshot:"),
                  !reset.isManualReset,
                  let transition = snapshotTransition(for: reset)
            else {
                return nil
            }
            guard let previousBoundary = transition.previous.resetsAt,
                  let currentBoundary = transition.current.resetsAt
            else {
                return nil
            }
            let resetDurationMinutes = snapshotDurationMinutes(for: reset)
            let threshold = Self.correctionThreshold(for: resetDurationMinutes)
            let boundaryAdvance = currentBoundary.timeIntervalSince(previousBoundary)
            let previousReset = snapshotResets
                .filter {
                    $0.id != reset.id
                        && $0.provider == reset.provider
                        && $0.bucketID == reset.bucketID
                        && snapshotDurationMinutes(for: $0) == resetDurationMinutes
                        && $0.detectedAt < reset.detectedAt
                }
                .max(by: { $0.detectedAt < $1.detectedAt })
            guard boundaryAdvance > 0, boundaryAdvance < threshold,
                  let previousReset
            else {
                return nil
            }
            return reset.detectedAt.timeIntervalSince(previousReset.detectedAt) < threshold ? reset.id : nil
        })

        guard !staleIDs.isEmpty else { return false }
        state.resets.removeAll { staleIDs.contains($0.id) }
        return true
    }

    private func snapshotTransition(for reset: ResetEvent) -> (previous: Snapshot, current: Snapshot)? {
        let matching = state.snapshots.filter {
            $0.provider == reset.provider
                && $0.bucketID == reset.bucketID
                && $0.durationMinutes == snapshotDurationMinutes(for: reset)
        }.sorted { $0.observedAt < $1.observedAt }

        guard let current = matching.min(by: {
            abs($0.observedAt.timeIntervalSince(reset.detectedAt))
                < abs($1.observedAt.timeIntervalSince(reset.detectedAt))
        }), abs(current.observedAt.timeIntervalSince(reset.detectedAt)) <= 1,
        let index = matching.firstIndex(where: { $0.observedAt == current.observedAt }),
        index > matching.startIndex
        else {
            return nil
        }

        return (matching[index - 1], current)
    }

    private func snapshotDurationMinutes(for reset: ResetEvent) -> Int? {
        // Snapshot IDs are generated with the exact duration value. Fall back
        // to matching any duration only for records written by older versions
        // whose ID shape cannot be parsed.
        let components = reset.id.split(separator: ":")
        guard components.count >= 5, let value = Int(components[3]) else { return nil }
        return value == -1 ? nil : value
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
