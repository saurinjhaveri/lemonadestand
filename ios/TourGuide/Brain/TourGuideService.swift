import Foundation
import CoreLocation

/// Orchestrates the "look at this" flow: photo + GPS → candidate landmarks →
/// (Phase 2) vision identification + narration.
///
/// Phase 1: captures the scene, fetches nearby landmark candidates, and logs
/// them so the end-to-end pipeline is verifiable. The OpenAI vision call that
/// turns this into spoken narration is added in Phase 2.
final class TourGuideService {
    private let places: PlacesClient

    init(places: PlacesClient = PlacesClient()) {
        self.places = places
    }

    func narrate(scene: CapturedScene) async -> GuideNarration {
        var candidates: [LandmarkCandidate] = []
        if let location = scene.location {
            candidates = (try? await places.nearbyLandmarks(at: location)) ?? []
        }

        let names = candidates.prefix(5).map(\.name).joined(separator: ", ")
        print("[Brain] captured \(scene.imageData.count) bytes; nearby: [\(names)]")

        // TODO(phase-2): call OpenAI Responses API (Config.visionModel) with the
        // JPEG + candidate names + coordinates and the TourGuidePersona prompt,
        // returning the model's identification + spoken narration. Optionally
        // ground facts via Wikipedia/Wikidata.
        let placeholder = candidates.first.map {
            "You appear to be near \($0.name). (Vision narration arrives in Phase 2.)"
        } ?? "Captured the scene. Add GPS + Phase 2 vision to identify it."

        return GuideNarration(
            identifiedName: candidates.first?.name,
            spokenText: placeholder,
            confident: false)
    }
}
