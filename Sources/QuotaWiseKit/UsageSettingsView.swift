import SwiftUI

public struct UsageSettingsView: View {
    @ObservedObject private var model: UsageApplicationModel
    @ObservedObject private var iconPreferences: MenuBarIconPreferences

    public init(model: UsageApplicationModel) {
        self.init(model: model, iconPreferences: .shared)
    }

    init(model: UsageApplicationModel, iconPreferences: MenuBarIconPreferences) {
        self.model = model
        self.iconPreferences = iconPreferences
    }

    public var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    )
                )
            }

            /*
             Codex returns usedPercent as an int32, so decimal-place choices
             cannot reveal any additional precision. Keep this control
             commented out for now while quota readings are forced to whole
             numbers.
             Section("Usage Studio") {
                 StudioPercentagePrecisionMenu(
                     selection: Binding(
                         get: { model.studioPercentagePrecision },
                         set: { model.studioPercentagePrecision = $0 }
                     )
                 )

                 Text("Choose how many decimal places to show in quota readings.")
                     .font(.callout)
                     .foregroundStyle(.secondary)
             }
             */

            Section("Menu Bar") {
                MenuBarIconSettingsContent(
                    model: model,
                    preferences: iconPreferences
                )
            }

            Section("Notifications") {
                QuotaResetNotificationSettingsContent(
                    mode: Binding(
                        get: { model.quotaResetNotificationMode },
                        set: { model.setQuotaResetNotificationMode($0) }
                    )
                )
            }

            Section("Data") {
                LabeledContent("Codex history", value: "~/.codex/sessions")
                LabeledContent("Claude history", value: "~/.claude/projects")
                LabeledContent("Refresh cadence", value: "Limits 1 min · history 15 min")
                Button("Refresh now") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing)
            }

            Section("Estimates") {
                LabeledContent("Credit value", value: "1 credit = USD $0.01")
                Text("API-equivalent prices estimate what the recorded tokens would cost through each provider's API. They are not subscription charges or an invoice. Claude limit percentages are inferred from local history unless an exact reset event is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("QuotaWise reads local usage metadata and the local Codex App Server. It does not upload prompts, responses, tokens, project names, or account data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
    }
}

struct StudioPercentagePrecisionMenu: View {
    @Binding var selection: PercentageDisplayPrecision

    var body: some View {
        Menu {
            ForEach(PercentageDisplayPrecision.allCases) { precision in
                Button {
                    selection = precision
                } label: {
                    if precision == selection {
                        Label(precision.displayName, systemImage: "checkmark")
                    } else {
                        Text(precision.displayName)
                    }
                }
            }
        } label: {
            StudioPercentagePrecisionMenuLabel(selection: selection)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose how many decimal places to show on the main quota readings")
        .accessibilityLabel("Percentage precision")
        .accessibilityValue(selection.displayName)
    }
}

struct StudioPercentagePrecisionMenuLabel: View {
    let selection: PercentageDisplayPrecision

    var body: some View {
        HStack(spacing: 5) {
            Text("Percent")
            Text("·")
                .foregroundStyle(UsagePalette.secondaryText)
            Text(selection.displayName)
                .foregroundStyle(UsagePalette.porcelain)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(UsagePalette.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(UsagePalette.hairline, lineWidth: 1)
                )
        )
    }
}

struct QuotaResetNotificationSettingsContent: View {
    @Binding var mode: QuotaResetNotificationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: mode == .persistentNotification ? "bell.badge.fill" : "bell")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mode.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify when quota resets")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("Watches each provider's tracked quota windows for a return to 100% remaining.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 2) {
                ForEach(QuotaResetNotificationMode.allCases) { option in
                    let isSelected = mode == option
                    Button {
                        mode = option
                    } label: {
                        Text(option.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.32) : Color.clear, lineWidth: 1)
                    )
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )

            Text(mode.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

struct MenuBarIconSettingsContent: View {
    @ObservedObject var model: UsageApplicationModel
    @ObservedObject var preferences: MenuBarIconPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Use live usage icon", isOn: enabledBinding)
                        .toggleStyle(StatusIconSwitchStyle())
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("Stack any two Codex or Claude Code signals in the menu bar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                StatusIconSettingsPreview(
                    model: model,
                    configuration: preferences.configuration
                )
            }

            VStack(spacing: 12) {
                StatusIconLayerEditor(
                    title: "TOP",
                    layer: layerBinding(\.top)
                )
                StatusIconLayerEditor(
                    title: "BOTTOM",
                    layer: layerBinding(\.bottom)
                )
            }
            .disabled(!preferences.configuration.isEnabled)
            .opacity(preferences.configuration.isEnabled ? 1 : 0.6)

            Text("Graphs plot local usage during the selected 5h or week and scale to that period's observed low and high. Bars show the remaining amount in the matching limit window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { preferences.configuration.isEnabled },
            set: { preferences.configuration.isEnabled = $0 }
        )
    }

    private func layerBinding(
        _ keyPath: WritableKeyPath<MenuBarIconConfiguration, MenuBarIconLayer>
    ) -> Binding<MenuBarIconLayer> {
        Binding(
            get: { preferences.configuration[keyPath: keyPath] },
            set: { preferences.configuration[keyPath: keyPath] = $0 }
        )
    }
}

