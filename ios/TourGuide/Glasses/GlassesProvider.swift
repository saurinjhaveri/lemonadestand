import Foundation
import UIKit

/// Abstraction over the glasses so the app can run in the simulator (Mock) and
/// against real hardware (Meta DAT) without changing the rest of the code.
protocol GlassesProvider: AnyObject {
    var connectionState: ConnectionState { get }
    var onConnectionStateChange: ((ConnectionState) -> Void)? { get set }

    /// Fired when a photo arrives that the app did NOT explicitly request — i.e.
    /// the wearer pressed the glasses' capture button. This is the hands-free
    /// trigger that runs the tour-guide pipeline automatically.
    var onPhotoCaptured: ((Data) -> Void)? { get set }

    func connect() async throws
    func disconnect()

    /// Capture a still from the glasses camera as JPEG data.
    /// `preferDevicePhoto` requests a real photo from the device (slower,
    /// highest quality — for reading text) instead of the cached stream frame.
    func capturePhoto(preferDevicePhoto: Bool) async throws -> Data
}

extension GlassesProvider {
    /// Fast path: cached stream frame when available.
    func capturePhoto() async throws -> Data {
        try await capturePhoto(preferDevicePhoto: false)
    }
}

enum GlassesError: LocalizedError {
    case notConnected
    case captureFailed
    case sdkUnavailable
    case setup(String)   // human-readable setup/registration problem

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Glasses not connected."
        case .captureFailed: return "Photo capture failed."
        case .sdkUnavailable: return "Meta DAT SDK not added. Add the SPM package to enable real glasses."
        case .setup(let message): return message
        }
    }
}

/// Simulator/dev stand-in. Returns a generated placeholder image so the full
/// pipeline (capture → location → brain) is exercisable without hardware.
final class MockGlassesProvider: GlassesProvider {
    private(set) var connectionState: ConnectionState = .disconnected {
        didSet { onConnectionStateChange?(connectionState) }
    }
    var onConnectionStateChange: ((ConnectionState) -> Void)?
    var onPhotoCaptured: ((Data) -> Void)?

    func connect() async throws {
        connectionState = .connecting
        try? await Task.sleep(nanoseconds: 600_000_000)
        connectionState = .connected
    }

    func disconnect() {
        connectionState = .disconnected
    }

    func capturePhoto(preferDevicePhoto: Bool) async throws -> Data {
        guard connectionState == .connected else { throw GlassesError.notConnected }
        let size = CGSize(width: 1024, height: 768)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "MOCK CAPTURE\n\(Date())"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white,
                .font: UIFont.boldSystemFont(ofSize: 36)
            ]
            text.draw(in: CGRect(x: 40, y: 320, width: 944, height: 200), withAttributes: attrs)
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw GlassesError.captureFailed
        }
        return data
    }
}
