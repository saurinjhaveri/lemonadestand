import Foundation
import CoreLocation

/// ChatGPT backend via the OpenAI Chat Completions API (supports vision).
/// Model is `Config.openAIChatModel` (full GPT-4o by default for best landmark
/// accuracy; switch to a mini model to cut cost).
final class OpenAIChatBackend: ReasoningBackend {
    let displayName = "ChatGPT"
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func generate(userText: String,
                  imageJPEG: Data?,
                  location: CLLocation?,
                  candidates: [LandmarkCandidate],
                  history: [ChatTurn],
                  memoryContext: String) async throws -> GuideResult {
        guard Config.hasOpenAIKey else { throw ReasoningError.missingKey("OpenAIAPIKey") }

        var content: [[String: Any]] = [
            ["type": "text",
             "text": TourPrompt.userText(userText, location: location, candidates: candidates)]
        ]
        if let imageJPEG {
            let dataURL = "data:image/jpeg;base64,\(imageJPEG.base64EncodedString())"
            content.append(["type": "image_url", "image_url": ["url": dataURL]])
        }

        let systemText = memoryContext.isEmpty ? TourPrompt.system
            : TourPrompt.system + "\n\nWhat you remember about this traveler:\n" + memoryContext
        var messages: [[String: Any]] = [["role": "system", "content": systemText]]
        for turn in history {
            messages.append(["role": turn.role.rawValue, "content": turn.text])
        }
        messages.append(["role": "user", "content": content])

        let body: [String: Any] = [
            "model": Config.openAIChatModel,
            "messages": messages,
            "max_tokens": 400
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(Config.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ReasoningError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw ReasoningError.badResponse
        }
        var usage = BrainUsage(provider: displayName, model: Config.openAIChatModel)
        if let u = json["usage"] as? [String: Any] {
            usage.inputTokens = u["prompt_tokens"] as? Int ?? 0
            usage.outputTokens = u["completion_tokens"] as? Int ?? 0
        }
        return GuideResult(text: text, usage: usage)
    }
}
