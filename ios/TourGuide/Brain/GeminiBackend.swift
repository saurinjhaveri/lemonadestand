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

    /// Hard request timeouts so a bad network can't hang a turn for 60s.
    static let apiSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 35
        return URLSession(configuration: c)
    }()

    init(model: String = Config.geminiModel, session: URLSession = GeminiBackend.apiSession) {
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

        let (text, usage) = try await send(systemText: systemText, contents: contents, maxTokens: 600)
        guard !text.isEmpty else { throw ReasoningError.badResponse }
        return GuideResult(text: text, usage: usage)
    }

    /// Vision-only pass: identify what's in the photo and read any text, as plain
    /// facts (no storytelling). Feeds a text-only reasoning brain (the "eyes →
    /// brain" handoff) so e.g. GPT-5 Nano can write the narration.
    func describeScene(imageJPEG: Data, userText: String,
                       location: CLLocation?, candidates: [LandmarkCandidate]) async throws -> String {
        guard !Config.geminiAPIKey.isEmpty else { throw ReasoningError.missingKey("GeminiAPIKey") }

        let hints = TourPrompt.context(location: location, candidates: candidates)
        let asked = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        You are the eyes of a tour-guide app. Look at the photo and report FACTS only — no storytelling:
        1) Identify the specific landmark / place / artwork / object if recognizable, and name it.
        2) Transcribe any readable text or signs.
        3) Note key visual details (materials, style, surroundings).
        Use the area/nearby hints ONLY to disambiguate — do not assume the user is at any listed place. \
        If unsure, give the most likely identification and say you're unsure. 2–5 sentences.
        \(asked.isEmpty ? "" : "The user also asked: \(asked)\n")Hints: \(hints)
        """
        let contents: [[String: Any]] = [[
            "role": "user",
            "parts": [["text": prompt],
                      ["inline_data": ["mime_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]]]
        ]]
        let (text, _) = try await send(systemText: nil, contents: contents, maxTokens: 350)
        guard !text.isEmpty else { throw ReasoningError.badResponse }
        return text
    }

    /// Verbatim page transcription — the escalation path when on-device OCR is
    /// low-confidence (Gemini reads soft/low-res text far better). ~$0.001/page.
    func transcribePage(_ imageJPEG: Data) async throws -> String {
        guard !Config.geminiAPIKey.isEmpty else { throw ReasoningError.missingKey("GeminiAPIKey") }
        let prompt = """
        Transcribe ALL readable text in this image VERBATIM, in natural reading \
        order (column by column if multi-column). Preserve paragraphs. Output \
        ONLY the transcription — no commentary, no headers, no notes.
        CRITICAL: transcribe ONLY characters you can actually see. NEVER guess, \
        reconstruct, or fill in words that are blurry or cut off. If the text is \
        too blurry or small to read reliably, respond with exactly: UNREADABLE
        """
        let contents: [[String: Any]] = [[
            "role": "user",
            "parts": [["text": prompt],
                      ["inline_data": ["mime_type": "image/jpeg",
                                       "data": imageJPEG.base64EncodedString()]]]
        ]]
        let (text, _) = try await send(systemText: nil, contents: contents, maxTokens: 2500)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReasoningError.badResponse }
        return trimmed
    }

    // MARK: - Shared request

    private func send(systemText: String?, contents: [[String: Any]],
                      maxTokens: Int) async throws -> (String, BrainUsage) {
        var body: [String: Any] = [
            "contents": contents,
            // thinkingBudget 0 disables 2.5-flash's hidden reasoning, which was
            // eating the token budget and truncating answers mid-sentence.
            "generationConfig": [
                "maxOutputTokens": maxTokens,
                "thinkingConfig": ["thinkingBudget": 0]
            ]
        ]
        if let systemText { body["system_instruction"] = ["parts": [["text": systemText]]] }

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

        var usage = BrainUsage(provider: displayName, model: model)
        if let u = json["usageMetadata"] as? [String: Any] {
            usage.inputTokens = u["promptTokenCount"] as? Int ?? 0
            usage.outputTokens = u["candidatesTokenCount"] as? Int ?? 0
        }
        return (text, usage)
    }
}
