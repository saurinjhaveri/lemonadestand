import Foundation

/// App configuration, read from the bundle (populated by Secrets.xcconfig at build time).
///
/// For production, prefer fetching short-lived credentials from your own backend
/// rather than shipping long-lived keys inside the app (see plan §3).
enum Config {
    static let openAIAPIKey: String = bundleValue("OpenAIAPIKey")
    static let googlePlacesAPIKey: String = bundleValue("GooglePlacesAPIKey")

    /// OpenAI Realtime model. Update if you adopt a newer realtime model.
    static let realtimeModel = "gpt-realtime"

    /// OpenAI vision/reasoning model used by the brain (Phase 2).
    static let visionModel = "gpt-4o"

    private static func bundleValue(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        if value.isEmpty {
            // Don't crash the app — just warn. Features needing this key won't work.
            print("⚠️ [Config] Missing \(key). Check Secrets.xcconfig.")
        }
        return value
    }

    /// True when the OpenAI key looks present (used to gate the voice feature).
    static var hasOpenAIKey: Bool {
        !openAIAPIKey.isEmpty && openAIAPIKey != "sk-your-openai-key"
    }
}
