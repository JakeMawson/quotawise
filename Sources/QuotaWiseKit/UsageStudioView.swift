import SwiftUI

public struct UsageStudioView: View {
    @ObservedObject private var model: UsageApplicationModel
    @State private var projectQuery = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let showLedgerForQA = CommandLine.arguments.contains("--qa-ledger")

    private enum ScrollTarget {
        static let top = "studio-top"
        static let ledger = "usage-ledger"
    }

    public init(model: UsageApplicationModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 310)
        } detail: {
            mainContent
        }
        .frame(minWidth: 980, minHeight: 680)
        .navigationSplitViewStyle(.balanced)
        .background(UsagePalette.nightInk)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: toggleSidebar) {
                    Label(sidebarToggleLabel, systemImage: "sidebar.left")
                }
                .accessibilityIdentifier("quotaWiseSidebarToggle")
                .help(sidebarToggleLabel)
            }
        }
        .task { await model.refreshIfNeeded() }
    }

    private var sidebarToggleLabel: String {
        columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar"
    }

    private func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    private var filteredProjects: [ProjectSummary] {
        model.projects.filter { project in
            project.provider == model.selectedProvider
                && (projectQuery.isEmpty
                    || project.name.localizedCaseInsensitiveContains(projectQuery)
                    || project.path.localizedCaseInsensitiveContains(projectQuery))
        }
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("QuotaWise")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                Text("LOCAL COMPUTE LEDGER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(UsagePalette.secondaryText)
            }

            ProviderSlider(selection: $model.selectedProvider)

            TextField("Search projects", text: $projectQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(UsagePalette.hairline))

            VStack(alignment: .leading, spacing: 6) {
                Text("PROJECTS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(UsagePalette.secondaryText)

                projectButton(name: "All projects", path: nil, credits: nil)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredProjects) { project in
                            projectButton(name: project.name, path: project.path, credits: project.credits)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRefreshing ? UsagePalette.burntAmber : UsagePalette.mineralTeal)
                    .frame(width: 6, height: 6)
                Text(model.isRefreshing ? "Refreshing local data" : "Private · local files only")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Let the content surface fill the native split-view sidebar.
            // The system sidebar owns the only visible outer outline.
            .background(UsagePalette.slateGlass.opacity(0.74))
        }
    }

    private func projectButton(name: String, path: String?, credits: Double?) -> some View {
        let selected = model.selectedProjectPath == path
        return Button {
            model.selectedProjectPath = path
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? UsagePalette.accent(for: model.selectedProvider) : Color.clear)
                    .frame(width: 3, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(selected ? UsagePalette.porcelain : UsagePalette.secondaryText)
                        .lineLimit(1)
                    if let credits {
                        Text("\(UsageFormat.credits(credits)) cr")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(UsagePalette.secondaryText.opacity(0.75))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? UsagePalette.accent(for: model.selectedProvider).opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path ?? "Show all projects")
    }

    @ViewBuilder
    private var mainContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The ledger can contain many rows. A lazy parent estimates its height until the
                // ledger reaches the viewport, which makes AppKit revise the scrollbar thumb while
                // someone is scrolling. The dashboard itself has only a small fixed set of panels,
                // so a regular stack gives the scroll view its full content height up front.
                VStack(alignment: .leading, spacing: 18) {
                    studioHeader
                        .id(ScrollTarget.top)

                    if case let .failed(message) = model.loadState {
                        failureBanner(message)
                    }

                    summaryCards

                    limitsAndChart

                    ModelCostBars(summaries: model.modelSummaries(), provider: model.selectedProvider)
                        .usagePanel()

                    ProjectCreditChart(
                        series: model.projectCreditSeries(),
                        provider: model.selectedProvider,
                        range: model.selectedRange,
                        historicalDay: model.selectedHistoricalDay
                    )
                    .usagePanel()

                    UsageLedgerTable(rows: model.dailyRows(), provider: model.selectedProvider)
                        .usagePanel(padding: 0)
                        .id(ScrollTarget.ledger)
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(UsagePalette.nightInk)
            .onAppear { scrollToLedgerIfNeeded(proxy) }
            .onChange(of: model.lastUpdated) { _, _ in scrollToLedgerIfNeeded(proxy) }
            .onChange(of: model.selectedProjectPath) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.selectedProvider) { _, _ in scrollToTop(proxy) }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(ScrollTarget.top, anchor: .top)
        }
    }

    private func scrollToLedgerIfNeeded(_ proxy: ScrollViewProxy) {
        guard showLedgerForQA else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(ScrollTarget.ledger, anchor: .top)
        }
    }

    private var studioHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedProjectPath == nil ? "Usage Studio" : model.projects.first { $0.path == model.selectedProjectPath }?.name ?? "Usage Studio")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                Text("\(model.selectedProvider.displayName) · API-equivalent analytics")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }
            Spacer()

            Picker(
                "Time range",
                selection: Binding(
                    get: { model.selectedRange },
                    set: { model.selectRange($0) }
                )
            ) {
                ForEach(UsageTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 270)

            if let day = model.selectedHistoricalDay {
                Button {
                    model.clearHistoricalDay()
                } label: {
                    Label("Latest", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(UsagePalette.secondaryAccent(for: model.selectedProvider))
                .help("Return from \(day.formatted(date: .long, time: .omitted)) to the latest rolling day")
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(UsagePalette.accent(for: model.selectedProvider))
            .disabled(model.isRefreshing)
        }
    }

    private var summaryCards: some View {
        let credits = model.totalCredits()
        let dollars = model.totalUSD()
        let tokens = model.totalTokens()
        let runway = model.headlineRemaining.map {
            "\(model.headlineConfidence == .estimated ? "~" : "")\(UsageFormat.percentage($0, precision: model.studioPercentagePrecision))"
        } ?? "—"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                SummaryMetric(title: "Runway", value: runway, note: model.headlineSubtitle, accent: UsagePalette.accent(for: model.selectedProvider))
                SummaryMetric(title: "Credits", value: UsageFormat.credits(credits), note: "1 credit = $0.01", accent: UsagePalette.secondaryAccent(for: model.selectedProvider))
                SummaryMetric(title: "API equivalent", value: UsageFormat.dollars(dollars), note: "Estimated, not billed", accent: UsagePalette.mineralTeal)
                SummaryMetric(title: "Tokens", value: UsageFormat.integer(tokens), note: selectedPeriodNote, accent: UsagePalette.porcelain)
            }
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    SummaryMetric(title: "Runway", value: runway, note: model.headlineSubtitle, accent: UsagePalette.accent(for: model.selectedProvider))
                    SummaryMetric(title: "Credits", value: UsageFormat.credits(credits), note: "1 credit = $0.01", accent: UsagePalette.secondaryAccent(for: model.selectedProvider))
                }
                HStack(spacing: 12) {
                    SummaryMetric(title: "API equivalent", value: UsageFormat.dollars(dollars), note: "Estimated, not billed", accent: UsagePalette.mineralTeal)
                    SummaryMetric(title: "Tokens", value: UsageFormat.integer(tokens), note: selectedPeriodNote, accent: UsagePalette.porcelain)
                }
            }
        }
    }

    private var limitsAndChart: some View {
        let limits = model.limits(for: model.selectedProvider)
        let points = model.chartPoints()
        let resets = model.visibleResets()
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    if limits.isEmpty {
                        EmptyLimitNotice(provider: model.selectedProvider)
                    } else {
                        ForEach(limits) { bucket in
                            LimitBucketCard(
                                bucket: bucket,
                                provider: model.selectedProvider,
                                compact: false,
                                percentagePrecision: model.studioPercentagePrecision
                            )
                        }
                    }
                }
                .frame(width: 320)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CREDIT FLOW")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(UsagePalette.secondaryText)
                            Text(creditFlowTitle)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(UsagePalette.porcelain)
                            Text(creditFlowSubtitle)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(UsagePalette.secondaryText)
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            if model.selectedRange == .fiveHours || model.selectedRange == .oneDay {
                                resetLegend(color: UsagePalette.porcelain.opacity(0.55), label: "Session reset")
                            } else {
                                resetLegend(color: UsagePalette.mineralTeal, label: "Weekly reset")
                            }
                            if resets.contains(where: \.isSparkModelReset) {
                                resetLegend(color: UsagePalette.burntAmber, label: "Spark reset")
                            }
                            if resets.contains(where: { $0.confidence == .estimated }) {
                                Text("Dashed = estimated")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(UsagePalette.secondaryText)
                            }
                        }
                    }

                    if points.isEmpty || points.allSatisfy({ $0.credits == 0 }) {
                        ContentUnavailableView(
                            "No usage in this range",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Choose a longer range or another project.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        UsageAreaChart(
                            points: points,
                            resets: resets,
                            provider: model.selectedProvider,
                            compact: false,
                            onDaySelected: { model.selectHistoricalDay($0) }
                        )
                        .frame(minHeight: 280)
                    }
                }
                .usagePanel()
            }
        }
    }

    private var selectedPeriodNote: String {
        if let day = model.selectedHistoricalDay {
            return day.formatted(.dateTime.day().month(.abbreviated).year())
        }
        return model.selectedRange.rawValue + " selected"
    }

    private var creditFlowTitle: String {
        if let day = model.selectedHistoricalDay {
            return "Usage on \(day.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
        return "Usage by \(model.selectedRange == .fiveHours ? "hour" : model.selectedRange == .oneDay ? "two-hour block" : "day")"
    }

    private var creditFlowSubtitle: String {
        if model.selectedHistoricalDay != nil {
            return "Two-hour breakdown · Latest returns to rolling 1d"
        }
        if model.selectedRange == .sevenDays || model.selectedRange == .thirtyDays {
            return "Click a date to inspect its 1d detail"
        }
        return "Click a point to inspect its calendar day"
    }

    private func resetLegend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 1, height: 10)
            Text(label)
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(UsagePalette.secondaryText)
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(UsagePalette.burntAmber)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(UsagePalette.porcelain)
            Spacer()
            Button("Try again") { Task { await model.refresh() } }
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(UsagePalette.burntAmber.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(UsagePalette.burntAmber.opacity(0.25)))
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String
    let note: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(UsagePalette.secondaryText)
            Text(value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(UsagePalette.porcelain)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 5) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text(note)
                    .lineLimit(1)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(UsagePalette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .usagePanel(padding: 16)
    }
}

