import Foundation
import AVFoundation

/// Speaks the guide's answer through the glasses. Two engines:
///  • DeviceSpeaker — free, on-device (AVSpeechSynthesizer), picks the best
///    installed voice (premium > enhanced > default).
///  • OpenAITTSSpeaker — natural neural voice (small cost).
protocol GuideSpeaker: AnyObject {
    func speak(_ text: String)
    func stop()
}

/// Free, on-device. Quality depends on the installed voice — download an
/// Enhanced/Premium voice in Settings → Accessibility → Spoken Content → Voices
/// for a much less robotic sound.
final class DeviceSpeaker: NSObject, GuideSpeaker {
    private let synth = AVSpeechSynthesizer()
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var voiceIdentifier: String?

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice()
        utterance.rate = rate
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private func bestVoice() -> AVSpeechSynthesisVoice? {
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Installed English voices, for an in-app picker.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }
}

/// Natural neural voices via the OpenAI TTS API (small per-character cost).
final class OpenAITTSSpeaker: NSObject, GuideSpeaker, AVAudioPlayerDelegate {
    var voice = "alloy"                 // alloy, echo, fable, onyx, nova, shimmer, …
    var model = "gpt-4o-mini-tts"
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    func speak(_ text: String) {
        stop()
        task = Task { [weak self] in
            guard let self, Config.hasOpenAIKey else { return }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            request.httpMethod = "POST"
            request.addValue("Bearer \(Config.openAIAPIKey)", forHTTPHeaderField: "Authorization")
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": self.model, "voice": self.voice,
                "input": text, "response_format": "mp3"
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !Task.isCancelled else { return }
            await MainActor.run { self.play(data) }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        player?.stop(); player = nil
    }

    private func play(_ data: Data) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            p.play()
        } catch {
            print("[TTS] playback error: \(error)")
        }
    }
}
