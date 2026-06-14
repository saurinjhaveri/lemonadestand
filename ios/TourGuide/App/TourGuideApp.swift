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
                    // Completes the Meta AI app linking handshake.
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
            #endif
        }
    }
}