private struct ModelCostBars: View {
    let summaries: [ModelCostSummary]
    let provider: AIProvider
    @State private var hoveredModel: String?

    var maximum: Double { max(0.01, summaries.map(\.apiEquivalentUSD).max() ?? 0.01) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MODEL API EQUIVALENT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(UsagePalette.secondaryText)
                    Text("Cost by model")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(UsagePalette.porcelain)
                }
                Spacer()
                Text("Hover a bar for USD")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }

            if summaries.isEmpty {
                Text("No model usage in this range.")
                    .font(.system(size: 11))
                    .foregroundStyle(UsagePalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ForEach(Array(summaries.prefix(10).enumerated()), id: \.element.id) { index, summary in
                    HStack(spacing: 12) {
                        Text(summary.model)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(UsagePalette.porcelain)
                            .lineLimit(1)
                            .frame(width: 190, alignment: .leading)

                        GeometryReader { geometry in
                            let fraction = summary.apiEquivalentUSD / maximum
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.055))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                UsagePalette.accent(for: provider).opacity(0.5),
                                                index == 0
                                                    ? UsagePalette.accent(for: provider)
                                                    : UsagePalette.secondaryAccent(for: provider),
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(5, geometry.size.width * fraction))
                            }
                        }
                        .frame(height: 9)

                        Text(
                            hoveredModel == summary.model
                                ? UsageFormat.dollars(summary.apiEquivalentUSD)
                                : "\(UsageFormat.credits(summary.credits)) cr"
                        )
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(hoveredModel == summary.model ? UsagePalette.mineralTeal : UsagePalette.secondaryText)
                        .frame(width: 92, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onHover { hovering in hoveredModel = hovering ? summary.model : nil }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(summary.model), \(UsageFormat.dollars(summary.apiEquivalentUSD)) API equivalent")
                }
            }
        }
    }
}

