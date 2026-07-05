import Foundation
import Vision
import CoreGraphics

/// Full-page text extraction for Read mode (books, newspapers, letters, menus).
/// On-device Apple Vision OCR — free, offline, private. Handles reading order,
/// multi-column layouts (newspapers), hyphenated line wraps, and paragraphs.
enum PageReader {
    struct Page {
        let text: String
        let lineCount: Int
        /// Too little text to be worth narrating — likely bad framing/focus.
        var isSparse: Bool { text.count < 80 || lineCount < 3 }
    }

    static func read(_ imageData: Data) async -> Page {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: readSync(imageData))
            }
        }
    }

    // MARK: - Private

    private struct Line { let text: String; let box: CGRect }

    private static func readSync(_ imageData: Data) -> Page {
        let handler = VNImageRequestHandler(data: imageData)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? handler.perform([request])

        let lines: [Line] = (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first, !top.string.isEmpty else { return nil }
            return Line(text: top.string, box: obs.boundingBox)
        }
        guard !lines.isEmpty else { return Page(text: "", lineCount: 0) }

        let text = clusterIntoColumns(lines)
            .map(joinColumn)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Page(text: text, lineCount: lines.count)
    }

    /// Newspapers have 2–4 columns; reading top-to-bottom across the whole page
    /// would interleave them. Cluster lines by horizontal center and read column
    /// by column — but fall back to a single flow (books, letters) unless the
    /// columns are unambiguous.
    private static func clusterIntoColumns(_ lines: [Line]) -> [[Line]] {
        let sorted = lines.sorted { $0.box.midX < $1.box.midX }
        var clusters: [[Line]] = []
        var current: [Line] = []
        var lastMidX: CGFloat = -1
        for line in sorted {
            if lastMidX >= 0, line.box.midX - lastMidX > 0.15, !current.isEmpty {
                clusters.append(current)
                current = []
            }
            current.append(line)
            lastMidX = line.box.midX
        }
        if !current.isEmpty { clusters.append(current) }

        let unambiguous = clusters.count >= 2 && clusters.count <= 4
            && clusters.allSatisfy { $0.count >= max(3, lines.count / 5) }
        return unambiguous ? clusters : [lines]
    }

    /// Order a column's lines top-to-bottom (Vision's origin is bottom-left),
    /// merge hyphenated wraps, and keep paragraph breaks.
    private static func joinColumn(_ lines: [Line]) -> String {
        let ordered = lines.sorted { a, b in
            if abs(a.box.maxY - b.box.maxY) > 0.008 { return a.box.maxY > b.box.maxY }
            return a.box.minX < b.box.minX
        }
        let heights = ordered.map(\.box.height).sorted()
        let medianH = heights[heights.count / 2]

        var out = ""
        var prevMinY: CGFloat?
        for line in ordered {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if out.isEmpty {
                out = t
            } else {
                let gap = (prevMinY ?? line.box.maxY) - line.box.maxY
                if out.hasSuffix("-"), t.first?.isLowercase == true {
                    out.removeLast()
                    out += t                       // de-hyphenate wrapped words
                } else if gap > medianH * 1.8 {
                    out += "\n\n" + t              // paragraph break
                } else {
                    out += " " + t
                }
            }
            prevMinY = line.box.minY
        }
        return out
    }
}
