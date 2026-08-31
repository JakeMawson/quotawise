import AppKit
import SwiftUI

struct EditingLimitTarget: Identifiable {
    let provider: AIProvider
    let existingLimit: WeeklyUsageLimit?
    var id: String { existingLimit?.id.uuidString ?? "new-\(provider.rawValue)" }
}

public struct MenuBarPanel: View {
    @ObservedObject private var model: UsageApplicationModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingLimitTarget: EditingLimitTarget?
    @State private var notificationAuthorizationState: NotificationAuthorizationState = .allowed
    @Environment(\.dismiss) private var dismiss
    private let onOpenStudio: (() -> Void)?

    public init(model: UsageApplicationModel, onOpenStudio: (() -> Void)? = nil) {
        self.model = model
        self.onOpenStudio = onOpenStudio
        _editingLimitTarget = State(
            initialValue: CommandLine.arguments.contains("--qa-limit-modal")
                ? EditingLimitTarget(
                    provider: model.selectedProvider,
                    existingLimit: model.weeklyUsageLimits(for: model.selectedProvider).first
                )
                : nil
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                ProviderSlider(selection: $model.selectedProvider)

                VStack(spacing: 8) {
                    if model.isIndexingHistory {
                        indexingNotice
                    }

                    runwayHeader
                        .providerContentAnimation(enabled: !reduceMotion)
                }

                limitSection

                if !model.isIndexingHistory {
                    historySection
                        .providerContentAnimation(enabled: !reduceMotion)
                }

                usageLimitControls
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().overlay(UsagePalette.hairline)

            footer
                .padding(14)
        }
        .frame(width: 392)
        .background(UsagePalette.nightInk)
        .preferredColorScheme(.dark)
        .task {
            await model.refreshIfNeeded()
            notificationAuthorizationState = await model.notificationAuthorizationState()
        }
        .sheet(item: $editingLimitTarget, onDismiss: {
            editingLimitTarget = nil
        }) { target in
            WeeklyUsageLimitEditor(
                provider: target.provider,
                existingLimit: target.existingLimit,
                onSave: { model.setWeeklyUsageLimit($0) },
                onDelete: {
                    if let id = target.existingLimit?.id {
                        model.deleteWeeklyUsageLimit(id: id, for: target.provider)
                    }
                }
            )
        }
    }

    private var usageLimitControls: some View {
        let limits = model.weeklyUsageLimits(for: model.selectedProvider)
        return VStack(alignment: .leading, spacing: 7) {
            if !limits.isEmpty, notificationAuthorizationState != .allowed {
                Text("NOTIFICATIONS NOT ENABLED")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundStyle(UsagePalette.burntAmber)
                    .padding(.horizontal, 3)
                    .accessibilityLabel("Notifications are not enabled")
            }

            WeeklyUsageLimitControl(
                provider: model.selectedProvider,
                limits: limits,
                isPaused: model.isProviderPaused(model.selectedProvider),
                onEdit: { limit in
                    editingLimitTarget = EditingLimitTarget(provider: model.selectedProvider, existingLimit: limit)
                },
                onAdd: {
                    editingLimitTarget = EditingLimitTarget(provider: model.selectedProvider, existingLimit: nil)
                },
                onResume: {
                    model.resumePausedTasks(for: model.selectedProvider)
                }
            )
        }
    }

