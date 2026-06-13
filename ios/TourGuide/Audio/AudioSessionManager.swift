import Foundation
import AVFoundation

/// Routes audio through the glasses, which appear to iOS as a Bluetooth headset.
///
/// We use `.playAndRecord` with Bluetooth options so the glasses' mics capture
/// the wearer and the open-ear speakers play the guide's voice. This is the
/// "audio in/out" half of the system and needs no Meta SDK.
final class AudioSessionManager: @unchecked Sendable {
    static let shared = AudioSessionManager()
    private init() {}

    func configureForVoiceChat() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [])
        preferBluetoothInput(on: session)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Prefer the glasses (a Bluetooth HFP route) for input when present.
    private func preferBluetoothInput(on session: AVAudioSession) {
        guard let inputs = session.availableInputs else { return }
        let bluetooth = inputs.first { input in
            [.bluetoothHFP, .bluetoothLE].contains(input.portType)
        }
        if let bluetooth {
            try? session.setPreferredInput(bluetooth)
            print("[Audio] using glasses input: \(bluetooth.portName)")
        } else {
            print("[Audio] no Bluetooth input found — are the glasses paired?")
        }
    }

    var isGlassesRouteActive: Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        return route.outputs.contains { [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE].contains($0.portType) }
    }
}