private struct UsageLedgerTable: View {
    let rows: [DailyUsageRow]
    let provider: AIProvider
    @State private var visibleDayCount: Int

    init(rows: [DailyUsageRow], provider: AIProvider) {
        self.rows = rows
        self.provider = provider
        _visibleDayCount = State(
            initialValue: UsageLedgerDisclosure.initialVisibleDayCount(
                for: UsageLedgerDisclosure.dayGroups(in: rows)
            )
        )
    }

    private var dayGroups: [UsageLedgerDayGroup] {
        UsageLedgerDisclosure.dayGroups(in: rows)
    }

    private var visibleDayGroups: [UsageLedgerDayGroup] {
        Array(dayGroups.prefix(visibleDayCount))
    }

    private var hasMoreDays: Bool {
        visibleDayCount < dayGroups.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("USAGE LEDGER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(UsagePalette.secondaryText)
                Text("Daily model and project totals")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
            }
            .padding(18)

            Divider().overlay(UsagePalette.hairline)
            ledgerRow(date: "Date", model: "Model", project: "Project", input: "Input", output: "Output", credits: "Credits", header: true)

            if rows.isEmpty {
                Text("No usage rows in this range.")
                    .font(.system(size: 11))
                    .foregroundStyle(UsagePalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ForEach(visibleDayGroups) { day in
                    ForEach(day.rows) { row in
                        Divider().overlay(UsagePalette.hairline.opacity(0.7))
                        ledgerRow(
                            date: row.date.formatted(.dateTime.month(.abbreviated).day()),
                            model: row.model,
                            project: row.projectName,
                            input: UsageFormat.integer(row.tokens.input + row.tokens.cachedInput + row.tokens.cacheWrite),
                            output: UsageFormat.integer(row.tokens.output),
                            credits: "\(row.isEstimate ? "~" : "")\(UsageFormat.credits(row.credits))",
                            header: false
                        )
                    }
                }

                if hasMoreDays {
                    Divider().overlay(UsagePalette.hairline.opacity(0.7))
                    Button {
                        visibleDayCount += 1
                    } label: {
                        Label("Show next day", systemImage: "chevron.down")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UsagePalette.accent(for: provider))
                    .contentShape(Rectangle())
                    .accessibilityHint("Reveals the next day of usage records")
                }
            }
        }
        .onChange(of: rows.map(\.id)) { _, _ in
            visibleDayCount = UsageLedgerDisclosure.initialVisibleDayCount(for: dayGroups)
        }
    }

