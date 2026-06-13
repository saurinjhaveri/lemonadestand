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
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat!
    private var isRunning = false

    // MARK: - Lifecycle

    func connect() {
        onStateChange?(.connecting)
        var request = URLRequest(url: URL(string:
            "wss://api.openai.com/v1/realtime?model=\(Config.realtimeModel)")!)
        request.addValue("Bearer \(Config.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        task = session.webSocketTask(with: request)
        task?.resume()
        receiveLoop()
        sendSessionUpdate()
        onStateChange?(.connected)
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
        startMicCapture()
        startPlayback()
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
        send([
            "type": "session.update",
            "session": [
                "instructions": instructions,
                "modalities": ["audio", "text"],
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": NSNull()   // we drive turns via push-to-talk
            ]
        ])
    }

    // MARK: - Mic capture → server

    private func startMicCapture() {
        let input = engine.inputNode
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
        try? engine.start()
    }

    // MARK: - Playback of model audio

    private func startPlayback() {
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        }
        if !engine.isRunning { try? engine.start() }
        player.play()
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
        case "response.audio.delta":
            if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                enqueuePlayback(pcm)
            }
        case "response.audio_transcript.delta", "response.text.delta":
            if let delta = json["delta"] as? String { onTranscript?(delta) }
        case "error":
            print("[Realtime] error event: \(json)")
        default:
            break
        }
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
