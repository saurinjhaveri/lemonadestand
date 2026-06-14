import Foundation
import CoreLocation

/// One remembered moment: a place + the exchange about it.
struct MemoryRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var placeName: String?
    var latitude: Double?
    var longitude: Double?
    var userText: String
    var guideText: String
    var tags: [String] = []
}

/// Pluggable long-term memory. Local (JSON) now; SwiftData / Supabase later can
/// adopt the same protocol without touching the rest of the app.
protocol MemoryStore {
    func add(_ record: MemoryRecord) async
    func recent(limit: Int) async -> [MemoryRecord]
    func near(_ location: CLLocation, radius: Double, limit: Int) async -> [MemoryRecord]
    func profile() async -> String
    func updateProfile(_ text: String) async
    func all() async -> [MemoryRecord]
}
