import Foundation

/// Disk-backed cache of narrations keyed by landmark + question, so re-asking
/// about the same spot is instant and free (and works offline). Facts are
/// stable, so entries don't expire; we just cap the count.
actor LandmarkCache {
    private struct Entry: Codable { let text: String; let date: Date }
    private var store: [String: Entry] = [:]
    private let url: URL
    private let maxEntries = 300

    init(filename: String = "landmark_cache.json") {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            store = saved
        }
    }

    func text(for key: String) -> String? { store[key]?.text }

    func set(_ text: String, for key: String) {
        store[key] = Entry(text: text, date: Date())
        if store.count > maxEntries {
            let oldest = store.sorted { $0.value.date < $1.value.date }
            for kv in oldest.prefix(store.count - maxEntries) { store[kv.key] = nil }
        }
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: url) }
    }
}
