import Foundation

struct PricingRate: Sendable {
    let input: Double
    let cachedInput: Double
    let cacheWriteFiveMinute: Double
    let cacheWriteOneHour: Double
    let output: Double
    let sourceLabel: String
    let isFallback: Bool
}

enum PricingCatalog {
    static func rate(for provider: AIProvider, model: String, at date: Date = Date()) -> PricingRate {
        let normalized = model.lowercased()

        switch provider {
        case .codex:
            if normalized.contains("5.6-sol") || normalized == "gpt-5.6" {
                return openAI(5, cached: 0.5, output: 30, "GPT-5.6 Sol")
            }
            if normalized.contains("5.6-terra") {
                return openAI(2.5, cached: 0.25, output: 15, "GPT-5.6 Terra")
            }
            if normalized.contains("5.6-luna") {
                return openAI(1, cached: 0.1, output: 6, "GPT-5.6 Luna")
            }
            if normalized.contains("5.4-mini") {
                return openAI(0.75, cached: 0.075, output: 4.5, "GPT-5.4 mini")
            }
            if normalized.contains("5.4") {
                return openAI(2.5, cached: 0.25, output: 15, "GPT-5.4")
            }
            if normalized.contains("spark") || normalized.contains("bengalfox") {
                return PricingRate(
                    input: 1,
                    cachedInput: 0.1,
                    cacheWriteFiveMinute: 1.25,
                    cacheWriteOneHour: 1.25,
                    output: 6,
                    sourceLabel: "Spark mapped to GPT-5.6 Luna API-equivalent",
                    isFallback: true
                )
            }
            if normalized.contains("5.3") || normalized.contains("5.2") {
                return openAI(1.75, cached: 0.175, output: 14, "GPT-5.2/5.3 estimate", fallback: true)
            }
            return openAI(2.5, cached: 0.25, output: 15, "OpenAI fallback estimate", fallback: true)

        case .claude:
            if normalized.contains("fable-5") || normalized.contains("fable 5") {
                return anthropic(10, output: 50, "Claude Fable 5")
            }
            if normalized.contains("opus-4-8") || normalized.contains("opus-4.8") {
                return anthropic(5, output: 25, "Claude Opus 4.8")
            }
            if normalized.contains("opus-4-7") || normalized.contains("opus-4.7") {
                return anthropic(5, output: 25, "Claude Opus 4.7")
            }
            if normalized.contains("opus-4-6") || normalized.contains("opus-4.6") {
                return anthropic(5, output: 25, "Claude Opus 4.6")
            }
            if normalized.contains("sonnet-5") || normalized.contains("sonnet 5") {
                let introductoryEnd = Calendar(identifier: .gregorian).date(
                    from: DateComponents(year: 2026, month: 9, day: 1)
                ) ?? .distantPast
                return date < introductoryEnd
                    ? anthropic(2, output: 10, "Claude Sonnet 5 introductory")
                    : anthropic(3, output: 15, "Claude Sonnet 5")
            }
            if normalized.contains("sonnet-4-6") || normalized.contains("sonnet-4.6")
                || normalized.contains("sonnet-4-5") || normalized.contains("sonnet-4.5") {
                return anthropic(3, output: 15, "Claude Sonnet 4.5/4.6")
            }
            if normalized.contains("haiku-4-5") || normalized.contains("haiku-4.5") {
                return anthropic(1, output: 5, "Claude Haiku 4.5")
            }
            return anthropic(5, output: 25, "Claude fallback estimate", fallback: true)
        }
    }

    static func cost(
        provider: AIProvider,
        model: String,
        tokens: TokenUsage,
        at date: Date,
        serviceTier: String? = nil
    ) -> (usd: Double, estimated: Bool) {
        let rate = rate(for: provider, model: model, at: date)
        let multiplier = serviceTier?.lowercased() == "priority" || serviceTier?.lowercased() == "fast" ? 2.0 : 1.0

        let input = Double(max(0, tokens.input)) * rate.input
        let cached = Double(max(0, tokens.cachedInput)) * rate.cachedInput
        let fiveMinuteWrite = Double(max(0, tokens.cacheWriteFiveMinute)) * rate.cacheWriteFiveMinute
        let oneHourWrite = Double(max(0, tokens.cacheWriteOneHour)) * rate.cacheWriteOneHour
        let genericWrites = Double(max(0, tokens.cacheWrite - tokens.cacheWriteFiveMinute - tokens.cacheWriteOneHour))
            * rate.cacheWriteFiveMinute
        let output = Double(max(0, tokens.output)) * rate.output
        let usd = (input + cached + fiveMinuteWrite + oneHourWrite + genericWrites + output) / 1_000_000
        return (usd * multiplier, rate.isFallback)
    }

    private static func openAI(
        _ input: Double,
        cached: Double,
        output: Double,
        _ label: String,
        fallback: Bool = false
    ) -> PricingRate {
        PricingRate(
            input: input,
            cachedInput: cached,
            cacheWriteFiveMinute: input * 1.25,
            cacheWriteOneHour: input * 1.25,
            output: output,
            sourceLabel: label,
            isFallback: fallback
        )
    }

    private static func anthropic(
        _ input: Double,
        output: Double,
        _ label: String,
        fallback: Bool = false
    ) -> PricingRate {
        PricingRate(
            input: input,
            cachedInput: input * 0.1,
            cacheWriteFiveMinute: input * 1.25,
            cacheWriteOneHour: input * 2,
            output: output,
            sourceLabel: label,
            isFallback: fallback
        )
    }
}
