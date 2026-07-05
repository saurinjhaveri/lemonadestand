import Foundation
import Combine
import CoreLocation
import UIKit

/// Coordinates location, on-device voice (Lite), the Camera Roll bridge, and the
/// reasoning/vision brain. Glasses reach the app by syncing their photos to the
/// iPhone Camera Roll (via the Meta AI app), which we watch and auto-narrate.
@MainActor
final class AppModel: ObservableObject {
    @Published var voiceState: ConnectionState = .disconnected   // mic/speech readiness
    @Published var glassesState: ConnectionState = .disconnected // DAT live stream
    @Published var isListening = false
    @Published var isThinking = false
    @Published var transcript = ""
    @Published var lastNarration = ""
    @Published var isPickingImage = false
    @Published var photoWatchStatus = ""
    /// Read mode: narrating pages (book/newspaper/letter) via on-device OCR.
    @Published private(set) var readModeActive = false
    private var readPageCount = 0

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

    // Live glasses connection (Meta DAT). Optional: the Camera Roll bridge keeps
    // working without it; when connected, capture is instant from the stream.
    private let glasses: GlassesProvider = AppModel.makeGlassesProvider()
    private static func makeGlassesProvider() -> GlassesProvider {
        #if canImport(MWDATCore)
        #if targetEnvironment(simulator)
        return MetaDATGlassesProvider(useMockDevice: true)   // simulated Ray-Ban
        #else
        return MetaDATGlassesProvider(useMockDevice: false)  // real glasses
        #endif
        #else
        return MockGlassesProvider()
        #endif
    }

    private let speech = SpeechRecognizer()
    private let deviceSpeaker = DeviceSpeaker()
    private let naturalSpeaker = OpenAITTSSpeaker()
    private var activeSpeaker: GuideSpeaker { ttsEngine == .natural ? naturalSpeaker : deviceSpeaker }
    private let service = TourGuideService()

    // Escalation OCR for Read mode (soft/low-res pages).
    private let pageTranscriber = GeminiBackend()

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

