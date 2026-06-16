import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text via Apple's Speech framework (free). Captures from
/// the active mic (e.g. the glasses, as a Bluetooth input) during push-to-talk.
///
/// Apple's recognizer auto-finalizes after a pause, which would cut you off
/// mid-thought. We keep the audio engine running for the whole hold and restart
/// the recognition task across pauses, accumulating the text, so capture only
/// ends when you release the button.
final class SpeechRecognizer {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""          // text from finalized segments
    private var latest = ""            // committed + current partial
    private var isActive = false
    private var onPartial: ((String) -> Void)?

    /// Ask for mic + speech permission. Returns true if both granted.
    func requestAuthorization() async -> Bool {
        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let micOK = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        return speechOK && micOK
    }

    /// Begin live transcription. `onPartial` streams the running text.
    func start(onPartial: @escaping (String) -> Void) throws {
        committed = ""; latest = ""; isActive = true
        self.onPartial = onPartial

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        beginRecognition()
    }

    /// Stop capture and return the best transcript so far.
    func finish() -> String {
        isActive = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        return latest
    }

    // MARK: - Private

    private func beginRecognition() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true   // free + private
        }
        self.request = request

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.latest = self.committed.isEmpty ? text
                    : (text.isEmpty ? self.committed : self.committed + " " + text)
                self.onPartial?(self.latest)
                if result.isFinal {
                    self.committed = self.latest
                    self.restartIfActive()
                }
            } else if error != nil {
                // Task ended (e.g. silence) — keep going if the user is still holding.
                self.restartIfActive()
            }
        }
    }

    private func restartIfActive() {
        task = nil
        request = nil
        guard isActive else { return }
        beginRecognition()
    }
}
