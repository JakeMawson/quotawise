import SwiftUI

public struct MenuBarUsageIndicator: View {
    @ObservedObject private var model: UsageApplicationModel
    @ObservedObject private var preferences: MenuBarIconPreferences
    private let pulseProgress: Double?

    public init(model: UsageApplicationModel, pulseProgress: Double? = nil) {
        self.init(model: model, preferences: .shared, pulseProgress: pulseProgress)
    }

    init(model: UsageApplicationModel, preferences: MenuBarIconPreferences, pulseProgress: Double? = nil) {
        self.model = model
        self.preferences = preferences
        self.pulseProgress = pulseProgress
    }

    public var body: some View {
        Group {
            if preferences.configuration.isEnabled {
                MenuBarUsageGlyph(
                    top: model.menuBarIconSnapshot(for: preferences.configuration.top),
                    bottom: model.menuBarIconSnapshot(for: preferences.configuration.bottom),
                    pulseProgress: pulseProgress
                )
            } else {
                Label(model.menuBarLabel, systemImage: "chart.line.uptrend.xyaxis")
            }
        }
        .task { await model.refreshIfNeeded() }
    }
}

/// Whether an icon layer would currently render as a flat line — no data, a single point, or every
/// value collapsed to the same height (e.g. an all-zero series while indexing) — meaning it is a
/// candidate for the pulse-sweep animation instead of a static dash. Mirrors exactly what
/// `MenuBarGraphShape` checks when deciding whether to draw the pulse.
extension MenuBarIconLayerSnapshot {
    var isFlatlinedGraph: Bool {
        selection.display == .graph && MenuBarIconSeries.isFlat(MenuBarIconSeries.normalized(graphValues))
    }
}

/// True when the enabled menu-bar icon has a graph layer with no data yet (first launch, or a
/// flatlined empty state while indexing). The status item is a static rendered image, so the app
/// delegate uses this to decide whether it needs to keep redrawing it on a timer for the pulse
/// animation, rather than only when the model actually changes.
@MainActor
public func menuBarIconHasFlatlinedGraphLayer(model: UsageApplicationModel) -> Bool {
    let configuration = MenuBarIconPreferences.shared.configuration
    guard configuration.isEnabled else { return false }
    return [configuration.top, configuration.bottom].contains {
        model.menuBarIconSnapshot(for: $0).isFlatlinedGraph
    }
}

struct MenuBarIconLayerSnapshot: Equatable, Sendable {
    let selection: MenuBarIconLayer
    let graphValues: [Double]
    let remainingPercent: Double?

    var accessibilityDescription: String {
        let prefix = "\(selection.provider.displayName) \(selection.period.displayName)"
        switch selection.display {
        case .graph:
            return graphValues.isEmpty
                ? "\(prefix) usage graph unavailable"
                : "\(prefix) usage graph"
        case .bar:
            guard let remainingPercent, remainingPercent.isFinite else {
                return "\(prefix) remaining usage unavailable"
            }
            return "\(prefix), \(UsageFormat.spokenPercentage(remainingPercent, precision: .wholeNumber)) remaining"
        }
    }
}

enum MenuBarIconSnapshotBuilder {
    static func window(
        in buckets: [LimitBucket],
        provider: AIProvider,
        period: MenuBarIconPeriod
    ) -> RateLimitWindow? {
        let preferredBucket = buckets.first { $0.id == provider.rawValue } ?? buckets.first
        let eligible = preferredBucket?.windows.compactMap { window -> RateLimitWindow? in
            guard let duration = window.durationMinutes else { return nil }
            switch period {
            case .fiveHours:
                guard window.kind == .session else { return nil }
            case .week:
                guard window.kind == .weekly else { return nil }
            }
            guard duration > 0 else { return nil }
            return window
        } ?? []

        return eligible.min {
            abs(($0.durationMinutes ?? 0) - period.targetDurationMinutes)
                < abs(($1.durationMinutes ?? 0) - period.targetDurationMinutes)
        }
    }
}

