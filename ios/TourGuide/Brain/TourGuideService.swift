import Foundation
import CoreLocation

/// Orchestrates a guide turn: GPS → nearby landmark candidates (Google Places)
/// → chosen reasoning/vision backend → spoken-style narration. Used by both the
/// voice answers (no image) and "Look at this" (with image).
final class TourGuideService {
    private let places: PlacesClient

    init(places: PlacesClient = PlacesClient()) {
        self.places = places
    }

    /// Throws on backend failure so the caller can fall back to another brain.
    func narrate(userText: String,
                 imageJPEG: Data?,
                 location: CLLocation?,
                 history: [ChatTurn],
                 memoryContext: String,
                 backend: ReasoningBackend) async throws -> GuideResult {
        var candidates: [LandmarkCandidate] = []
        if let location, !Config.googlePlacesAPIKey.isEmpty {
            candidates = (try? await places.nearbyLandmarks(at: location)) ?? []
        }
        return try await backend.generate(
            userText: userText, imageJPEG: imageJPEG,
            location: location, candidates: candidates,
            history: history, memoryContext: memoryContext)
    }
}
