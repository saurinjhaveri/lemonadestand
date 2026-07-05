import Foundation

/// Fetches a QR-linked web page and reduces it to speakable text (title + body,
/// scripts/styles/tags stripped, whitespace collapsed, capped for the prompt).
enum WebPageReader {
    static func fetchReadableText(from url: URL, maxChars: Int = 6000) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (iPhone; like Safari)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return nil }

        var html = raw
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>",
                        "<!--[\\s\\S]*?-->", "<noscript[\\s\\S]*?</noscript>"] {
            html = html.replacingOccurrences(of: pattern, with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        let title = firstMatch("<title[^>]*>([\\s\\S]*?)</title>", in: html)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in entities { text = text.replacingOccurrences(of: k, with: v) }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let body = String(text.prefix(maxChars))
        if let title, !title.isEmpty { return "TITLE: \(title)\n\(body)" }
        return body
    }

    /// Interpret a QR payload as a fetchable web URL (adds https:// for bare
    /// "www.example.com"-style payloads). Nil for wifi/contact/plain-text codes.
    static func url(fromQRPayload payload: String) -> URL? {
        let s = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://") {
            return URL(string: s)
        }
        if s.lowercased().hasPrefix("www."), !s.contains(" ") {
            return URL(string: "https://\(s)")
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
