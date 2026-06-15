import Foundation
import CoreLocation

/// Orchestrates a guide turn: infer intent → nearby landmark candidates (Google
/// Places) + verified facts (Wikipedia) → chosen reasoning/vision backend →
/// spoken-style narration, with a landmark cache for instant/free repeats.
/// Used by both the voice answers (no image) and "Look at this" (with image).
final class TourGuideService {
    private let places: PlacesClient
    private let wiki: WikipediaClient
    private let cache: LandmarkCache

    init(places: PlacesClient = PlacesClient(),
         wiki: WikipediaClient = WikipediaClient(),
         cache: LandmarkCache = LandmarkCache()) {
        self.places = places
        self.wiki = wiki
        self.cache = cache
    }

    /// Throws on backend failure so the caller can fall back to another brain.
    /// `cacheSalt` should encode the brain + length so different settings don't
    /// share cached answers.
    func narrate(userText: String,
                 imageJPEG: Data?,
                 location: CLLocation?,
                 history: [ChatTurn],
                 memoryContext: String,
                 backend: ReasoningBackend,
                 cacheSalt: String = "") async throws -> GuideResult {
        let intent = TourIntent.detect(userText)

        // Nearby landmark candidates (wider for "plan the area" intents).
        var candidates: [LandmarkCandidate] = []
        if let location, !Config.googlePlacesAPIKey.isEmpty {
            let radius = intent.isArea ? 1500 : 150
            candidates = (try? await places.nearbyLandmarks(at: location, radius: radius)) ?? []
        }

        // Cache: only for fresh (non-follow-up) turns with a stable anchor.
        let allowCache = history.isEmpty
        let key = cacheKey(intent: intent, salt: cacheSalt, userText: userText,
                           hasImage: imageJPEG != nil, candidates: candidates, location: location)
        if allowCache, let key, let hit = await cache.text(for: key) {
            return GuideResult(text: hit, usage: BrainUsage(provider: "cache"))
        }

        // Wikipedia grounding (best-effort; ignore failures / offline).
        var facts: [WikiFact] = []
        if let location {
            facts = (try? await wiki.nearbyFacts(
                at: location,
                radius: intent.isArea ? 1500 : 700,
                limit: intent.isArea ? 5 : 3)) ?? []
        }
        let grounding = TourPrompt.grounding(facts: facts, intent: intent)

        let result = try await backend.generate(
            userText: userText, imageJPEG: imageJPEG,
            location: location, candidates: candidates, grounding: grounding,
            history: history, memoryContext: memoryContext)

        if allowCache, let key { await cache.set(result.text, for: key) }
        return result
    }

    /// A stable key anchored to a specific landmark (identify) or area (planning).
    /// Returns nil when there's nothing solid to anchor on — then we don't cache.
    private func cacheKey(intent: TourIntent, salt: String, userText: String,
                          hasImage: Bool, candidates: [LandmarkCandidate],
                          location: CLLocation?) -> String? {
        let q = userText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let anchor: String?
        if intent.isArea {
            // Coarse area (~110m grid) — area advice is stable across a block.
            anchor = location.map { String(format: "geo:%.3f,%.3f",
                                           $0.coordinate.latitude, $0.coordinate.longitude) }
        } else if let nearest = candidates.first,
                  (nearest.distanceMeters ?? .infinity) <= 60 {
            // A clearly dominant landmark right here.
            anchor = "pid:\(nearest.id)"
        } else {
            anchor = nil   // ambiguous identify → don't cache
        }
        guard let anchor else { return nil }
        return "\(intent)|\(salt)|\(anchor)|img:\(hasImage)|q:\(q)"
    }
}
