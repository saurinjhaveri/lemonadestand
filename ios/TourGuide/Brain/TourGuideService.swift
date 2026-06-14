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

    func narrate(userText: String,
                 imageJPEG: Data?,
                 location: CLLocation?,
                 backend: ReasoningBackend) async -> String {
        var candidates: [LandmarkCandidate] = []
        if let location, !Config.googlePlacesAPIKey.isEmpty {
            candidates = (try? await places.nearbyLandmarks(at: location)) ?? []
        }
        do {
            return try await backend.generate(
                userText: userText, imageJPEG: imageJPEG,
                location: location, candidates: candidates)
        } catch {
            return "Sorry — couldn't reach \(backend.displayName): \(error.localizedDescription)"
        }
    }
}
