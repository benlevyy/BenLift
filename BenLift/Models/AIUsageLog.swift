import Foundation
import SwiftData

/// One row per Claude API call. The app makes exactly one kind of call —
/// a chat turn — so this doubles as the complete record of what the app
/// spent and when, surfaced in Settings.
@Model
final class AIUsageLog {
    var id: UUID
    var timestamp: Date
    var intelligenceRaw: String
    var inputTokens: Int
    var outputTokens: Int
    /// Input tokens served from the prompt cache, billed at a tenth of the
    /// normal input rate.
    var cachedInputTokens: Int
    var latencySeconds: Double
    /// Computed at write time from the rates below, so historical rows keep
    /// the price that was actually charged even if rates change later.
    var costUSD: Double

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        intelligence: Intelligence,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0,
        latencySeconds: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.intelligenceRaw = intelligence.rawValue
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.latencySeconds = latencySeconds
        self.costUSD = Self.cost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens
        )
    }

    var intelligence: Intelligence {
        Intelligence(rawValue: intelligenceRaw) ?? .quick
    }

    // MARK: - Pricing

    /// Claude Opus 5 list rates, USD per million tokens.
    static let inputRatePerMTok: Double = 5.0
    static let outputRatePerMTok: Double = 25.0
    /// Cache reads bill at 10% of the input rate.
    static let cacheReadMultiplier: Double = 0.1

    static func cost(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int) -> Double {
        let uncachedInput = max(0, inputTokens - cachedInputTokens)
        let inputCost = Double(uncachedInput) / 1_000_000 * inputRatePerMTok
        let cacheCost = Double(cachedInputTokens) / 1_000_000 * inputRatePerMTok * cacheReadMultiplier
        let outputCost = Double(outputTokens) / 1_000_000 * outputRatePerMTok
        return inputCost + cacheCost + outputCost
    }
}