extension UsageApplicationModel {
    func menuBarIconSnapshot(
        for selection: MenuBarIconLayer,
        now: Date = Date()
    ) -> MenuBarIconLayerSnapshot {
        switch selection.display {
        case .graph:
            let values = chartPoints(
                provider: selection.provider,
                range: selection.period.usageRange,
                projectPath: nil,
                now: now
            ).map(\.credits)
            return MenuBarIconLayerSnapshot(
                selection: selection,
                graphValues: MenuBarIconSeries.blockAverages(values, maximumCount: 8),
                remainingPercent: nil
            )
        case .bar:
            let window = MenuBarIconSnapshotBuilder.window(
                in: limits(for: selection.provider),
                provider: selection.provider,
                period: selection.period
            )
            return MenuBarIconLayerSnapshot(
                selection: selection,
                graphValues: [],
                remainingPercent: window?.remainingPercent
            )
        }
    }
}

enum MenuBarIconSeries {
    static func blockAverages(_ values: [Double], maximumCount: Int) -> [Double] {
        guard maximumCount > 0, values.count > maximumCount else { return values }
        let bucketWidth = Double(values.count) / Double(maximumCount)
        return (0..<maximumCount).map { index in
            let start = Int((Double(index) * bucketWidth).rounded(.down))
            let proposedEnd = Int((Double(index + 1) * bucketWidth).rounded(.down))
            let end = min(values.count, max(start + 1, proposedEnd))
            let bucket = values[start..<end]
            return bucket.reduce(0, +) / Double(bucket.count)
        }
    }

    static func normalized(_ values: [Double]) -> [Double] {
        guard let minimum = values.min(), let maximum = values.max() else { return [] }
        let spread = maximum - minimum
        guard spread > 0.000_001 else { return values.map { _ in 0.5 } }
        let paddedMinimum = minimum - spread * 0.12
        let paddedMaximum = maximum + spread * 0.12
        return values.map { value in
            max(0, min(1, (value - paddedMinimum) / (paddedMaximum - paddedMinimum)))
        }
    }

    /// True when a set of already-normalized values would render as a flat line: no data, a single
    /// point, or every value collapsed to the same height (e.g. an all-zero series while indexing).
    /// This is the single source of truth for whether the graph gets the pulse-sweep treatment.
    static func isFlat(_ normalizedValues: [Double]) -> Bool {
        guard let first = normalizedValues.first, normalizedValues.count > 1 else { return true }
        return normalizedValues.allSatisfy { abs($0 - first) < 0.000_001 }
    }
}

struct MenuBarUsageGlyph: View {
    let top: MenuBarIconLayerSnapshot
    let bottom: MenuBarIconLayerSnapshot
    var pulseProgress: Double?

    var body: some View {
        let metrics = MenuBarIconLayout.metrics(
            top: top.selection.display,
            bottom: bottom.selection.display
        )
        VStack(spacing: metrics.gap) {
            layer(top)
                .frame(height: metrics.topHeight)
            layer(bottom)
                .frame(height: metrics.bottomHeight)
        }
        .padding(.vertical, metrics.outerPadding)
        .frame(width: 36, height: 20)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Top: \(top.accessibilityDescription). Bottom: \(bottom.accessibilityDescription).")
    }

    @ViewBuilder
    private func layer(_ snapshot: MenuBarIconLayerSnapshot) -> some View {
        let color = snapshot.selection.color == .automatic
            ? Color.primary
            : Color(hex: snapshot.selection.color.hex(for: snapshot.selection.provider))
        switch snapshot.selection.display {
        case .graph:
            MiniUsageGraph(
                values: snapshot.graphValues,
                color: color,
                pulseProgress: pulseProgress
            )
        case .bar:
            MiniRemainingBar(
                remainingPercent: snapshot.remainingPercent,
                color: color,
                showPercentage: snapshot.selection.showPercentage
            )
        }
    }
}

