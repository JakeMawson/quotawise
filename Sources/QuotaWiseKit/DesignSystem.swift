import SwiftUI

enum UsagePalette {
    static let nightInk = Color(hex: 0x0B1017)
    static let slateGlass = Color(hex: 0x151D28)
    static let liftedSlate = Color(hex: 0x1B2532)
    static let porcelain = Color(hex: 0xF2F5F7)
    static let secondaryText = Color(hex: 0x98A6B7)
    static let hairline = Color.white.opacity(0.09)
    static let signalBlue = Color(hex: 0x5B8CFF)
    static let mineralTeal = Color(hex: 0x3CC8B4)
    static let burntAmber = Color(hex: 0xF2A43A)
    static let danger = Color(hex: 0xFF6B73)

    static func accent(for provider: AIProvider) -> Color {
        provider == .codex ? signalBlue : burntAmber
    }

    static func secondaryAccent(for provider: AIProvider) -> Color {
        provider == .codex ? mineralTeal : Color(hex: 0xFFCB78)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

struct UsagePanel: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(UsagePalette.slateGlass)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(UsagePalette.hairline, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func usagePanel(padding: CGFloat = 18) -> some View {
        modifier(UsagePanel(padding: padding))
    }
}

enum UsageFormat {
    static func integer(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func credits(_ value: Double) -> String {
        if value >= 10_000 { return value.formatted(.number.notation(.compactName).precision(.fractionLength(1))) }
        if value >= 100 { return value.formatted(.number.precision(.fractionLength(0))) }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 3 : 2)))
    }

    static func percentage(
        _ value: Double,
        precision: PercentageDisplayPrecision = .wholeNumber
    ) -> String {
        "\(value.formatted(.number.precision(.fractionLength(precision.fractionDigits))))%"
    }

    static func spokenPercentage(
        _ value: Double,
        precision: PercentageDisplayPrecision = .wholeNumber
    ) -> String {
        percentage(value, precision: precision).replacingOccurrences(of: "%", with: " percent")
    }

    static func reset(_ date: Date?) -> String {
        guard let date else { return "Reset time unavailable" }
        let now = Date()
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "Resets \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))"
    }

    static func relative(_ date: Date?, relativeTo now: Date = Date()) -> String {
        guard let date else { return "Not refreshed yet" }
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(date).rounded(.down)))
        if elapsedSeconds < 3_600 {
            return "\(elapsedSeconds) second\(elapsedSeconds == 1 ? "" : "s") ago"
        }

        let elapsedHours = elapsedSeconds / 3_600
        return "\(elapsedHours) hour\(elapsedHours == 1 ? "" : "s") ago"
    }
}
