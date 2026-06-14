import Foundation
import CoreLocation

/// On-device, offline, free memory store backed by JSON files in Documents.
/// Conforms to `MemoryStore`; swap for SwiftData/Supabase later with no caller
/// changes. An actor so file I/O stays off the main thread and is serialized.
actor LocalMemoryStore: MemoryStore {
    private var records: [MemoryRecord] = []
    private var profileText = ""
    private let recordsURL: URL
    private let profileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recordsURL = docs.appendingPathComponent("memory.json")
        profileURL = docs.appendingPathComponent("profile.txt")
        if let data = try? Data(contentsOf: recordsURL),
           let decoded = try? JSONDecoder().decode([MemoryRecord].self, from: data) {
            records = decoded
        }
        profileText = (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
    }

    func add(_ record: MemoryRecord) {
        records.append(record)
        persist()
    }

    func recent(limit: Int) -> [MemoryRecord] {
        Array(records.suffix(limit).reversed())
    }

    func near(_ location: CLLocation, radius: Double, limit: Int) -> [MemoryRecord] {
        records.compactMap { r -> (MemoryRecord, Double)? in
            guard let lat = r.latitude, let lon = r.longitude else { return nil }
            let d = location.distance(from: CLLocation(latitude: lat, longitude: lon))
            return d <= radius ? (r, d) : nil
        }
        .sorted { $0.1 < $1.1 }
        .prefix(limit)
        .map(\.0)
    }

    func profile() -> String { profileText }

    func updateProfile(_ text: String) {
        profileText = text
        persist()
    }

    func all() -> [MemoryRecord] { records }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: recordsURL) }
        try? profileText.write(to: profileURL, atomically: true, encoding: .utf8)
    }
}
