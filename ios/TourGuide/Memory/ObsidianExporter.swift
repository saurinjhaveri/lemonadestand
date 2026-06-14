import Foundation

/// Mirrors memories into a markdown "vault" folder (Documents/TourGuideVault),
/// one daily note with `[[place]]` backlinks and `#tags` — open it in Obsidian.
///
/// Make it browsable in Files/Obsidian by enabling file sharing in Info.plist
/// (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace — set in project.yml),
/// or point Obsidian (via iCloud/Obsidian Sync) at this folder.
actor ObsidianExporter {
    private let dir: URL
    private let dayFmt = ISO8601DateFormatter()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("TourGuideVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func append(_ r: MemoryRecord) {
        let day = day(r.date)
        let time = clock(r.date)
        let place = r.placeName ?? "Unknown spot"
        let file = dir.appendingPathComponent("\(day).md")

        var entry = "\n## \(time) — [[\(place)]]\n"
        if let lat = r.latitude, let lon = r.longitude {
            entry += String(format: "*%.5f, %.5f*\n\n", lat, lon)
        }
        if !r.userText.isEmpty { entry += "**You:** \(r.userText)\n\n" }
        entry += "**Guide:** \(r.guideText)\n"
        if !r.tags.isEmpty {
            entry += "\n" + r.tags.map { "#\($0)" }.joined(separator: " ") + "\n"
        }

        let header = "# Tour journal — \(day)\n"
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? header
        try? (existing + entry).write(to: file, atomically: true, encoding: .utf8)
    }

    private func day(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    private func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }
}
