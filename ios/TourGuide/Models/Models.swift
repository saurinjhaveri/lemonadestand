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
