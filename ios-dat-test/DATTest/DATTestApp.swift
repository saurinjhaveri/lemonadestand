import SwiftUI
#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct DATTestApp: App {
    @StateObject private var tester = DATTester()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tester)
            #if canImport(MWDATCore)
                .onOpenURL { url in
                    tester.log("onOpenURL: \(url.absoluteString.prefix(80))")
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    tester.log("universalLink: \(url.absoluteString.prefix(80))")
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
            #endif
        }
    }
}
