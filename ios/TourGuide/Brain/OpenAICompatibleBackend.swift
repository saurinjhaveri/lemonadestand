import Foundation
import CoreLocation

/// Generic backend for any OpenAI-compatible Chat Completions API.
/// Works with OpenAI, OpenRouter, Groq, GitHub Models, Cerebras, DeepSeek, etc.
/// — just supply baseURL + apiKey + model.
final class OpenAICompatibleBackend: ReasoningBackend {
    let displayName: String
    let supportsVision: Bool
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(displayName: String, baseURL: String, apiKey: String, model: String,
         supportsVision: Bool, session: URLSession = .shared) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.supportsVision = supportsVision
        self.session = session
    }

    func generate(userText: String,
                  imageJPEG: Data?,
                  location: CLLocation?,
                  candidates: [LandmarkCandidate],
                  grounding: String,
                  history: [ChatTurn],
                  memoryContext: String) async throws -> GuideResult {
        guard !apiKey.isEmpty else { throw ReasoningError.missingKey("\(displayName) API key") }

        let systemText = memoryContext.isEmpty ? TourPrompt.system
            : TourPrompt.system + "\n\nFollow these standing instructions and context:\n" + memoryContext

        // Build the user message (text, plus image only if this model has vision).
        let userTurn = TourPrompt.userText(userText, location: location,
                                           candidates: candidates, grounding: grounding)
        let userContent: Any
        if supportsVision, let imageJPEG {
            let dataURL = "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"
            userContent = [["type": "text", "text": userTurn],
                           ["type": "image_url", "image_url": ["url": dataURL]]]
        } else {
            userContent = userTurn
        }

        var messages: [[String: Any]] = [["role": "system", "content": systemText]]
        for turn in history { messages.append(["role": turn.role.rawValue, "content": turn.text]) }
        messages.append(["role": "user", "content": userContent])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 600   // answer length is capped by the prompt
        ]
        // OpenRouter only: route to the fastest host for this model (big latency
        // win, no model change). Ignored by other OpenAI-compatible endpoints.
        if baseURL.contains("openrouter") {
            body["provider"] = ["sort": "throughput", "allow_fallbacks": true]
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional OpenRouter attribution headers (ignored by other providers).
        request.addValue("https://tourguide.app", forHTTPHeaderField: "HTTP-Referer")
        request.addValue("TourGuide", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ReasoningError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let raw = message["content"] as? String else {
            throw ReasoningError.badResponse
        }
        let text = Self.stripReasoning(raw)
        guard !text.isEmpty else { throw ReasoningError.badResponse }

        var usage = BrainUsage(provider: displayName, model: model)
        if let u = json["usage"] as? [String: Any] {
            usage.inputTokens = u["prompt_tokens"] as? Int ?? 0
            usage.outputTokens = u["completion_tokens"] as? Int ?? 0
        }
        return GuideResult(text: text, usage: usage)
    }

    /// Some reasoning models (e.g. DeepSeek R1) may inline <think>…</think>.
    private static func stripReasoning(_ s: String) -> String {
        guard let start = s.range(of: "<think>"), let end = s.range(of: "</think>") else {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = s
        if end.upperBound > start.lowerBound {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
