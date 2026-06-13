import Foundation

// TODO(meta-dat): once you have GitHub-gated access to the SDK and have added
// the SPM package (see project.yml), `import MetaWearablesDAT` here and replace
// the placeholder bodies below with the real SDK calls. The symbol names below
// are illustrative — confirm them against the actual SDK headers/docs.
//
// import MetaWearablesDAT

/// Real glasses provider backed by the Meta Wearables Device Access Toolkit.
///
/// Expected SDK shape (verify against the real API):
///   - Discover/connect a paired device session.
///   - Request a camera capability and call a "capture photo" API.
///   - Receive JPEG/HEIC frame data in a completion/async result.
final class MetaDATGlassesProvider: GlassesProvider {
    private(set) var connectionState: ConnectionState = .disconnected {
        didSet { onConnectionStateChange?(connectionState) }
    }
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    // private var session: WearableSession?      // TODO(meta-dat)
    // private var camera: CameraCapability?      // TODO(meta-dat)

    func connect() async throws {
        connectionState = .connecting
        // TODO(meta-dat):
        //   let session = try await WearableManager.shared.connect()
        //   self.session = session
        //   self.camera = try await session.requestCapability(.camera)
        //   session.onDisconnect = { [weak self] in self?.connectionState = .disconnected }
        //   connectionState = .connected
        connectionState = .failed("Meta DAT SDK not yet integrated — see TODO(meta-dat).")
        throw GlassesError.sdkUnavailable
    }

    func disconnect() {
        // TODO(meta-dat): session?.disconnect()
        connectionState = .disconnected
    }

    func capturePhoto() async throws -> Data {
        // TODO(meta-dat):
        //   guard let camera else { throw GlassesError.notConnected }
        //   let frame = try await camera.capturePhoto(resolution: .high)
        //   return frame.jpegData
        throw GlassesError.sdkUnavailable
    }
}
