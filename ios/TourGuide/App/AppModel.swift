import Foundation
import Combine
import CoreLocation

/// Coordinates location, on-device voice (Lite), the Camera Roll bridge, and the
/// reasoning/vision brain. Glasses reach the app by syncing their photos to the
/// iPhone Camera Roll (via the Meta AI app), which we watch and auto-narrate.
@MainActor
final class AppModel: ObservableObject {
    @Published var voiceState: ConnectionState = .disconnected   // mic/speech readiness
    @Published var isListening = false
    @Published var isThinking = false
    @Published var transcript = ""
    @Published var lastNarration = ""
    @Published var isPickingImage = false
    @Published var photoWatchStatus = ""

    // Settings (persisted).
    @Published var backendChoice: BackendChoice {
        didSet { UserDefaults.standard.set(backendChoice.rawValue, forKey: "backendChoice") }
    }
    @Published var ttsEngine: TTSEngine {
        didSet { UserDefaults.standard.set(ttsEngine.rawValue, forKey: "ttsEngine") }
    }
    @Published var guideLength: GuideLength {
        didSet { UserDefaults.standard.set(guideLength.rawValue, forKey: "guideLength") }
    }
    @Published var customInstructions: String {
        didSet { UserDefaults.standard.set(customInstructions, forKey: "customInstructions") }
    }
    /// Auto-narrate new Camera Roll photos (how glasses captures reach the app —
    /// they sync in via the Meta AI app).
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
    /// Voice name for the Natural (OpenAI) TTS engine.
    @Published var naturalVoice: String {
        didSet {
            naturalSpeaker.voice = naturalVoice
            UserDefaults.standard.set(naturalVoice, forKey: "naturalVoice")
        }
    }
    static let naturalVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]

    // Cost tracking (brain spend). OpenAI exposes no balance API; we estimate and
    // (optionally) show real billed spend via the Admin Costs API.
    @Published var sessionBrainUSD: Double = 0
    @Published var lastTurn: String = "—"
    @Published var lifetimeCostUSD: Double = UserDefaults.standard.double(forKey: "lifetimeCostUSD")
    @Published var billedMonthText: String = ""

    var sessionTotalUSD: Double { sessionBrainUSD }

    private let billing = BillingClient()
    private let photoWatcher = PhotoLibraryWatcher()
    @Published private(set) var sessionActive = false
    private var history: [ChatTurn] = []

    let location = LocationManager()

    private let speech = SpeechRecognizer()
    private let deviceSpeaker = DeviceSpeaker()
    private let naturalSpeaker = OpenAITTSSpeaker()
    private var activeSpeaker: GuideSpeaker { ttsEngine == .natural ? naturalSpeaker : deviceSpeaker }
    private let service = TourGuideService()

    // Persistent "second brain": traveler profile + per-place recall + journal.
    private let memory: MemoryStore = LocalMemoryStore()
    private let exporter = ObsidianExporter()
    private let autoFallback = true   // fall back to a lighter same-provider model on failure

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

        // A new photo in the Camera Roll (e.g. synced from the glasses) → narrate
        // it hands-free. Ignore captures that land while we're still answering.
        photoWatcher.onNewPhoto = { [weak self] data in
            Task { @MainActor in
                guard let self, !self.isThinking else { return }
                await self.respond(userText: "", imageJPEG: data)
            }
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
        sessionBrainUSD = 0
        history.removeAll()
        sessionActive = true
        await applyPhotoWatcher()
        location.start()
        try? AudioSessionManager.shared.configureForVoiceChat()
        let ok = await speech.requestAuthorization()
        voiceState = ok ? .connected : .failed("Speech/mic permission denied")
    }

    func endSession() {
        stopSpeaking()
        AudioSessionManager.shared.deactivate()
        location.stop()
        photoWatcher.stop()
        sessionActive = false
        isListening = false
        voiceState = .disconnected
    }

    /// Shut the guide up immediately (button / barge-in).
    func stopSpeaking() {
        deviceSpeaker.stop()
        naturalSpeaker.stop()
    }

    /// Start/stop the Camera Roll watcher to match the toggle + session state.
    private func applyPhotoWatcher() async {
        if autoNarratePhotos && sessionActive {
            let ok = await photoWatcher.start()
            photoWatchStatus = ok ? "Watching for new photos" : "Photo access denied — enable in Settings"
        } else {
            photoWatcher.stop()
            photoWatchStatus = ""
        }
    }

    // MARK: - Push-to-talk (on-device speech)

    func beginTalking() {
        transcript = ""
        isListening = true
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

    func endTalking() {
        isListening = false
        let text = speech.finish()
        Task { await self.respond(userText: text, imageJPEG: nil) }
    }

    /// Typed prompt: tell the guide where you are / what you see.
    func ask(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        transcript = t
        Task { await respond(userText: t, imageJPEG: nil) }
    }

    // MARK: - On-screen follow-ups (tap instead of speaking)

    private func send(_ prompt: String, shownAs label: String) {
        transcript = label
        Task { await respond(userText: prompt, imageJPEG: nil) }
    }
    func tellMore()  { send("Tell me more about this — go deeper with a short story or a couple more facts.", shownAs: "Tell me more") }
    func whereNext() { send("Where should I go next nearby, and why? Pick the single best spot.", shownAs: "Where to next?") }
    func thatsIt()   { stopSpeaking(); transcript = ""; lastNarration = "" }

    // MARK: - "Look at this" (manual photo)

    /// Pick a photo to identify (camera on device, library otherwise). The
    /// hands-free path is the Camera Roll watcher; this is the manual trigger.
    func lookAtThis() async {
        isPickingImage = true
    }

    func usePickedImage(_ data: Data?) {
        isPickingImage = false
        guard let data else { return }
        Task { await respond(userText: "", imageJPEG: data) }
    }

    /// Run the brain pipeline (memory recall + auto-fallback), speak the answer,
    /// then record cost, conversation memory, and the journal entry.
    private func respond(userText: String, imageJPEG: Data?) async {
        isThinking = true
        defer { isThinking = false }

        // On-device scan first (free, instant): QR codes take a dedicated fast
        // path; readable signs/labels become a grounding hint for the brain.
        var sceneText = ""
        if let imageJPEG {
            let scan = await SceneScanner.scan(imageJPEG)
            if let qr = scan.qrPayloads.first {
                await respondToQR(qr)
                return
            }
            sceneText = scan.hintText
        }

        let loc = resolvedLocation()
        let mark = await placemark(for: loc)
        let revisit = updateCheckin(area: mark?.subLocality ?? mark?.locality)
        let mem = await buildDirectives(near: loc, revisit: revisit)

        // The chosen brain writes the answer. If it can't see and there's a photo,
        // TourGuideService runs the Gemini "eyes → brain" handoff automatically.
        let primary: ReasoningBackend = backend
        let secondary: ReasoningBackend = fallbackBackend

        var result: GuideResult
        var ok = true
        do {
            result = try await service.narrate(
                userText: userText, imageJPEG: imageJPEG,
                location: loc, history: history, memoryContext: mem,
                sceneText: sceneText,
                backend: primary, cacheSalt: cacheSalt(primary))
        } catch {
            if autoFallback {
                do {
                    result = try await service.narrate(
                        userText: userText, imageJPEG: imageJPEG,
                        location: loc, history: history, memoryContext: mem,
                        sceneText: sceneText,
                        backend: secondary, cacheSalt: cacheSalt(secondary))
                } catch let e2 {
                    ok = false
                    result = GuideResult(text: failureText(primary: error, secondary: e2),
                                         usage: BrainUsage())
                }
            } else {
                ok = false
                result = GuideResult(
                    text: isOffline(error)
                        ? "You seem to be offline — try again when you have signal."
                        : "Sorry — \(primary.displayName) failed: \(error.localizedDescription)",
                    usage: BrainUsage())
            }
        }

        await deliver(result, ok: ok,
                      said: userText.isEmpty ? "(looked at something)" : userText,
                      loc: loc, placeName: mark?.name ?? mark?.locality,
                      fallbackProvider: primary.displayName)
    }

    /// Speak + record a finished turn (shared by the normal and QR paths).
    private func deliver(_ result: GuideResult, ok: Bool, said: String,
                         loc: CLLocation?, placeName: String?,
                         fallbackProvider: String) async {
        lastNarration = result.text
        activeSpeaker.speak(result.text)

        history.append(ChatTurn(role: .user, text: said))
        history.append(ChatTurn(role: .assistant, text: result.text))
        if history.count > 8 { history.removeFirst(history.count - 8) }

        if ok {
            let record = MemoryRecord(
                placeName: placeName,
                latitude: loc?.coordinate.latitude,
                longitude: loc?.coordinate.longitude,
                userText: said, guideText: result.text)
            await memory.add(record)
            await exporter.append(record)
        }

        let cost = result.usage.estimatedCostUSD
        sessionBrainUSD += cost
        lifetimeCostUSD += cost
        UserDefaults.standard.set(lifetimeCostUSD, forKey: "lifetimeCostUSD")
        let tokens = result.usage.inputTokens + result.usage.outputTokens
        lastTurn = String(format: "%@ · %d tok · ~$%.4f",
                          result.usage.provider.isEmpty ? fallbackProvider : result.usage.provider,
                          tokens, cost)
    }

    // MARK: - QR fast path

    /// A QR code in the photo takes priority: URL codes → fetch the page and
    /// summarize it aloud; other payloads (wifi/plain text) are read out as-is.
    private func respondToQR(_ payload: String) async {
        transcript = "(scanned a QR code)"
        let loc = resolvedLocation()

        guard let url = WebPageReader.url(fromQRPayload: payload) else {
            let text = "This QR code isn't a website. It contains: \(payload)"
            await deliver(GuideResult(text: text, usage: BrainUsage()), ok: true,
                          said: "(scanned a QR code)", loc: loc, placeName: nil,
                          fallbackProvider: "on-device")
            return
        }

        guard let page = await WebPageReader.fetchReadableText(from: url) else {
            let text = "I found a QR code linking to \(url.host ?? url.absoluteString), "
                + "but I couldn't load the page."
            await deliver(GuideResult(text: text, usage: BrainUsage()), ok: false,
                          said: "(scanned a QR code)", loc: loc, placeName: nil,
                          fallbackProvider: "on-device")
            return
        }

        let mem = await buildDirectives(near: loc, revisit: true)   // no area intro for QR reads
        let prompt = """
        I scanned a QR code linking to \(url.absoluteString). Below is the page's text. \
        Tell me, spoken-style, what this page is and the key useful information \
        (headline facts, prices, hours, instructions, menu highlights — whatever applies). \
        Don't read the URL aloud.

        PAGE TEXT:
        \(page)
        """

        var result: GuideResult
        var ok = true
        do {
            result = try await backend.generate(
                userText: prompt, imageJPEG: nil, location: nil, candidates: [],
                grounding: "", history: [], memoryContext: mem)
        } catch {
            do {
                result = try await fallbackBackend.generate(
                    userText: prompt, imageJPEG: nil, location: nil, candidates: [],
                    grounding: "", history: [], memoryContext: mem)
            } catch let e2 {
                ok = false
                result = GuideResult(
                    text: "I loaded \(url.host ?? "the page") but couldn't summarize it: \(e2.localizedDescription)",
                    usage: BrainUsage())
            }
        }
        await deliver(result, ok: ok,
                      said: "(scanned a QR code → \(url.host ?? url.absoluteString))",
                      loc: loc, placeName: url.host, fallbackProvider: backend.displayName)
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
        guard at > 0, Date().timeIntervalSince1970 - at < 6 * 3600 else { return nil }
        let lat = d.double(forKey: "lastLat"), lng = d.double(forKey: "lastLng")
        guard lat != 0 || lng != 0 else { return nil }
        return CLLocation(latitude: lat, longitude: lng)
    }

    // Remember which neighborhood we've already introduced, so we don't repeat
    // the area intro every turn (persists across sessions = the "check-in").
    private var lastCheckinArea: String {
        get { UserDefaults.standard.string(forKey: "lastCheckinArea") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "lastCheckinArea") }
    }

    /// True if we're still in the same neighborhood we last introduced (so skip
    /// the area intro). Records a new area as checked-in.
    private func updateCheckin(area: String?) -> Bool {
        guard let area, !area.isEmpty else { return false }
        if area == lastCheckinArea { return true }
        lastCheckinArea = area
        return false
    }

    /// Standing directives + memory injected into every prompt: length rule,
    /// custom instructions, learned profile, nearby & recent.
    private func buildDirectives(near loc: CLLocation?, revisit: Bool) async -> String {
        var lines: [String] = []
        lines.append("Answer length: " + guideLength.directive)
        if revisit {
            lines.append("I'm still in a neighborhood you've already introduced — do NOT re-describe "
                + "the area or give general neighborhood context again; answer only the specific "
                + "place or question.")
        }
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

    private func placemark(for loc: CLLocation?) async -> CLPlacemark? {
        guard let loc else { return nil }
        return (try? await CLGeocoder().reverseGeocodeLocation(loc))?.first
    }
}
