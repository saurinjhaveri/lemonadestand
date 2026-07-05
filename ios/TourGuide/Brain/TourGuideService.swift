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
                 sceneText: String = "",
                 backend: ReasoningBackend,
                 cacheSalt: String = "") async throws -> GuideResult {
        let intent = TourIntent.detect(userText)

        // Latency: a text-only brain would need a Gemini "eyes" pass THEN its
        // own call — two model round-trips back to back. For photo turns,
        // answer with the vision backend directly (one call); the chosen brain
        // still handles all text turns.
        let effective: ReasoningBackend =
            (imageJPEG != nil && !backend.supportsVision) ? vision : backend

        // On follow-ups (e.g. "tell me more") reuse the conversation instead of
        // re-fetching grounding — skip Places + Wikipedia for a faster reply.
        // Keep Places for area asks like "where next?" which need fresh candidates.
        let isFollowUp = !history.isEmpty
        let placesLoc: CLLocation? = (!isFollowUp || intent.isArea) ? location : nil
        let factsLoc: CLLocation? = isFollowUp ? nil : location

        // Kick off the independent fetches CONCURRENTLY and time-box them —
        // grounding is nice-to-have; a slow tail must never stall the answer.
        async let candidatesTask = withDeadline(2.0) { await self.nearbyCandidates(at: placesLoc, intent: intent) }
        async let factsTask = withDeadline(2.5) { await self.nearbyFacts(at: factsLoc, intent: intent) }

        let candidates = (await candidatesTask) ?? []

        // Cache: only for fresh (non-follow-up) turns with a stable anchor.
        let allowCache = history.isEmpty
        let key = cacheKey(intent: intent, salt: cacheSalt, userText: userText,
                           hasImage: imageJPEG != nil, candidates: candidates, location: location)
        if allowCache, let key, let hit = await cache.text(for: key) {
            return GuideResult(text: hit, usage: BrainUsage(provider: "cache"))
        }

        let facts = (await factsTask) ?? []
        var grounding = TourPrompt.grounding(facts: facts, intent: intent)

        // On-device OCR hint: signs/labels/barcodes read from the photo — often
        // the strongest identification evidence, and it cost nothing.
        if !sceneText.isEmpty {
            let block = "Text read from the scene by on-device OCR (signs/labels in the photo):\n\(sceneText)"
            grounding = grounding.isEmpty ? block : grounding + "\n\n" + block
        }

        let result = try await effective.generate(
            userText: userText, imageJPEG: imageJPEG,
            location: location, candidates: candidates, grounding: grounding,
            history: history, memoryContext: memoryContext)

        if allowCache, let key { await cache.set(result.text, for: key) }
        return result
    }

    // MARK: - Concurrent fetch helpers

    /// Run `op` but give up after `seconds` — returns nil on timeout.
    private func withDeadline<T: Sendable>(_ seconds: Double,
                                           _ op: @Sendable @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

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
