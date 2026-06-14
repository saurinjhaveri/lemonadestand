import Foundation
import Combine
import CoreLocation

/// Coordinates the glasses, location, voice (Realtime or Lite), and brain.
@MainActor
final class AppModel: ObservableObject {
    @Published var glassesState: ConnectionState = .disconnected
    @Published var voiceState: ConnectionState = .disconnected
    @Published var isListening = false
    @Published var isThinking = false
    @Published var transcript = ""
    @Published var lastNarration = ""

    // Mode + backend selection (persisted).
    @Published var voiceMode: VoiceMode {
        didSet { UserDefaults.standard.set(voiceMode.rawValue, forKey: "voiceMode") }
    }
    @Published var backendChoice: BackendChoice {
        didSet { UserDefaults.standard.set(backendChoice.rawValue, forKey: "backendChoice") }
    }

    // Usage / cost tracking (Realtime only; OpenAI gives no balance API).
    @Published var sessionUsage = RealtimeUsage()
    @Published var lifetimeCostUSD: Double = UserDefaults.standard.double(forKey: "lifetimeCostUSD")

    let location = LocationManager()

    // Auto-selects the real Meta DAT provider once the SDK package is added;
    // uses the mock until then. See makeGlassesProvider().
    private let glasses: GlassesProvider = AppModel.makeGlassesProvider()
    private let voice = RealtimeClient()

    private static func makeGlassesProvider() -> GlassesProvider {
        #if canImport(MWDATCore)
        #if targetEnvironment(simulator)
        return MetaDATGlassesProvider(useMockDevice: true)   // simulated Ray-Ban
        #else
        return MetaDATGlassesProvider(useMockDevice: false)  // real glasses
        #endif
        #else
        return MockGlassesProvider()                         // SDK not added yet
        #endif
    }
    private let speech = SpeechRecognizer()
    private let speaker = Speaker()
    private let service = TourGuideService()

    private var backend: ReasoningBackend {
        backendChoice == .gpt ? OpenAIChatBackend() : GeminiBackend()
    }

    init() {
        voiceMode = VoiceMode(rawValue: UserDefaults.standard.string(forKey: "voiceMode") ?? "") ?? .lite
        backendChoice = BackendChoice(rawValue: UserDefaults.standard.string(forKey: "backendChoice") ?? "") ?? .gemini

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

    // MARK: - Session

    func startSession() async {
        sessionUsage = RealtimeUsage()
        lastSessionCost = 0
        location.start()
        do {
            try AudioSessionManager.shared.configureForVoiceChat()
            try await glasses.connect()
        } catch {
            glassesState = .failed(error.localizedDescription)
        }

        switch voiceMode {
        case .realtime:
            voice.connect()
        case .lite:
            let ok = await speech.requestAuthorization()
            voiceState = ok ? .connected : .failed("Speech/mic permission denied")
        }
    }

    func endSession() {
        voice.disconnect()
        speaker.stop()
        glasses.disconnect()
        AudioSessionManager.shared.deactivate()
        location.stop()
        isListening = false
        voiceState = .disconnected
    }

    // MARK: - Push-to-talk

    func beginTalking() {
        transcript = ""
        isListening = true
        switch voiceMode {
        case .realtime:
            voice.startListening()
        case .lite:
            speaker.stop()
            do {
                try speech.start { [weak self] partial in
                    Task { @MainActor in self?.transcript = partial }
                }
            } catch {
                transcript = "Speech error: \(error.localizedDescription)"
                isListening = false
            }
        }
    }

    func endTalking() {
        isListening = false
        switch voiceMode {
        case .realtime:
            voice.stopListening()
        case .lite:
            let text = speech.finish()
            Task { await self.respond(userText: text, imageJPEG: nil) }
        }
    }

    // MARK: - "Look at this" (vision)

    func lookAtThis() async {
        do {
            let imageData = try await glasses.capturePhoto()
            await respond(userText: "", imageJPEG: imageData)
        } catch {
            lastNarration = "Capture failed: \(error.localizedDescription)"
        }
    }

    /// Run the brain pipeline and speak the answer (Lite/look-at-this path).
    private func respond(userText: String, imageJPEG: Data?) async {
        isThinking = true
        defer { isThinking = false }
        let answer = await service.narrate(
            userText: userText, imageJPEG: imageJPEG,
            location: location.location, backend: backend)
        lastNarration = answer
        speaker.speak(answer)
    }

    // MARK: - Usage

    private var lastSessionCost: Double = 0
    private func updateUsage(_ usage: RealtimeUsage) {
        sessionUsage = usage
        let cost = usage.estimatedCostUSD
        lifetimeCostUSD += max(0, cost - lastSessionCost)
        lastSessionCost = cost
        UserDefaults.standard.set(lifetimeCostUSD, forKey: "lifetimeCostUSD")
    }
}
