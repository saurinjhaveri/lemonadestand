import Foundation
import AVFoundation

/// OpenAI Realtime API client (speech-to-speech over WebSocket).
///
/// Captures mic audio (from the glasses via Bluetooth), streams PCM16 to the
/// Realtime endpoint, and plays the model's audio responses back — giving the
/// hands-free, low-latency "talking guide" conversation.
///
/// Audio format: PCM16, 24 kHz, mono (Realtime default).
final class RealtimeClient: NSObject {
    var instructions: String = TourGuidePersona.systemPrompt
    var onTranscript: ((String) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    private let sampleRate: Double = 24_000
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat!
    private var isRunning = false

    // MARK: - Lifecycle

    func connect() {
        onStateChange?(.connecting)
        guard Config.hasOpenAIKey else {
            onStateChange?(.failed("No OpenAI API key in Secrets.xcconfig"))
            return
        }
        let urlString = "wss://api.openai.com/v1/realtime?model=\(Config.realtimeModel)"
        var request = URLRequest(url: URL(string: urlString)!)
        request.addValue("Bearer \(Config.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        // GA Realtime: no "OpenAI-Beta: realtime=v1" header (that selects the
        // disabled beta shape). GA uses the nested session/audio event shapes below.
        print("[Realtime] connecting model=\(Config.realtimeModel)")

        // Retain the session (a deallocated session invalidates the task).
        // Use a delegate so we can surface the real failure (HTTP status / close code).
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        task = session.webSocketTask(with: request)
        task?.resume()
        receiveLoop()
        // .connected / sendSessionUpdate happen in didOpenWithProtocol below.
    }

    func disconnect() {
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onStateChange?(.disconnected)
    }

    // MARK: - Push-to-talk

    func startListening() {
        guard !isRunning else { return }
        isRunning = true
        prepareEngineIfNeeded()   // attach + connect player BEFORE starting
        installMicTap()
        engine.prepare()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("[Realtime] engine start failed: \(error)")
            isRunning = false
            return
        }
        if !player.isPlaying { player.play() }   // safe: graph is connected + running
    }

    func stopListening() {
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        // Commit the captured audio and ask the model to respond.
        send(["type": "input_audio_buffer.commit"])
        send(["type": "response.create"])
    }

    // MARK: - Session config

    private func sendSessionUpdate() {
        // GA shape: audio config is nested under session.audio.input/output,
        // formats are objects, and modalities are "output_modalities".
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": ["model": "whisper-1"],
                        "turn_detection": NSNull()   // manual turns via push-to-talk
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "voice": "alloy"
                    ]
                ]
            ]
        ])
    }

    // MARK: - Engine graph setup

    /// Attach + connect the playback node once, while the engine is stopped.
    /// Building the graph before starting avoids the "player started in a
    /// disconnected state" crash.
    private func prepareEngineIfNeeded() {
        guard playbackFormat == nil else { return }
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        // Touch the input node so its format is realized before we tap it.
        _ = engine.inputNode
    }

    // MARK: - Mic capture → server

    private func installMicTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hwFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.int16ChannelData else { return }
            let bytes = Int(out.frameLength) * 2
            let data = Data(bytes: channel[0], count: bytes)
            self.send([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString()
            ])
        }
    }

    private func enqueuePlayback(_ pcm16: Data) {
        let frameCount = AVAudioFrameCount(pcm16.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData else { return }
        buffer.frameLength = frameCount
        pcm16.withUnsafeBytes { raw in
            channel[0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frameCount))
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - WebSocket plumbing

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error { print("[Realtime] send error: \(error)") }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onStateChange?(.failed(error.localizedDescription))
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        // GA names first, beta names kept as fallback.
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                enqueuePlayback(pcm)
            }
        case "response.output_audio_transcript.delta", "response.output_text.delta",
             "response.audio_transcript.delta", "response.text.delta":
            if let delta = json["delta"] as? String { onTranscript?(delta) }
        case "error":
            print("[Realtime] error event: \(json)")
        default:
            break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate (diagnostics + connection state)

extension RealtimeClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        print("[Realtime] websocket open")
        onStateChange?(.connected)
        sendSessionUpdate()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        print("[Realtime] closed code=\(closeCode.rawValue) reason=\(text)")
        onStateChange?(.failed("Closed \(closeCode.rawValue) \(text)"))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if let status { print("[Realtime] HTTP status \(status)") }
        guard let error else { return }
        print("[Realtime] failed: \(error)")
        let message = status.map { code in
            switch code {
            case 401: return "401 — bad/expired OpenAI key"
            case 403: return "403 — key lacks Realtime access"
            case 404: return "404 — model '\(Config.realtimeModel)' not found"
            case 429: return "429 — rate limit / no credit"
            default:  return "HTTP \(code)"
            }
        } ?? error.localizedDescription
        onStateChange?(.failed(message))
    }
}

/// The guide's spoken persona. Mirror this in the Phase 2 vision/reasoning calls.
enum TourGuidePersona {
    static let systemPrompt = """
    You are an expert local tour guide — warm, funny, and concise. When the user \
    asks about a place, combine what they say with their surroundings to give \
    spoken-style answers (~30–45 seconds): say what it is in one vivid sentence, \
    give 2–3 genuinely interesting facts or a short story (not a Wikipedia dump), \
    and finish with practical advice for this spot: what's unmissable, and what's \
    overrated or avoidable. Keep it conversational for text-to-speech — no bullet \
    points or headers. If unsure, say what it likely is and ask one quick question.
    """
}
