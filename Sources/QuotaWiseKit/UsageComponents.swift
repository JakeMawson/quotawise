import Charts
import SwiftUI

struct ProviderSlider: View {
    @Binding var selection: AIProvider
    let animatesSelection: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pillSelection: AIProvider
    @Namespace private var selectionPillNamespace
    private let height: CGFloat = 38

    init(selection: Binding<AIProvider>, animatesSelection: Bool = true) {
        _selection = selection
        _pillSelection = State(initialValue: selection.wrappedValue)
        self.animatesSelection = animatesSelection
    }

    var body: some View {
        HStack(spacing: 0) {
            providerButton(.codex)
                .background { selectionPill(for: .codex) }
            providerButton(.claude)
                .background { selectionPill(for: .claude) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Capsule().fill(Color.white.opacity(0.055)))
        .overlay(Capsule().stroke(UsagePalette.hairline, lineWidth: 1))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage provider")
        .onChange(of: selection) { _, provider in
            guard pillSelection != provider else { return }
            movePill(to: provider)
        }
    }

    @ViewBuilder
    private func selectionPill(for provider: AIProvider) -> some View {
        if pillSelection == provider {
            Capsule()
                .fill(UsagePalette.liftedSlate)
                .overlay(
                    Capsule()
                        .stroke(UsagePalette.accent(for: provider).opacity(0.55), lineWidth: 1)
                )
                .shadow(color: UsagePalette.accent(for: provider).opacity(0.18), radius: 12)
                .padding(4)
                .matchedGeometryEffect(id: "provider-selection-pill", in: selectionPillNamespace)
        }
    }

    private func providerButton(_ provider: AIProvider) -> some View {
        Button {
            select(provider)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(UsagePalette.accent(for: provider))
                    .frame(width: 6, height: 6)
                    .shadow(color: UsagePalette.accent(for: provider).opacity(0.55), radius: 4)
                Text(provider.displayName)
                    .font(.system(size: 12, weight: pillSelection == provider ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(pillSelection == provider ? UsagePalette.porcelain : UsagePalette.secondaryText)
                    .frame(height: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(MouseDownButtonStyle {
            select(provider)
        })
        .accessibilityAddTraits(selection == provider ? .isSelected : [])
    }

    private func select(_ provider: AIProvider) {
        guard selection != provider else { return }

        // The provider panels have very different intrinsic heights.  Do not
        // put their replacement in the same animation transaction as the
        // selection pill: NSPopover otherwise interpolates its preferred size
        // while SwiftUI is reflowing both panels, which makes their contents
        // appear to jump against the popover's anchored edge.
        var contentTransaction = Transaction(animation: nil)
        contentTransaction.disablesAnimations = true
        withTransaction(contentTransaction) {
            selection = provider
        }

        movePill(to: provider)
    }

    private func movePill(to provider: AIProvider) {
        guard pillSelection != provider else { return }
        if reduceMotion || !animatesSelection {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pillSelection = provider
            }
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                pillSelection = provider
            }
        }
    }
}

private struct MouseDownButtonStyle: ButtonStyle {
    let onMouseDown: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    onMouseDown()
                }
            }
    }
}

struct ConfidencePill: View {
    let confidence: DataConfidence
    let label: String?

    init(confidence: DataConfidence, label: String? = nil) {
        self.confidence = confidence
        self.label = label
    }

    var body: some View {
        let color: Color = confidence == .exact ? UsagePalette.mineralTeal : UsagePalette.burntAmber
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label ?? (confidence == .exact ? "LIVE · EXACT" : confidence == .estimated ? "ESTIMATED" : "UNAVAILABLE"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.7)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.09)))
        .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 1))
    }
}

struct LimitBucketCard: View {
    let bucket: LimitBucket
    let provider: AIProvider
    let compact: Bool
    let percentagePrecision: PercentageDisplayPrecision

