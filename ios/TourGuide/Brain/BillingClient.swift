import Foundation

/// OpenAI billing via the **Admin** API. The remaining-balance endpoint
/// (`credit_grants`) is browser-session-only and rejects API keys, so we report
/// actual *billed spend* via the Costs API instead — the closest API-accessible
/// figure. Requires an Admin key (sk-admin-…) in Secrets.plist as `OpenAIAdminKey`.
final class BillingClient {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    var hasAdminKey: Bool {
        let k = Config.openAIAdminKey
        return !k.isEmpty && k.hasPrefix("sk-")
    }

    /// Total billed USD since the start of the current month (UTC), or nil.
    func monthToDateUSD() async -> Double? {
        guard hasAdminKey else { return nil }

        let cal = Calendar(identifier: .gregorian)
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let start = Int(startOfMonth.timeIntervalSince1970)

        var comps = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        comps.queryItems = [
            .init(name: "start_time", value: String(start)),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31")
        ]
        var request = URLRequest(url: comps.url!)
        request.addValue("Bearer \(Config.openAIAdminKey)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["data"] as? [[String: Any]] else {
            return nil
        }
        var total = 0.0
        for bucket in buckets {
            guard let results = bucket["results"] as? [[String: Any]] else { continue }
            for result in results {
                if let amount = result["amount"] as? [String: Any],
                   let value = amount["value"] as? Double {
                    total += value
                }
            }
        }
        return total
    }
}
