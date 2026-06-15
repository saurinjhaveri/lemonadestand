import SwiftUI
#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct TourGuideApp: App {
    @StateObject private var model = AppModel()

    init() {
        #if canImport(MWDATCore)
        try? Wearables.configure()   // Meta DAT SDK init (no-op until package added)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
            #if canImport(MWDATCore)
                .onOpenURL { url in
                    // Custom-scheme callback (tourguide://) for the linking handshake.
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    // Universal Link callback (https://…github.io/…) for the handshake.
                    guard let url = activity.webpageURL else { return }
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
            #endif
        }
    }
}