private struct StatusIconSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                configuration.label
                    .foregroundStyle(Color.primary)

                ZStack {
                    Capsule()
                        .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.15))
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                        .padding(2)
                        .offset(x: configuration.isOn ? 8 : -8)
                }
                .frame(width: 36, height: 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StatusIconLayerEditor: View {
    let title: String
    @Binding var layer: MenuBarIconLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                Spacer()
                Text("\(layer.provider.displayName) · \(layer.display.displayName) · \(layer.period.displayName) · \(layer.color.displayName(for: layer.provider))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            StatusIconChoiceRow(
                title: "Provider",
                values: AIProvider.allCases,
                selection: $layer.provider,
                label: \AIProvider.displayName
            )
            StatusIconChoiceRow(
                title: "Visual",
                values: MenuBarIconDisplay.allCases,
                selection: $layer.display,
                label: \MenuBarIconDisplay.displayName
            )
            StatusIconChoiceRow(
                title: "Period",
                values: MenuBarIconPeriod.allCases,
                selection: $layer.period,
                label: \MenuBarIconPeriod.displayName
            )
            if layer.display == .bar {
                StatusIconPercentageRow(showPercentage: $layer.showPercentage)
            }
            StatusIconColorRow(layer: $layer)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

private struct StatusIconPercentageRow: View {
    @Binding var showPercentage: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("Show %")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            HStack(spacing: 2) {
                ForEach([false, true], id: \.self) { value in
                    let isSelected = value == showPercentage
                    Button {
                        showPercentage = value
                    } label: {
                        Text(value ? "On" : "Off")
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.32) : Color.clear, lineWidth: 1)
                    )
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
        }
    }
}

private struct StatusIconColorRow: View {
    @Binding var layer: MenuBarIconLayer

    var body: some View {
        HStack(spacing: 12) {
            Text("Color")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(MenuBarIconColor.allCases) { choice in
                    let isSelected = choice == layer.color
                    let name = choice.displayName(for: layer.provider)
                    let swatch = choice == .automatic
                        ? Color.primary
                        : Color(hex: choice.hex(for: layer.provider))
                    let selectionTint = choice == .automatic ? Color.primary : swatch
                    Button {
                        layer.color = choice
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(swatch)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.primary.opacity(0.22), lineWidth: 0.75))
                            Text(name)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .rounded))
                        }
                        .foregroundStyle(isSelected ? selectionTint : Color.primary.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? selectionTint.opacity(choice == .automatic ? 0.08 : 0.14) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isSelected ? selectionTint.opacity(0.38) : Color.clear, lineWidth: 1)
                    )
                    .accessibilityLabel("\(name) color")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
        }
    }
}

private struct StatusIconChoiceRow<Value: Hashable & Identifiable>: View {
    let title: String
    let values: [Value]
    @Binding var selection: Value
    let label: KeyPath<Value, String>

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(values) { value in
                    let isSelected = value == selection
                    Button {
                        selection = value
                    } label: {
                        Text(value[keyPath: label])
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.32) : Color.clear, lineWidth: 1)
                    )
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
        }
    }
}

private struct StatusIconSettingsPreview: View {
    let model: UsageApplicationModel
    let configuration: MenuBarIconConfiguration

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 9) {
                Circle()
                    .fill(Color.white.opacity(0.42))
                    .frame(width: 4, height: 4)
                Group {
                    if configuration.isEnabled {
                        MenuBarUsageGlyph(
                            top: model.menuBarIconSnapshot(for: configuration.top),
                            bottom: model.menuBarIconSnapshot(for: configuration.bottom)
                        )
                    } else {
                        Label(model.menuBarLabel, systemImage: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
            }
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(UsagePalette.nightInk)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )

            Text("LIVE PREVIEW")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live menu bar icon preview")
    }
}
