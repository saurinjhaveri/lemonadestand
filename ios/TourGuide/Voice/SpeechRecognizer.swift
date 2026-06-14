import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text via Apple's Speech framework (free). Captures from
/// the glasses mic (the active Bluetooth input) during push-to-talk.
final class SpeechRecognizer {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""

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
        latest = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true   // free + private
        }
        self.request = request

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.latest = result.bestTranscription.formattedString
            onPartial(self.latest)
        }
    }

    /// Stop capture and return the best transcript so far.
    func finish() -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        return latest
    }
}
