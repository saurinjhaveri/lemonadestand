import SwiftUI
#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct TourGuideApp: App {
    @StateObject private var model = AppModel()

    init() {
        #if canImport(MWDATCore)
        try? Wearables.configure()   // ignore "already configured"
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
            #if canImport(MWDATCore)
                .onOpenURL { url in
                    // Custom-scheme callback (tourguide://) — completes the Meta AI
                    // registration/permission handshakes.
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
            #endif
        }
    }
}
