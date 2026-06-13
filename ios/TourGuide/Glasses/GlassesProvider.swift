import Foundation
import UIKit

/// Abstraction over the glasses so the app can run in the simulator (Mock) and
/// against real hardware (Meta DAT) without changing the rest of the code.
protocol GlassesProvider: AnyObject {
    var connectionState: ConnectionState { get }
    var onConnectionStateChange: ((ConnectionState) -> Void)? { get set }

    func connect() async throws
    func disconnect()

    /// Capture a single still from the glasses camera as JPEG data.
    func capturePhoto() async throws -> Data
}

enum GlassesError: Error {
    case notConnected
    case captureFailed
    case sdkUnavailable
}

/// Simulator/dev stand-in. Returns a generated placeholder image so the full
/// pipeline (capture → location → brain) is exercisable without hardware.
final class MockGlassesProvider: GlassesProvider {
    private(set) var connectionState: ConnectionState = .disconnected {
        didSet { onConnectionStateChange?(connectionState) }
    }
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    func connect() async throws {
        connectionState = .connecting
        try? await Task.sleep(nanoseconds: 600_000_000)
        connectionState = .connected
    }

    func disconnect() {
        connectionState = .disconnected
    }

    func capturePhoto() async throws -> Data {
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