    init(
        bucket: LimitBucket,
        provider: AIProvider,
        compact: Bool,
        percentagePrecision: PercentageDisplayPrecision = .wholeNumber
    ) {
        self.bucket = bucket
        self.provider = provider
        self.compact = compact
        self.percentagePrecision = percentagePrecision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(bucket.displayName)
                        .font(.system(size: compact ? 13 : 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(UsagePalette.porcelain)
                    if let plan = bucket.planType {
                        Text(plan.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(UsagePalette.secondaryText)
                    }
                }
                Spacer()
                if !compact { ConfidencePill(confidence: bucket.confidence) }
            }

            if bucket.windows.isEmpty {
                Text("No active usage window is reported for this model.")
                    .font(.system(size: 12))
                    .foregroundStyle(UsagePalette.secondaryText)
            } else {
                ForEach(Array(bucket.windows.enumerated()), id: \.element.id) { index, window in
                    LimitRail(
                        title: window.durationLabel,
                        window: window,
                        accent: index == 0
                            ? UsagePalette.accent(for: provider)
                            : UsagePalette.secondaryAccent(for: provider),
                        compact: compact,
                        percentagePrecision: percentagePrecision
                    )
                }
            }
        }
        .padding(compact ? 14 : 18)
        .background(
            RoundedRectangle(cornerRadius: compact ? 15 : 18, style: .continuous)
                .fill(UsagePalette.slateGlass)
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 15 : 18, style: .continuous)
                        .stroke(UsagePalette.hairline, lineWidth: 1)
                )
        )
    }
}

