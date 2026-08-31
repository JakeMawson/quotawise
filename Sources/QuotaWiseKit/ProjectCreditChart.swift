import Charts
import SwiftUI

struct ProjectCreditChart: View {
    let series: [ProjectCreditSeries]
    let provider: AIProvider
    let range: UsageTimeRange
    let historicalDay: Date?
    @State private var selectedDate: Date?

    private let otherColor = Color(hex: 0x697585)

    init(
        series: [ProjectCreditSeries],
        provider: AIProvider,
        range: UsageTimeRange,
        historicalDay: Date?,
        initialSelectedDate: Date? = nil
    ) {
        self.series = series
        self.provider = provider
        self.range = range
        self.historicalDay = historicalDay
        _selectedDate = State(initialValue: initialSelectedDate)
    }

    private var namedColors: [Color] {
        [
            UsagePalette.accent(for: provider),
            UsagePalette.secondaryAccent(for: provider),
            Color(hex: 0xA78BFA),
            Color(hex: 0xF472B6),
            Color(hex: 0x38BDF8),
            Color(hex: 0x84CC16),
            UsagePalette.danger,
        ]
    }

    private var maximum: Double {
        let top = series.flatMap(\.points).map(\.upperCredits).max() ?? 0
        return max(1, top * 1.16)
    }

    private var bucketDates: [Date] {
        series.first?.points.map(\.date) ?? []
    }

    private var selectedBucket: Date? {
        guard let selectedDate else { return nil }
        return bucketDates.min {
            abs($0.timeIntervalSince(selectedDate)) < abs($1.timeIntervalSince(selectedDate))
        }
    }

    private var selectedEntries: [(ProjectCreditSeries, ProjectCreditPoint)] {
        guard let selectedBucket else { return [] }
        return series.compactMap { item in
            guard let point = item.points.first(where: { $0.date == selectedBucket }) else { return nil }
            return (item, point)
        }
    }

    private var selectedTotal: Double {
        selectedEntries.last?.1.upperCredits ?? 0
    }

    private var selectionAnnotationPosition: AnnotationPosition {
        Self.shouldPlaceSelectionAnnotationBelow(
            selectedTotal: selectedTotal,
            maximum: maximum
        ) ? .bottom : .top
    }

    nonisolated static func shouldPlaceSelectionAnnotationBelow(
        selectedTotal: Double,
        maximum: Double
    ) -> Bool {
        guard maximum > 0, selectedTotal.isFinite, maximum.isFinite else { return false }
        return selectedTotal / maximum >= 0.55
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PROJECT CREDIT FLOW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(UsagePalette.secondaryText)
                    Text("Credits by project")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(UsagePalette.porcelain)
                }
                Spacer()
                Text(periodLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }

            if series.isEmpty || series.allSatisfy({ $0.totalCredits == 0 }) {
                ContentUnavailableView(
                    "No project usage in this period",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Choose another range, day, provider, or project.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 9) {
                    ForEach(series) { item in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: item))
                                .frame(width: 10, height: 10)
                            Text(item.name)
                                .lineLimit(1)
                                .foregroundStyle(UsagePalette.porcelain)
                            Spacer(minLength: 4)
                            Text("\(UsageFormat.credits(item.totalCredits)) cr")
                                .foregroundStyle(UsagePalette.secondaryText)
                        }
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.name), \(UsageFormat.credits(item.totalCredits)) credits")
                    }
                }

                Chart {
                    ForEach(series) { item in
                        ForEach(item.points) { point in
                            AreaMark(
                                x: .value("Date", point.date),
                                yStart: .value("Lower credits", point.lowerCredits),
                                yEnd: .value("Upper credits", point.upperCredits),
                                series: .value("Project", item.name)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(color(for: item).opacity(item.isOther ? 0.32 : 0.46))

                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Cumulative credits", point.upperCredits),
                                series: .value("Project boundary", item.name)
                            )
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(color(for: item).opacity(item.isOther ? 0.72 : 0.92))
                        }
                    }

                    if let selectedBucket {
                        RuleMark(x: .value("Selected bucket", selectedBucket))
                            .foregroundStyle(UsagePalette.porcelain.opacity(0.28))
                        PointMark(
                            x: .value("Selected bucket", selectedBucket),
                            y: .value("Total credits", selectedTotal)
                        )
                        .symbolSize(46)
                        .foregroundStyle(UsagePalette.porcelain)
                        .annotation(
                            position: selectionAnnotationPosition,
                            alignment: .center,
                            spacing: 9,
                            overflowResolution: AnnotationOverflowResolution(
                                x: .fit(to: .plot),
                                y: .fit(to: .plot)
                            )
                        ) {
                            selectionAnnotation(selectedBucket)
                        }
                    }
                }
                .chartYScale(domain: 0...maximum)
                .chartLegend(.hidden)
                .chartXSelection(value: $selectedDate)
                .chartPlotStyle { plot in
                    plot
                        .background(UsagePalette.nightInk.opacity(0.34))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(minHeight: 270)
                .accessibilityLabel("Stacked project credit usage chart")
                .accessibilityHint("The heaviest project is the lowest band and Other is grey")
                .onChange(of: series) { _, _ in selectedDate = nil }
            }
        }
    }

    private var periodLabel: String {
        if let historicalDay {
            return historicalDay.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return "Top 7 + Other · \(range.rawValue)"
    }

    private func color(for item: ProjectCreditSeries) -> Color {
        if item.isOther { return otherColor }
        let named = series.filter { !$0.isOther }
        let index = named.firstIndex(where: { $0.id == item.id }) ?? 0
        return namedColors[index % namedColors.count]
    }

    private func selectionAnnotation(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bucketLabel(date))
                .foregroundStyle(UsagePalette.secondaryText)
            Text("\(UsageFormat.credits(selectedTotal)) cr total")
                .foregroundStyle(UsagePalette.porcelain)
            ForEach(Array(selectedEntries.filter { $0.1.credits > 0 }.prefix(4)), id: \.0.id) { entry in
                HStack(spacing: 5) {
                    Circle().fill(color(for: entry.0)).frame(width: 5, height: 5)
                    Text(entry.0.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(UsageFormat.credits(entry.1.credits))
                }
                .foregroundStyle(UsagePalette.porcelain)
            }
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(minWidth: 150)
        .background(RoundedRectangle(cornerRadius: 8).fill(UsagePalette.nightInk))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UsagePalette.hairline))
    }

    private func bucketLabel(_ date: Date) -> String {
        switch range {
        case .fiveHours, .oneDay:
            date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        case .sevenDays, .thirtyDays:
            date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
