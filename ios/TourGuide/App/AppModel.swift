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
    @Published var ttsEngine: TTSEngine {
        didSet { UserDefaults.standard.set(ttsEngine.rawValue, forKey: "ttsEngine") }
    }
    /// Voice name for the Natural (OpenAI) engine.
    @Published var naturalVoice: String {
        didSet {
            naturalSpeaker.voice = naturalVoice
            UserDefaults.standard.set(naturalVoice, forKey: "naturalVoice")
        }
    }
    static let naturalVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]

    // Usage / cost tracking. OpenAI exposes no balance API; we meter spend and
    // (optionally) show real billed spend via the Admin Costs API.
    @Published var sessionUsage = RealtimeUsage()      // Realtime voice tokens
    @Published var sessionBrainUSD: Double = 0         // Gemini/ChatGPT this session
    @Published var lastTurn: String = "—"             // e.g. "Gemini · 1,240 tok · ~$0.0000"
    @Published var lifetimeCostUSD: Double = UserDefaults.standard.double(forKey: "lifetimeCostUSD")
    @Published var billedMonthText: String = ""        // from Admin Costs API

    /// Combined estimated cost this session (voice + brain).
    var sessionTotalUSD: Double { sessionUsage.estimatedCostUSD + sessionBrainUSD }

    private let billing = BillingClient()
    private var history: [ChatTurn] = []   // conversation memory (Phase 3)

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
    private let deviceSpeaker = DeviceSpeaker()
    private let naturalSpeaker = OpenAITTSSpeaker()
    private var activeSpeaker: GuideSpeaker { ttsEngine == .natural ? naturalSpeaker : deviceSpeaker }
    private let service = TourGuideService()

    // Persistent "second brain" (Phase 3). Local now; Supabase/SwiftData later.
    private let memory: MemoryStore = LocalMemoryStore()
    private let exporter = ObsidianExporter()
    private let autoFallback = true   // Gemini↔ChatGPT on failure (e.g. 429)

    private func makeBackend(_ choice: BackendChoice) -> ReasoningBackend {
        choice == .gpt ? OpenAIChatBackend() : GeminiBackend()
    }
    private var backend: ReasoningBackend { makeBackend(backendChoice) }
    private var fallbackBackend: ReasoningBackend {
        makeBackend(backendChoice == .gpt ? .gemini : .gpt)
    }

    init() {
        voiceMode = VoiceMode(rawValue: UserDefaults.standard.string(forKey: "voiceMode") ?? "") ?? .lite
        backendChoice = BackendChoice(rawValue: UserDefaults.standard.string(forKey: "backendChoice") ?? "") ?? .gemini
        ttsEngine = TTSEngine(rawValue: UserDefaults.standard.string(forKey: "ttsEngine") ?? "") ?? .device
        let savedVoice = UserDefaults.standard.string(forKey: "naturalVoice") ?? "alloy"
        naturalVoice = savedVoice
        naturalSpeaker.voice = savedVoice

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

    var canShowBilling: Bool { billing.hasAdminKey }

    func refreshBilling() async {
        guard billing.hasAdminKey else { return }
        billedMonthText = "…"
        if let usd = await billing.monthToDateUSD() {
            billedMonthText = String(format: "$%.2f this month (billed)", usd)
        } else {
            billedMonthText = "unavailable"
        }
    }

    func startSession() async {
        sessionUsage = RealtimeUsage()
        sessionBrainUSD = 0
        lastSessionCost = 0
        history.removeAll()
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

    /// Shut the guide up immediately (button / barge-in), all engines.
    func stopSpeaking() {
        deviceSpeaker.stop()
        naturalSpeaker.stop()
        voice.cancelResponse()
    }

    func endSession() {
        voice.disconnect()
        stopSpeaking()
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
            stopSpeaking()
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

    /// Run the brain pipeline (with memory recall + auto-fallback), speak the
    /// answer, then record cost, conversation memory, and the journal entry.
    private func respond(userText: String, imageJPEG: Data?) async {
        isThinking = true
        defer { isThinking = false }

        let loc = location.location
        let mem = await buildMemoryContext(near: loc)

        // Try the selected brain; fall back to the other on failure (e.g. 429).
        var result: GuideResult
        var ok = true
        do {
            result = try await service.narrate(
                userText: userText, imageJPEG: imageJPEG,
                location: loc, history: history, memoryContext: mem, backend: backend)
        } catch {
            if autoFallback {
                do {
                    let alt = try await service.narrate(
                        userText: userText, imageJPEG: imageJPEG,
                        location: loc, history: history, memoryContext: mem, backend: fallbackBackend)
                    result = GuideResult(text: "(via \(fallbackBackend.displayName)) " + alt.text,
                                         usage: alt.usage)
                } catch let e2 {
                    ok = false
                    result = GuideResult(
                        text: "Both brains failed. \(backend.displayName): \(error.localizedDescription). "
                            + "\(fallbackBackend.displayName): \(e2.localizedDescription)",
                        usage: BrainUsage())
                }
            } else {
                ok = false
                result = GuideResult(
                    text: "Sorry — \(backend.displayName) failed: \(error.localizedDescription)",
                    usage: BrainUsage())
            }
        }

        lastNarration = result.text
        activeSpeaker.speak(result.text)

        // Short-term conversation memory for follow-ups.
        let said = userText.isEmpty ? "(looked at something)" : userText
        history.append(ChatTurn(role: .user, text: said))
        history.append(ChatTurn(role: .assistant, text: result.text))
        if history.count > 8 { history.removeFirst(history.count - 8) }

        // Persist successful turns to the long-term store + Obsidian journal.
        if ok {
            let name = await placeName(for: loc)
            let record = MemoryRecord(
                placeName: name,
                latitude: loc?.coordinate.latitude,
                longitude: loc?.coordinate.longitude,
                userText: said, guideText: result.text)
            await memory.add(record)
            await exporter.append(record)
        }

        // Per-turn cost meter.
        let cost = result.usage.estimatedCostUSD
        sessionBrainUSD += cost
        lifetimeCostUSD += cost
        UserDefaults.standard.set(lifetimeCostUSD, forKey: "lifetimeCostUSD")
        let tokens = result.usage.inputTokens + result.usage.outputTokens
        lastTurn = String(format: "%@ · %d tok · ~$%.4f",
                          result.usage.provider.isEmpty ? backend.displayName : result.usage.provider,
                          tokens, cost)
    }

    /// Build a compact memory context: profile + nearby + recent records.
    private func buildMemoryContext(near loc: CLLocation?) async -> String {
        var lines: [String] = []
        let profile = await memory.profile()
        if !profile.isEmpty { lines.append("Traveler profile: \(profile)") }
        if let loc {
            for r in await memory.near(loc, radius: 400, limit: 3) {
                lines.append("Been near here before: \(r.placeName ?? "a spot") — "
                             + String(r.guideText.prefix(120)))
            }
        }
        for r in await memory.recent(limit: 3) {
            lines.append("Recently you asked: \"\(r.userText)\"")
        }
        return lines.joined(separator: "\n")
    }

    private func placeName(for loc: CLLocation?) async -> String? {
        guard let loc else { return nil }
        let marks = try? await CLGeocoder().reverseGeocodeLocation(loc)
        return marks?.first.flatMap { $0.name ?? $0.locality }
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