struct MenuBarIconLayout: Equatable {
    let topHeight: CGFloat
    let bottomHeight: CGFloat
    let gap: CGFloat
    let outerPadding: CGFloat

    static func metrics(
        top: MenuBarIconDisplay,
        bottom: MenuBarIconDisplay,
        totalHeight: CGFloat = 20
    ) -> MenuBarIconLayout {
        let base: (top: CGFloat, bottom: CGFloat, gap: CGFloat)
        switch (top, bottom) {
        case (.graph, .graph):
            base = (8, 8, 2)
        case (.bar, .bar):
            base = (4, 4, 6)
        case (.graph, .bar):
            base = (10, 5, 3)
        case (.bar, .graph):
            base = (5, 10, 3)
        }

        let occupied = base.top + base.bottom + base.gap
        if occupied <= totalHeight {
            return MenuBarIconLayout(
                topHeight: base.top,
                bottomHeight: base.bottom,
                gap: base.gap,
                outerPadding: (totalHeight - occupied) / 2
            )
        }

        let scale = max(0, totalHeight / occupied)
        return MenuBarIconLayout(
            topHeight: base.top * scale,
            bottomHeight: base.bottom * scale,
            gap: base.gap * scale,
            outerPadding: 0
        )
    }
}

private struct MiniUsageGraph: View {
    let values: [Double]
    let color: Color
    var pulseProgress: Double?

    var body: some View {
        Group {
            if let pulseProgress, MenuBarIconSeries.isFlat(MenuBarIconSeries.normalized(values)) {
                MenuBarPulseHeartbeat(progress: pulseProgress, color: color)
            } else {
                MenuBarGraphShape(values: values)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .padding(.horizontal, 1.2)
        .padding(.vertical, 0.4)
    }
}

private struct MenuBarGraphShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        let normalized = MenuBarIconSeries.normalized(values)
        var path = Path()
        guard !MenuBarIconSeries.isFlat(normalized) else {
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.36, y: rect.midY))
            return path
        }

        let points = normalized.enumerated().map { index, value in
            CGPoint(
                x: rect.minX + rect.width * CGFloat(index) / CGFloat(normalized.count - 1),
                y: rect.maxY - rect.height * CGFloat(value)
            )
        }
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let before = points[max(0, index - 1)]
            let start = points[index]
            let end = points[index + 1]
            let after = points[min(points.count - 1, index + 2)]
            let control1 = CGPoint(
                x: start.x + (end.x - before.x) / 6,
                y: start.y + (end.y - before.y) / 6
            )
            let control2 = CGPoint(
                x: end.x - (after.x - start.x) / 6,
                y: end.y - (after.y - start.y) / 6
            )
            path.addCurve(to: end, control1: control1, control2: control2)
        }
        return path
    }
}

/// A fixed cardiac-monitor-style waveform (flat lead-in, a sharp QRS-like spike/dip, a gentler
/// bump, flat lead-out) drawn in place of a plain flat dash while there is no real graph data yet
/// (first launch, or a flatlined empty state while indexing).
private struct MenuBarHeartbeatShape: Shape {
    static let breakpoints: [(x: CGFloat, y: CGFloat)] = [
        (0.00, 0.00),
        (0.16, 0.00),
        (0.22, -0.14),
        (0.27, 0.90),
        (0.32, -0.60),
        (0.37, 0.10),
        (0.42, 0.00),
        (0.58, 0.00),
        (0.66, 0.30),
        (0.74, 0.00),
        (1.00, 0.00),
    ]

