import Foundation
import Combine
import CoreLocation

/// Coordinates the glasses, location, voice, and brain for the UI.
@MainActor
final class AppModel: ObservableObject {
    @Published var glassesState: ConnectionState = .disconnected
    @Published var voiceState: ConnectionState = .disconnected
    @Published var isListening = false
    @Published var transcript = ""
    @Published var lastNarration = ""

    // Usage / cost tracking (OpenAI gives no balance API, so we meter spend).
    @Published var sessionUsage = RealtimeUsage()
    @Published var lifetimeCostUSD: Double = UserDefaults.standard.double(forKey: "lifetimeCostUSD")

    let location = LocationManager()

    // Phase 1 runs on the mock so it works in the simulator.
    // Swap to MetaDATGlassesProvider() once the SDK is integrated.
    private let glasses: GlassesProvider = MockGlassesProvider()
    private let voice = RealtimeClient()
    private let brain = TourGuideService()

    init() {
        glasses.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in self?.glassesState = state }
        }
        voice.onStateChange = { [weak self] state in
            Task { @MainActor in self?.voiceState = state }
        }
        voice.onTranscript = { [weak self] delta in
            Task { @MainActor in self?.transcript += delta }
        }
        voice.onUsage = { [weak self] usage in
            Task { @MainActor in self?.updateUsage(usage) }
        }
    }

    /// Track this session's usage and accumulate a persisted lifetime total.
    private var lastSessionCost: Double = 0
    private func updateUsage(_ usage: RealtimeUsage) {
        sessionUsage = usage
        // Add only the delta since the last report to the lifetime total.
        let cost = usage.estimatedCostUSD
        lifetimeCostUSD += max(0, cost - lastSessionCost)
        lastSessionCost = cost
        UserDefaults.standard.set(lifetimeCostUSD, forKey: "lifetimeCostUSD")
    }

    func startSession() async {
        sessionUsage = RealtimeUsage()
        lastSessionCost = 0
        location.start()
        do {
            try AudioSessionManager.shared.configureForVoiceChat()
            try await glasses.connect()
            voice.connect()
        } catch {
            glassesState = .failed(error.localizedDescription)
        }
    }

    func endSession() {
        voice.disconnect()
        glasses.disconnect()
        AudioSessionManager.shared.deactivate()
        location.stop()
    }

    // Push-to-talk: hold to speak, release to get the answer.
    func beginTalking() {
        transcript = ""
        isListening = true
        voice.startListening()
    }

    func endTalking() {
        isListening = false
        voice.stopListening()
    }

    /// "Look at this" — capture a frame and run the brain pipeline.
    func lookAtThis() async {
        do {
            let imageData = try await glasses.capturePhoto()
            let scene = CapturedScene(
                imageData: imageData,
                location: location.location,
                heading: location.heading)
            let narration = await brain.narrate(scene: scene)
            lastNarration = narration.spokenText
        } catch {
            lastNarration = "Capture failed: \(error.localizedDescription)"
        }
    }
}
