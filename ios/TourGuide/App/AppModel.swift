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
    /// True while the dev/sim photo picker is up (no real glasses camera).
    @Published var isPickingImage = false

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
    /// Answer length / verbosity (anti-ramble).
    @Published var guideLength: GuideLength {
        didSet { UserDefaults.standard.set(guideLength.rawValue, forKey: "guideLength") }
    }
    /// Your standing instructions, always injected (like ChatGPT custom instructions).
    @Published var customInstructions: String {
        didSet { UserDefaults.standard.set(customInstructions, forKey: "customInstructions") }
    }
    /// Auto-narrate new Camera Roll photos (how glasses captures reach the app
    /// without the DAT SDK — they sync in via the Meta AI app).
    @Published var autoNarratePhotos: Bool {
        didSet {
            UserDefaults.standard.set(autoNarratePhotos, forKey: "autoNarratePhotos")
            Task { await applyPhotoWatcher() }
        }
    }
    /// Selected on-device voice (identifier), e.g. Zoe (Premium).
    @Published var deviceVoiceID: String = "" {
        didSet {
            deviceSpeaker.voiceIdentifier = deviceVoiceID.isEmpty ? nil : deviceVoiceID
            UserDefaults.standard.set(deviceVoiceID, forKey: "deviceVoiceID")
        }
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
    private let photoWatcher = PhotoLibraryWatcher()
    private var sessionActive = false
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
        switch choice {
        case .gemini:
            return GeminiBackend()
        case .gpt:
            return OpenAICompatibleBackend(displayName: "ChatGPT", baseURL: Config.openAIBaseURL,
                                           apiKey: Config.openAIAPIKey, model: Config.openAIChatModel,
                                           supportsVision: true)
        case .openrouter:
            return OpenAICompatibleBackend(displayName: Config.openRouterDisplayName, baseURL: Config.openRouterBaseURL,
                                           apiKey: Config.openRouterAPIKey, model: Config.openRouterModel,
                                           supportsVision: false)
        }
    }
    private var backend: ReasoningBackend { makeBackend(backendChoice) }
    /// Fallback stays on the SAME provider with a lighter model, so a free user
    /// is never silently charged for a paid provider.
    private var fallbackBackend: ReasoningBackend {
        switch backendChoice {
        case .gemini:
            return GeminiBackend(model: "gemini-2.5-flash-lite")
        case .gpt:
            return OpenAICompatibleBackend(displayName: "ChatGPT", baseURL: Config.openAIBaseURL,
                                           apiKey: Config.openAIAPIKey, model: "gpt-4o-mini",
                                           supportsVision: true)
        case .openrouter:
            return OpenAICompatibleBackend(displayName: "OpenRouter", baseURL: Config.openRouterBaseURL,
                                           apiKey: Config.openRouterAPIKey, model: Config.openRouterFallbackModel,
                                           supportsVision: false)
        }
    }

    init() {
        voiceMode = VoiceMode(rawValue: UserDefaults.standard.string(forKey: "voiceMode") ?? "") ?? .lite
        backendChoice = BackendChoice(rawValue: UserDefaults.standard.string(forKey: "backendChoice") ?? "") ?? .openrouter
        ttsEngine = TTSEngine(rawValue: UserDefaults.standard.string(forKey: "ttsEngine") ?? "") ?? .device
        guideLength = GuideLength(rawValue: UserDefaults.standard.string(forKey: "guideLength") ?? "") ?? .brief
        customInstructions = UserDefaults.standard.string(forKey: "customInstructions") ?? ""
        autoNarratePhotos = UserDefaults.standard.object(forKey: "autoNarratePhotos") as? Bool ?? true
        let savedVoice = UserDefaults.standard.string(forKey: "naturalVoice") ?? "alloy"
        naturalVoice = savedVoice
        naturalSpeaker.voice = savedVoice

        // Device voice: use the saved pick, else auto-prefer Zoe (Premium).
        let savedDeviceVoice = UserDefaults.standard.string(forKey: "deviceVoiceID") ?? ""
        if savedDeviceVoice.isEmpty {
            let voices = DeviceSpeaker.availableVoices()
            let pick = voices.first { $0.name.localizedCaseInsensitiveContains("Zoe") && $0.quality == .premium }
                ?? voices.first { $0.name.localizedCaseInsensitiveContains("Zoe") }
                ?? voices.first { $0.quality == .premium }
            deviceVoiceID = pick?.identifier ?? ""
        } else {
            deviceVoiceID = savedDeviceVoice
        }
        deviceSpeaker.voiceIdentifier = deviceVoiceID.isEmpty ? nil : deviceVoiceID

        glasses.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in self?.glassesState = state }
        }
        // Wearer pressed the glasses' capture button → narrate it hands-free.
        // Ignore captures that land while we're still answering the previous one.
        glasses.onPhotoCaptured = { [weak self] data in
            Task { @MainActor in
                guard let self, !self.isThinking else { return }
                await self.respond(userText: "", imageJPEG: data)
            }
        }
        // Same hands-free path for glasses photos that arrive via the Camera Roll
        // (the DAT-free bridge through the Meta AI app).
        photoWatcher.onNewPhoto = { [weak self] data in
            Task { @MainActor in
                guard let self, !self.isThinking else { return }
                await self.respond(userText: "", imageJPEG: data)
            }
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
        sessionActive = true
        await applyPhotoWatcher()
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
        sessionActive = false
        photoWatcher.stop()
        isListening = false
        voiceState = .disconnected
    }

    /// Start/stop the Camera Roll watcher to match the toggle + session state.
    @Published var photoWatchStatus = ""
    private func applyPhotoWatcher() async {
        if autoNarratePhotos && sessionActive {
            let ok = await photoWatcher.start()
            photoWatchStatus = ok ? "Watching Camera Roll for glasses photos"
                                  : "Photo access denied — enable it in Settings"
        } else {
            photoWatcher.stop()
            photoWatchStatus = ""
        }
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

    /// Typed prompt: tell the guide where you are / what you see.
    func ask(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        transcript = t
        Task { await respond(userText: t, imageJPEG: nil) }
    }

    // MARK: - "Look at this" (vision)

    /// Real glasses camera is only available with the DAT SDK on a device — in
    /// the simulator (or before DAT lands) we'd capture a mock placeholder, so
    /// fall back to picking a real photo to test the vision pipeline.
    private static let hasRealCamera: Bool = {
        #if canImport(MWDATCore) && !targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    func lookAtThis() async {
        guard Self.hasRealCamera else {
            isPickingImage = true   // dev/sim: pick a real photo instead of the mock frame
            return
        }
        do {
            let imageData = try await glasses.capturePhoto()
            await respond(userText: "", imageJPEG: imageData)
        } catch {
            lastNarration = "Capture failed: \(error.localizedDescription)"
        }
    }

    /// Called by the photo picker (dev/sim path) with the chosen image.
    func usePickedImage(_ data: Data?) {
        isPickingImage = false
        guard let data else { return }
        Task { await respond(userText: "", imageJPEG: data) }
    }

    /// Run the brain pipeline (with memory recall + auto-fallback), speak the
    /// answer, then record cost, conversation memory, and the journal entry.
    private func respond(userText: String, imageJPEG: Data?) async {
        isThinking = true
        defer { isThinking = false }

        let loc = resolvedLocation()   // GPS now, or last-known if signal dropped
        let mem = await buildDirectives(near: loc)

        // The chosen brain writes the answer. If it can't see and there's a photo,
        // TourGuideService runs the Gemini "eyes → brain" handoff automatically.
        let primary: ReasoningBackend = backend
        let secondary: ReasoningBackend = fallbackBackend

        // Try the primary brain; fall back to a free/lighter one on failure (e.g. 429).
        var result: GuideResult
        var ok = true
        do {
            result = try await service.narrate(
                userText: userText, imageJPEG: imageJPEG,
                location: loc, history: history, memoryContext: mem,
                backend: primary, cacheSalt: cacheSalt(primary))
        } catch {
            if autoFallback {
                do {
                    let alt = try await service.narrate(
                        userText: userText, imageJPEG: imageJPEG,
                        location: loc, history: history, memoryContext: mem,
                        backend: secondary, cacheSalt: cacheSalt(secondary))
                    result = GuideResult(text: "(via \(secondary.displayName)) " + alt.text,
                                         usage: alt.usage)
                } catch let e2 {
                    ok = false
                    result = GuideResult(text: failureText(primary: error, secondary: e2),
                                         usage: BrainUsage())
                }
            } else {
                ok = false
                result = GuideResult(
                    text: isOffline(error)
                        ? "You seem to be offline — I can't reach the guide right now. Try again when you have signal."
                        : "Sorry — \(primary.displayName) failed: \(error.localizedDescription)",
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
                          result.usage.provider.isEmpty ? primary.displayName : result.usage.provider,
                          tokens, cost)
    }

    /// Cache answers per brain + length so different settings don't collide.
    private func cacheSalt(_ b: ReasoningBackend) -> String { "\(b.displayName)|\(guideLength.rawValue)" }

    private func isOffline(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                .cannotConnectToHost, .cannotFindHost, .dataNotAllowed,
                .internationalRoamingOff].contains(url.code)
    }

    private func failureText(primary: Error, secondary: Error) -> String {
        if isOffline(primary) && isOffline(secondary) {
            return "You seem to be offline. I can only talk about places I've already told you about "
                + "(saved in your journal) — try again when you have signal."
        }
        return "Both brains failed. \(primary.localizedDescription) / \(secondary.localizedDescription)"
    }

    // MARK: - Last-known location (poor-signal fallback)

    /// Current GPS if available (cached for later), else the last good fix
    /// (if recent enough to still be useful).
    private func resolvedLocation() -> CLLocation? {
        if let loc = location.location {
            let d = UserDefaults.standard
            d.set(loc.coordinate.latitude, forKey: "lastLat")
            d.set(loc.coordinate.longitude, forKey: "lastLng")
            d.set(Date().timeIntervalSince1970, forKey: "lastLocAt")
            return loc
        }
        let d = UserDefaults.standard
        let at = d.double(forKey: "lastLocAt")
        guard at > 0, Date().timeIntervalSince1970 - at < 6 * 3600 else { return nil }  // < 6h old
        let lat = d.double(forKey: "lastLat"), lng = d.double(forKey: "lastLng")
        guard lat != 0 || lng != 0 else { return nil }
        return CLLocation(latitude: lat, longitude: lng)
    }

    /// Build the standing directives + memory injected into every prompt:
    /// length rule, your custom instructions, learned profile, nearby & recent.
    private func buildDirectives(near loc: CLLocation?) async -> String {
        var lines: [String] = []
        lines.append("Answer length: " + guideLength.directive)
        let ci = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ci.isEmpty { lines.append("User's standing instructions (obey these): \(ci)") }
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
