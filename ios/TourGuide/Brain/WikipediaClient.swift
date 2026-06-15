import Foundation
import CoreLocation

/// A verified fact about a place, pulled from Wikipedia to ground the guide's
/// answers (cuts hallucinated "fun facts" — the #1 risk in the plan).
struct WikiFact {
    let title: String
    let extract: String
    let distanceMeters: Double?
}

/// Wikipedia grounding: geosearch articles near the wearer, then pull a short
/// intro extract for each. Free, no API key. Best-effort — callers ignore
/// failures (offline, etc.) and simply proceed ungrounded.
final class WikipediaClient {
    private let session: URLSession
    private let endpoint = "https://en.wikipedia.org/w/api.php"
    // Wikipedia asks for a descriptive User-Agent; default URLSession UA can 403.
    private let userAgent = "TourGuide/1.0 (smart-glasses tour guide; contact: app)"

    init(session: URLSession = .shared) { self.session = session }

    func nearbyFacts(at location: CLLocation, radius: Int = 800, limit: Int = 4) async throws -> [WikiFact] {
        let pages = try await geosearch(at: location, radius: radius, limit: limit)
        guard !pages.isEmpty else { return [] }
        let extracts = try await extracts(pageIDs: pages.map(\.pageid))
        return pages.compactMap { page in
            guard let extract = extracts[page.pageid], !extract.isEmpty else { return nil }
            return WikiFact(title: page.title, extract: extract, distanceMeters: page.dist)
        }
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ items: [URLQueryItem], as type: T.Type) async throws -> T {
        var comps = URLComponents(string: endpoint)!
        comps.queryItems = items + [.init(name: "format", value: "json"),
                                    .init(name: "formatversion", value: "2")]
        var request = URLRequest(url: comps.url!)
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ReasoningError.badResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func geosearch(at location: CLLocation, radius: Int, limit: Int) async throws -> [GeoPage] {
        let coord = "\(location.coordinate.latitude)|\(location.coordinate.longitude)"
        let r: GeoResponse = try await get([
            .init(name: "action", value: "query"),
            .init(name: "list", value: "geosearch"),
            .init(name: "gscoord", value: coord),
            .init(name: "gsradius", value: String(radius)),
            .init(name: "gslimit", value: String(limit))
        ], as: GeoResponse.self)
        return r.query.geosearch
    }

    /// Plain-text intro for each page id, truncated client-side. (We use
    /// `exintro` + `exlimit=max` because `exsentences` only returns one page.)
    private func extracts(pageIDs: [Int]) async throws -> [Int: String] {
        let ids = pageIDs.map { String($0) }.joined(separator: "|")
        let r: ExtractResponse = try await get([
            .init(name: "action", value: "query"),
            .init(name: "prop", value: "extracts"),
            .init(name: "explaintext", value: "1"),
            .init(name: "exintro", value: "1"),
            .init(name: "exlimit", value: "max"),
            .init(name: "pageids", value: ids)
        ], as: ExtractResponse.self)
        var out: [Int: String] = [:]
        for page in r.query.pages { out[page.pageid] = page.extract.map(Self.trim) }
        return out
    }

    /// Keep extracts short for TTS + token budget (~2 sentences / 320 chars).
    private static func trim(_ s: String, maxChars: Int = 320) -> String {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > maxChars else { return clean }
        let cut = String(clean.prefix(maxChars))
        if let dot = cut.range(of: ".", options: .backwards) { return String(cut[..<dot.upperBound]) }
        return cut + "…"
    }

    // MARK: - Wire format (formatversion=2)

    private struct GeoResponse: Decodable { let query: GeoQuery }
    private struct GeoQuery: Decodable { let geosearch: [GeoPage] }
    private struct GeoPage: Decodable { let pageid: Int; let title: String; let dist: Double }

    private struct ExtractResponse: Decodable { let query: ExtractQuery }
    private struct ExtractQuery: Decodable { let pages: [ExtractPage] }
    private struct ExtractPage: Decodable { let pageid: Int; let extract: String? }
}
