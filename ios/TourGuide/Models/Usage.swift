import Foundation

/// Token usage reported by the Realtime API in `response.done`, plus an
/// estimated dollar cost. Token counts are exact; the cost is an estimate based
/// on the editable rates below.
struct RealtimeUsage: Codable, Equatable {
    var inputTextTokens = 0
    var inputAudioTokens = 0
    var inputCachedTokens = 0
    var outputTextTokens = 0
    var outputAudioTokens = 0

    var totalTokens: Int {
        inputTextTokens + inputAudioTokens + inputCachedTokens
            + outputTextTokens + outputAudioTokens
    }

    /// Estimated USD using `Pricing` (per-1M-token rates).
    var estimatedCostUSD: Double {
        (Double(inputTextTokens)   * Pricing.inputText
         + Double(inputAudioTokens)  * Pricing.inputAudio
         + Double(inputCachedTokens) * Pricing.cachedInput
         + Double(outputTextTokens)  * Pricing.outputText
         + Double(outputAudioTokens) * Pricing.outputAudio) / 1_000_000.0
    }

    mutating func add(_ other: RealtimeUsage) {
        inputTextTokens   += other.inputTextTokens
        inputAudioTokens  += other.inputAudioTokens
        inputCachedTokens += other.inputCachedTokens
        outputTextTokens  += other.outputTextTokens
        outputAudioTokens += other.outputAudioTokens
    }
}

/// USD per 1,000,000 tokens. ⚠️ These are ESTIMATES for gpt-realtime-mini —
/// verify and update from https://openai.com/api/pricing/ . The displayed cost
/// is only as accurate as these numbers; token counts themselves are exact.
enum Pricing {
    static let inputText: Double   = 0.60
    static let inputAudio: Double  = 10.00
    static let cachedInput: Double = 0.30
    static let outputText: Double  = 2.40
    static let outputAudio: Double = 20.00

    /// Per-1M text/vision token rates for the Lite/"Look at this" brains.
    /// ⚠️ Estimates — update from each provider's pricing page.
    static func brainCost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let inRate: Double, outRate: Double
        if model.contains("mini") {                 // gpt-4o-mini
            (inRate, outRate) = (0.15, 0.60)
        } else if model.hasPrefix("gpt-4o") || model.hasPrefix("gpt-5") {
            (inRate, outRate) = (2.50, 10.00)       // full GPT-4o/5-class
        } else if model.contains("gemini") {
            (inRate, outRate) = (0.0, 0.0)          // free tier (set rates if you exceed it)
        } else {
            (inRate, outRate) = (0.0, 0.0)
        }
        return (Double(inputTokens) * inRate + Double(outputTokens) * outRate) / 1_000_000.0
    }
}

/// Usage + cost for one brain (Gemini/ChatGPT) turn.
struct BrainUsage: Equatable {
    var provider = ""
    var model = ""
    var inputTokens = 0
    var outputTokens = 0
    var estimatedCostUSD: Double {
        Pricing.brainCost(model: model, inputTokens: inputTokens, outputTokens: outputTokens)
    }
}

/// A brain turn's spoken text plus its usage.
struct GuideResult {
    let text: String
    let usage: BrainUsage
}

/// One prior conversation turn, for context/memory.
struct ChatTurn: Equatable {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

