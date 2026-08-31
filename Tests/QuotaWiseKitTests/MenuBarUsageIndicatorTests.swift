import AppKit
import SwiftUI
import XCTest
@testable import QuotaWiseKit

final class MenuBarUsageIndicatorTests: XCTestCase {
    func testRelativeRefreshAgeKeepsCountingSecondsPastTheFirstMinute() {
        let refreshedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            UsageFormat.relative(refreshedAt, relativeTo: refreshedAt.addingTimeInterval(62)),
            "62 seconds ago"
        )
    }

    func testRelativeRefreshAgeClampsSmallClockSkewToZero() {
        let refreshedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            UsageFormat.relative(refreshedAt, relativeTo: refreshedAt.addingTimeInterval(-0.5)),
            "0 seconds ago"
        )
    }

    @MainActor
    func testPreferencesDefaultToRequestedCodexWeekGraphOverBar() throws {
        let key = "menu-bar-icon-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removeObject(forKey: key) }

        let preferences = MenuBarIconPreferences(defaults: defaults, key: key)

        XCTAssertTrue(preferences.configuration.isEnabled)
        XCTAssertEqual(preferences.configuration.top, .defaultTop)
        XCTAssertEqual(preferences.configuration.bottom, .defaultBottom)
        XCTAssertEqual(preferences.configuration.top.period, .week)
        XCTAssertEqual(preferences.configuration.bottom.period, .week)
        XCTAssertEqual(preferences.configuration.top.color, .automatic)
        XCTAssertEqual(preferences.configuration.bottom.color, .automatic)
    }

    @MainActor
    func testPreferencesPersistIndependentTopAndBottomSelections() throws {
        let key = "menu-bar-icon-persistence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removeObject(forKey: key) }

        let first = MenuBarIconPreferences(defaults: defaults, key: key)
        first.configuration = MenuBarIconConfiguration(
            isEnabled: false,
            top: MenuBarIconLayer(provider: .claude, display: .bar, period: .fiveHours, color: .providerAccent),
            bottom: MenuBarIconLayer(provider: .codex, display: .graph, period: .week)
        )

        let second = MenuBarIconPreferences(defaults: defaults, key: key)
        XCTAssertEqual(second.configuration, first.configuration)
        XCTAssertFalse(second.configuration.isEnabled)
        XCTAssertEqual(second.configuration.top.provider, .claude)
        XCTAssertEqual(second.configuration.bottom.provider, .codex)
        XCTAssertEqual(second.configuration.top.color, .providerAccent)
        XCTAssertEqual(second.configuration.bottom.color, .automatic)
    }

    func testLegacyLayerWithoutColorMigratesToAuto() throws {
        let legacy = Data(#"{"provider":"claude","display":"bar","period":"fiveHours"}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuBarIconLayer.self, from: legacy)

        XCTAssertEqual(decoded.provider, .claude)
        XCTAssertEqual(decoded.color, .automatic)
    }

    func testLegacyWhiteColourMigratesToAuto() throws {
        let legacy = Data(#"{"provider":"claude","display":"bar","period":"fiveHours","color":"white"}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuBarIconLayer.self, from: legacy)

        XCTAssertEqual(decoded.color, .automatic)
    }

    func testProviderAccentResolvesToRequestedBlueAndYellow() {
        XCTAssertEqual(MenuBarIconColor.automatic.displayName(for: .codex), "Auto")
        XCTAssertEqual(MenuBarIconColor.providerAccent.displayName(for: .codex), "Blue")
        XCTAssertEqual(MenuBarIconColor.providerAccent.displayName(for: .claude), "Yellow")
        XCTAssertEqual(MenuBarIconColor.providerAccent.hex(for: .codex), 0x5B8CFF)
        XCTAssertEqual(MenuBarIconColor.providerAccent.hex(for: .claude), 0xFFCB78)
    }

    @MainActor
    func testPreferencesUseSafeDefaultsWhenPersistedDataIsInvalid() throws {
        let key = "menu-bar-icon-invalid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removeObject(forKey: key) }
        defaults.set(Data("not-json".utf8), forKey: key)

        let preferences = MenuBarIconPreferences(defaults: defaults, key: key)
        XCTAssertEqual(preferences.configuration, .default)
    }

    func testDenseGraphSeriesIsAveragedToEightRepresentativePoints() {
        let values = (1...24).map(Double.init)
        let averaged = MenuBarIconSeries.blockAverages(values, maximumCount: 8)

        XCTAssertEqual(averaged.count, 8)
        XCTAssertEqual(averaged[0], 2, accuracy: 0.0001)
        XCTAssertEqual(averaged[7], 23, accuracy: 0.0001)
    }

    func testShortGraphSeriesKeepsEveryFiveHourOrWeeklyPoint() {
        let values = [1.0, 8, 3, 6, 2, 9, 4, 7]
        XCTAssertEqual(MenuBarIconSeries.blockAverages(values, maximumCount: 8), values)
    }

    func testGraphNormalizationUsesObservedLowAndHighRatherThanZeroToOneHundred() throws {
        let normalized = MenuBarIconSeries.normalized([72, 74, 73])

        XCTAssertEqual(normalized.count, 3)
        XCTAssertLessThan(try XCTUnwrap(normalized.min()), 0.2)
        XCTAssertGreaterThan(try XCTUnwrap(normalized.max()), 0.8)
        XCTAssertEqual(MenuBarIconSeries.normalized([42, 42, 42]), [0.5, 0.5, 0.5])
        XCTAssertTrue(MenuBarIconSeries.normalized([]).isEmpty)
    }

    func testLimitSelectionUsesMainProviderBucketAndNearestMatchingWindow() throws {
        let spark = LimitBucket(
            id: "spark",
            provider: .codex,
            displayName: "Spark",
            planType: nil,
            windows: [Self.window(used: 5, duration: 300)],
            confidence: .exact,
            sourceDescription: "fixture"
        )
        let codex = LimitBucket(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            planType: nil,
            windows: [
                Self.window(used: 25, duration: 360),
                Self.window(used: 35, duration: 300),
                Self.window(used: 65, duration: 10_080),
            ],
            confidence: .exact,
            sourceDescription: "fixture"
        )

        let fiveHours = try XCTUnwrap(
            MenuBarIconSnapshotBuilder.window(
                in: [spark, codex],
                provider: .codex,
                period: .fiveHours
            )
        )
        let week = try XCTUnwrap(
            MenuBarIconSnapshotBuilder.window(
                in: [spark, codex],
                provider: .codex,
                period: .week
            )
        )

        XCTAssertEqual(fiveHours.durationMinutes, 300)
        XCTAssertEqual(fiveHours.remainingPercent, 65, accuracy: 0.0001)
        XCTAssertEqual(week.durationMinutes, 10_080)
        XCTAssertEqual(week.remainingPercent, 35, accuracy: 0.0001)
    }

    func testMissingLimitWindowRemainsUnavailable() {
        let bucket = LimitBucket(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            planType: nil,
            windows: [Self.window(used: 65, duration: 10_080)],
            confidence: .exact,
            sourceDescription: "fixture"
        )
        XCTAssertNil(
            MenuBarIconSnapshotBuilder.window(
                in: [bucket],
                provider: .codex,
                period: .fiveHours
            )
        )
    }

    func testMissingGraphDataHasAnHonestAccessibilityDescription() {
        let snapshot = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .claude, display: .graph, period: .fiveHours),
            graphValues: [],
            remainingPercent: nil
        )
        XCTAssertEqual(snapshot.accessibilityDescription, "Claude Code 5h usage graph unavailable")
    }

    func testMenuBarPercentageAccessibilityRemainsWholeNumber() {
        let snapshot = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .codex, display: .bar, period: .week),
            graphValues: [],
            remainingPercent: 42.6
        )

        XCTAssertEqual(snapshot.accessibilityDescription, "Codex Week, 43 percent remaining")
    }

    func testAdaptiveLayoutMakesGraphsLargeAndTwoBarsBreathe() {
        let mixed = MenuBarIconLayout.metrics(top: .graph, bottom: .bar)
        let reversed = MenuBarIconLayout.metrics(top: .bar, bottom: .graph)
        let twoGraphs = MenuBarIconLayout.metrics(top: .graph, bottom: .graph)
        let twoBars = MenuBarIconLayout.metrics(top: .bar, bottom: .bar)

        XCTAssertEqual(mixed.topHeight / mixed.bottomHeight, 2, accuracy: 0.0001)
        XCTAssertEqual(reversed.bottomHeight / reversed.topHeight, 2, accuracy: 0.0001)
        XCTAssertLessThan(twoGraphs.topHeight, mixed.topHeight)
        XCTAssertEqual(twoBars.topHeight, 4, accuracy: 0.0001)
        XCTAssertGreaterThan(twoBars.gap, mixed.gap)
        XCTAssertGreaterThan(twoBars.outerPadding, mixed.outerPadding)
    }

    @MainActor
    func testMenuBarUsageGlyphAndSettingsRenderForQA() throws {
        let graphWeek = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .codex, display: .graph, period: .week),
            graphValues: [12, 18, 14, 33, 21, 28, 17, 25],
            remainingPercent: nil
        )
        let graphFiveHours = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .claude, display: .graph, period: .fiveHours),
            graphValues: [51, 54, 53, 57, 55, 59],
            remainingPercent: nil
        )
        let barWeek = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .codex, display: .bar, period: .week),
            graphValues: [],
            remainingPercent: 42
        )
        let barFiveHours = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .claude, display: .bar, period: .fiveHours),
            graphValues: [],
            remainingPercent: 73
        )
        let unavailable = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .claude, display: .bar, period: .week),
            graphValues: [],
            remainingPercent: nil
        )
        let nonFinite = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .codex, display: .bar, period: .week, color: .automatic, showPercentage: true),
            graphValues: [],
            remainingPercent: .nan
        )
        let emptyBar = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .codex, display: .bar, period: .fiveHours),
            graphValues: [],
            remainingPercent: 0
        )
        let fullBar = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .claude, display: .bar, period: .week),
            graphValues: [],
            remainingPercent: 100
        )
        let blueGraph = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .codex, display: .graph, period: .week, color: .providerAccent),
            graphValues: graphWeek.graphValues,
            remainingPercent: nil
        )
        let yellowBar = MenuBarIconLayerSnapshot(
            selection: MenuBarIconLayer(provider: .claude, display: .bar, period: .fiveHours, color: .providerAccent),
            graphValues: [],
            remainingPercent: 73
        )

        let darkAutoGlyph = MenuBarUsageGlyph(top: graphWeek, bottom: barWeek)
            .background(UsagePalette.nightInk)
            .environment(\.colorScheme, .dark)
        let lightAutoGlyph = MenuBarUsageGlyph(top: graphWeek, bottom: barWeek)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let coloredNativeGlyph = MenuBarUsageGlyph(top: blueGraph, bottom: yellowBar)
            .background(UsagePalette.nightInk)
        let glyphSheet = VStack(alignment: .leading, spacing: 20) {
            glyphRow("White + white", MenuBarUsageGlyph(top: graphWeek, bottom: barWeek))
            glyphRow("Blue + yellow", MenuBarUsageGlyph(top: blueGraph, bottom: yellowBar))
            glyphRow("Bar + graph", MenuBarUsageGlyph(top: barFiveHours, bottom: graphWeek))
            glyphRow("Graph + graph", MenuBarUsageGlyph(top: graphWeek, bottom: graphFiveHours))
            glyphRow("Bar + bar", MenuBarUsageGlyph(top: barWeek, bottom: barFiveHours))
            glyphRow("Empty + full", MenuBarUsageGlyph(top: emptyBar, bottom: fullBar))
            glyphRow("Unavailable", MenuBarUsageGlyph(top: graphFiveHours, bottom: unavailable))
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(UsagePalette.nightInk)
        .environment(\.colorScheme, .dark)

        let key = "menu-bar-icon-render-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removeObject(forKey: key) }
        let preferences = MenuBarIconPreferences(defaults: defaults, key: key)
        preferences.configuration = MenuBarIconConfiguration(
            isEnabled: true,
            top: blueGraph.selection,
            bottom: yellowBar.selection
        )
        let settings = MenuBarIconSettingsContent(
            model: UsageApplicationModel(),
            preferences: preferences
        )
        .padding(22)
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let nativeImage = try Self.render(darkAutoGlyph, scale: 2)
        let lightAutoImage = try Self.render(lightAutoGlyph, scale: 2)
        let lightAutoZoomImage = try Self.render(lightAutoGlyph, scale: 8)
        let coloredNativeImage = try Self.render(coloredNativeGlyph, scale: 2)
        let coloredZoomImage = try Self.render(coloredNativeGlyph, scale: 8)
        let sheetImage = try Self.render(glyphSheet, scale: 4)
        let settingsImage = try Self.render(settings, scale: 2)
        let nonFiniteImage = try Self.render(
            MenuBarUsageGlyph(top: nonFinite, bottom: nonFinite)
                .background(UsagePalette.nightInk)
                .environment(\.colorScheme, .dark),
            scale: 2
        )
        let defaultSettingsKey = "menu-bar-icon-render-default-\(UUID().uuidString)"
        let defaultSettingsDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultSettingsKey))
        defer { defaultSettingsDefaults.removeObject(forKey: defaultSettingsKey) }
        let defaultSettingsPreferences = MenuBarIconPreferences(
            defaults: defaultSettingsDefaults,
            key: defaultSettingsKey
        )
        let defaultSettings = MenuBarIconSettingsContent(
            model: UsageApplicationModel(),
            preferences: defaultSettingsPreferences
        )
        .padding(22)
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let defaultSettingsImage = try Self.render(defaultSettings, scale: 2)
        let disabledKey = "menu-bar-icon-render-disabled-\(UUID().uuidString)"
        let disabledDefaults = try XCTUnwrap(UserDefaults(suiteName: disabledKey))
        defer { disabledDefaults.removeObject(forKey: disabledKey) }
        let disabledPreferences = MenuBarIconPreferences(defaults: disabledDefaults, key: disabledKey)
        disabledPreferences.configuration = MenuBarIconConfiguration(
            isEnabled: false,
            top: graphWeek.selection,
            bottom: barFiveHours.selection
        )
        let disabledSettings = MenuBarIconSettingsContent(
            model: UsageApplicationModel(),
            preferences: disabledPreferences
        )
        .padding(22)
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let disabledSettingsImage = try Self.render(disabledSettings, scale: 2)
        XCTAssertEqual(nativeImage.size.width, 36, accuracy: 0.5)
        XCTAssertEqual(nativeImage.size.height, 20, accuracy: 0.5)
        XCTAssertGreaterThan(Self.lightContrastPixelCount(in: nativeImage), 20)
        XCTAssertGreaterThan(Self.darkContrastPixelCount(in: lightAutoImage), 20)
        XCTAssertEqual(lightAutoZoomImage.size, nativeImage.size)
        XCTAssertEqual(coloredNativeImage.size, nativeImage.size)
        XCTAssertEqual(coloredZoomImage.size, nativeImage.size)
        XCTAssertGreaterThan(sheetImage.size.width, 0)
        XCTAssertGreaterThan(nonFiniteImage.size.width, 0)
        XCTAssertEqual(settingsImage.size.width, 540, accuracy: 0.5)
        XCTAssertGreaterThan(settingsImage.size.height, 300)
        XCTAssertEqual(defaultSettingsImage.size, settingsImage.size)
        XCTAssertEqual(disabledSettingsImage.size, settingsImage.size)

        if let outputDirectory = ProcessInfo.processInfo.environment["AI_USAGE_QA_OUTPUT_DIR"]
            .map(URL.init(fileURLWithPath:)) {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try Self.write(nativeImage, to: outputDirectory.appending(path: "menu-bar-glyph-native@2x.png"))
            try Self.write(lightAutoZoomImage, to: outputDirectory.appending(path: "menu-bar-glyph-auto-light@8x.png"))
            try Self.write(coloredNativeImage, to: outputDirectory.appending(path: "menu-bar-glyph-color-native@2x.png"))
            try Self.write(coloredZoomImage, to: outputDirectory.appending(path: "menu-bar-glyph-color-zoom@8x.png"))
            try Self.write(sheetImage, to: outputDirectory.appending(path: "menu-bar-glyph-layouts@4x.png"))
            try Self.write(settingsImage, to: outputDirectory.appending(path: "menu-bar-settings@2x.png"))
            try Self.write(defaultSettingsImage, to: outputDirectory.appending(path: "menu-bar-settings-default@2x.png"))
            try Self.write(disabledSettingsImage, to: outputDirectory.appending(path: "menu-bar-settings-disabled@2x.png"))
        }
    }

    private static func window(used: Double, duration: Int) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: used,
            durationMinutes: duration,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            confidence: .exact,
            estimateBasis: nil
        )
    }

    @MainActor
    private func glyphRow(_ title: String, _ glyph: MenuBarUsageGlyph) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(width: 110, alignment: .leading)
            glyph
                .scaleEffect(4)
                .frame(width: 144, height: 80)
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, scale: CGFloat) throws -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try XCTUnwrap(renderer.nsImage)
    }

    private static func write(_ image: NSImage, to url: URL) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    private static func darkContrastPixelCount(in image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return 0
        }

        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent < 0.72,
                   color.greenComponent < 0.72,
                   color.blueComponent < 0.72 {
                    count += 1
                }
            }
        }
        return count
    }

    private static func lightContrastPixelCount(in image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return 0
        }

        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.88,
                   color.greenComponent > 0.88,
                   color.blueComponent > 0.88 {
                    count += 1
                }
            }
        }
        return count
    }
}