    private var runwayHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.headlineRemaining.map {
                    "\(model.headlineConfidence == .estimated ? "~" : "")\(UsageFormat.percentage($0, precision: model.studioPercentagePrecision))"
                } ?? "—")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                    .contentTransition(.numericText())
                    .animation(providerTransitionAnimation, value: model.selectedProvider)
                Text("RUNWAY REMAINING")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(UsagePalette.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                ConfidencePill(
                    confidence: model.headlineConfidence,
                    label: model.headlineConfidenceLabel
                )
                Text(model.headlineSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(UsagePalette.secondaryText)
            }
        }
    }

    private var indexingNotice: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(UsagePalette.burntAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text("INDEXING LOCAL HISTORY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(UsagePalette.burntAmber)
                Text("At least \(model.indexingFileCount ?? 0) session files — building a compact local index")
                    .font(.system(size: 10))
                    .foregroundStyle(UsagePalette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(UsagePalette.burntAmber.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(UsagePalette.burntAmber.opacity(0.28)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Indexing local history. Building a compact usage index.")
    }

    @ViewBuilder
    private var limitSection: some View {
        let limits = model.limits(for: model.selectedProvider)
        if limits.isEmpty {
            EmptyLimitNotice(provider: model.selectedProvider)
        } else {
            VStack(spacing: 10) {
                ForEach(limits) { bucket in
                    LimitBucketCard(
                        bucket: bucket,
                        provider: model.selectedProvider,
                        compact: true,
                        percentagePrecision: model.studioPercentagePrecision
                    )
                }

                if model.selectedProvider == .codex,
                   !limits.flatMap(\.windows).contains(where: { ($0.durationMinutes ?? .max) <= 360 }) {
                    HStack(spacing: 7) {
                        Image(systemName: "minus.circle")
                        Text("No rolling 5-hour Codex limit is currently applied")
                        Spacer()
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private var historySection: some View {
        let points = model.chartPoints(
            provider: model.selectedProvider,
            range: .thirtyDays,
            projectPath: nil
        )
        let resets = model.visibleResets(provider: model.selectedProvider, range: .thirtyDays)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("30-DAY CREDIT FLOW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(UsagePalette.secondaryText)
                    Text("\(UsageFormat.credits(points.reduce(0) { $0 + $1.credits })) credits")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(UsagePalette.porcelain)
                        .contentTransition(.numericText())
                        .animation(providerTransitionAnimation, value: model.selectedProvider)
                }
                Spacer()
                if !resets.isEmpty {
                    let estimated = resets.contains(where: { $0.confidence == .estimated })
                    Label("\(estimated ? "~" : "")\(resets.count) weekly seam\(resets.count == 1 ? "" : "s")", systemImage: "line.3.horizontal.decrease")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(UsagePalette.mineralTeal)
                }
            }

            if points.allSatisfy({ $0.credits == 0 }) {
                HStack {
                    Spacer()
                    Text("No usage in this period")
                        .font(.system(size: 11))
                        .foregroundStyle(UsagePalette.secondaryText)
                    Spacer()
                }
                .frame(height: 92)
                .background(RoundedRectangle(cornerRadius: 10).fill(UsagePalette.slateGlass.opacity(0.55)))
            } else {
                UsageAreaChart(
                    points: points,
                    resets: resets,
                    provider: model.selectedProvider,
                    compact: true
                )
                .frame(height: 108)
                .animation(providerTransitionAnimation, value: model.selectedProvider)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(UsagePalette.slateGlass)
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(UsagePalette.hairline))
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: model.isRefreshing ? "arrow.trianglehead.2.clockwise.rotate.90" : "arrow.clockwise")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(UsagePalette.secondaryText)
            .background(Circle().fill(Color.white.opacity(0.055)))
            .disabled(model.isRefreshing)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(UsageFormat.relative(model.lastUpdated, relativeTo: timeline.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(UsagePalette.secondaryText)
            }

            Spacer()

            Button {
                if let onOpenStudio {
                    // `dismiss`/`openWindow` only have real implementations when
                    // this view is hosted inside a SwiftUI Scene. In production
                    // this panel is hosted by a bare NSHostingController (see
                    // AppDelegate.resetStatusPopoverContent), where those
                    // environment actions are no-ops, so the host supplies an
                    // AppKit-backed action instead.
                    onOpenStudio()
                } else {
                    dismiss()
                    DispatchQueue.main.async {
                        openWindow(id: "usage-studio")
                        DispatchQueue.main.async {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            guard let studioWindow = NSApplication.shared.windows.first(where: { $0.title.contains("Usage Studio") }) else {
                                return
                            }
                            studioWindow.makeKeyAndOrderFront(nil)
                            studioWindow.orderFrontRegardless()
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Open Usage Studio")
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(UsagePalette.nightInk)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Capsule().fill(UsagePalette.accent(for: model.selectedProvider)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var providerTransitionAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }
}

private extension View {
    /// Restores the panel's local numeric/chart transitions after the provider
    /// binding has deliberately disabled its enclosing layout transaction.
    /// This is applied only to fixed-height regions, so it cannot animate the
    /// Codex/Claude intrinsic-height difference that re-anchors the popover.
    @ViewBuilder
    func providerContentAnimation(enabled: Bool) -> some View {
        transaction { transaction in
            transaction.disablesAnimations = !enabled
        }
    }
}