    private func ledgerRow(
        date: String,
        model: String,
        project: String,
        input: String,
        output: String,
        credits: String,
        header: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Text(date).frame(width: 72, alignment: .leading)
            Text(model).frame(minWidth: 150, maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(project).frame(minWidth: 130, maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(input).frame(width: 76, alignment: .trailing)
            Text(output).frame(width: 76, alignment: .trailing)
            Text(credits).frame(width: 74, alignment: .trailing)
        }
        .font(.system(size: header ? 9 : 10, weight: header ? .bold : .medium, design: .monospaced))
        .foregroundStyle(header ? UsagePalette.secondaryText : UsagePalette.porcelain.opacity(0.88))
        .padding(.horizontal, 18)
        .padding(.vertical, header ? 10 : 12)
    }
}

struct UsageLedgerDayGroup: Identifiable {
    let date: Date
    let rows: [DailyUsageRow]

    var id: Date { date }
}

enum UsageLedgerDisclosure {
    static func dayGroups(
        in rows: [DailyUsageRow],
        calendar: Calendar = .current
    ) -> [UsageLedgerDayGroup] {
        Dictionary(grouping: rows) { row in
            calendar.startOfDay(for: row.date)
        }
        .map { date, rows in
            UsageLedgerDayGroup(
                date: date,
                rows: rows.sorted { $0.apiEquivalentUSD > $1.apiEquivalentUSD }
            )
        }
        .sorted { $0.date > $1.date }
    }

    static func initialVisibleDayCount(
        for dayGroups: [UsageLedgerDayGroup],
        minimumRows: Int = 10
    ) -> Int {
        guard let firstDay = dayGroups.first else { return 0 }
        return firstDay.rows.count < minimumRows && dayGroups.count > 1 ? 2 : 1
    }
}
