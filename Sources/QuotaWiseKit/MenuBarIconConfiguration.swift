import Combine
import Foundation

enum MenuBarIconDisplay: String, CaseIterable, Codable, Identifiable, Sendable {
    case graph
    case bar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .graph: "Graph"
        case .bar: "Bar"
        }
    }
}

enum MenuBarIconPeriod: String, CaseIterable, Codable, Identifiable, Sendable {
    case fiveHours
    case week

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveHours: "5h"
        case .week: "Week"
        }
    }

    var usageRange: UsageTimeRange {
        switch self {
        case .fiveHours: .fiveHours
        case .week: .sevenDays
        }
    }

    var targetDurationMinutes: Int {
        switch self {
        case .fiveHours: 300
        case .week: 10_080
        }
    }
}

enum MenuBarIconColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "auto"
    case providerAccent

    var id: String { rawValue }

    func displayName(for provider: AIProvider) -> String {
        switch self {
        case .automatic:
            "Auto"
        case .providerAccent:
            provider == .codex ? "Blue" : "Yellow"
        }
    }

    func hex(for provider: AIProvider) -> UInt32 {
        switch self {
        case .automatic:
            0xFFFFFF
        case .providerAccent:
            provider == .codex ? 0x5B8CFF : 0xFFCB78
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "auto", "white":
            self = .automatic
        case "providerAccent":
            self = .providerAccent
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown menu bar icon colour"
            )
        }
    }
}

struct MenuBarIconLayer: Codable, Equatable, Sendable {
    var provider: AIProvider
    var display: MenuBarIconDisplay
    var period: MenuBarIconPeriod
    var color: MenuBarIconColor
    /// Only meaningful when `display == .bar`: shows the remaining percentage as a number to the
    /// left of the bar, shrinking the bar to make room.
    var showPercentage: Bool

    init(
        provider: AIProvider,
        display: MenuBarIconDisplay,
        period: MenuBarIconPeriod,
        color: MenuBarIconColor = .automatic,
        showPercentage: Bool = false
    ) {
        self.provider = provider
        self.display = display
        self.period = period
        self.color = color
        self.showPercentage = showPercentage
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case display
        case period
        case color
        case showPercentage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AIProvider.self, forKey: .provider)
        display = try container.decode(MenuBarIconDisplay.self, forKey: .display)
        period = try container.decode(MenuBarIconPeriod.self, forKey: .period)
        color = try container.decodeIfPresent(MenuBarIconColor.self, forKey: .color) ?? .automatic
        showPercentage = try container.decodeIfPresent(Bool.self, forKey: .showPercentage) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(display, forKey: .display)
        try container.encode(period, forKey: .period)
        try container.encode(color, forKey: .color)
        try container.encode(showPercentage, forKey: .showPercentage)
    }

    static let defaultTop = MenuBarIconLayer(
        provider: .codex,
        display: .graph,
        period: .week
    )

    static let defaultBottom = MenuBarIconLayer(
        provider: .codex,
        display: .bar,
        period: .week
    )
}

struct MenuBarIconConfiguration: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var top: MenuBarIconLayer
    var bottom: MenuBarIconLayer

    static let `default` = MenuBarIconConfiguration(
        isEnabled: true,
        top: .defaultTop,
        bottom: .defaultBottom
    )
}

@MainActor
final class MenuBarIconPreferences: ObservableObject {
    static let shared = MenuBarIconPreferences()

    @Published var configuration: MenuBarIconConfiguration {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "menu-bar-icon-configuration-v1"
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(MenuBarIconConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}
