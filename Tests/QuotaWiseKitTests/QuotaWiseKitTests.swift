import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import QuotaWiseKit

final class QuotaWiseKitTests: XCTestCase {
    func testStatusItemAvailabilityRecoversOnlyForUnavailableItems() {
        XCTAssertFalse(
            StatusItemAvailability.requiresRecovery(
                hasStatusItem: true,
                hasButton: true
            )
        )
        XCTAssertTrue(
            StatusItemAvailability.requiresRecovery(
                hasStatusItem: false,
                hasButton: true
            )
        )
        XCTAssertTrue(
            StatusItemAvailability.requiresRecovery(
                hasStatusItem: true,
                hasButton: false
            )
        )
    }

    func testPercentageFormattingSupportsWholeOneAndTwoDecimalPlaces() {
        XCTAssertEqual(UsageFormat.percentage(1.234, precision: .wholeNumber), "1%")
        XCTAssertEqual(UsageFormat.percentage(1.234, precision: .oneDecimal), "1.2%")
        XCTAssertEqual(UsageFormat.percentage(1.234, precision: .twoDecimals), "1.23%")
        XCTAssertEqual(UsageFormat.spokenPercentage(99.876, precision: .twoDecimals), "99.88 percent")
    }

    func testUsageLedgerDisclosureShowsOnlyNewestDayWhenItHasTenRows() {
        let newest = Date(timeIntervalSince1970: 1_785_700_000)
        let older = newest.addingTimeInterval(-86_400)
        let rows = (0..<10).map { index in
            Self.dailyUsageRow(id: "newest-\(index)", date: newest, credits: Double(index + 1))
        } + [Self.dailyUsageRow(id: "older", date: older, credits: 1)]

        let groups = UsageLedgerDisclosure.dayGroups(in: rows)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.rows.count, 10)
        XCTAssertEqual(UsageLedgerDisclosure.initialVisibleDayCount(for: groups), 1)
    }

    func testUsageLedgerDisclosureIncludesNextDayForSparseNewestDay() {
        let newest = Date(timeIntervalSince1970: 1_785_700_000)
        let older = newest.addingTimeInterval(-86_400)
        let rows = (0..<3).map { index in
            Self.dailyUsageRow(id: "newest-\(index)", date: newest, credits: Double(index + 1))
        } + (0..<11).map { index in
            Self.dailyUsageRow(id: "older-\(index)", date: older, credits: Double(index + 1))
        }

        let groups = UsageLedgerDisclosure.dayGroups(in: rows)

        XCTAssertEqual(groups.map(\.rows.count), [3, 11])
        XCTAssertEqual(UsageLedgerDisclosure.initialVisibleDayCount(for: groups), 2)
    }

    func testStudioDisplayPrecisionStoreDefaultsAndPersists() throws {
        let key = "studio-display-precision-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }

        let first = StudioDisplaySettingsStore(defaults: defaults, key: key)
        XCTAssertEqual(first.load(), .wholeNumber)

        first.save(.twoDecimals)
        XCTAssertEqual(StudioDisplaySettingsStore(defaults: defaults, key: key).load(), .twoDecimals)
    }

    @MainActor
    func testStudioPercentagePrecisionStatesRenderForQA() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["AI_USAGE_QA_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:)) else { return }

        let bucket = LimitBucket(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            planType: "Pro",
            windows: [
                RateLimitWindow(
                    usedPercent: 98.765,
                    durationMinutes: 10_080,
                    resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                    confidence: .exact,
                    estimateBasis: nil
                ),
                RateLimitWindow(
                    usedPercent: 1.234,
                    durationMinutes: 300,
                    resetsAt: Date(timeIntervalSince1970: 1_800_018_000),
                    confidence: .exact,
                    estimateBasis: nil
                ),
            ],
            confidence: .exact,
            sourceDescription: "QA fixture"
        )

        for precision in PercentageDisplayPrecision.allCases {
            let card = LimitBucketCard(
                bucket: bucket,
                provider: .codex,
                compact: false,
                percentagePrecision: precision
            )
            .padding(18)
            .frame(width: 430)
            .background(UsagePalette.nightInk)
            .environment(\.colorScheme, .dark)
            try Self.writeRenderedPNG(card, named: "studio-percentage-\(precision.displayName.replacingOccurrences(of: " ", with: "-"))@4x.png", to: outputDirectory)
        }

        let menu = StudioPercentagePrecisionMenuLabel(selection: .twoDecimals)
            .padding(18)
            .background(UsagePalette.nightInk)
            .environment(\.colorScheme, .dark)
        try Self.writeRenderedPNG(menu, named: "studio-percentage-menu@4x.png", to: outputDirectory)
    }

    @MainActor
    func testLargeHistoryThresholdStartsAtOneHundredFiles() {
        XCTAssertEqual(UsageApplicationModel.indexingFileThreshold, 100)
    }

    @MainActor
    func testIndexingQAStateIsVisibleToTheMenuPanel() {
        let model = UsageApplicationModel()
        model.showIndexingForQA()

        XCTAssertTrue(model.isIndexingHistory)
        XCTAssertEqual(model.indexingFileCount, 100)
    }

    func testScannerRecognizesAnEmptyCacheAsNeedingInitialIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scanner = LocalUsageScanner(
            codexHome: root.appending(path: "codex"),
            claudeHome: root.appending(path: "claude"),
            cacheURL: root.appending(path: "usage-index-v5.json")
        )

        let requiresInitialIndex = await scanner.needsInitialIndex
        XCTAssertTrue(requiresInitialIndex)
    }

    func testHistoricalDayPeriodUsesLocalMidnightAndExclusiveNextMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Perth"))
        let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 14)))
        let period = UsagePeriod.resolve(
            range: .oneDay,
            historicalDay: selected,
            now: selected.addingTimeInterval(3 * 86_400),
            calendar: calendar
        )

        XCTAssertEqual(calendar.component(.hour, from: period.start), 0)
        XCTAssertEqual(calendar.component(.day, from: period.start), 3)
        XCTAssertEqual(calendar.component(.hour, from: period.end), 0)
        XCTAssertEqual(calendar.component(.day, from: period.end), 4)
        XCTAssertTrue(period.contains(period.start))
        XCTAssertTrue(period.contains(period.end.addingTimeInterval(-0.001)))
        XCTAssertFalse(period.contains(period.end))
    }

    @MainActor
    func testHistoricalDaySelectionSwitchesToOneDayAndManualRangeClearsIt() throws {
        let model = UsageApplicationModel()
        let day = Date(timeIntervalSince1970: 1_785_700_000)
        model.selectHistoricalDay(day)
        XCTAssertEqual(model.selectedRange, .oneDay)
        XCTAssertNotNil(model.selectedHistoricalDay)

        model.selectRange(.sevenDays)
        XCTAssertEqual(model.selectedRange, .sevenDays)
        XCTAssertNil(model.selectedHistoricalDay)
    }

    func testEventFilteringHonorsProviderProjectAndHistoricalBoundaries() {
        let start = Date(timeIntervalSince1970: 1_785_700_000)
        let period = UsagePeriod(start: start, end: start.addingTimeInterval(86_400))
        let events = [
            Self.usageEvent(id: "start", date: start, project: "/A", provider: .codex, credits: 10),
            Self.usageEvent(id: "inside", date: start.addingTimeInterval(60), project: "/A", provider: .codex, credits: 20),
            Self.usageEvent(id: "other-project", date: start.addingTimeInterval(120), project: "/B", provider: .codex, credits: 30),
            Self.usageEvent(id: "other-provider", date: start.addingTimeInterval(180), project: "/A", provider: .claude, credits: 40),
            Self.usageEvent(id: "end", date: period.end, project: "/A", provider: .codex, credits: 50),
        ]

        let filtered = UsageApplicationModel.filterEvents(
            events,
            provider: .codex,
            projectPath: "/A",
            period: period
        )
        XCTAssertEqual(filtered.map(\.id), ["start", "inside"])
    }

    func testProjectCreditSeriesUsesTopNamedProjectsGroupsOtherAndStacksByTotal() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = Date(timeIntervalSince1970: 1_785_700_000)
        let second = first.addingTimeInterval(86_400)
        let events = [
            Self.usageEvent(id: "a1", date: first, project: "/A", credits: 60),
            Self.usageEvent(id: "a2", date: second, project: "/A", credits: 40),
            Self.usageEvent(id: "b1", date: first, project: "/B", credits: 20),
            Self.usageEvent(id: "b2", date: second, project: "/B", credits: 50),
            Self.usageEvent(id: "c1", date: first, project: "/C", credits: 50),
            Self.usageEvent(id: "d1", date: second, project: "/D", credits: 30),
        ]
        let buckets = [
            calendar.startOfDay(for: first),
            calendar.startOfDay(for: second),
        ]
        let result = UsageApplicationModel.buildProjectCreditSeries(
            events: events,
            bucketDates: buckets,
            range: .thirtyDays,
            calendar: calendar,
            maxNamedProjects: 2
        )

        XCTAssertEqual(result.map(\.name), ["A", "Other", "B"])
        XCTAssertEqual(result.map(\.totalCredits), [100, 80, 70])
        XCTAssertEqual(result[0].points[0].lowerCredits, 0)
        XCTAssertEqual(result[0].points[0].upperCredits, 60)
        XCTAssertEqual(result[1].points[0].lowerCredits, 60)
        XCTAssertEqual(result[1].points[0].upperCredits, 110)
        XCTAssertEqual(result[2].points[0].lowerCredits, 110)
        XCTAssertEqual(result[2].points[0].upperCredits, 130)
        XCTAssertEqual(result.last?.points.last?.upperCredits, 120)
    }

    func testProjectCreditSeriesOmitsOtherWhenSevenOrFewerProjectsExist() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_785_700_000)
        let events = (1...3).map {
            Self.usageEvent(id: "p\($0)", date: date, project: "/P\($0)", credits: Double($0 * 10))
        }
        let result = UsageApplicationModel.buildProjectCreditSeries(
            events: events,
            bucketDates: [calendar.startOfDay(for: date)],
            range: .sevenDays,
            calendar: calendar
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertFalse(result.contains(where: \.isOther))
    }

    func testProjectCreditSeriesIsEmptyWhenTheSelectedPeriodHasNoUsage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_785_700_000)

        let result = UsageApplicationModel.buildProjectCreditSeries(
            events: [],
            bucketDates: [calendar.startOfDay(for: date)],
            range: .oneDay,
            calendar: calendar
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testProjectTooltipFlipsBelowWhenSelectedPointIsNearPlotTop() {
        XCTAssertTrue(
            ProjectCreditChart.shouldPlaceSelectionAnnotationBelow(
                selectedTotal: 55,
                maximum: 100
            )
        )
        XCTAssertTrue(
            ProjectCreditChart.shouldPlaceSelectionAnnotationBelow(
                selectedTotal: 86,
                maximum: 100
            )
        )
    }

    func testProjectTooltipStaysAboveWhenItHasEnoughTopClearance() {
        XCTAssertFalse(
            ProjectCreditChart.shouldPlaceSelectionAnnotationBelow(
                selectedTotal: 54.9,
                maximum: 100
            )
        )
        XCTAssertFalse(
            ProjectCreditChart.shouldPlaceSelectionAnnotationBelow(
                selectedTotal: 1,
                maximum: 0
            )
        )
    }

    @MainActor
    func testProjectTooltipRenderedQAStates() throws {
        let fixture = Self.projectTooltipFixture()
        let outputDirectory = ProcessInfo.processInfo.environment["AI_USAGE_QA_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:))

        let states: [(name: String, selectedDate: Date, width: CGFloat)] = [
            ("high-normal", fixture.dates[2], 900),
            ("low-normal", fixture.dates[1], 900),
            ("high-compact", fixture.dates[2], 680),
        ]

        for state in states {
            let chart = ProjectCreditChart(
                series: fixture.series,
                provider: .codex,
                range: .thirtyDays,
                historicalDay: nil,
                initialSelectedDate: state.selectedDate
            )
            .padding(24)
            .frame(width: state.width, height: 520, alignment: .topLeading)
            .foregroundStyle(UsagePalette.porcelain)
            .background(UsagePalette.nightInk)
            .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: chart)
            renderer.scale = 4
            let image: NSImage = try XCTUnwrap(renderer.nsImage)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)

            if let outputDirectory {
                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
                let tiff = try XCTUnwrap(image.tiffRepresentation)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
                let png = try XCTUnwrap(
                    bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
                )
                try png.write(to: outputDirectory.appending(path: "project-tooltip-\(state.name)@4x.png"))
            }
        }
    }

    func testOpenAISolPricingSeparatesCachedTokens() {
        let tokens = TokenUsage(input: 1_000_000, cachedInput: 1_000_000, output: 1_000_000)
        let result = PricingCatalog.cost(
            provider: .codex,
            model: "gpt-5.6-sol",
            tokens: tokens,
            at: Date()
        )
        XCTAssertEqual(result.usd, 35.5, accuracy: 0.0001)
        XCTAssertFalse(result.estimated)
    }

    func testClaudeResetDateUsesSuppliedTimeZoneAndRollsForward() throws {
        let formatter = ISO8601DateFormatter()
        let observed = try XCTUnwrap(formatter.date(from: "2026-07-14T22:45:40Z"))
        let reset = try XCTUnwrap(
            LocalUsageScanner.parseClaudeResetDate(
                text: "You've hit your session limit · resets 10:50am (Australia/Perth)",
                observedAt: observed
            )
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Perth"))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reset)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 50)
    }

    func testRateObservationDropCreatesOneReset() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let observations = [
            RateObservation(
                provider: .codex,
                bucketID: "codex",
                bucketName: "Codex",
                observedAt: base,
                usedPercent: 72,
                durationMinutes: 10_080,
                resetsAt: base.addingTimeInterval(3_600)
            ),
            RateObservation(
                provider: .codex,
                bucketID: "codex",
                bucketName: "Codex",
                observedAt: base.addingTimeInterval(3_601),
                usedPercent: 3,
                durationMinutes: 10_080,
                resetsAt: base.addingTimeInterval(7 * 86_400)
            ),
        ]
        let resets = LocalUsageScanner.detectResets(in: observations)
        XCTAssertEqual(resets.count, 1)
        XCTAssertEqual(resets.first?.kind, .weekly)
        XCTAssertEqual(resets.first?.date, base.addingTimeInterval(3_600))
    }

    func testStaleConcurrentUsagePercentDoesNotCreateResetWithoutBoundaryAdvance() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = base.addingTimeInterval(7 * 86_400)
        let observations = [72.0, 18.0, 74.0, 20.0].enumerated().map { index, used in
            RateObservation(
                provider: .codex,
                bucketID: "codex",
                bucketName: "Codex",
                observedAt: base.addingTimeInterval(Double(index * 60)),
                usedPercent: used,
                durationMinutes: 10_080,
                resetsAt: reset
            )
        }
        XCTAssertTrue(LocalUsageScanner.detectResets(in: observations).isEmpty)
    }

    func testCodexLimitDecoderHandlesWeeklyOnlyAndSparkBucket() throws {
        let response: [String: Any] = [
            "id": 2,
            "result": [
                "rateLimits": [:],
                "rateLimitsByLimitId": [
                    "codex": [
                        "limitId": "codex",
                        "planType": "pro",
                        "primary": [
                            "usedPercent": 12,
                            "windowDurationMins": 10_080,
                            "resetsAt": 1_800_000_000,
                        ],
                        "secondary": NSNull(),
                    ],
                    "codex_bengalfox": [
                        "limitId": "codex_bengalfox",
                        "limitName": "GPT-5.3-Codex-Spark",
                        "primary": [
                            "usedPercent": 4,
                            "windowDurationMins": 10_080,
                            "resetsAt": 1_800_000_100,
                        ],
                    ],
                ],
            ],
        ]
        let buckets = try CodexAppServerClient.decodeLimitResponse(response)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.first?.id, "codex")
        XCTAssertEqual(buckets.first?.windows.count, 1)
        XCTAssertEqual(buckets.first?.windows.first?.durationMinutes, 10_080)
        XCTAssertEqual(buckets.last?.displayName, "Spark")
    }

    func testScannerDeduplicatesClaudeMessagesPreservesTimestampsAndUsesCodexCumulativeDeltas() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let claude = root.appending(path: ".claude")
        let codexSessions = codex.appending(path: "sessions")
        let claudeProjects = claude.appending(path: "projects/project")
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProjects, withIntermediateDirectories: true)

        let codexLines: [[String: Any]] = [
            ["timestamp": "2026-08-01T00:00:00Z", "type": "session_meta", "payload": ["id": "session-1", "cwd": "/tmp/Example"]],
            ["timestamp": "2026-08-01T00:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Example"]],
            Self.tokenLine(timestamp: "2026-08-01T00:01:00Z", input: 100, cached: 20, output: 10),
            Self.tokenLine(timestamp: "2026-08-01T00:02:00Z", input: 180, cached: 30, output: 25),
        ]
        let codexSessionURL = codexSessions.appending(path: "session.jsonl")
        try writeJSONLines(codexLines, to: codexSessionURL)

        let claudeMessage: [String: Any] = [
            "timestamp": "2026-08-01T01:00:00Z",
            "type": "assistant",
            "uuid": "row-1",
            "cwd": "/tmp/ClaudeExample",
            "message": [
                "id": "message-1",
                "model": "claude-opus-4-8",
                "usage": [
                    "input_tokens": 10,
                    "cache_read_input_tokens": 20,
                    "cache_creation_input_tokens": 5,
                    "output_tokens": 30,
                ],
                "content": [],
            ],
        ]
        let claudeReset: [String: Any] = [
            "timestamp": "2026-08-01T01:10:00Z",
            "type": "assistant",
            "uuid": "reset-row",
            "cwd": "/tmp/ClaudeExample",
            "error": "rate_limit",
            "message": [
                "id": "reset-message",
                "model": "<synthetic>",
                "content": [["type": "text", "text": "You've hit your session limit · resets 2pm (Australia/Perth)"]],
            ],
        ]
        try writeJSONLines([claudeMessage, claudeMessage, claudeReset], to: claudeProjects.appending(path: "session.jsonl"))

        let scanner = LocalUsageScanner(codexHome: codex, claudeHome: claude)
        let result = await scanner.scanAll()
        XCTAssertEqual(result.events.filter { $0.provider == .codex }.count, 2)
        XCTAssertEqual(
            result.events.filter { $0.provider == .codex }.map(\.timestamp),
            [
                try XCTUnwrap(Date.parseUsageTimestamp("2026-08-01T00:01:00Z")),
                try XCTUnwrap(Date.parseUsageTimestamp("2026-08-01T00:02:00Z")),
            ]
        )
        XCTAssertEqual(result.events.filter { $0.provider == .claude }.count, 1)
        XCTAssertEqual(result.events.filter { $0.provider == .codex }.reduce(0) { $0 + $1.tokens.input }, 150)
        XCTAssertEqual(result.events.filter { $0.provider == .codex }.reduce(0) { $0 + $1.tokens.cachedInput }, 30)
        XCTAssertEqual(result.events.filter { $0.provider == .codex }.reduce(0) { $0 + $1.tokens.output }, 25)
        XCTAssertEqual(result.resetEvents.filter { $0.provider == .claude }.count, 1)

        try appendJSONLine(
            Self.tokenLine(timestamp: "2026-08-01T00:03:00Z", input: 250, cached: 40, output: 30),
            to: codexSessionURL
        )
        let appended = await scanner.scanAll()
        XCTAssertEqual(appended.events.filter { $0.provider == .codex }.count, 3)
        XCTAssertEqual(appended.events.filter { $0.provider == .codex }.reduce(0) { $0 + $1.tokens.input }, 210)
        XCTAssertEqual(appended.events.filter { $0.provider == .codex }.reduce(0) { $0 + $1.tokens.cachedInput }, 40)
        XCTAssertEqual(appended.events.filter { $0.provider == .codex }.reduce(0) { $0 + $1.tokens.output }, 30)
    }

    func testScannerDropsOldEventsInsideARecentlyModifiedCodexFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let old = Date().addingTimeInterval(-50 * 86_400)
        let recent = Date().addingTimeInterval(-60)
        try writeJSONLines([
            ["timestamp": formatter.string(from: old), "type": "session_meta", "payload": ["id": "rolling-codex", "cwd": "/tmp/Rolling"]],
            ["timestamp": formatter.string(from: old.addingTimeInterval(1)), "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Rolling"]],
            Self.tokenLine(timestamp: formatter.string(from: old.addingTimeInterval(60)), input: 100, cached: 0, output: 1),
            Self.tokenLine(timestamp: formatter.string(from: recent), input: 140, cached: 0, output: 2),
        ], to: sessions.appending(path: "active.jsonl"))

        let scanner = LocalUsageScanner(codexHome: codex, claudeHome: root.appending(path: ".claude"), codexLookbackDays: 35)
        let result = await scanner.scanAll()
        let events = result.events.filter { $0.provider == .codex }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.tokens.input, 40)
        XCTAssertGreaterThanOrEqual(events.first?.timestamp ?? .distantPast, Date().addingTimeInterval(-35 * 86_400))
    }

    func testScannerCompactsOlderHistoryButKeepsRecentDetail() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let old = (Calendar.current.dateInterval(of: .hour, for: Date().addingTimeInterval(-40 * 3_600))?.start
            ?? Date().addingTimeInterval(-40 * 3_600)).addingTimeInterval(60)
        let recent = Date().addingTimeInterval(-60 * 60)
        var values: [[String: Any]] = [
            ["timestamp": formatter.string(from: old), "type": "session_meta", "payload": ["id": "compact-codex", "cwd": "/tmp/Compact"]],
            ["timestamp": formatter.string(from: old.addingTimeInterval(1)), "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Compact"]],
        ]
        for value in 1...65 {
            values.append(
                Self.tokenLine(
                    timestamp: formatter.string(from: old.addingTimeInterval(Double(value * 30))),
                    input: value,
                    cached: 0,
                    output: value
                )
            )
        }
        values.append(Self.tokenLine(timestamp: formatter.string(from: recent), input: 66, cached: 0, output: 66))
        try writeJSONLines(values, to: sessions.appending(path: "compact.jsonl"))

        let scanner = LocalUsageScanner(codexHome: codex, claudeHome: root.appending(path: ".claude"), codexLookbackDays: 35)
        let events = (await scanner.scanAll()).events.filter { $0.provider == .codex }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.reduce(0) { $0 + $1.tokens.input }, 66)
        XCTAssertEqual(events.filter { $0.id.hasPrefix("hour:") }.count, 1)
    }

    func testScannerRetainsCodexAppendCheckpointAfterExpiredEventsAreEvicted() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let old = Date().addingTimeInterval(-50 * 86_400)
        let recent = Date().addingTimeInterval(-60)
        let session = sessions.appending(path: "checkpoint.jsonl")
        try writeJSONLines([
            ["timestamp": formatter.string(from: old), "type": "session_meta", "payload": ["id": "checkpoint-codex", "cwd": "/tmp/Checkpoint"]],
            ["timestamp": formatter.string(from: old.addingTimeInterval(1)), "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Checkpoint"]],
            Self.tokenLine(timestamp: formatter.string(from: old.addingTimeInterval(60)), input: 100, cached: 0, output: 1),
        ], to: session)

        let scanner = LocalUsageScanner(codexHome: codex, claudeHome: root.appending(path: ".claude"), codexLookbackDays: 35)
        let first = await scanner.scanAll()
        XCTAssertTrue(first.events.isEmpty)
        try appendJSONLine(Self.tokenLine(timestamp: formatter.string(from: recent), input: 140, cached: 0, output: 2), to: session)

        let events = (await scanner.scanAll()).events.filter { $0.provider == .codex }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.tokens.input, 40)
    }

    func testScannerBoundsClaudeHistoryAndSkipsNoOpCacheWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let claude = root.appending(path: ".claude/projects/project")
        let cache = root.appending(path: "usage-index-v5.json")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let old = formatter.string(from: Date().addingTimeInterval(-70 * 86_400))
        let recent = formatter.string(from: Date().addingTimeInterval(-60))
        try writeJSONLines([
            Self.claudeUsageLine(timestamp: old, id: "old-claude", input: 10),
            Self.claudeUsageLine(timestamp: recent, id: "recent-claude", input: 20),
        ], to: claude.appending(path: "history.jsonl"))

        let scanner = LocalUsageScanner(
            codexHome: codex,
            claudeHome: root.appending(path: ".claude"),
            codexLookbackDays: 35,
            claudeLookbackDays: 63,
            cacheURL: cache
        )
        let first = await scanner.scanAll()
        XCTAssertEqual(first.events.filter { $0.provider == .claude }.map(\.id), ["claude:recent-claude"])
        let before = try Data(contentsOf: cache)
        _ = await scanner.scanAll()
        XCTAssertEqual(try Data(contentsOf: cache), before)
    }

    func testScannerAppendsNewClaudeMessagesWithoutLosingExistingOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let claude = root.appending(path: ".claude/projects/project")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let session = claude.appending(path: "growing.jsonl")
        try writeJSONLines([
            Self.claudeUsageLine(timestamp: "2026-08-01T00:00:00Z", id: "message-1", input: 10),
        ], to: session)

        let scanner = LocalUsageScanner(
            codexHome: root.appending(path: ".codex"),
            claudeHome: root.appending(path: ".claude"),
            claudeLookbackDays: nil
        )
        let first = await scanner.scanAll()
        XCTAssertEqual(first.events.filter { $0.provider == .claude }.map(\.id), ["claude:message-1"])

        try appendJSONLine(
            Self.claudeUsageLine(timestamp: "2026-08-01T00:01:00Z", id: "message-2", input: 20),
            to: session
        )
        let appended = await scanner.scanAll()
        XCTAssertEqual(
            Set(appended.events.filter { $0.provider == .claude }.map(\.id)),
            ["claude:message-1", "claude:message-2"]
        )
        XCTAssertEqual(appended.events.filter { $0.provider == .claude }.reduce(0) { $0 + $1.tokens.input }, 30)
    }

    /// Simulates the scanner capturing a file signature exactly as a session process is mid-write
    /// on a new line: the truncated bytes are on disk but the line has no closing JSON or trailing
    /// newline yet. A later append-resume must not silently lose that line's data once it completes.
    func testScannerResumesCodexAppendFromLastCompleteLineAfterMidWriteCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let session = sessions.appending(path: "midwrite.jsonl")
        try writeJSONLines([
            ["timestamp": "2026-08-01T00:00:00Z", "type": "session_meta", "payload": ["id": "midwrite", "cwd": "/tmp/MidWrite"]],
            ["timestamp": "2026-08-01T00:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/MidWrite"]],
        ], to: session)

        let scanner = LocalUsageScanner(codexHome: codex, claudeHome: root.appending(path: ".claude"), codexLookbackDays: nil)
        let initial = await scanner.scanAll()
        XCTAssertTrue(initial.events.filter { $0.provider == .codex }.isEmpty)

        let fullLine = try JSONSerialization.data(withJSONObject: Self.tokenLine(
            timestamp: "2026-08-01T00:01:00Z", input: 100, cached: 0, output: 5
        ))
        let truncationPoint = fullLine.count - 25
        try appendRawUnterminated(fullLine.prefix(truncationPoint), to: session)

        let midWrite = await scanner.scanAll()
        XCTAssertTrue(
            midWrite.events.filter { $0.provider == .codex }.isEmpty,
            "a truncated line must not produce a corrupt event"
        )

        var remainder = Data(fullLine.suffix(from: truncationPoint))
        remainder.append(0x0A)
        try appendRawUnterminated(remainder, to: session)

        let completed = await scanner.scanAll()
        let events = completed.events.filter { $0.provider == .codex }
        XCTAssertEqual(events.count, 1, "the completed line must be fully recovered, not silently lost")
        XCTAssertEqual(events.first?.tokens.input, 100)
        XCTAssertEqual(events.first?.tokens.output, 5)
    }

    /// The Claude equivalent of the Codex mid-write test above: a truncated second message must
    /// not corrupt or drop the already-cached first message, and must be fully recovered once the
    /// writer finishes the line.
    func testScannerResumesClaudeAppendFromLastCompleteLineAfterMidWriteCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let claude = root.appending(path: ".claude/projects/project")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let session = claude.appending(path: "midwrite.jsonl")
        try writeJSONLines([
            Self.claudeUsageLine(timestamp: "2026-08-01T00:00:00Z", id: "first-message", input: 10),
        ], to: session)

        let scanner = LocalUsageScanner(
            codexHome: root.appending(path: ".codex"),
            claudeHome: root.appending(path: ".claude"),
            claudeLookbackDays: nil
        )
        let initial = await scanner.scanAll()
        XCTAssertEqual(initial.events.filter { $0.provider == .claude }.map(\.id), ["claude:first-message"])

        let fullLine = try JSONSerialization.data(withJSONObject: Self.claudeUsageLine(
            timestamp: "2026-08-01T00:01:00Z", id: "second-message", input: 25
        ))
        let truncationPoint = fullLine.count - 25
        try appendRawUnterminated(fullLine.prefix(truncationPoint), to: session)

        let midWrite = await scanner.scanAll()
        XCTAssertEqual(
            midWrite.events.filter { $0.provider == .claude }.map(\.id),
            ["claude:first-message"],
            "a truncated line must not produce a corrupt event, and the already-cached message must be retained"
        )

        var remainder = Data(fullLine.suffix(from: truncationPoint))
        remainder.append(0x0A)
        try appendRawUnterminated(remainder, to: session)

        let completed = await scanner.scanAll()
        XCTAssertEqual(
            Set(completed.events.filter { $0.provider == .claude }.map(\.id)),
            ["claude:first-message", "claude:second-message"],
            "the completed second message must be fully recovered, not silently lost"
        )
    }

    func testFailedClaudeParseIsNotCachedAndRetriesAfterPermissionsFixed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let claude = root.appending(path: ".claude/projects/project")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let session = claude.appending(path: "unreadable.jsonl")
        try writeJSONLines([
            Self.claudeUsageLine(timestamp: "2026-08-01T00:00:00Z", id: "blocked-message", input: 10),
        ], to: session)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: session.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.path) }

        let scanner = LocalUsageScanner(
            codexHome: root.appending(path: ".codex"),
            claudeHome: root.appending(path: ".claude"),
            claudeLookbackDays: nil
        )
        let failed = await scanner.scanAll()
        XCTAssertTrue(failed.events.isEmpty)
        XCTAssertFalse(failed.warnings.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.path)
        let retried = await scanner.scanAll()
        XCTAssertEqual(retried.events.filter { $0.provider == .claude }.map(\.id), ["claude:blocked-message"])
    }

    func testNativeCodexDailyReportMatchesCLICompatibilityFields() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let firstSession: [[String: Any]] = [
            ["timestamp": "2026-06-01T01:00:00Z", "type": "session_meta", "payload": ["id": "session-a", "cwd": "/tmp/Alpha"]],
            ["timestamp": "2026-06-01T01:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Alpha"]],
            Self.tokenLine(timestamp: "2026-06-01T01:01:00Z", input: 100, cached: 20, output: 10),
            Self.tokenLine(timestamp: "2026-06-01T01:02:00Z", input: 180, cached: 30, output: 25),
        ]
        let secondSession: [[String: Any]] = [
            ["timestamp": "2026-06-02T01:00:00Z", "type": "session_meta", "payload": ["id": "session-b", "cwd": "/tmp/Beta"]],
            ["timestamp": "2026-06-02T01:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-terra", "cwd": "/tmp/Beta"]],
            Self.tokenLine(timestamp: "2026-06-02T01:01:00Z", input: 50, cached: 5, output: 7),
        ]
        try writeJSONLines(firstSession, to: sessions.appending(path: "first.jsonl"))
        try writeJSONLines(secondSession, to: sessions.appending(path: "second.jsonl"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let report = await CodexUsageReporter.daily(
            codexHome: codex,
            calendar: calendar,
            lookbackDays: nil
        )

        XCTAssertEqual(report.data.map(\.date), ["2026-06-01", "2026-06-02"])
        XCTAssertEqual(report.data[0].models, ["gpt-5.6-sol"])
        XCTAssertEqual(report.data[0].inputTokens, 150)
        XCTAssertEqual(report.data[0].cachedInputTokens, 30)
        XCTAssertEqual(report.data[0].outputTokens, 25)
        XCTAssertEqual(report.data[0].reasoningOutputTokens, 0)
        XCTAssertEqual(report.data[0].totalTokens, 205)
        XCTAssertGreaterThan(report.data[0].costUSD, 0)
        XCTAssertEqual(report.data[1].models, ["gpt-5.6-terra"])
        XCTAssertEqual(report.data[1].inputTokens, 45)
        XCTAssertEqual(report.data[1].cachedInputTokens, 5)
        XCTAssertEqual(report.data[1].outputTokens, 7)

        let encoded = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertNotNil(rows[0]["date"])
        XCTAssertNotNil(rows[0]["models"])
        XCTAssertNotNil(rows[0]["inputTokens"])
        XCTAssertNotNil(rows[0]["outputTokens"])
        XCTAssertNotNil(rows[0]["reasoningOutputTokens"])
        XCTAssertNotNil(rows[0]["cachedInputTokens"])
        XCTAssertNotNil(rows[0]["totalTokens"])
        XCTAssertNotNil(rows[0]["costUSD"])

        let filteredByPath = await CodexUsageReporter.daily(
            codexHome: codex,
            calendar: calendar,
            lookbackDays: nil,
            project: "/tmp/Alpha"
        )
        XCTAssertEqual(filteredByPath.data.count, 1)
        XCTAssertEqual(filteredByPath.data[0].date, "2026-06-01")
        XCTAssertEqual(filteredByPath.data[0].models, ["gpt-5.6-sol"])

        let filteredByName = await CodexUsageReporter.daily(
            codexHome: codex,
            calendar: calendar,
            lookbackDays: nil,
            project: "Beta"
        )
        XCTAssertEqual(filteredByName.data.count, 1)
        XCTAssertEqual(filteredByName.data[0].date, "2026-06-02")
    }

    func testNativeCodexDailyReportExcludesUndatedEventsFromBoundedWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions/2026/08/03")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let values: [[String: Any]] = [
            ["timestamp": "2026-08-03T01:00:00Z", "type": "session_meta", "payload": ["id": "session-undated", "cwd": "/tmp/Undated"]],
            ["timestamp": "2026-08-03T01:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Undated"]],
            [
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": 9_000_000,
                            "cached_input_tokens": 0,
                            "cache_write_input_tokens": 0,
                            "output_tokens": 1_000_000,
                            "reasoning_output_tokens": 0,
                        ],
                    ],
                ],
            ],
        ]
        try writeJSONLines(values, to: sessions.appending(path: "undated.jsonl"))

        let report = await CodexUsageReporter.daily(codexHome: codex, lookbackDays: 35)
        XCTAssertTrue(report.data.isEmpty)
    }

    func testNativeCodexDailyReportKeepsSameHourEventsFromSeparateSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        for session in ["one", "two"] {
            let values: [[String: Any]] = [
                ["timestamp": "2026-08-01T01:00:00Z", "type": "session_meta", "payload": ["id": session, "cwd": "/tmp/SameProject"]],
                ["timestamp": "2026-08-01T01:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/SameProject"]],
                Self.tokenLine(timestamp: "2026-08-01T01:01:00Z", input: 100, cached: 20, output: 10),
            ]
            try writeJSONLines(values, to: sessions.appending(path: "\(session).jsonl"))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let report = await CodexUsageReporter.daily(
            codexHome: codex,
            calendar: calendar,
            lookbackDays: nil
        )

        XCTAssertEqual(report.data.count, 1)
        XCTAssertEqual(report.data[0].inputTokens, 160)
        XCTAssertEqual(report.data[0].cachedInputTokens, 40)
        XCTAssertEqual(report.data[0].outputTokens, 20)
        XCTAssertEqual(report.data[0].totalTokens, 220)
    }

    func testNativeCodexDailyReportIgnoresStaleCumulativeCounterDrops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let values: [[String: Any]] = [
            ["timestamp": "2026-08-01T01:00:00Z", "type": "session_meta", "payload": ["id": "stale-counters", "cwd": "/tmp/Stale"]],
            ["timestamp": "2026-08-01T01:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Stale"]],
            Self.tokenLine(timestamp: "2026-08-01T01:01:00Z", input: 100, cached: 20, output: 10),
            Self.tokenLine(timestamp: "2026-08-01T01:02:00Z", input: 60, cached: 10, output: 5),
            Self.tokenLine(timestamp: "2026-08-01T01:03:00Z", input: 120, cached: 25, output: 12),
        ]
        try writeJSONLines(values, to: sessions.appending(path: "stale.jsonl"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let report = await CodexUsageReporter.daily(
            codexHome: codex,
            calendar: calendar,
            lookbackDays: nil
        )

        XCTAssertEqual(report.data.count, 1)
        XCTAssertEqual(report.data[0].inputTokens, 95)
        XCTAssertEqual(report.data[0].cachedInputTokens, 25)
        XCTAssertEqual(report.data[0].outputTokens, 12)
        XCTAssertEqual(report.data[0].totalTokens, 132)
    }

    func testLargeFastScanHandlesMoreThanOneArgumentBatchAndColonPaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString):large-scan", directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        for index in 0..<300 {
            let values: [[String: Any]] = [
                ["timestamp": "2026-08-01T00:00:00Z", "type": "session_meta", "payload": ["id": "large-\(index)", "cwd": "/tmp/Large"]],
                ["timestamp": "2026-08-01T00:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Large"]],
                Self.tokenLine(timestamp: "2026-08-01T00:01:00Z", input: 10, cached: 0, output: 1),
            ]
            try writeJSONLines(values, to: sessions.appending(path: "\(index).jsonl"))
        }

        let scanner = LocalUsageScanner(codexHome: codex, claudeHome: root.appending(path: ".claude"), codexLookbackDays: nil)
        let result = await scanner.scanAll()
        XCTAssertEqual(result.events.filter { $0.provider == .codex }.count, 300)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testFailedFastScanIsNotCachedAndRetriesUnchangedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let session = sessions.appending(path: "retry.jsonl")
        try writeJSONLines([
            ["timestamp": "2026-08-01T00:00:00Z", "type": "session_meta", "payload": ["id": "retry", "cwd": "/tmp/Retry"]],
            ["timestamp": "2026-08-01T00:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Retry"]],
            Self.tokenLine(timestamp: "2026-08-01T00:01:00Z", input: 10, cached: 0, output: 1),
        ], to: session)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: session.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.path) }

        let scanner = LocalUsageScanner(codexHome: codex, claudeHome: root.appending(path: ".claude"), codexLookbackDays: nil)
        let failed = await scanner.scanAll()
        XCTAssertTrue(failed.events.isEmpty)
        XCTAssertFalse(failed.warnings.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.path)
        let retried = await scanner.scanAll()
        XCTAssertEqual(retried.events.count, 1)
    }

    func testClaudeSessionEstimateIncludesEveryEventInActiveFiveHours() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            Self.usageEvent(id: "historical-a", date: now.addingTimeInterval(-10 * 3_600), project: "/Claude", provider: .claude, credits: 60),
            Self.usageEvent(id: "historical-b", date: now.addingTimeInterval(-6 * 3_600), project: "/Claude", provider: .claude, credits: 40),
            Self.usageEvent(id: "active-a", date: now.addingTimeInterval(-4 * 3_600), project: "/Claude", provider: .claude, credits: 90),
            Self.usageEvent(id: "active-b", date: now, project: "/Claude", provider: .claude, credits: 10),
        ]

        let limits = EstimatedLimitBuilder.claudeLimits(events: events, resets: [], now: now)
        let session = try XCTUnwrap(limits.first?.windows.first { $0.durationMinutes == 300 })
        XCTAssertEqual(session.usedPercent, 100, accuracy: 0.0001)
        XCTAssertEqual(session.resetsAt, now.addingTimeInterval(3_600))
    }

    func testClaudeEstimateIsUnavailableWithoutHistoricalBaseline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            Self.usageEvent(id: "only", date: now, project: "/Claude", provider: .claude, credits: 1),
        ]
        XCTAssertTrue(EstimatedLimitBuilder.claudeLimits(events: events, resets: [], now: now).isEmpty)
    }

    func testClaudeExactUsageParserHandlesOfficialRateLimitPayload() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "rate_limits": [
                "five_hour": [
                    "used_percentage": 23.5,
                    "resets_at": 1_800_018_000,
                ],
                "seven_day": [
                    "utilization": 41,
                    "resets_at": "2027-01-15T12:00:00Z",
                ],
            ],
        ])

        let snapshot = try XCTUnwrap(
            ClaudeUsageSnapshotParser.parse(
                data: data,
                source: .oauthLive,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        XCTAssertEqual(snapshot.source, .oauthLive)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 23.5)
        XCTAssertEqual(snapshot.fiveHour?.durationMinutes, 300)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_800_018_000))
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 41)
        XCTAssertEqual(snapshot.sevenDay?.durationMinutes, 10_080)
        XCTAssertEqual(snapshot.limitBucket.confidence, .exact)
    }

    func testClaudeOAuthUsageRequestHasBoundedTimeout() {
        let request = ClaudeUsageReader.oauthUsageRequest(token: "test-token")

        XCTAssertEqual(request.timeoutInterval, ClaudeUsageReader.oauthRequestTimeout)
        XCTAssertLessThan(request.timeoutInterval, 60)
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testClaudeUsageReaderUsesFreshDesktopPlanUsageHistoryAsExactFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let claudeDirectory = applicationSupport.appending(path: "Claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "samples": [
                ["org": "account", "t": Int((now.addingTimeInterval(-120)).timeIntervalSince1970 * 1_000), "u": ["fh": 23, "sd": 27]],
            ],
        ])
        try data.write(to: claudeDirectory.appending(path: "plan-usage-history.json"))

        let reader = ClaudeUsageReader(
            homeDirectory: root.appending(path: "Home", directoryHint: .isDirectory),
            applicationSupportDirectory: applicationSupport,
            now: { now }
        )
        let result = await reader.read()
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.source, .claudeDesktopHistory)
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 23)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 27)
        XCTAssertEqual(snapshot.limitBucket.windows.map(\.confidence), [.exact, .exact])
    }

    func testClaudeUsageReaderKeepsStaleDesktopPlanUsageHistoryAsExactCachedData() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let claudeDirectory = applicationSupport.appending(path: "Claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "samples": [
                ["org": "account", "t": Int((now.addingTimeInterval(-16 * 60)).timeIntervalSince1970 * 1_000), "u": ["fh": 23, "sd": 27]],
            ],
        ])
        try data.write(to: claudeDirectory.appending(path: "plan-usage-history.json"))

        let reader = ClaudeUsageReader(
            homeDirectory: root.appending(path: "Home", directoryHint: .isDirectory),
            applicationSupportDirectory: applicationSupport,
            now: { now }
        )
        let snapshot = await reader.read()
        let result = try XCTUnwrap(snapshot)
        XCTAssertEqual(result.source, .claudeDesktopHistory)
        XCTAssertEqual(result.fiveHour?.usedPercent, 23)
        XCTAssertEqual(result.sevenDay?.usedPercent, 27)
    }

    func testOldSessionWithRecentModificationStillContributesRecentEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions/2025/01/01")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        try writeJSONLines([
            ["timestamp": timestamp, "type": "session_meta", "payload": ["id": "resumed-old", "cwd": "/tmp/Old"]],
            ["timestamp": timestamp, "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Old"]],
            Self.tokenLine(timestamp: timestamp, input: 10, cached: 0, output: 1),
        ], to: sessions.appending(path: "rollout-2025-01-01T00-00-00-resumed.jsonl"))

        let report = await CodexUsageReporter.daily(codexHome: codex, lookbackDays: 35)
        XCTAssertEqual(report.data.count, 1)
    }

    func testPreciseEventTimestampKeepsHalfHourTimezoneCalendarDay() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try writeJSONLines([
            ["timestamp": "2026-08-03T18:45:00Z", "type": "session_meta", "payload": ["id": "india-midnight", "cwd": "/tmp/India"]],
            ["timestamp": "2026-08-03T18:45:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/India"]],
            Self.tokenLine(timestamp: "2026-08-03T18:45:02Z", input: 10, cached: 0, output: 1),
        ], to: sessions.appending(path: "india.jsonl"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let report = await CodexUsageReporter.daily(codexHome: codex, calendar: calendar, lookbackDays: nil)
        XCTAssertEqual(report.data.map(\.date), ["2026-08-04"])
    }

    func testRecordedCodexTierAppliesOnlyAfterSettingsEventAndSurvivesCache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codex = root.appending(path: ".codex")
        let sessions = codex.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try writeJSONLines([
            ["timestamp": "2026-08-01T00:00:00Z", "type": "session_meta", "payload": ["id": "tiers", "cwd": "/tmp/Tiers"]],
            ["timestamp": "2026-08-01T00:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5.6-sol", "cwd": "/tmp/Tiers"]],
            Self.tokenLine(timestamp: "2026-08-01T00:01:00Z", input: 100, cached: 20, output: 10),
            [
                "timestamp": "2026-08-01T00:01:30Z",
                "type": "event_msg",
                "payload": [
                    "type": "thread_settings_applied",
                    "thread_settings": ["service_tier": "priority"],
                ],
            ],
            Self.tokenLine(timestamp: "2026-08-01T00:02:00Z", input: 200, cached: 40, output: 20),
        ], to: sessions.appending(path: "tiers.jsonl"))

        let scanner = LocalUsageScanner(codexHome: codex, claudeHome: root.appending(path: ".claude"), codexLookbackDays: nil)
        let first = await scanner.scanAll().events.filter { $0.provider == .codex }
        let cached = await scanner.scanAll().events.filter { $0.provider == .codex }
        XCTAssertEqual(first.map(\.serviceTier), [nil, "priority"])
        XCTAssertEqual(first[1].apiEquivalentUSD, first[0].apiEquivalentUSD * 2, accuracy: 0.000_001)
        XCTAssertEqual(cached, first)
    }

    func testVisibleResetDeduplicationKeepsMultipleSessionBoundaries() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let estimated = Self.resetEvent(id: "estimated", date: base, confidence: .estimated)
        let exactDuplicate = Self.resetEvent(id: "exact", date: base.addingTimeInterval(30), confidence: .exact)
        let later = Self.resetEvent(id: "later", date: base.addingTimeInterval(5 * 3_600), confidence: .estimated)
        let result = UsageApplicationModel.deduplicateVisibleResets(
            [estimated, exactDuplicate, later],
            kind: .session
        )
        XCTAssertEqual(result.map(\.id), ["exact", "later"])
    }

    func testWeeklyMarkersFilterToTheVisibleShortRange() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let period = UsagePeriod(start: start, end: start.addingTimeInterval(5 * 3_600))
        let weeklyInside = Self.resetEvent(
            id: "weekly-inside",
            date: start.addingTimeInterval(4 * 3_600),
            confidence: .exact,
            kind: .weekly
        )
        let weeklyOutside = Self.resetEvent(
            id: "weekly-outside",
            date: start.addingTimeInterval(6 * 3_600),
            confidence: .estimated,
            kind: .weekly
        )
        let sessionInside = Self.resetEvent(
            id: "session-inside",
            date: start.addingTimeInterval(2 * 3_600),
            confidence: .exact,
            kind: .session,
            bucketID: "codex_bengalfox"
        )

        let result = UsageApplicationModel.observedResetMarkers(
            from: [weeklyInside, weeklyOutside, sessionInside],
            provider: .codex,
            kind: .weekly,
            period: period,
            now: period.end
        )

        XCTAssertEqual(result.map(\.id), ["weekly-inside"])
    }

    func testWeeklyBackfillUsesOneSeamPerWeekWhenMultipleBucketsHaveDifferentResetTimes() async {
        let week = TimeInterval(7 * 24 * 3_600)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let primaryReset = now.addingTimeInterval(24 * 3_600)
        let secondaryReset = primaryReset.addingTimeInterval(2 * 24 * 3_600)
        let buckets = [
            Self.limitBucket(id: "codex", resetAt: primaryReset),
            Self.limitBucket(id: "spark", resetAt: secondaryReset),
        ]

        let store = LimitSnapshotStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appending(path: "limit-snapshots.json")
        )
        let result = await store.seedWeeklyBackfill(
            from: buckets,
            observedResets: [],
            at: now,
            cutoff: now.addingTimeInterval(-4 * week),
        )

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(Set(result.map(\.bucketID)), ["codex"])
    }

    func testWeeklyBackfillDatesStayFrozenWhenFutureResetSchedulesChange() async {
        let week = TimeInterval(7 * 24 * 3_600)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "limit-snapshots.json")
        let store = LimitSnapshotStore(fileURL: fileURL)
        let first = await store.seedWeeklyBackfill(
            from: [Self.limitBucket(id: "codex", resetAt: now.addingTimeInterval(24 * 3_600))],
            observedResets: [],
            at: now,
            cutoff: now.addingTimeInterval(-4 * week)
        )
        let second = await store.seedWeeklyBackfill(
            from: [
                Self.limitBucket(id: "codex", resetAt: now.addingTimeInterval(3 * 24 * 3_600)),
                Self.limitBucket(id: "spark", resetAt: now.addingTimeInterval(5 * 24 * 3_600)),
            ],
            observedResets: [],
            at: now,
            cutoff: now.addingTimeInterval(-4 * week)
        )

        XCTAssertEqual(second.map(\.date), first.map(\.date))
        XCTAssertEqual(second.map(\.id), first.map(\.id))
    }

    func testWeeklyScheduleAddsOneElapsedSeamAfterInactivity() async {
        let week = TimeInterval(7 * 24 * 3_600)
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        let observedAt = anchor.addingTimeInterval(week * 1.5)
        let store = LimitSnapshotStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appending(path: "limit-snapshots.json")
        )
        let exactAnchor = Self.resetEvent(
            id: "exact-anchor",
            date: anchor,
            confidence: .exact,
            kind: .weekly
        )

        let result = await store.seedWeeklyBackfill(
            from: [Self.limitBucket(id: "codex", resetAt: observedAt.addingTimeInterval(3 * 24 * 3_600))],
            observedResets: [exactAnchor],
            at: observedAt,
            cutoff: anchor.addingTimeInterval(-4 * week)
        )

        let scheduled = result.filter { $0.id.hasPrefix("schedule:") }
        XCTAssertEqual(scheduled.map(\.date), [anchor.addingTimeInterval(week)])
        XCTAssertEqual(scheduled.first?.label, "Weekly reset (estimated schedule)")
        XCTAssertEqual(scheduled.first?.bucketID, "codex")
        XCTAssertFalse(result.contains { $0.date == anchor.addingTimeInterval(2 * week) })
    }

    func testWeeklyScheduleIsIdempotentAndExtendsFromLatestScheduledSeam() async {
        let week = TimeInterval(7 * 24 * 3_600)
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        let firstObservation = anchor.addingTimeInterval(week * 1.5)
        let secondObservation = anchor.addingTimeInterval(week * 2.5)
        let store = LimitSnapshotStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appending(path: "limit-snapshots.json")
        )
        let exactAnchor = Self.resetEvent(
            id: "exact-anchor",
            date: anchor,
            confidence: .exact,
            kind: .weekly
        )
        let buckets = [Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(3 * 24 * 3_600))]

        let first = await store.seedWeeklyBackfill(
            from: buckets,
            observedResets: [exactAnchor],
            at: firstObservation,
            cutoff: anchor.addingTimeInterval(-4 * week)
        )
        let repeated = await store.seedWeeklyBackfill(
            from: buckets,
            observedResets: [exactAnchor],
            at: firstObservation,
            cutoff: anchor.addingTimeInterval(-4 * week)
        )
        let extended = await store.seedWeeklyBackfill(
            from: buckets,
            observedResets: [exactAnchor],
            at: secondObservation,
            cutoff: anchor.addingTimeInterval(-4 * week)
        )

        XCTAssertEqual(first.filter { $0.id.hasPrefix("schedule:") }.map(\.id), repeated.filter { $0.id.hasPrefix("schedule:") }.map(\.id))
        XCTAssertEqual(
            extended.filter { $0.id.hasPrefix("schedule:") }.map(\.date),
            [anchor.addingTimeInterval(week), anchor.addingTimeInterval(2 * week)]
        )
    }

    func testWeeklyScheduleSkipsAnyExistingWeeklyLineAtCandidateDate() async {
        let week = TimeInterval(7 * 24 * 3_600)
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        let observedAt = anchor.addingTimeInterval(week * 1.5)
        let store = LimitSnapshotStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appending(path: "limit-snapshots.json")
        )
        let primary = Self.resetEvent(id: "primary-anchor", date: anchor, confidence: .exact, kind: .weekly)
        let spark = Self.resetEvent(
            id: "spark-at-candidate",
            date: anchor.addingTimeInterval(week + 90),
            confidence: .exact,
            kind: .weekly,
            bucketID: "spark"
        )

        let result = await store.seedWeeklyBackfill(
            from: [Self.limitBucket(id: "codex", resetAt: observedAt.addingTimeInterval(3 * 24 * 3_600))],
            observedResets: [primary, spark],
            at: observedAt,
            cutoff: anchor.addingTimeInterval(-4 * week)
        )

        XCTAssertFalse(result.contains { $0.id.hasPrefix("schedule:") })
    }

    func testExactWeeklyObservationReplacesMatchingScheduledEstimateOnly() async {
        let week = TimeInterval(7 * 24 * 3_600)
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduledDate = anchor.addingTimeInterval(week)
        let store = LimitSnapshotStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appending(path: "limit-snapshots.json")
        )
        let primary = Self.resetEvent(id: "primary-anchor", date: anchor, confidence: .exact, kind: .weekly)
        let buckets = [Self.limitBucket(id: "codex", resetAt: scheduledDate.addingTimeInterval(3 * 24 * 3_600))]

        let scheduled = await store.seedWeeklyBackfill(
            from: buckets,
            observedResets: [primary],
            at: scheduledDate,
            cutoff: anchor.addingTimeInterval(-4 * week)
        )
        XCTAssertTrue(scheduled.contains { $0.id.hasPrefix("schedule:") })

        let exact = Self.resetEvent(
            id: "observed-weekly-reset",
            date: scheduledDate.addingTimeInterval(90),
            confidence: .exact,
            kind: .weekly
        )
        let corrected = await store.seedWeeklyBackfill(
            from: buckets,
            observedResets: [primary, exact],
            at: scheduledDate.addingTimeInterval(90),
            cutoff: anchor.addingTimeInterval(-4 * week)
        )

        XCTAssertFalse(corrected.contains { $0.id.hasPrefix("schedule:") })
        XCTAssertTrue(corrected.contains { $0.id.hasPrefix("backfill:") })
    }

    func testObservedSparkWeeklyResetIsPersistedWithoutReanchoringPrimaryHistory() async {
        let week = TimeInterval(7 * 24 * 3_600)
        let firstObservation = Date(timeIntervalSince1970: 1_800_000_000)
        let secondObservation = firstObservation.addingTimeInterval(4 * 3_600)
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "limit-snapshots.json")
        let cutoff = firstObservation.addingTimeInterval(-4 * week)
        let bucketsBeforeReset = [
            Self.limitBucket(id: "codex", resetAt: firstObservation.addingTimeInterval(2 * 24 * 3_600), usedPercent: 48),
            Self.limitBucket(id: "spark", resetAt: firstObservation.addingTimeInterval(2 * 24 * 3_600), usedPercent: 71),
        ]
        let store = LimitSnapshotStore(fileURL: fileURL)
        let initial = await store.seedWeeklyBackfill(
            from: bucketsBeforeReset,
            observedResets: [],
            at: firstObservation,
            cutoff: cutoff
        )
        let initialEstimatedDates = initial.filter { $0.confidence == .estimated }.map(\.date)

        _ = await store.observe(bucketsBeforeReset, at: firstObservation)
        let detected = await store.observe(
            [
                Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(2 * 24 * 3_600), usedPercent: 50),
                Self.limitBucket(id: "spark", resetAt: secondObservation.addingTimeInterval(2 * 24 * 3_600), usedPercent: 12),
            ],
            at: secondObservation
        )

        let sparkReset = try! XCTUnwrap(detected.first { $0.bucketID == "spark" && $0.confidence == .exact })
        XCTAssertTrue(sparkReset.isSparkModelReset)
        XCTAssertFalse(Self.resetEvent(id: "primary", date: firstObservation, confidence: .exact).isSparkModelReset)

        let result = await store.seedWeeklyBackfill(
            from: [
                Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(2 * 24 * 3_600)),
                Self.limitBucket(id: "spark", resetAt: secondObservation.addingTimeInterval(2 * 24 * 3_600)),
            ],
            observedResets: detected,
            at: secondObservation,
            cutoff: cutoff
        )
        XCTAssertTrue(result.contains(where: { $0.id == sparkReset.id }))
        XCTAssertEqual(result.filter { $0.confidence == .estimated }.map(\.date), initialEstimatedDates)
        XCTAssertEqual(result.filter { $0.confidence == .estimated }.map(\.bucketID), Array(repeating: "codex", count: initialEstimatedDates.count))
    }

    func testWeeklyRemainingIncreaseAcrossStoreRecreationAnchorsAndFreezesBackfill() async {
        let week = TimeInterval(7 * 24 * 3_600)
        let firstObservation = Date(timeIntervalSince1970: 1_800_000_000)
        let secondObservation = firstObservation.addingTimeInterval(4 * 3_600)
        let expectedReset = firstObservation.addingTimeInterval(2 * 3_600)
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "limit-snapshots.json")
        let cutoff = firstObservation.addingTimeInterval(-4 * week)

        let firstRun = LimitSnapshotStore(fileURL: fileURL)
        _ = await firstRun.observe(
            [Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(5 * 24 * 3_600), usedPercent: 82)],
            at: firstObservation
        )
        _ = await firstRun.seedWeeklyBackfill(
            from: [Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(5 * 24 * 3_600))],
            observedResets: [],
            at: firstObservation,
            cutoff: cutoff
        )

        // Recreating the actor models a later app launch reading the same
        // Application Support file.
        let secondRun = LimitSnapshotStore(fileURL: fileURL)
        let detected = await secondRun.observe(
            [Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(12 * 24 * 3_600), usedPercent: 21)],
            at: secondObservation
        )
        let actual = try! XCTUnwrap(detected.first { $0.confidence == .exact && $0.kind == .weekly })
        XCTAssertEqual(actual.date, expectedReset)
        XCTAssertEqual(actual.label, "codex weekly reset")

        let reanchored = await secondRun.seedWeeklyBackfill(
            from: [Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(12 * 24 * 3_600))],
            observedResets: detected,
            at: secondObservation,
            cutoff: cutoff
        )
        let expectedDates = [1, 2, 3, 4].map { expectedReset.addingTimeInterval(-Double($0) * week) }
        XCTAssertEqual(
            reanchored.filter { $0.confidence == .estimated && $0.kind == .weekly }.map(\.date),
            expectedDates.reversed()
        )

        // A later exact seam cannot rewrite the persisted first-anchor history.
        let thirdRun = LimitSnapshotStore(fileURL: fileURL)
        let frozen = await thirdRun.seedWeeklyBackfill(
            from: [Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(15 * 24 * 3_600))],
            observedResets: [
                Self.resetEvent(
                    id: "later-exact",
                    date: secondObservation.addingTimeInterval(7 * 24 * 3_600),
                    confidence: .exact,
                    kind: .weekly
                ),
            ],
            at: secondObservation.addingTimeInterval(7 * 24 * 3_600),
            cutoff: cutoff
        )
        XCTAssertEqual(
            frozen.filter { $0.confidence == .estimated && $0.kind == .weekly }.map(\.date),
            expectedDates.reversed()
        )
    }

    func testLimitSnapshotStoreImportsLegacySnapshotWhenNewFileIsAbsent() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let legacyURL = root.appending(path: "AI Usage Bar/limit-snapshots.json")
        let newURL = root.appending(path: "QuotaWise/limit-snapshots.json")
        let firstObservation = Date(timeIntervalSince1970: 1_800_000_000)
        let secondObservation = firstObservation.addingTimeInterval(4 * 3_600)

        let legacyStore = LimitSnapshotStore(fileURL: legacyURL)
        _ = await legacyStore.observe(
            [Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(3 * 24 * 3_600), usedPercent: 78)],
            at: firstObservation
        )

        let migratedStore = LimitSnapshotStore(fileURL: newURL, legacyFileURL: legacyURL)
        let resets = await migratedStore.observe(
            [Self.limitBucket(id: "codex", resetAt: secondObservation.addingTimeInterval(10 * 24 * 3_600), usedPercent: 18)],
            at: secondObservation
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(resets.count, 1, "The imported snapshot must retain the prior usage baseline.")
        XCTAssertEqual(resets.first?.provider, .codex)
    }

    func testWeeklySeamsKeepDistinctExactResetsWithoutRepeatingThemIntoBackfill() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let backfill = Self.resetEvent(
            id: "backfill",
            date: base.addingTimeInterval(-7 * 24 * 3_600),
            confidence: .estimated,
            kind: .weekly
        )
        let firstExact = Self.resetEvent(
            id: "first-exact",
            date: base,
            confidence: .exact,
            kind: .weekly
        )
        let secondExact = Self.resetEvent(
            id: "second-exact",
            date: base.addingTimeInterval(2 * 3_600),
            confidence: .exact,
            kind: .weekly,
            bucketID: "spark"
        )

        let result = UsageApplicationModel.deduplicateVisibleResets(
            [backfill, firstExact, secondExact],
            kind: .weekly
        )

        XCTAssertEqual(result.map(\.id), ["backfill", "first-exact", "second-exact"])
    }

    func testResetSeamsGroupNearSimultaneousPrimaryAndSparkResets() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = Self.resetEvent(
            id: "codex-weekly",
            date: base,
            confidence: .exact,
            kind: .weekly
        )
        let spark = Self.resetEvent(
            id: "spark-weekly",
            date: base.addingTimeInterval(90),
            confidence: .exact,
            kind: .weekly,
            bucketID: "codex_bengalfox"
        )

        let seams = ResetSeam.group([spark, primary])

        XCTAssertEqual(seams.count, 1)
        XCTAssertEqual(seams[0].date, primary.date)
        XCTAssertTrue(seams[0].containsPrimaryReset)
        XCTAssertEqual(seams[0].events.map(\.id), ["codex-weekly", "spark-weekly"])
    }

    func testResetSeamsKeepStandalonePrimaryAndSparkMarkersSeparate() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = Self.resetEvent(
            id: "codex-weekly",
            date: base,
            confidence: .exact,
            kind: .weekly
        )
        let spark = Self.resetEvent(
            id: "spark-weekly",
            date: base.addingTimeInterval(121),
            confidence: .exact,
            kind: .weekly,
            bucketID: "codex_bengalfox"
        )

        let seams = ResetSeam.group([primary, spark])

        XCTAssertEqual(seams.count, 2)
        XCTAssertTrue(seams[0].containsPrimaryReset)
        XCTAssertFalse(seams[1].containsPrimaryReset)
        XCTAssertEqual(seams[0].events.map(\.id), ["codex-weekly"])
        XCTAssertEqual(seams[1].events.map(\.id), ["spark-weekly"])
    }

    @MainActor
    func testWeeklySeamChartRendersFrozenBackfillForQA() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["AI_USAGE_QA_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:)) else { return }

        let start = Date(timeIntervalSince1970: 1_799_000_000)
        let points = (0..<30).map { day in
            let credits = [8.0, 13, 7, 6, 28, 11, 5, 9, 15, 7][day % 10]
            return UsageChartPoint(
                date: start.addingTimeInterval(Double(day) * 86_400),
                credits: credits,
                apiEquivalentUSD: credits / 100,
                tokens: Int64(credits * 1_000)
            )
        }
        let primaryResets = [3, 10, 17].enumerated().map { index, day in
            Self.resetEvent(
                id: "backfill-\(index)",
                date: start.addingTimeInterval(Double(day) * 86_400),
                confidence: .estimated,
                kind: .weekly
            )
        }
        let scheduledReset = ResetEvent(
            id: "schedule:codex:weekly-fixture",
            provider: .codex,
            date: start.addingTimeInterval(24 * 86_400),
            detectedAt: start.addingTimeInterval(29 * 86_400),
            kind: .weekly,
            bucketID: "codex",
            label: "Weekly reset (estimated schedule)",
            confidence: .estimated
        )
        let sparkReset = ResetEvent(
            id: "spark-observed",
            provider: .codex,
            date: start.addingTimeInterval(27 * 86_400),
            detectedAt: start.addingTimeInterval(27 * 86_400),
            kind: .weekly,
            bucketID: "spark",
            label: "Spark weekly reset",
            confidence: .exact
        )
        let sharedPrimaryReset = Self.resetEvent(
            id: "primary-observed",
            date: sparkReset.date,
            confidence: .exact,
            kind: .weekly
        )
        let resets = primaryResets + [scheduledReset, sharedPrimaryReset, sparkReset]
        let card = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("30-DAY CREDIT FLOW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(UsagePalette.secondaryText)
                    Text("1.6M credits")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(UsagePalette.porcelain)
                }
                Spacer()
                Label("~3 historical seams · 1 scheduled · shared Codex + Spark reset", systemImage: "line.3.horizontal.decrease")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(UsagePalette.mineralTeal)
            }
            UsageAreaChart(points: points, resets: resets, provider: .codex, compact: true)
                .frame(height: 108)
        }
        .padding(14)
        .frame(width: 364)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(UsagePalette.slateGlass)
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(UsagePalette.hairline))
        )
        .padding(14)
        .background(UsagePalette.nightInk)
        .environment(\.colorScheme, .dark)

        try Self.writeRenderedPNG(card, named: "weekly-seam-scheduled-overview@4x.png", to: outputDirectory)

        let hoverCard = UsageAreaChart(
            points: points,
            resets: resets,
            provider: .codex,
            compact: false,
            initialHoveredReset: scheduledReset
        )
        .frame(width: 620, height: 300)
        .padding(20)
        .background(UsagePalette.nightInk)
        .environment(\.colorScheme, .dark)
        try Self.writeRenderedPNG(hoverCard, named: "weekly-seam-scheduled-hover@4x.png", to: outputDirectory)

        for (name, point, width, height) in [
            ("left-edge", points[0], 620.0, 300.0),
            ("center", points[12], 620.0, 300.0),
            ("right-edge", points[points.count - 1], 620.0, 300.0),
            ("near-top", points[4], 620.0, 300.0),
            ("top-clearance", points[4], 620.0, 160.0),
            ("mobile-left-edge", points[0], 350.0, 280.0),
            ("mobile-right-edge", points[points.count - 1], 350.0, 280.0),
        ] {
            let pointHoverCard = UsageAreaChart(
                points: points,
                resets: resets,
                provider: .codex,
                compact: false,
                initialHoveredDate: point.date
            )
            .frame(width: width, height: height)
            .padding(20)
            .background(UsagePalette.nightInk)
            .environment(\.colorScheme, .dark)
            let renderedCard = name.hasPrefix("mobile-")
                ? AnyView(pointHoverCard.frame(width: 390, height: 844, alignment: .top))
                : AnyView(pointHoverCard)
            try Self.writeRenderedPNG(renderedCard, named: "credit-flow-point-hover-\(name)@4x.png", to: outputDirectory)
        }

        let edgeChart = UsageAreaChart(
            points: points,
            resets: resets,
            provider: .codex,
            compact: false,
            initialHoveredDate: points[0].date
        )
        .frame(width: 620, height: 300)
        .padding(20)

        let studioContext = HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(UsagePalette.slateGlass)
                .frame(width: 240, height: 340)
            edgeChart
        }
        .padding(20)
        .background(UsagePalette.nightInk)
        .environment(\.colorScheme, .dark)
        try Self.writeRenderedPNG(studioContext, named: "credit-flow-point-hover-left-edge-studio-context@4x.png", to: outputDirectory)
    }

    func testHistoryResetDeduplicationDoesNotCollapseSameDaySessions() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let resets = [
            Self.resetEvent(id: "one", date: base, confidence: .exact),
            Self.resetEvent(id: "duplicate", date: base.addingTimeInterval(30), confidence: .exact),
            Self.resetEvent(id: "two", date: base.addingTimeInterval(5 * 3_600), confidence: .exact),
        ]
        XCTAssertEqual(LocalUsageScanner.deduplicateResets(resets, tolerance: 120).map(\.id), ["one", "two"])
    }

    func testRefreshWorkUsesOneMinuteLimitsAndFifteenMinuteHistoryCadence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            UsageApplicationModel.refreshWork(
                lastUpdated: now.addingTimeInterval(-59),
                lastHistoryUpdated: now.addingTimeInterval(-901),
                now: now
            ),
            .none
        )
        XCTAssertEqual(
            UsageApplicationModel.refreshWork(
                lastUpdated: now.addingTimeInterval(-60),
                lastHistoryUpdated: now.addingTimeInterval(-899),
                now: now
            ),
            .limitsOnly
        )
        XCTAssertEqual(
            UsageApplicationModel.refreshWork(
                lastUpdated: now.addingTimeInterval(-60),
                lastHistoryUpdated: now.addingTimeInterval(-900),
                now: now
            ),
            .limitsAndHistory
        )
    }

    func testRefreshWorkBypassesCooldownWhenNoLimitDataIsAvailableYet() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Within the normal 60s cooldown, but with no live limit data for either provider yet —
        // e.g. the previous attempt failed or a fresh popover open before the first fetch landed —
        // a retry should still be attempted rather than sitting on "unavailable" for a full minute.
        XCTAssertEqual(
            UsageApplicationModel.refreshWork(
                lastUpdated: now.addingTimeInterval(-1),
                lastHistoryUpdated: now.addingTimeInterval(-901),
                now: now,
                hasAnyLimitData: false
            ),
            .limitsAndHistory
        )
        // The same recency, but with limit data already present, still honors the cooldown.
        XCTAssertEqual(
            UsageApplicationModel.refreshWork(
                lastUpdated: now.addingTimeInterval(-1),
                lastHistoryUpdated: now.addingTimeInterval(-901),
                now: now,
                hasAnyLimitData: true
            ),
            .none
        )
    }

    func testAppServerClientDrainsLargeStderrAndCompletesProtocol() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fake-codex")
        let script = """
        #!/bin/zsh -f
        /usr/bin/yes x | /usr/bin/head -c 262144 >&2
        IFS= read -r initialize
        print -r -- '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r limits
        print -r -- '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1800000000}}}}}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let buckets = try await CodexAppServerClient(executableURL: executable).fetchLimits()
        XCTAssertEqual(buckets.first?.id, "codex")
        XCTAssertEqual(buckets.first?.windows.first?.usedPercent, 12)
    }

    func testAppServerTerminationEscalatesForIgnoredTerminateSignal() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
        ]
        try process.run()
        defer {
            if process.isRunning {
                _ = CodexAppServerClient.terminate(process, gracePeriod: 0, killPeriod: 0.5)
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
        let started = Date()
        XCTAssertTrue(CodexAppServerClient.terminate(process, gracePeriod: 0.1, killPeriod: 0.5))
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testWeeklyUsageLimitsPersistIndependentlyAndDeleteIndependently() throws {
        let suiteName = "QuotaWiseKitTests.weekly-limits.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WeeklyUsageLimitStore(defaults: defaults, key: "limits")
        let codex = WeeklyUsageLimit(provider: .codex, remainingPercent: 20, severity: .pauseThreads)
        let claude = WeeklyUsageLimit(provider: .claude, remainingPercent: 12, severity: .persistentNotification)

        store.save(codex)
        store.save(claude)
        XCTAssertEqual(store.limits(for: .codex), [codex])
        XCTAssertEqual(store.limits(for: .claude), [claude])

        store.delete(id: codex.id, for: .codex)
        XCTAssertEqual(store.limits(for: .codex), [])
        XCTAssertEqual(store.limits(for: .claude), [claude])
    }

    func testWeeklyUsageLimitsSupportMultipleThresholdsPerProvider() throws {
        let suiteName = "QuotaWiseKitTests.weekly-limits-multi.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WeeklyUsageLimitStore(defaults: defaults, key: "limits")
        let higher = WeeklyUsageLimit(provider: .codex, remainingPercent: 50, severity: .notification)
        let lower = WeeklyUsageLimit(provider: .codex, remainingPercent: 10, severity: .pauseThreads)

        store.save(higher)
        store.save(lower)
        XCTAssertEqual(Set(store.limits(for: .codex).map(\.id)), [higher.id, lower.id])

        store.delete(id: higher.id, for: .codex)
        XCTAssertEqual(store.limits(for: .codex), [lower])
    }

    func testWeeklyUsageLimitDisplayOrderIsHighestPercentFirstThenMildestSeverity() {
        let seventyFivePause = WeeklyUsageLimit(provider: .codex, remainingPercent: 75, severity: .pauseThreads)
        let fiftyNotify = WeeklyUsageLimit(provider: .codex, remainingPercent: 50, severity: .notification)
        let fiftyPause = WeeklyUsageLimit(provider: .codex, remainingPercent: 50, severity: .pauseThreads)
        let fiftyQuit = WeeklyUsageLimit(provider: .codex, remainingPercent: 50, severity: .quitProvider)
        let twentyFiveNotify = WeeklyUsageLimit(provider: .codex, remainingPercent: 25, severity: .notification)

        let shuffled = [fiftyQuit, twentyFiveNotify, seventyFivePause, fiftyNotify, fiftyPause]
        let ordered = shuffled.sorted(by: WeeklyUsageLimit.displayOrder)

        XCTAssertEqual(ordered, [seventyFivePause, fiftyNotify, fiftyPause, fiftyQuit, twentyFiveNotify])
    }

    func testPauseResumeTracksOnlyExactActiveTasksAndSurvivesStoreReload() throws {
        let discovery = TestProcessDiscovery(processIDs: [7_001, 7_002, 7_003])
        let inspector = TestProcessInspector(identities: [
            7_001: "started-a",
            7_002: "started-b",
        ])
        let signals = TestSignalRecorder(discovery: discovery, performSystemSignal: false)
        let controller = ProviderProcessController(
            discovery: discovery,
            inspector: inspector,
            signal: { processID, signal in signals.record(processID: processID, signal: signal) },
            wait: { _ in }
        )

        let paused = controller.pauseThreads(for: .codex)
        XCTAssertEqual(paused.failedProcessIDs, [])
        XCTAssertEqual(paused.pausedTasks, [
            PausedProviderTask(processID: 7_001, startIdentity: "started-a"),
            PausedProviderTask(processID: 7_002, startIdentity: "started-b"),
        ])
        XCTAssertEqual(signals.values.map(\.signal), [SIGSTOP, SIGSTOP])
        XCTAssertEqual(signals.values.map(\.processID), [7_001, 7_002])

        let suiteName = "QuotaWiseKitTests.paused-provider-tasks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "paused-tasks"
        PausedProviderTaskStore(defaults: defaults, key: key).set(paused.pausedTasks, for: .codex)
        let reloadedTasks = PausedProviderTaskStore(defaults: defaults, key: key).all()[.codex]
        XCTAssertEqual(reloadedTasks, paused.pausedTasks)

        inspector.setIdentity("new-process-using-old-pid", for: 7_002)
        let resumed = controller.resumeThreads(try XCTUnwrap(reloadedTasks))
        XCTAssertEqual(resumed.resumedTasks, [PausedProviderTask(processID: 7_001, startIdentity: "started-a")])
        XCTAssertEqual(resumed.staleTasks, [PausedProviderTask(processID: 7_002, startIdentity: "started-b")])
        XCTAssertEqual(resumed.failedTasks, [])
        XCTAssertEqual(signals.values.last?.signal, SIGCONT)
        XCTAssertEqual(signals.values.last?.processID, 7_001)
    }

    func testWeeklyUsageLimitTriggerFiresOnceUntilItRearmsAboveThreshold() {
        let limit = WeeklyUsageLimit(provider: .codex, remainingPercent: 20, severity: .notification)
        var record = WeeklyUsageLimitRecord(limit: limit, hasFired: false)

        XCTAssertEqual(
            WeeklyUsageLimitEvaluator.decision(record: record, remainingPercent: 20.1),
            .none
        )
        XCTAssertEqual(
            WeeklyUsageLimitEvaluator.decision(record: record, remainingPercent: 20),
            .trigger
        )

        record.hasFired = true
        XCTAssertEqual(
            WeeklyUsageLimitEvaluator.decision(record: record, remainingPercent: 8),
            .none
        )
        XCTAssertEqual(
            WeeklyUsageLimitEvaluator.decision(record: record, remainingPercent: 99),
            .rearm
        )

        record.hasFired = false
        XCTAssertEqual(
            WeeklyUsageLimitEvaluator.decision(record: record, remainingPercent: 8),
            .trigger
        )
    }

    func testEveryWeeklyLimitSeverityDispatchesItsExpectedAction() async {
        let discovery = TestProcessDiscovery(processIDs: [8_765])
        let inspector = TestProcessInspector(identities: [8_765: "test-thread"])
        let signals = TestSignalRecorder(discovery: discovery, performSystemSignal: false)
        let notifier = TestUsageLimitNotifier()
        let controller = ProviderProcessController(
            discovery: discovery,
            inspector: inspector,
            signal: { processID, signal in signals.record(processID: processID, signal: signal) },
            wait: { _ in }
        )
        let handler = SystemUsageLimitActionHandler(processes: controller, notifier: notifier)

        await handler.prepareNotifications()
        _ = await handler.perform(
            limit: WeeklyUsageLimit(provider: .codex, remainingPercent: 20, severity: .notification),
            remainingPercent: 19.6
        )
        _ = await handler.perform(
            limit: WeeklyUsageLimit(provider: .codex, remainingPercent: 20, severity: .persistentNotification),
            remainingPercent: 19.6
        )
        _ = await handler.perform(
            limit: WeeklyUsageLimit(provider: .codex, remainingPercent: 20, severity: .pauseThreads),
            remainingPercent: 19.6
        )
        _ = await handler.perform(
            limit: WeeklyUsageLimit(provider: .codex, remainingPercent: 20, severity: .quitProvider),
            remainingPercent: 19.6
        )

        let notifications = await notifier.events
        let preparedCount = await notifier.preparedCount
        XCTAssertEqual(preparedCount, 1)
        XCTAssertEqual(notifications.count, 4)
        XCTAssertFalse(notifications[0].persistent)
        XCTAssertTrue(notifications[1].persistent)
        XCTAssertFalse(notifications[2].persistent)
        XCTAssertFalse(notifications[3].persistent)
        XCTAssertTrue(signals.values.contains(where: { $0.signal == SIGSTOP }))
        XCTAssertTrue(signals.values.contains(where: { $0.signal == SIGKILL }))
        XCTAssertTrue(discovery.includeApplicationCalls.contains(false))
        XCTAssertTrue(discovery.includeApplicationCalls.contains(true))
    }

    func testFailedPauseAndQuitUsePersistentFallbackNotification() async {
        let discovery = TestProcessDiscovery(processIDs: [8_766])
        let inspector = TestProcessInspector(identities: [8_766: "test-thread"])
        let notifier = TestUsageLimitNotifier()
        let controller = ProviderProcessController(
            discovery: discovery,
            inspector: inspector,
            signal: { _, _ in -1 },
            wait: { _ in }
        )
        let handler = SystemUsageLimitActionHandler(processes: controller, notifier: notifier)

        _ = await handler.perform(
            limit: WeeklyUsageLimit(provider: .claude, remainingPercent: 10, severity: .pauseThreads),
            remainingPercent: 9
        )
        _ = await handler.perform(
            limit: WeeklyUsageLimit(provider: .claude, remainingPercent: 10, severity: .quitProvider),
            remainingPercent: 9
        )

        let notifications = await notifier.events
        XCTAssertEqual(notifications.count, 2)
        XCTAssertTrue(notifications.allSatisfy(\.persistent))
        XCTAssertTrue(notifications[0].message.contains("could not be paused"))
        XCTAssertTrue(notifications[1].message.contains("could not be quit"))
    }

    func testForceQuitKillsOnlyInjectedProcessThatIgnoresNormalTermination() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)",
        ]
        try process.run()
        defer {
            if process.isRunning {
                _ = CodexAppServerClient.terminate(process, gracePeriod: 0, killPeriod: 0.5)
            }
        }
        Thread.sleep(forTimeInterval: 0.1)

        let discovery = TestProcessDiscovery(processIDs: [process.processIdentifier])
        let signals = TestSignalRecorder(discovery: discovery, performSystemSignal: true)
        let controller = ProviderProcessController(
            discovery: discovery,
            signal: { processID, signal in signals.record(processID: processID, signal: signal) },
            wait: { Thread.sleep(forTimeInterval: min($0, 0.05)) }
        )

        XCTAssertTrue(controller.forceQuit(.claude))
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(Set(signals.values.map(\.processID)), [process.processIdentifier])
        XCTAssertTrue(signals.values.allSatisfy { $0.signal == SIGKILL })
    }

    @MainActor
    func testWeeklyUsageLimitViewsRenderForQA() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["AI_USAGE_QA_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:)) else { return }

        let control = VStack(spacing: 16) {
            WeeklyUsageLimitControl(provider: .codex, limits: [], isPaused: false, onEdit: { _ in }, onAdd: {}, onResume: {})
            WeeklyUsageLimitControl(
                provider: .codex,
                limits: [
                    WeeklyUsageLimit(provider: .codex, remainingPercent: 20, severity: .pauseThreads),
                    WeeklyUsageLimit(provider: .codex, remainingPercent: 5, severity: .quitProvider),
                ],
                isPaused: false,
                onEdit: { _ in },
                onAdd: {},
                onResume: {}
            )
            WeeklyUsageLimitControl(
                provider: .claude,
                limits: [WeeklyUsageLimit(provider: .claude, remainingPercent: 12, severity: .persistentNotification)],
                isPaused: true,
                onEdit: { _ in },
                onAdd: {},
                onResume: {}
            )
        }
        .padding(18)
        .frame(width: 392)
        .background(UsagePalette.nightInk)
        .environment(\.colorScheme, .dark)

        let editor = WeeklyUsageLimitEditor(
            provider: .codex,
            existingLimit: WeeklyUsageLimit(provider: .codex, remainingPercent: 20, severity: .pauseThreads),
            onSave: { _ in },
            onDelete: {}
        )
        .environment(\.colorScheme, .dark)

        let providerSlider = VStack(spacing: 12) {
            ProviderSlider(selection: .constant(.codex))
            ProviderSlider(selection: .constant(.claude))
        }
        .padding(18)
        .frame(width: 392)
        .background(UsagePalette.nightInk)
        .environment(\.colorScheme, .dark)

        let providerSliderInTallPanel = VStack(alignment: .leading, spacing: 16) {
            ProviderSlider(selection: .constant(.claude))
            Text("9%")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(UsagePalette.porcelain)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 392, height: 190, alignment: .top)
        .background(UsagePalette.nightInk)
        .environment(\.colorScheme, .dark)

        let exactClaudeBucket = LimitBucket(
            id: "claude-live",
            provider: .claude,
            displayName: "Claude Code",
            planType: nil,
            windows: [
                RateLimitWindow(
                    usedPercent: 23,
                    durationMinutes: 300,
                    resetsAt: Date(timeIntervalSince1970: 1_800_018_000),
                    confidence: .exact,
                    estimateBasis: "Live Claude usage response"
                ),
                RateLimitWindow(
                    usedPercent: 27,
                    durationMinutes: 10_080,
                    resetsAt: Date(timeIntervalSince1970: 1_800_604_800),
                    confidence: .exact,
                    estimateBasis: "Live Claude usage response"
                ),
            ],
            confidence: .exact,
            sourceDescription: "Claude Desktop plan usage history"
        )
        let exactClaudeCard = LimitBucketCard(bucket: exactClaudeBucket, provider: .claude, compact: false)
            .padding(18)
            .frame(width: 392)
            .background(UsagePalette.nightInk)
            .environment(\.colorScheme, .dark)

        let exactClaudeConfidenceStates = HStack(spacing: 12) {
            ConfidencePill(confidence: .exact, label: "LIVE · EXACT")
            ConfidencePill(confidence: .exact, label: "EXACT · CACHED")
        }
        .padding(18)
        .background(UsagePalette.nightInk)
        .environment(\.colorScheme, .dark)

        try Self.writeRenderedPNG(control, named: "weekly-limit-controls@4x.png", to: outputDirectory)
        try Self.writeRenderedPNG(editor, named: "weekly-limit-editor@4x.png", to: outputDirectory)
        try Self.writeRenderedPNG(providerSlider, named: "provider-slider@4x.png", to: outputDirectory)
        try Self.writeRenderedPNG(providerSliderInTallPanel, named: "provider-slider-tall-panel@4x.png", to: outputDirectory)
        try Self.writeRenderedPNG(exactClaudeCard, named: "claude-exact-limit-card@4x.png", to: outputDirectory)
        try Self.writeRenderedPNG(exactClaudeConfidenceStates, named: "claude-exact-confidence-states@4x.png", to: outputDirectory)
    }

    @MainActor
    private static func writeRenderedPNG<V: View>(_ view: V, named name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: name))
    }

    private static func projectTooltipFixture() -> (series: [ProjectCreditSeries], dates: [Date]) {
        let start = Date(timeIntervalSince1970: 1_783_209_600)
        let dates = (0..<5).map { start.addingTimeInterval(Double($0) * 86_400) }
        let descriptors: [(id: String, name: String, isOther: Bool, credits: [Double])] = [
            ("launcher", "Launcher", false, [8, 8, 50, 8, 8]),
            ("prosthetic", "ProstheticSimulator", false, [3, 3, 25, 3, 3]),
            ("other", "Other", true, [2, 2, 15, 2, 2]),
            ("beersimpl", "beersimpl", false, [1, 4, 10, 1, 1]),
        ]
        var cumulative = Array(repeating: 0.0, count: dates.count)
        let series = descriptors.map { descriptor in
            let points = dates.enumerated().map { index, date in
                let lower = cumulative[index]
                cumulative[index] += descriptor.credits[index]
                return ProjectCreditPoint(
                    date: date,
                    seriesID: descriptor.id,
                    seriesName: descriptor.name,
                    credits: descriptor.credits[index],
                    lowerCredits: lower,
                    upperCredits: cumulative[index]
                )
            }
            return ProjectCreditSeries(
                id: descriptor.id,
                name: descriptor.name,
                totalCredits: descriptor.credits.reduce(0, +),
                isOther: descriptor.isOther,
                points: points
            )
        }
        return (series, dates)
    }

    private static func tokenLine(timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "cache_write_input_tokens": 0,
                        "output_tokens": output,
                        "reasoning_output_tokens": 0,
                    ],
                ],
                "rate_limits": [
                    "limit_id": "codex",
                    "primary": [
                        "used_percent": 12,
                        "window_minutes": 10_080,
                        "resets_at": 1_800_000_000,
                    ],
                ],
            ],
        ]
    }

    private static func claudeUsageLine(timestamp: String, id: String, input: Int) -> [String: Any] {
        [
            "timestamp": timestamp,
            "type": "assistant",
            "uuid": id,
            "cwd": "/tmp/ClaudeRolling",
            "message": [
                "id": id,
                "model": "claude-opus-4-8",
                "usage": [
                    "input_tokens": input,
                    "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 0,
                    "output_tokens": 1,
                ],
                "content": [],
            ],
        ]
    }

    private static func usageEvent(
        id: String,
        date: Date,
        project: String,
        provider: AIProvider = .codex,
        credits: Double
    ) -> UsageEvent {
        UsageEvent(
            id: id,
            provider: provider,
            timestamp: date,
            model: provider == .codex ? "gpt-test" : "claude-test",
            projectPath: project,
            projectName: URL(filePath: project).lastPathComponent,
            tokens: TokenUsage(input: Int64(credits)),
            apiEquivalentUSD: credits / 100,
            pricingWasEstimated: false,
            serviceTier: nil
        )
    }

    private static func dailyUsageRow(id: String, date: Date, credits: Double) -> DailyUsageRow {
        DailyUsageRow(
            id: id,
            date: date,
            model: "gpt-test",
            projectName: "Test project",
            tokens: TokenUsage(input: Int64(credits)),
            credits: credits,
            apiEquivalentUSD: credits / 100,
            isEstimate: false
        )
    }

    private static func resetEvent(
        id: String,
        date: Date,
        confidence: DataConfidence,
        kind: ResetKind = .session,
        bucketID: String = "codex"
    ) -> ResetEvent {
        ResetEvent(
            id: id,
            provider: .codex,
            date: date,
            detectedAt: date,
            kind: kind,
            bucketID: bucketID,
            label: id,
            confidence: confidence
        )
    }

    private static func limitBucket(id: String, resetAt: Date, usedPercent: Double = 50) -> LimitBucket {
        LimitBucket(
            id: id,
            provider: .codex,
            displayName: id,
            planType: nil,
            windows: [
                RateLimitWindow(
                    usedPercent: usedPercent,
                    durationMinutes: 10_080,
                    resetsAt: resetAt,
                    confidence: .exact,
                    estimateBasis: nil
                ),
            ],
            confidence: .exact,
            sourceDescription: "test"
        )
    }

    private func writeJSONLines(_ values: [[String: Any]], to url: URL) throws {
        let lines = try values.map { value in
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url)
    }

    private func appendJSONLine(_ value: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Appends raw bytes with no trailing newline, simulating a writer caught mid-line: the byte
    /// range is on disk, but the line is not yet terminated/complete.
    private func appendRawUnterminated(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private final class TestProcessDiscovery: ProviderProcessDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<pid_t>
    private var includeApplicationValues: [Bool] = []

    init(processIDs: Set<pid_t>) {
        values = processIDs
    }

    func processIDs(for provider: AIProvider, includeApplication: Bool) -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        includeApplicationValues.append(includeApplication)
        return values
    }

    var includeApplicationCalls: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return includeApplicationValues
    }

    func markExited(_ processID: pid_t) {
        lock.lock()
        values.remove(processID)
        lock.unlock()
    }
}

private final class TestProcessInspector: ProviderProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [pid_t: String]

    init(identities: [pid_t: String]) {
        self.identities = identities
    }

    func activeIdentity(for processID: pid_t) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return identities[processID]
    }

    func matches(_ pausedTask: PausedProviderTask) -> Bool {
        activeIdentity(for: pausedTask.processID) == pausedTask.startIdentity
    }

    func setIdentity(_ identity: String?, for processID: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        identities[processID] = identity
    }
}

private final class TestSignalRecorder: @unchecked Sendable {
    struct Entry: Sendable {
        let processID: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private let discovery: TestProcessDiscovery
    private let performSystemSignal: Bool
    private var entries: [Entry] = []

    init(discovery: TestProcessDiscovery, performSystemSignal: Bool) {
        self.discovery = discovery
        self.performSystemSignal = performSystemSignal
    }

    var values: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    @discardableResult
    func record(processID: pid_t, signal: Int32) -> Int32 {
        lock.lock()
        entries.append(Entry(processID: processID, signal: signal))
        lock.unlock()
        let result = performSystemSignal ? Darwin.kill(processID, signal) : 0
        if result == 0, signal == SIGKILL {
            discovery.markExited(processID)
        }
        return result
    }
}

private actor TestUsageLimitNotifier: UsageLimitNotifying {
    struct Event: Sendable {
        let provider: AIProvider
        let title: String
        let message: String
        let persistent: Bool
    }

    private(set) var events: [Event] = []
    private(set) var preparedCount = 0

    func prepare() async {
        preparedCount += 1
    }

    func notify(provider: AIProvider, title: String, message: String, persistent: Bool) async {
        events.append(Event(provider: provider, title: title, message: message, persistent: persistent))
    }
}
