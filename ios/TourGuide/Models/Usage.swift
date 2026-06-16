import Foundation

/// Per-1M token cost estimates for the reasoning/vision brains.
enum Pricing {
    /// Per-1M text/vision token rates for the Lite/"Look at this" brains.
    /// ⚠️ Estimates — update from each provider's pricing page.
    static func brainCost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let inRate: Double, outRate: Double
        if model.contains("nano") {                 // gpt-5-nano (OpenRouter)
            (inRate, outRate) = (0.05, 0.40)
        } else if model.contains("scout") || model.contains("llama") {
            (inRate, outRate) = (0.10, 0.30)        // Llama 4 Scout (OpenRouter)
        } else if model.contains("mini") {          // gpt-4o-mini
            (inRate, outRate) = (0.15, 0.60)
        } else if model.contains("gpt-4o") || model.contains("gpt-5") {
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

