import Foundation

// Real glasses provider backed by the Meta Wearables Device Access Toolkit.
//
// This whole file is guarded by `#if canImport(MWDATCore)`:
//   • Before you add the SDK package → compiles to a harmless stub, the app
//     keeps building and uses MockGlassesProvider.
//   • After you add the SPM package (https://github.com/facebook/meta-wearables-dat-ios)
//     → the real implementation below activates automatically.
//
// Written against DAT iOS v0.x API. If your SDK version renames a symbol, the
// compiler will point right at it — adjust and rebuild.

#if canImport(MWDATCore)
import MWDATCore
import MWDATCamera
#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

final class MetaDATGlassesProvider: GlassesProvider {
    private(set) var connectionState: ConnectionState = .disconnected {
        didSet { onConnectionStateChange?(connectionState) }
    }
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    /// When true (e.g. on the Simulator), drives a simulated Ray-Ban via
    /// MockDeviceKit so the real code path is testable without hardware.
    private let useMockDevice: Bool

    // Concrete SDK types per v0.x docs; adjust names if your SDK differs.
    private var session: DeviceSession?
    private var stream: CameraStream?
    private var photoContinuation: CheckedContinuation<Data, Error>?

    init(useMockDevice: Bool = false) {
        self.useMockDevice = useMockDevice
    }

    func connect() async throws {
        connectionState = .connecting
        try? Wearables.configure()   // safe to call; ignore "already configured"
        let wearables = Wearables.shared

        #if canImport(MWDATMockDevice)
        if useMockDevice {
            let kit = MockDeviceKit.shared
            kit.enable()
            let mock = kit.pairRaybanMeta()
            await mock.powerOn()
            await mock.unfold()
            await mock.don()
        }
        #endif

        try await ensureRegistered(wearables)
        _ = try? await wearables.requestPermission(.camera)

        // Start a device session and wait until it's running.
        let selector = AutoDeviceSelector(wearables: wearables)
        let deviceSession = try wearables.createSession(deviceSelector: selector)
        try deviceSession.start()
        for await state in deviceSession.stateStream() {
            if state == .started { break }
            if state == .stopped { throw GlassesError.notConnected }
        }
        self.session = deviceSession

        // Add a camera stream and listen for captured photos.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 24)
        guard let stream = try deviceSession.addStream(config: config) else {
            throw GlassesError.captureFailed
        }
        stream.photoDataPublisher.listen { [weak self] photoData in
            self?.photoContinuation?.resume(returning: photoData.data)
            self?.photoContinuation = nil
        }
        await stream.start()
        self.stream = stream
        connectionState = .connected
    }

    func disconnect() {
        let stream = self.stream
        let session = self.session
        self.stream = nil
        self.session = nil
        Task {
            await stream?.stop()
            session?.stop()
        }
        connectionState = .disconnected
    }

    func capturePhoto() async throws -> Data {
        guard let stream else { throw GlassesError.notConnected }
        return try await withCheckedThrowingContinuation { cont in
            self.photoContinuation = cont
            stream.capturePhoto(format: .jpeg)
        }
    }

    /// One-time linking with the Meta AI app. Opens the link flow if needed and
    /// returns once the app is registered. URL callback is handled in
    /// TourGuideApp via `.onOpenURL`.
    private func ensureRegistered(_ wearables: Wearables) async throws {
        for await state in wearables.registrationStateStream() {
            switch state {
            case .registered:
                return
            case .available:
                try await wearables.startRegistration()
            case .unavailable:
                throw GlassesError.notConnected
            default:
                continue   // .registering — keep waiting
            }
        }
    }
}

#else

// SDK not added yet — stub so the project still builds. Add the SPM package to
// activate the real implementation above.
final class MetaDATGlassesProvider: GlassesProvider {
    private(set) var connectionState: ConnectionState = .disconnected {
        didSet { onConnectionStateChange?(connectionState) }
    }
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    init(useMockDevice: Bool = false) {}

    func connect() async throws {
        connectionState = .failed("Meta DAT SDK not added. Add the SPM package to enable real glasses.")
        throw GlassesError.sdkUnavailable
    }
    func disconnect() { connectionState = .disconnected }
    func capturePhoto() async throws -> Data { throw GlassesError.sdkUnavailable }
}

#endif
