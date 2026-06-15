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
    var onPhotoCaptured: ((Data) -> Void)?

    /// When true (e.g. on the Simulator), drives a simulated Ray-Ban via
    /// MockDeviceKit so the real code path is testable without hardware.
    private let useMockDevice: Bool

    // Concrete SDK types (MWDAT iOS 0.7.0). NB: the camera stream type is
    // `MWDATCamera.Stream` — must be qualified to avoid clashing with Foundation.Stream.
    private var session: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var photoToken: (any AnyListenerToken)?
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
            // initiallyRegistered + permissions granted so the simulator runs the
            // full pipeline without a real Meta App ID / DAT approval.
            kit.enable(config: MockDeviceKitConfig(initiallyRegistered: true,
                                                   initialPermissionsGranted: true))
            let mock = kit.pairRaybanMeta()
            mock.powerOn()
            mock.unfold()
            mock.don()
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
        // One publisher delivers BOTH app-requested captures and photos the
        // wearer takes with the glasses' hardware button. If we're awaiting an
        // app-requested capture, resume it; otherwise it's a hands-free capture
        // — forward it to onPhotoCaptured so the app narrates it automatically.
        photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
            guard let self else { return }
            let data = photoData.data
            if let cont = self.photoContinuation {
                self.photoContinuation = nil
                cont.resume(returning: data)
            } else {
                DispatchQueue.main.async { self.onPhotoCaptured?(data) }
            }
        }
        await stream.start()
        self.stream = stream
        connectionState = .connected
    }

    func disconnect() {
        let stream = self.stream
        let session = self.session
        let token = self.photoToken
        self.stream = nil
        self.session = nil
        self.photoToken = nil
        Task {
            await token?.cancel()
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
    private func ensureRegistered(_ wearables: any WearablesInterface) async throws {
        // Already registered (incl. the auto-registered mock device) → done.
        if wearables.registrationState == .registered { return }
        for await state in wearables.registrationStateStream() {
            switch state {
            case .registered:
                return
            case .available:
                // The Simulator's mock device auto-registers; don't kick off the
                // real Meta-app linking flow (which would need a real Meta App ID).
                if useMockDevice { continue }
                do {
                    try await wearables.startRegistration()
                } catch let e as RegistrationError {
                    throw GlassesError.setup(Self.explain(e))
                }
            case .unavailable:
                if useMockDevice { continue }
                throw GlassesError.setup("Glasses registration unavailable. Make sure the Meta AI "
                    + "app is installed, your glasses are paired, and Developer Mode is enabled.")
            default:
                continue   // .registering — keep waiting
            }
        }
    }

    private static func explain(_ e: RegistrationError) -> String {
        switch e {
        case .configurationInvalid:
            return "Meta DAT config invalid — set a real MWDAT.MetaAppID in project.yml "
                + "(it's still the YOUR_META_APP_ID placeholder) and make sure your bundle ID "
                + "matches the app you registered in the Wearables Developer Center."
        case .metaAINotInstalled:
            return "The Meta AI app isn't installed. Install it and pair your glasses, then retry."
        case .networkUnavailable:
            return "No network — registration needs internet. Reconnect and retry."
        case .alreadyRegistered:
            return "Already registered (this shouldn't block you — try again)."
        case .unknown:
            return "Glasses registration failed (unknown error)."
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
    var onPhotoCaptured: ((Data) -> Void)?

    init(useMockDevice: Bool = false) {}

    func connect() async throws {
        connectionState = .failed("Meta DAT SDK not added. Add the SPM package to enable real glasses.")
        throw GlassesError.sdkUnavailable
    }
    func disconnect() { connectionState = .disconnected }
    func capturePhoto() async throws -> Data { throw GlassesError.sdkUnavailable }
}

#endif
