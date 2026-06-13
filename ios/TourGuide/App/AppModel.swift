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
    }

    func startSession() async {
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
