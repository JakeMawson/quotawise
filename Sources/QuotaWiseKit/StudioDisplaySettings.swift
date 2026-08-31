import Foundation

enum PercentageDisplayPrecision: Int, CaseIterable, Codable, Identifiable, Sendable {
    case wholeNumber = 0
    case oneDecimal = 1
    case twoDecimals = 2

    var id: Int { rawValue }

    var fractionDigits: Int { rawValue }

    var displayName: String {
        switch self {
        case .wholeNumber: "Whole"
        case .oneDecimal: "1 dp"
        case .twoDecimals: "2 dp"
        }
    }
}

final class StudioDisplaySettingsStore {
    static let defaultKey = "studio-percentage-precision-v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = StudioDisplaySettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PercentageDisplayPrecision {
        guard let rawValue = defaults.object(forKey: key) as? Int else {
            return .wholeNumber
        }
        return PercentageDisplayPrecision(rawValue: rawValue) ?? .wholeNumber
    }

    func save(_ precision: PercentageDisplayPrecision) {
        defaults.set(precision.rawValue, forKey: key)
    }
}
