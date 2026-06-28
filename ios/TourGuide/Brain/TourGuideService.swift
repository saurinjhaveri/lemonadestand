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
    private let vision: GeminiBackend   // "eyes" for text-only brains

    init(places: PlacesClient = PlacesClient(),
         wiki: WikipediaClient = WikipediaClient(),
         cache: LandmarkCache = LandmarkCache(),
         vision: GeminiBackend = GeminiBackend()) {
        self.places = places
        self.wiki = wiki
        self.cache = cache
        self.vision = vision
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
        let needsVision = imageJPEG != nil && !backend.supportsVision

        // On follow-ups (e.g. "tell me more") reuse the conversation instead of
        // re-fetching grounding — skip Places + Wikipedia for a faster reply.
        // Keep Places for area asks like "where next?" which need fresh candidates.
        let isFollowUp = !history.isEmpty
        let placesLoc: CLLocation? = (!isFollowUp || intent.isArea) ? location : nil
        let factsLoc: CLLocation? = isFollowUp ? nil : location

        // Kick off the independent network fetches CONCURRENTLY (instead of
        // Places → Wikipedia → vision sequentially). The slowest one sets the
        // latency floor rather than the sum — ~2–3s faster per "Look at this".
        async let candidatesTask = nearbyCandidates(at: placesLoc, intent: intent)
        async let factsTask = nearbyFacts(at: factsLoc, intent: intent)
        async let readTask = visionRead(needsVision ? imageJPEG : nil, userText: userText, location: location)

        let candidates = await candidatesTask

        // Cache: only for fresh (non-follow-up) turns with a stable anchor.
        let allowCache = history.isEmpty
        let key = cacheKey(intent: intent, salt: cacheSalt, userText: userText,
                           hasImage: imageJPEG != nil, candidates: candidates, location: location)
        if allowCache, let key, let hit = await cache.text(for: key) {
            return GuideResult(text: hit, usage: BrainUsage(provider: "cache"))
        }

        let facts = await factsTask
        var grounding = TourPrompt.grounding(facts: facts, intent: intent)

        // "Eyes → brain" handoff: if the chosen brain can't see, fold in Gemini's
        // read of the photo (computed in parallel above).
        var imageForBackend = imageJPEG
        var textForBackend = userText
        let read = await readTask
        if needsVision {
            if let read, !read.isEmpty {
                let block = "What the camera sees (from a vision model — this IS the photo the user "
                    + "is looking at right now; treat it as if you saw it yourself and narrate "
                    + "accordingly, do NOT say you can't see images):\n\(read)"
                grounding = grounding.isEmpty ? block : grounding + "\n\n" + block
                imageForBackend = nil
                if textForBackend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textForBackend = "Tell me about what I'm looking at."
                }
            } else {
                // Vision read failed → let the vision backend narrate the image directly.
                let result = try await vision.generate(
                    userText: userText, imageJPEG: imageJPEG,
                    location: location, candidates: candidates, grounding: grounding,
                    history: history, memoryContext: memoryContext)
                if allowCache, let key { await cache.set(result.text, for: key) }
                return result
            }
        }

        let result = try await backend.generate(
            userText: textForBackend, imageJPEG: imageForBackend,
            location: location, candidates: candidates, grounding: grounding,
            history: history, memoryContext: memoryContext)

        if allowCache, let key { await cache.set(result.text, for: key) }
        return result
    }

    // MARK: - Concurrent fetch helpers

    private func nearbyCandidates(at location: CLLocation?, intent: TourIntent) async -> [LandmarkCandidate] {
        guard let location, !Config.googlePlacesAPIKey.isEmpty else { return [] }
        return (try? await places.nearbyLandmarks(at: location, radius: intent.isArea ? 1500 : 150)) ?? []
    }

    private func nearbyFacts(at location: CLLocation?, intent: TourIntent) async -> [WikiFact] {
        guard let location else { return [] }
        return (try? await wiki.nearbyFacts(at: location,
                                            radius: intent.isArea ? 1500 : 700,
                                            limit: intent.isArea ? 5 : 3)) ?? []
    }

    private func visionRead(_ imageJPEG: Data?, userText: String, location: CLLocation?) async -> String? {
        guard let imageJPEG else { return nil }
        return (try? await vision.describeScene(imageJPEG: imageJPEG, userText: userText,
                                                location: location, candidates: []))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
