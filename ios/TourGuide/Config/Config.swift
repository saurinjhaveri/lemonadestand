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

    /// Gemini model for Lite mode + "Look at this". Update to the latest flash
    /// model from https://ai.google.dev/gemini-api/docs/models if needed.
    static let geminiModel = "gemini-2.0-flash"

    static var openAIAPIKey: String { secrets["OpenAIAPIKey"] ?? "" }
    static var googlePlacesAPIKey: String { secrets["GooglePlacesAPIKey"] ?? "" }
    static var geminiAPIKey: String { secrets["GeminiAPIKey"] ?? "" }

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
