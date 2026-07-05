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
import UIKit
import CoreBluetooth
import MWDATCore
import MWDATCamera
#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

/// The DAT SDK discovers/registers glasses over BLE but never triggers the iOS
/// Bluetooth permission prompt itself — without authorization it just reports
/// "unavailable"/no devices. Creating a CBCentralManager forces the prompt.
private final class BluetoothPermission: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothPermission()
    private var central: CBCentralManager?
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// Shows the Bluetooth prompt if needed and waits until iOS resolves it.
    func ensurePrompted() async {
        guard CBCentralManager.authorization == .notDetermined else { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
            if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

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
    private var frameToken: (any AnyListenerToken)?
    private var photoContinuation: CheckedContinuation<Data, Error>?

    // Latest live-stream frame, kept for instant capture: if a photo request is
    // slow, we answer from the stream instead — "look at this" never hangs.
    private let frameLock = NSLock()
    private var _latestFrame: MWDATCamera.VideoFrame?

    private func latestFrameJPEG() -> Data? {
        frameLock.lock(); let frame = _latestFrame; frameLock.unlock()
        return frame?.makeUIImage()?.jpegData(compressionQuality: 0.7)
    }

    init(useMockDevice: Bool = false) {
        self.useMockDevice = useMockDevice
    }

    func connect() async throws {
        connectionState = .connecting

        // Bluetooth authorization is a hard prerequisite (the SDK won't ask).
        await BluetoothPermission.shared.ensurePrompted()
        if CBCentralManager.authorization == .denied {
            throw GlassesError.setup("Bluetooth permission is off — enable it in "
                + "Settings ▸ Tour Guide ▸ Bluetooth, then retry.")
        }

        try? Wearables.configure()   // safe to call; ignore "already configured"
        let wearables = Wearables.shared

        var mockDeviceId: DeviceIdentifier?
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
            mockDeviceId = mock.deviceIdentifier
        }
        #endif

        // Best-effort registration. In Developer Mode the production linking flow
        // isn't used, so we time-box it and proceed — if the session genuinely
        // needs registration, createSession below will surface a clear error.
        try? await withTimeout(15, step: "registration") {
            try await self.ensureRegistered(wearables)
        }
        // Camera permission is granted in the Meta AI app. Check first and only
        // trigger the request flow if needed — that flow opens a meta.ai universal
        // link that fails (LSApplicationWorkspaceError 115) on older Meta AI app
        // versions. If you grant Camera manually in the Meta AI app, this is skipped.
        let camStatus = (try? await wearables.checkPermissionStatus(.camera)) ?? .denied
        if camStatus != .granted {
            _ = try? await wearables.requestPermission(.camera)
        }

        // Wait for the (mock or real) device to be discovered before we create a
        // session, otherwise the selector finds nothing → noEligibleDevice.
        await waitForDevice(wearables, timeout: 10)

        // Target the mock device explicitly on the Simulator; on a real device,
        // require a discovered device and check its compatibility so we can give a
        // precise reason instead of a bare "no eligible device".
        let selector: any DeviceSelector
        if let mockDeviceId {
            selector = SpecificDeviceSelector(device: mockDeviceId)
        } else {
            guard let deviceId = wearables.devices.first else {
                throw GlassesError.setup("No glasses found. Make sure your Ray-Ban Meta are "
                    + "connected in the Meta AI app (Bluetooth) and you're wearing them with the "
                    + "hinges open, then tap Retry glasses.")
            }
            if let device = wearables.deviceForIdentifier(deviceId) {
                switch device.compatibility() {
                case .deviceUpdateRequired:
                    throw GlassesError.setup("Your glasses need a firmware update — update them in "
                        + "the Meta AI app, then tap Retry glasses.")
                case .sdkUpdateRequired:
                    throw GlassesError.setup("Your glasses need a newer toolkit than this build "
                        + "bundles. Update the meta-wearables-dat package, then rebuild.")
                default:
                    break
                }
            }
            selector = SpecificDeviceSelector(device: deviceId)
        }
        let deviceSession = try wearables.createSession(deviceSelector: selector)
        try deviceSession.start()
        try await withTimeout(20, step: "starting the session") {
            for await state in deviceSession.stateStream() {
                if state == .started { return }
                if state == .stopped {
                    throw GlassesError.setup("The glasses session stopped. Make sure they're "
                        + "connected in the Meta AI app, worn, and Developer Mode is on.")
                }
            }
        }
        self.session = deviceSession

        // Add a camera stream and listen for captured photos.
        // Capture-oriented config: we only need the LATEST frame for snapshots,
        // not smooth video. 2fps/.medium keeps Bluetooth usage tiny — continuous
        // .high/24fps saturates the shared BT/2.4GHz radio, strangling the
        // phone's internet (slow/hung answers) and heating the glasses. Per
        // Meta's docs, .medium also gives BETTER per-frame quality than .high.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 2)
        guard let stream = try deviceSession.addStream(config: config) else {
            throw GlassesError.captureFailed
        }
        // One publisher delivers BOTH app-requested captures and photos the
        // wearer takes with the glasses' hardware button. If we're awaiting an
        // app-requested capture, resume it; otherwise it's a hands-free capture
        // — forward it to onPhotoCaptured so the app narrates it automatically.
        photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
            // Serialize continuation handling on main to avoid racing the failsafe.
            DispatchQueue.main.async {
                guard let self else { return }
                if let cont = self.photoContinuation {
                    self.photoContinuation = nil
                    cont.resume(returning: photoData.data)
                } else {
                    self.onPhotoCaptured?(photoData.data)
                }
            }
        }
        // Keep the newest live frame around for instant/fallback capture.
        frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            guard let self else { return }
            self.frameLock.lock(); self._latestFrame = frame; self.frameLock.unlock()
        }
        try await withTimeout(20, step: "starting the camera") { await stream.start() }
        self.stream = stream
        connectionState = .connected
    }

    func disconnect() {
        let stream = self.stream
        let session = self.session
        let tokens: [(any AnyListenerToken)?] = [photoToken, frameToken]
        self.stream = nil
        self.session = nil
        self.photoToken = nil
        self.frameToken = nil
        // Don't strand a pending capture await.
        DispatchQueue.main.async {
            if let cont = self.photoContinuation {
                self.photoContinuation = nil
                cont.resume(throwing: GlassesError.notConnected)
            }
        }
        frameLock.lock(); _latestFrame = nil; frameLock.unlock()
        Task {
            for t in tokens { await t?.cancel() }
            await stream?.stop()
            session?.stop()
        }
        connectionState = .disconnected
    }

    func capturePhoto() async throws -> Data {
        guard let stream else { throw GlassesError.notConnected }
        // Instant path: the live stream already delivers what the wearer sees,
        // at the same streaming resolution a device photo request returns —
        // minus the multi-second round trip. Only fall back to a real photo
        // request when no frame has arrived yet.
        if let data = latestFrameJPEG() { return data }
        // ALL continuation handling is serialized on the main queue — the photo
        // listener and the failsafe both run there, so a resume can never be
        // missed (a set-on-background/read-on-main race could hang the turn).
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                // A second tap must not orphan the pending capture.
                if let old = self.photoContinuation {
                    self.photoContinuation = nil
                    if let data = self.latestFrameJPEG() { old.resume(returning: data) }
                    else { old.resume(throwing: GlassesError.captureFailed) }
                }
                self.photoContinuation = cont
                let requested = stream.capturePhoto(format: .jpeg)
                if !requested {
                    // Device refused the request — answer from the live frame now.
                    self.photoContinuation = nil
                    if let data = self.latestFrameJPEG() { cont.resume(returning: data) }
                    else { cont.resume(throwing: GlassesError.captureFailed) }
                    return
                }
                // Failsafe: if the photo doesn't arrive promptly, answer with the
                // newest live-stream frame instead of hanging the turn.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, let pending = self.photoContinuation else { return }
                    self.photoContinuation = nil
                    if let data = self.latestFrameJPEG() {
                        pending.resume(returning: data)
                    } else {
                        pending.resume(throwing: GlassesError.captureFailed)
                    }
                }
            }
        }
    }

    /// One-time linking with the Meta AI app. Opens the link flow if needed and
    /// returns once the app is registered. URL callback is handled in
    /// TourGuideApp via `.onOpenURL`.
    /// Run an async step but fail with a clear, labeled error instead of hanging
    /// forever (DAT calls can stall if the glasses aren't reachable).
    private func withTimeout<T: Sendable>(_ seconds: Double, step: String,
                                          _ op: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw GlassesError.setup("Timed out during \(step). Check the glasses are "
                    + "connected in the Meta AI app, worn (hinges open), and Developer Mode is on.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Poll until Wearables has discovered at least one device (or we time out).
    private func waitForDevice(_ wearables: any WearablesInterface, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while wearables.devices.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)   // 0.15s
        }
    }

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
