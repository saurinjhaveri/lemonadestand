import Foundation
import CoreLocation

/// A photo captured from the glasses, plus where the wearer was standing.
struct CapturedScene {
    let imageData: Data          // JPEG
    let location: CLLocation?
    let heading: CLLocationDirection?
    let timestamp: Date = Date()
}

/// A candidate landmark returned by Google Places, used to ground vision ID.
struct LandmarkCandidate: Codable, Identifiable {
    let id: String               // Places place_id
    let name: String
    let types: [String]
    let rating: Double?
    let userRatingsTotal: Int?
    let distanceMeters: Double?
}

/// The guide's answer for a captured scene (Phase 2 fills this in fully).
struct GuideNarration {
    let identifiedName: String?
    let spokenText: String
    let confident: Bool
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// How the voice conversation runs.
enum VoiceMode: String, CaseIterable, Identifiable {
    case lite       // Apple on-device STT + TTS + text/vision backend (free with Gemini)
    case realtime   // OpenAI Realtime speech-to-speech ($$)
    var id: String { rawValue }
    var label: String { self == .lite ? "Lite (free)" : "Realtime ($$)" }
}

/// Which reasoning/vision backend powers Lite mode + "Look at this".
enum BackendChoice: String, CaseIterable, Identifiable {
    case openrouter // OpenRouter (GPT-5 Nano) — cheap, fast, strong (text)
    case gemini     // free tier, best free vision
    case gpt        // ChatGPT, best landmark accuracy ($)
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openrouter: return "\(Config.openRouterDisplayName) (¢)"
        case .gemini: return "Gemini (free)"
        case .gpt: return "ChatGPT ($)"
        }
    }
}

/// Which text-to-speech engine speaks answers (Lite mode + "Look at this").
enum TTSEngine: String, CaseIterable, Identifiable {
    case device    // free, on-device
    case natural   // OpenAI neural voice ($)
    var id: String { rawValue }
    var label: String { self == .device ? "Device (free)" : "Natural ($)" }
}

/// How long/verbose the guide's answers are.
enum GuideLength: String, CaseIterable, Identifiable {
    case brief, standard, detailed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .brief: return "Brief"
        case .standard: return "Standard"
        case .detailed: return "Detailed"
        }
    }
    var directive: String {
        switch self {
        case .brief:
            return "Body ~2 sentences: the most interesting fact or two, no filler. Then add your one-line follow-up offer."
        case .standard:
            return "Body ~3–4 sentences: a couple of genuinely interesting facts or a short story. Then add your one-line follow-up offer."
        case .detailed:
            return "Body ~5–6 sentences: a vivid short story plus a couple of facts, staying focused. Then add your one-line follow-up offer."
        }
    }
}
