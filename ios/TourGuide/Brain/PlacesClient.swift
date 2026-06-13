import Foundation
import CoreLocation

/// Google Places — grounds "what is this?" by the wearer's coordinates.
/// Nearby Search returns candidate landmarks; their names are fed (with the
/// photo) to the vision model in Phase 2 so identification is reliable.
final class PlacesClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String = Config.googlePlacesAPIKey, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Tourist-relevant places near a coordinate, nearest first.
    func nearbyLandmarks(at location: CLLocation, radius: Int = 120) async throws -> [LandmarkCandidate] {
        var components = URLComponents(string:
            "https://maps.googleapis.com/maps/api/place/nearbysearch/json")!
        components.queryItems = [
            .init(name: "location", value: "\(location.coordinate.latitude),\(location.coordinate.longitude)"),
            .init(name: "radius", value: String(radius)),
            .init(name: "type", value: "tourist_attraction"),
            .init(name: "key", value: apiKey)
        ]
        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(NearbyResponse.self, from: data)

        return response.results.map { result in
            let placeLoc = CLLocation(
                latitude: result.geometry.location.lat,
                longitude: result.geometry.location.lng)
            return LandmarkCandidate(
                id: result.placeId,
                name: result.name,
                types: result.types ?? [],
                rating: result.rating,
                userRatingsTotal: result.userRatingsTotal,
                distanceMeters: location.distance(from: placeLoc))
        }
        .sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
    }

    // MARK: - Wire format

    private struct NearbyResponse: Decodable { let results: [Result] }
    private struct Result: Decodable {
        let placeId: String
        let name: String
        let types: [String]?
        let rating: Double?
        let userRatingsTotal: Int?
        let geometry: Geometry
        enum CodingKeys: String, CodingKey {
            case placeId = "place_id", name, types, rating
            case userRatingsTotal = "user_ratings_total", geometry
        }
    }
    private struct Geometry: Decodable { let location: LatLng }
    private struct LatLng: Decodable { let lat: Double; let lng: Double }
}
