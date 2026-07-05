import Foundation

/// App configuration. API keys are read from `Secrets.plist` (git-ignored) which
/// you create from `Secrets.example.plist`.
///
/// For production, prefer fetching short-lived credentials from your own backend
/// rather than shipping long-lived keys inside the app (see plan §3).
enum Config {
    /// OpenAI Realtime model. "mini" is the cheaper audio model; switch to
    /// "gpt-realtime" for the higher-quality (pricier) voice.
    static let realtimeModel = "gpt-realtime-mini"

    /// ChatGPT text/vision model for Lite mode + "Look at this".
    /// Full GPT-4o for best landmark accuracy; use "gpt-4o-mini" to cut cost.
    static let openAIChatModel = "gpt-4o"
    static let openAIBaseURL = "https://api.openai.com/v1"

    // OpenRouter: one endpoint, many models. Paid but tiny — a fraction of a
    // cent per tour question. Swap the slug for any model at
    // https://openrouter.ai/models (sort by price). GPT-5 Nano = fast + cheap +
    // strong general knowledge, ideal for narration.
    static let openRouterBaseURL = "https://openrouter.ai/api/v1"
    static let openRouterDisplayName = "GPT-5 Nano"
    static let openRouterModel = "openai/gpt-5-nano"                 // ~$0.05/$0.40 per M
    static let openRouterFallbackModel = "meta-llama/llama-4-scout"  // cheap multimodal fallback
    static var openRouterAPIKey: String { secrets["OpenRouterAPIKey"] ?? "" }

    /// Gemini model for Lite mode + "Look at this". Update to the latest flash
    /// model from https://ai.google.dev/gemini-api/docs/models if needed.
    static let geminiModel = "gemini-2.5-flash"

    static var openAIAPIKey: String { secrets["OpenAIAPIKey"] ?? "" }
    static var googlePlacesAPIKey: String { secrets["GooglePlacesAPIKey"] ?? "" }
    static var geminiAPIKey: String { secrets["GeminiAPIKey"] ?? "" }
    /// Google Cloud Vision (document OCR for Read mode). Can be the same key as
    /// Places if that Google Cloud project has the Cloud Vision API enabled.
    static var googleVisionAPIKey: String {
        let k = secrets["GoogleVisionAPIKey"] ?? ""
        return k.isEmpty ? googlePlacesAPIKey : k
    }
    /// Optional OpenAI Admin key (sk-admin-…) for the Costs API (real billed spend).
    static var openAIAdminKey: String { secrets["OpenAIAdminKey"] ?? "" }

    /// True when the OpenAI key looks present (used to gate the voice feature).
    static var hasOpenAIKey: Bool {
        !openAIAPIKey.isEmpty && openAIAPIKey != "sk-your-openai-key"
    }

    /// Loaded once from Secrets.plist in the app bundle.
    private static let secrets: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            print("⚠️ [Config] Secrets.plist not found in the bundle. " +
                  "Copy Secrets.example.plist → Secrets.plist, fill in your keys, " +
                  "then re-run `xcodegen generate`.")
            return [:]
        }
        let masked = dict.mapValues { $0.isEmpty ? "(empty)" : "\($0.prefix(6))… len \($0.count)" }
        print("[Config] loaded Secrets.plist: \(masked)")
        return dict
    }()
}
