import Foundation

/// What the user is actually asking for, inferred from their words. Drives how
/// wide we search (a single landmark vs. the whole area) and how the model is
/// told to answer.
enum TourIntent {
    case identify    // "what is this?" — a specific thing in front of them
    case itinerary   // "plan my next 2 hours", "what's worth seeing here?"
    case traps       // "is this a tourist trap?", "what should I skip?"

    /// Area intents want a wider Places/Wikipedia search radius and more results.
    var isArea: Bool { self != .identify }

    /// Extra instruction appended to the prompt for this intent.
    var directive: String {
        switch self {
        case .identify:
            return ""
        case .itinerary:
            return "The user wants a short plan for this area. Using ONLY the nearby places and "
                + "reference facts provided, propose a walking route of 3–5 stops in a sensible order, "
                + "with one short reason each, and call out anything overrated to skip. Spoken-style, no lists."
        case .traps:
            return "The user wants candid advice on what's worth it vs. overrated nearby. Using the "
                + "nearby places and reference facts, say what's genuinely worth seeing and which are "
                + "tourist traps or long lines to skip — and a better alternative if there is one."
        }
    }

    static func detect(_ text: String) -> TourIntent {
        let t = text.lowercased()
        let trapWords = ["tourist trap", "overrated", "worth it", "should i skip",
                         "skip ", "avoid", "waste of time", "rip off", "rip-off"]
        if trapWords.contains(where: t.contains) { return .traps }
        let planWords = ["plan ", "itinerary", "next hour", "hours here", "two hours", "2 hours",
                         "what should i", "what to do", "what to see", "worth seeing",
                         "worth visiting", "must see", "must-see", "highlights", "route",
                         "what's near", "whats near", "what's around", "things to do"]
        if planWords.contains(where: t.contains) { return .itinerary }
        return .identify
    }
}
