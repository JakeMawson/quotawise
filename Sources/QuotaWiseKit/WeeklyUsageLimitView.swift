import Foundation
import SwiftUI

struct WeeklyUsageLimitControl: View {
    let provider: AIProvider
    let limits: [WeeklyUsageLimit]
    let isPaused: Bool
    let onEdit: (WeeklyUsageLimit) -> Void
    let onAdd: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            if isPaused {
                pausedRow
            }

            if limits.isEmpty {
                emptyRow
            } else {
                ForEach(Array(limits.enumerated()), id: \.element.id) { index, limit in
                    HStack(spacing: 9) {
                        limitPill(limit)
                        circleButton(systemImage: "pencil", help: "Edit \(provider.displayName) limit") {
                            onEdit(limit)
                        }
                        .accessibilityLabel("Edit \(provider.displayName) weekly usage limit at \(limit.remainingPercent) percent remaining")

                        if index == limits.count - 1 {
                            circleButton(systemImage: "plus", help: "Add another \(provider.displayName) limit") {
                                onAdd()
                            }
                            .accessibilityLabel("Add another \(provider.displayName) weekly usage limit")
                        }
                    }
                }
            }
        }
    }

    private var pausedRow: some View {
        Button(action: onResume) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Paused · click to resume")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer(minLength: 8)
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UsagePalette.burntAmber)
            }
            .foregroundStyle(UsagePalette.porcelain)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.065))
                    .overlay(Capsule().stroke(UsagePalette.burntAmber.opacity(0.48), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(provider.displayName) tasks paused. Click to resume.")
    }

    private var emptyRow: some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .font(.system(size: 12, weight: .semibold))
                Text("Set limit")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer(minLength: 8)
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(UsagePalette.porcelain)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.065))
                    .overlay(Capsule().stroke(UsagePalette.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set weekly usage limit")
    }

    private func limitPill(_ limit: WeeklyUsageLimit) -> some View {
        Button(action: { onEdit(limit) }) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 12, weight: .semibold))
                Text("Set for \(limit.remainingPercent)% remaining")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer(minLength: 8)
                Image(systemName: limit.severity.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UsagePalette.accent(for: provider))
            }
            .foregroundStyle(UsagePalette.secondaryText)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.045))
                    .overlay(Capsule().stroke(UsagePalette.accent(for: provider).opacity(0.26), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Limit set for \(limit.remainingPercent) percent remaining")
    }

    private func circleButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UsagePalette.porcelain)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.065))
                        .overlay(Circle().stroke(UsagePalette.hairline))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct WeeklyUsageLimitEditor: View {
    let provider: AIProvider
    let existingLimit: WeeklyUsageLimit?
    let onSave: (WeeklyUsageLimit) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var remainingPercent: Int
    @State private var severity: WeeklyLimitSeverity

    init(
        provider: AIProvider,
        existingLimit: WeeklyUsageLimit?,
        onSave: @escaping (WeeklyUsageLimit) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.provider = provider
        self.existingLimit = existingLimit
        self.onSave = onSave
        self.onDelete = onDelete
        _remainingPercent = State(initialValue: existingLimit?.remainingPercent ?? 20)
        _severity = State(initialValue: existingLimit?.severity ?? .notification)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                header
                thresholdSection
                severitySection
                experimentalNote
            }
            .padding(22)

            Divider().overlay(UsagePalette.hairline)

            footer
                .padding(16)
        }
        .frame(width: 408)
        .background(UsagePalette.nightInk)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(UsagePalette.accent(for: provider).opacity(0.13))
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(UsagePalette.accent(for: provider))
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(existingLimit == nil ? "Set weekly usage limit" : "Edit weekly usage limit")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                Text(provider.displayName)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(UsagePalette.accent(for: provider))
            }

            Spacer()

            Text("EXPERIMENTAL")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(UsagePalette.burntAmber)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(UsagePalette.burntAmber.opacity(0.09)))
                .overlay(Capsule().stroke(UsagePalette.burntAmber.opacity(0.24)))
        }
    }

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TRIGGER AT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(UsagePalette.secondaryText)
                Text("\(remainingPercent)% remaining")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.porcelain)
                    .contentTransition(.numericText())
            }

            Slider(
                value: Binding(
                    get: { Double(remainingPercent) },
                    set: { remainingPercent = Int($0.rounded()) }
                ),
                in: 1...100,
                step: 1
            )
            .tint(UsagePalette.accent(for: provider))
            .accessibilityLabel("Weekly usage remaining trigger")
            .accessibilityValue("\(remainingPercent) percent remaining")

            HStack {
                Text("1%")
                Spacer()
                Text("Weekly usage remaining")
                Spacer()
                Text("100%")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(UsagePalette.secondaryText)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(UsagePalette.slateGlass)
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(UsagePalette.hairline))
        )
    }

    private var severitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHEN IT REACHES THE LIMIT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(UsagePalette.secondaryText)

            VStack(spacing: 7) {
                ForEach(WeeklyLimitSeverity.allCases) { option in
                    severityRow(option)
                }
            }
        }
    }

    private func severityRow(_ option: WeeklyLimitSeverity) -> some View {
        let selected = severity == option
        let color = option == .quitProvider ? UsagePalette.danger : UsagePalette.accent(for: provider)
        return Button {
            severity = option
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(selected ? color.opacity(0.16) : Color.white.opacity(0.045))
                    Image(systemName: option.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? color : UsagePalette.secondaryText)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title(for: provider))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(UsagePalette.porcelain)
                    Text(option.detail(for: provider))
                        .font(.system(size: 9))
                        .foregroundStyle(UsagePalette.secondaryText)
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? color : UsagePalette.secondaryText.opacity(0.55))
            }
            .padding(.horizontal, 11)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? color.opacity(0.075) : Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(selected ? color.opacity(0.38) : UsagePalette.hairline)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title(for: provider))
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var experimentalNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "flask")
                .foregroundStyle(UsagePalette.burntAmber)
            Text("This is experimental. Keep QuotaWise running so it can watch the provider's weekly usage and trigger this limit.")
                .font(.system(size: 10))
                .foregroundStyle(UsagePalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if existingLimit != nil {
                Button("Delete limit", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(UsagePalette.danger)
            }

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(UsagePalette.secondaryText)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .keyboardShortcut(.cancelAction)

            Button {
                onSave(
                    WeeklyUsageLimit(
                        id: existingLimit?.id ?? UUID(),
                        provider: provider,
                        remainingPercent: remainingPercent,
                        severity: severity
                    )
                )
                dismiss()
            } label: {
                Text(existingLimit == nil ? "Set limit" : "Save limit")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.nightInk)
                    .padding(.horizontal, 15)
                    .frame(height: 34)
                    .background(Capsule().fill(UsagePalette.accent(for: provider)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }
}