        glasses.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in self?.glassesState = state }
        }
        // Photos delivered by the live DAT stream (app-requested captures resolve
        // their own continuation; anything unsolicited lands here).
        glasses.onPhotoCaptured = { [weak self] data in
            Task { @MainActor in
                guard let self, !self.isThinking else { return }
                await self.respond(userText: "", imageJPEG: data)
            }
        }
        // A new photo in the Camera Roll (e.g. synced from the glasses) → narrate
        // it hands-free. Acknowledge the instant it's detected (before the image
        // even loads) so the wait feels short.
        photoWatcher.onPhotoDetected = { [weak self] in
            Task { @MainActor in
                guard let self, !self.isThinking else { return }
                self.stopSpeaking()                       // new capture interrupts old answer
                self.transcript = "(new photo from glasses)"
                self.activeSpeaker.speak("Got it — taking a look.")
            }
        }
        photoWatcher.onNewPhoto = { [weak self] data in
            Task { @MainActor in
                guard let self, !self.isThinking else { return }
                if self.readModeActive {
                    // Hardware-button photos are full-resolution — the sharpest
                    // possible page scan for Read mode.
                    await self.readPage(data)
                } else {
                    await self.respond(userText: "", imageJPEG: data)
                }
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
        // Live glasses stream is a bonus, not a requirement — connect in the
        // background; the Camera Roll bridge works either way.
        Task { await retryGlasses() }
    }

    /// Attempt (or re-attempt) the live DAT glasses connection.
    func retryGlasses() async {
        do {
            try await glasses.connect()
        } catch {
            glassesState = .failed(error.localizedDescription)
        }
    }

    func endSession() {
        stopSpeaking()
        glasses.disconnect()
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
        Task { await route(text) }
    }

    /// Route a spoken/typed turn: read-mode commands first, then read/look
    /// intents, then the normal conversation pipeline.
    private func route(_ text: String) async {
        if readModeActive {
            if Self.isDoneReadingIntent(text) { stopReading(); return }
            if text.trimmingCharacters(in: .whitespaces).isEmpty
                || Self.isNextPageIntent(text) || Self.isReadIntent(text) {
                await captureAndReadPage()
                return
            }
            readModeActive = false   // a real question mid-read → answer it normally
            photoWatcher.fullResolution = false
        }
        if Self.isReadIntent(text) {
            await startReading()
            return
        }
        // Hands-free point-and-shoot: if the live stream is up and you're
        // asking about what you SEE, grab a frame instantly — no button.
        if glassesState == .connected, Self.isLookIntent(text),
           let frame = try? await glasses.capturePhoto() {
            await respond(userText: text, imageJPEG: frame)
            return
        }
        await respond(userText: text, imageJPEG: nil)
    }

    /// "What am I looking at?"-style asks that should trigger a live capture.
    private static func isLookIntent(_ t: String) -> Bool {
        let s = t.lowercased()
        guard !s.isEmpty else { return false }
        return ["look at this", "looking at", "what is this", "what's this", "whats this",
                "what is that", "what's that", "whats that", "see this", "check this out",
                "tell me about this"].contains { s.contains($0) }
    }

    private static func isReadIntent(_ t: String) -> Bool {
        let s = t.lowercased()
        return ["read this", "read the", "read that", "read it", "read to me", "read book",
                "read a book", "read newspaper", "read page", "start reading", "read mode",
                "scan this"].contains { s.contains($0) }
    }

    private static func isNextPageIntent(_ t: String) -> Bool {
        let s = t.lowercased()
        return ["next page", "next", "continue", "keep going", "turn the page",
                "go on"].contains { s.contains($0) }
    }

    private static func isDoneReadingIntent(_ t: String) -> Bool {
        let s = t.lowercased()
        return ["stop reading", "done reading", "that's it", "thats it", "i'm done",
                "im done", "finished", "stop"].contains { s.contains($0) }
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

    /// "Look at this": instant frame from the live glasses stream when connected;
    /// otherwise pick a photo (camera on device, library otherwise).
    func lookAtThis() async {
        if glassesState == .connected {
            transcript = "(looking through the glasses)"
            isThinking = true                       // immediate feedback during capture
            let frame = try? await glasses.capturePhoto()
            isThinking = false
            if let frame {
                await respond(userText: "", imageJPEG: frame)
            } else {
                lastNarration = "Couldn't grab a frame from the glasses — try again."
                activeSpeaker.speak("Sorry, I couldn't grab that. Try again.")
            }
            return
        }
        isPickingImage = true
    }

    func usePickedImage(_ data: Data?) {
        isPickingImage = false
        guard let data else { return }
        Task {
            if readModeActive { await readPage(data) }
            else { await respond(userText: "", imageJPEG: data) }
        }
    }

    // MARK: - Read mode (books / newspapers / letters — on-device OCR → speech)

    func startReading() async {
        stopSpeaking()
        readModeActive = true
        photoWatcher.fullResolution = true    // hardware-button pages at full 12MP
        readPageCount = 0
        await captureAndReadPage()
    }

    func captureAndReadPage() async {
        if glassesState == .connected {
            isThinking = true
            // Text needs pixels: ask the glasses for a REAL photo (slower than
            // the cached stream frame, far sharper). Falls back internally.
            let shot = try? await glasses.capturePhoto(preferDevicePhoto: true)
            isThinking = false
            if let shot { await readPage(shot); return }
        }
        isPickingImage = true   // picked photo routes to readPage while in read mode
    }

    func stopReading() {
        readModeActive = false
        photoWatcher.fullResolution = false
        stopSpeaking()
        transcript = ""
        lastNarration = ""
    }

    /// Distinctive words for cross-checking an AI transcription against what
    /// the on-device OCR actually saw.
    private static func contentWords(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 })
    }

    /// OCR the page on-device (free/offline); a low-confidence read may be
    /// repaired by verified AI transcription (~$0.001/page). Unreadable pages
    /// get an honest tip — never invented text.
    /// Deliberately no journaling: what you read stays on the phone.
    private func readPage(_ imageJPEG: Data) async {
        isThinking = true
        defer { isThinking = false }

        var text: String?
        var tag = ""

        // 1) Google Cloud Vision document OCR when configured — purpose-built
        //    for dense pages and imperfect scans, verbatim by construction.
        if !Config.googleVisionAPIKey.isEmpty {
            if let cloud = try? await CloudOCR.transcribe(imageJPEG), cloud.count > 40 {
                text = cloud
                tag = " · Cloud"
            }
        }

        // 2) On-device OCR (free/offline), with verified AI repair for shaky
        //    reads: AI may only repair a real read, and only when it agrees with
        //    most of the words the on-device OCR actually saw — never invent.
        if text == nil {
            var page = await PageReader.read(imageJPEG)
            if !page.isSparse, page.confidence < 0.35,
               let ai = try? await pageTranscriber.transcribePage(imageJPEG),
               !ai.uppercased().contains("UNREADABLE"), ai.count > 40 {
                let seen = Self.contentWords(page.text)
                let claimed = Self.contentWords(ai)
                let overlap = seen.isEmpty ? 0
                    : Double(seen.intersection(claimed).count) / Double(seen.count)
                if overlap >= 0.5 {
                    page = PageReader.Page(text: ai, lineCount: page.lineCount, confidence: 1)
                    tag = " · AI"
                }
            }
            if !page.isSparse { text = page.text }
        }

        guard let text else {
            let tip = glassesState == .connected
                ? "I couldn't read much there. Hold the page about arm's length away — too "
                  + "close goes out of focus — keep it steady, or press the capture button "
                  + "on your glasses for the sharpest photo."
                : "I couldn't read much there. Try a sharper photo from about arm's length."
            lastNarration = tip
            deviceSpeaker.speak(tip)
            return
        }

        readPageCount += 1
        // Show source resolution + engine — makes any bad read attributable.
        if let dims = UIImage(data: imageJPEG)?.size {
            transcript = String(format: "(page %d · %.0f×%.0f%@)", readPageCount, dims.width, dims.height, tag)
        } else {
            transcript = "(page \(readPageCount)\(tag))"
        }
        lastNarration = text
        // Long-form reading always uses the free on-device voice — a whole page
        // through a paid TTS API would cost real money and hit size limits.
        deviceSpeaker.speak(text)
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

        let t0 = Date()
        let loc = resolvedLocation()
        let revisit = updateCheckin(at: loc)   // coordinate grid — no geocode on the hot path
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
                      loc: loc, fallbackProvider: primary.displayName,
                      elapsed: Date().timeIntervalSince(t0))
    }

    /// Speak + record a finished turn (shared by the normal and QR paths).
    /// Speaking happens FIRST; the geocode for the journal runs after, off the
    /// perceived-latency path.
    private func deliver(_ result: GuideResult, ok: Bool, said: String,
                         loc: CLLocation?, placeName: String? = nil,
                         fallbackProvider: String, elapsed: TimeInterval? = nil) async {
        lastNarration = result.text
        activeSpeaker.speak(result.text)

        history.append(ChatTurn(role: .user, text: said))
        history.append(ChatTurn(role: .assistant, text: result.text))
        if history.count > 8 { history.removeFirst(history.count - 8) }

        if ok {
            var name = placeName
            if name == nil, let mark = await placemark(for: loc) {
                name = mark.name ?? mark.locality
            }
            let record = MemoryRecord(
                placeName: name,
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
        let timing = elapsed.map { String(format: " · %.1fs", $0) } ?? ""
        lastTurn = String(format: "%@ · %d tok · ~$%.4f%@",
                          result.usage.provider.isEmpty ? fallbackProvider : result.usage.provider,
                          tokens, cost, timing)
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

    /// True if we're still in the same ~550m grid cell we last introduced (so
    /// skip the area intro). Coordinate-based — reverse geocoding cost 1–3s per
    /// turn on the hot path. Records the new cell as checked-in.
    private func updateCheckin(at loc: CLLocation?) -> Bool {
        guard let c = loc?.coordinate else { return false }
        let cell = String(format: "%.3f,%.3f",
                          (c.latitude * 200).rounded() / 200,
                          (c.longitude * 200).rounded() / 200)
        if cell == lastCheckinArea { return true }
        lastCheckinArea = cell
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
