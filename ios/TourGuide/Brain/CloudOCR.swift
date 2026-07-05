import Foundation

/// Google Cloud Vision document OCR — the strongest reader for book/newspaper
/// pages. Real OCR (verbatim by construction, cannot hallucinate), built for
/// dense text and imperfect scans, returns reading-order text with paragraphs.
/// ~$1.50 per 1,000 pages after a free 1,000/month.
enum CloudOCR {
    static func transcribe(_ imageJPEG: Data) async throws -> String {
        let key = Config.googleVisionAPIKey
        guard !key.isEmpty else { throw ReasoningError.missingKey("GoogleVisionAPIKey") }

        let body: [String: Any] = [
            "requests": [[
                "image": ["content": imageJPEG.base64EncodedString()],
                "features": [["type": "DOCUMENT_TEXT_DETECTION"]],
                "imageContext": ["languageHints": ["en"]]
            ]]
        ]
        var request = URLRequest(url: URL(string:
            "https://vision.googleapis.com/v1/images:annotate?key=\(key)")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await GeminiBackend.apiSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ReasoningError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = json["responses"] as? [[String: Any]],
              let annotation = responses.first?["fullTextAnnotation"] as? [String: Any],
              let text = annotation["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReasoningError.badResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
