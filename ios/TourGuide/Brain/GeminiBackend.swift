import Foundation
import CoreLocation

/// Google Gemini backend (free tier, strong vision). Uses the Generative
/// Language API. Model is `Config.geminiModel`. Needs `GeminiAPIKey` in
/// Secrets.plist (get one free at https://aistudio.google.com/apikey).
final class GeminiBackend: ReasoningBackend {
    let displayName = "Gemini"
    let supportsVision = true
    private let model: String
    private let session: URLSession

    init(model: String = Config.geminiModel, session: URLSession = .shared) {
        self.model = model
        self.session = session
    }

    func generate(userText: String,
                  imageJPEG: Data?,
                  location: CLLocation?,
                  candidates: [LandmarkCandidate],
                  grounding: String,
                  history: [ChatTurn],
                  memoryContext: String) async throws -> GuideResult {
        guard !Config.geminiAPIKey.isEmpty else { throw ReasoningError.missingKey("GeminiAPIKey") }

        var parts: [[String: Any]] = [
            ["text": TourPrompt.userText(userText, location: location,
                                         candidates: candidates, grounding: grounding)]
        ]
        if let imageJPEG {
            parts.append(["inline_data": ["mime_type": "image/jpeg",
                                          "data": imageJPEG.base64EncodedString()]])
        }

        // Prior turns as Gemini "contents" (assistant maps to role "model").
        var contents: [[String: Any]] = history.map { turn in
            ["role": turn.role == .user ? "user" : "model",
             "parts": [["text": turn.text]]]
        }
        contents.append(["role": "user", "parts": parts])

        let systemText = memoryContext.isEmpty ? TourPrompt.system
            : TourPrompt.system + "\n\nFollow these standing instructions and context:\n" + memoryContext
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemText]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": 400]   // cap rambling + save quota
        ]

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/"
            + "\(model):generateContent?key=\(Config.geminiAPIKey)"
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ReasoningError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = json["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let resultParts = content["parts"] as? [[String: Any]] else {
            throw ReasoningError.badResponse
        }
        let text = resultParts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ReasoningError.badResponse }

        var usage = BrainUsage(provider: displayName, model: model)
        if let u = json["usageMetadata"] as? [String: Any] {
            usage.inputTokens = u["promptTokenCount"] as? Int ?? 0
            usage.outputTokens = u["candidatesTokenCount"] as? Int ?? 0
        }
        return GuideResult(text: text, usage: usage)
    }
}