    func path(in rect: CGRect) -> Path {
        let maxAbs = Self.breakpoints.map { abs($0.y) }.max() ?? 1
        // Shift the whole waveform slightly right within the icon, compressing it just enough to
        // still land exactly on the right edge rather than clipping.
        let horizontalInset = rect.width * 0.07
        let points = Self.breakpoints.map { point in
            CGPoint(
                x: rect.minX + horizontalInset + (rect.width - horizontalInset) * point.x,
                y: rect.midY - (point.y / maxAbs) * (rect.height / 2) * 1.05
            )
        }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

/// The waveform itself never disappears: a dim copy is always fully drawn, and a phosphor-style
/// afterglow continuously sweeps left to right along that same fixed path every 1.5s (a 1s sweep,
/// then a brief hold before it loops) — brightest at the head where the trace just passed, easing
/// back down to the dim baseline over the trail, like an old CRT oscilloscope. The head and its
/// trail travel all the way past the right edge and fully exit before the hold, rather than
/// stopping and parking at the edge.
private struct MenuBarPulseHeartbeat: View {
    let progress: Double
    let color: Color

    private static let baseOpacity = 0.22
    private static let trailLength = 0.6
    private static let headWidth = 0.012

    var body: some View {
        let clamped = max(0, min(1, progress))
        // Travel the head from 0 to 1 + trailLength so the trail has fully faded past x = 1 by the
        // time the sweep completes, instead of stopping right at the edge.
        let head = clamped * (1 + Self.trailLength)
        let headFraction = max(0, min(1, head))
        let trailStart = max(0, min(1, head - Self.trailLength))
        ZStack {
            MenuBarHeartbeatShape()
                .stroke(color.opacity(Self.baseOpacity), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))

            if headFraction > trailStart {
                MenuBarHeartbeatShape()
                    .trim(from: trailStart, to: headFraction)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: color.opacity(Self.baseOpacity), location: trailStart),
                                .init(color: color.opacity(0.55), location: trailStart + (headFraction - trailStart) * 0.6),
                                .init(color: color, location: headFraction),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                    )
            }

            if headFraction < 1, clamped > 0 {
                MenuBarHeartbeatShape()
                    .trim(from: headFraction, to: min(1, headFraction + Self.headWidth))
                    .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct MiniRemainingBar: View {
    let remainingPercent: Double?
    let color: Color
    var showPercentage: Bool = false

    /// Whole-number percentage text with no leading zeros or decimals, e.g. "25%".
    private var percentageText: String? {
        guard let remainingPercent, remainingPercent.isFinite else { return nil }
        return UsageFormat.percentage(remainingPercent, precision: .wholeNumber)
    }

    var body: some View {
        GeometryReader { geometry in
            if showPercentage, let percentageText {
                let margin: CGFloat = 3.5
                let textWidth = CGFloat(percentageText.count) * 6.6
                let barWidth = max(4, geometry.size.width - textWidth - margin)

                // Pin both the text and the bar to the geometry's own height (rather than letting
                // an HStack size itself to the taller, unconstrained text) so the bar's vertical
                // center never shifts when the percentage label is toggled on or off. The text is
                // allowed to overflow above/below that height via fixedSize.
                ZStack(alignment: .leading) {
                    Text(percentageText)
                        .font(.system(size: 9.1, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .fixedSize()
                        .frame(width: textWidth, height: geometry.size.height, alignment: .leading)

                    bar(width: barWidth)
                        .frame(height: geometry.size.height)
                        .offset(x: textWidth + margin)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            } else {
                bar(width: geometry.size.width)
            }
        }
    }

    @ViewBuilder
    private func bar(width: CGFloat) -> some View {
        let safeRemainingPercent = remainingPercent.flatMap { $0.isFinite ? $0 : nil }
        let fraction = max(0, min(1, (safeRemainingPercent ?? 0) / 100))
        ZStack(alignment: .leading) {
            Capsule()
                .fill(color.opacity(0.16))

            if safeRemainingPercent != nil, fraction > 0 {
                Capsule()
                    .fill(color)
                    .frame(width: max(1.5, width * fraction))
            }

            if safeRemainingPercent == nil {
                Capsule()
                    .fill(color.opacity(0.48))
                    .frame(width: width * 0.24, height: 1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: width)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(safeRemainingPercent == nil ? 0.32 : 0.58), lineWidth: 0.75)
        )
    }
}
