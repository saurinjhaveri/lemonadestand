import Foundation
import CoreLocation

/// A swappable reasoning/vision backend. Implementations: OpenAI (ChatGPT) and
/// Google Gemini. Both take the user's words + optional photo + GPS + nearby
/// landmark candidates and return spoken-style tour-guide narration.
protocol ReasoningBackend {
    var displayName: String { get }
    func generate(userText: String,
                  imageJPEG: Data?,
                  location: CLLocation?,
                  candidates: [LandmarkCandidate],
                  history: [ChatTurn],
                  memoryContext: String) async throws -> GuideResult
}

enum ReasoningError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey(let k): return "Missing \(k) in Secrets.plist"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(140))"
        case .badResponse: return "Unexpected response from the model"
        }
    }
}

/// Shared prompt scaffolding so both backends behave consistently.
enum TourPrompt {
    static var system: String { TourGuidePersona.systemPrompt }

    /// Compact context line. GPS is framed as APPROXIMATE area, and nearby places
    /// as reference only — never as "where the user is."
    static func context(location: CLLocation?, candidates: [LandmarkCandidate]) -> String {
        var parts: [String] = []
        if let loc = location {
            parts.append(String(format: "Approximate area only (GPS, not the exact spot): %.5f, %.5f.",
                                loc.coordinate.latitude, loc.coordinate.longitude))
        }
        if !candidates.isEmpty {
            let list = candidates.prefix(6).map { c -> String in
                var s = c.name
                if let r = c.rating { s += " (★\(r))" }
                if let d = c.distanceMeters { s += " ~\(Int(d))m" }
                return s
            }.joined(separator: "; ")
            parts.append("Some places that exist somewhere in this broader area "
                + "(reference only — do NOT assume the user is at any of these): \(list).")
        }
        return parts.isEmpty ? "(no location available)" : parts.joined(separator: " ")
    }

    /// The full user turn text (context + their question or a default).
    static func userText(_ userText: String, location: CLLocation?, candidates: [LandmarkCandidate]) -> String {
        let question = userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Identify what's in this photo and tell me about it. If the photo doesn't clearly show a place/landmark/artwork, say you can't tell and ask me what I'm looking at — do NOT guess based on my GPS area."
            : userText
        return "\(context(location: location, candidates: candidates))\n\nUser: \(question)"
    }
}