struct LimitRail: View {
    let title: String
    let window: RateLimitWindow
    let accent: Color
    let compact: Bool
    let percentagePrecision: PercentageDisplayPrecision

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                if window.confidence == .estimated {
                    Text("EST.")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(UsagePalette.burntAmber)
                }
                Spacer()
                Text(UsageFormat.reset(window.resetsAt))
                    .font(.system(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }

            GeometryReader { geometry in
                let fraction = window.remainingPercent / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.075))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.7), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(5, geometry.size.width * fraction))
                        .shadow(color: accent.opacity(0.28), radius: 6)

                    Rectangle()
                        .fill(UsagePalette.porcelain.opacity(0.9))
                        .frame(width: 1, height: 14)
                        .offset(x: min(geometry.size.width - 1, max(1, geometry.size.width * fraction)))
                }
            }
            .frame(height: compact ? 7 : 8)

            HStack(alignment: .firstTextBaseline) {
                Text("\(UsageFormat.percentage(window.remainingPercent, precision: percentagePrecision)) remaining")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                Spacer()
                Text("\(UsageFormat.percentage(window.usedPercent, precision: percentagePrecision)) used")
                    .font(.system(size: compact ? 9 : 10, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }

            if !compact, let basis = window.estimateBasis {
                Text(basis)
                    .font(.system(size: 10))
                    .foregroundStyle(UsagePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(UsageFormat.spokenPercentage(window.remainingPercent, precision: percentagePrecision)) remaining. \(UsageFormat.reset(window.resetsAt))")
    }
}

struct UsageAreaChart: View {
    let points: [UsageChartPoint]
    let resets: [ResetEvent]
    let provider: AIProvider
    let compact: Bool
    let onDaySelected: ((Date) -> Void)?
    @State private var selectedDate: Date?
    @State private var hoveredDate: Date?
    @State private var hoveredResetSeam: ResetSeam?

    init(
        points: [UsageChartPoint],
        resets: [ResetEvent],
        provider: AIProvider,
        compact: Bool,
        onDaySelected: ((Date) -> Void)? = nil,
        initialHoveredDate: Date? = nil,
        initialHoveredReset: ResetEvent? = nil
    ) {
        let resetSeams = ResetSeam.group(resets)
        self.points = points
        self.resets = resets
        self.provider = provider
        self.compact = compact
        self.onDaySelected = onDaySelected
        _hoveredDate = State(initialValue: initialHoveredDate)
        _hoveredResetSeam = State(initialValue: initialHoveredReset.flatMap { reset in
            resetSeams.first { $0.events.contains(reset) }
        })
    }

    private var resetSeams: [ResetSeam] { ResetSeam.group(resets) }

    private var maximum: Double {
        max(1, (points.map(\.credits).max() ?? 0) * 1.16)
    }

    private var selectedPoint: UsageChartPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var hoveredPoint: UsageChartPoint? {
        guard let hoveredDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(hoveredDate)) < abs($1.date.timeIntervalSince(hoveredDate)) }
    }

    private var inspectedPoint: UsageChartPoint? {
        hoveredPoint ?? selectedPoint
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("Credits", point.credits)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            UsagePalette.accent(for: provider).opacity(0.72),
                            UsagePalette.accent(for: provider).opacity(0.025),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Credits", point.credits)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: compact ? 1.6 : 2.1, lineCap: .round, lineJoin: .round))
                .foregroundStyle(UsagePalette.accent(for: provider))
            }

            ForEach(resetSeams) { seam in
                RuleMark(x: .value("Reset", seam.date))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: seam.confidence == .estimated ? [3, 4] : [1, 3]))
                    .foregroundStyle(resetMarkerColor(for: seam))
            }

            if let seam = hoveredResetSeam {
                RuleMark(x: .value("Hovered reset", seam.date))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: seam.confidence == .estimated ? [3, 4] : [1, 3]))
                    .foregroundStyle(resetMarkerColor(for: seam).opacity(0.95))
            }

            if !compact, let point = inspectedPoint {
                RuleMark(x: .value("Inspected date", point.date))
                    .foregroundStyle(UsagePalette.porcelain.opacity(0.35))
                PointMark(
                    x: .value("Inspected date", point.date),
                    y: .value("Inspected credits", point.credits)
                )
                .symbolSize(50)
                .foregroundStyle(UsagePalette.porcelain)
            }
        }
        .chartYScale(domain: 0...maximum)
        .chartLegend(.hidden)
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(compact ? .hidden : .automatic)
        .chartPlotStyle { plot in
            plot
                .background(UsagePalette.nightInk.opacity(0.34))
                .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
        }
        .chartXSelection(value: compact ? .constant(nil) : $selectedDate)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    let overlay = Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                updateHoveredPoint(at: location, proxy: proxy, geometry: geometry)
                                updateHoveredReset(at: location, proxy: proxy, geometry: geometry)
                            case .ended:
                                hoveredDate = nil
                                hoveredResetSeam = nil
                            }
                        }

                    if compact || onDaySelected == nil {
                        overlay
                    } else {
                        overlay.simultaneousGesture(
                            SpatialTapGesture().onEnded { value in
                                selectDay(at: value.location, proxy: proxy, geometry: geometry)
                            }
                        )
                    }

                    if let seam = hoveredResetSeam,
                       let anchor = proxy.plotFrame,
                       let resetX = proxy.position(forX: seam.date) {
                        let frame = geometry[anchor]
                        resetTooltip(seam)
                            .fixedSize()
                            .allowsHitTesting(false)
                            .position(
                                x: frame.origin.x + resetX,
                                y: frame.origin.y + min(56, max(42, frame.height * 0.2))
                            )
                    }

                    if !compact,
                       let point = inspectedPoint,
                       let anchor = proxy.plotFrame,
                       let pointX = proxy.position(forX: point.date),
                       let pointY = proxy.position(forY: point.credits) {
                        let frame = geometry[anchor]
                        pointTooltip(point)
                            .fixedSize()
                            .allowsHitTesting(false)
                            .position(
                                x: frame.origin.x + pointX,
                                y: pointTooltipCenterY(for: pointY, in: frame)
                            )
                    }
                }
            }
        }
        .accessibilityLabel("Daily API-equivalent credit usage chart")
        .accessibilityHint(compact ? "Hover a reset seam for details" : "Move across the chart to inspect a value, or click a date to inspect that day")
    }

    private func selectDay(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let frame = geometry[anchor]
        guard frame.contains(location), frame.width > 0 else { return }
        let plotX = location.x - frame.origin.x
        guard let date: Date = proxy.value(atX: plotX),
              let point = points.min(by: {
                  abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
              }) else { return }
        selectedDate = point.date
        onDaySelected?(point.date)
    }

    private func updateHoveredReset(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let anchor = proxy.plotFrame else {
            hoveredResetSeam = nil
            return
        }
        let frame = geometry[anchor]
        guard frame.contains(location) else {
            hoveredResetSeam = nil
            return
        }
        let plotX = location.x - frame.origin.x
        let nearest = resetSeams.compactMap { seam -> (seam: ResetSeam, distance: CGFloat)? in
            guard let resetX = proxy.position(forX: seam.date) else { return nil }
            return (seam, abs(resetX - plotX))
        }.min { $0.distance < $1.distance }
        if let nearest, nearest.distance <= 12 {
            hoveredResetSeam = nearest.seam
        } else {
            hoveredResetSeam = nil
        }
    }

    private func updateHoveredPoint(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard !compact,
              let anchor = proxy.plotFrame else {
            hoveredDate = nil
            return
        }
        let frame = geometry[anchor]
        guard frame.contains(location), frame.width > 0 else {
            hoveredDate = nil
            return
        }
        let plotX = location.x - frame.origin.x
        guard let date: Date = proxy.value(atX: plotX),
              let point = points.min(by: {
                  abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
              }) else {
            hoveredDate = nil
            return
        }
        hoveredDate = point.date
    }

    private func resetTooltip(_ seam: ResetSeam) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(resetTooltipTitle(for: seam))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(UsagePalette.porcelain)
            Text(seam.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(UsagePalette.secondaryText)
            ForEach(seam.events) { reset in
                Text("\(reset.label) · \(reset.bucketID)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }
            Text(resetEvidenceLabel(for: seam))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(resetMarkerColor(for: seam))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(UsagePalette.nightInk))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UsagePalette.hairline))
    }

    private func pointTooltip(_ point: UsageChartPoint) -> some View {
        VStack(spacing: 2) {
            Text(point.date.formatted(date: .abbreviated, time: .omitted))
            Text("\(UsageFormat.credits(point.credits)) cr · \(UsageFormat.dollars(point.apiEquivalentUSD))")
                .foregroundStyle(UsagePalette.porcelain)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(UsagePalette.nightInk))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UsagePalette.hairline))
    }

    private func pointTooltipCenterY(for pointY: CGFloat, in plotFrame: CGRect) -> CGFloat {
        let tooltipHeight: CGFloat = 44
        let spacing: CGFloat = 10
        let above = plotFrame.minY + pointY - spacing - tooltipHeight / 2
        return above >= plotFrame.minY
            ? above
            : plotFrame.minY + pointY + spacing + tooltipHeight / 2
    }

    private func resetTooltipTitle(for seam: ResetSeam) -> String {
        guard seam.events.count > 1 else { return seam.events.first?.label ?? "Reset" }
        let kind = seam.events.first?.kind == .weekly ? "weekly" : "session"
        return "Combined " + kind + " reset"
    }

    private func resetEvidenceLabel(for seam: ResetSeam) -> String {
        guard seam.confidence != .exact else { return "Observed reset" }
        return seam.events.first?.kind == .session
            ? "Estimated session schedule"
            : "Estimated weekly seam"
    }

    private func resetMarkerColor(for seam: ResetSeam) -> Color {
        if seam.containsPrimaryReset {
            return UsagePalette.mineralTeal.opacity(0.75)
        }
        if seam.events.contains(where: \.isSparkModelReset) {
            return UsagePalette.burntAmber.opacity(0.88)
        }
        if seam.events.first?.kind == .weekly {
            return UsagePalette.mineralTeal.opacity(0.75)
        }
        return UsagePalette.porcelain.opacity(0.32)
    }
}

struct EmptyLimitNotice: View {
    let provider: AIProvider

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(UsagePalette.accent(for: provider))
            VStack(alignment: .leading, spacing: 2) {
                Text("No active limit window")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                Text(provider == .codex
                    ? "Codex did not return a rolling or weekly bucket. Usage history remains available."
                    : "Open Claude Code once to establish local usage history.")
                    .font(.system(size: 10))
                    .foregroundStyle(UsagePalette.secondaryText)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(UsagePalette.slateGlass))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(UsagePalette.hairline))
    }
}
