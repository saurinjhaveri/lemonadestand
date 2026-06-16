import Foundation
import SwiftUI
import CoreBluetooth
#if canImport(MWDATCore)
import MWDATCore
import MWDATCamera
#endif

/// Minimal, heavily-logged Meta DAT connection tester. Every step appends to an
/// on-screen log so we can see exactly where connecting to the glasses works or
/// fails — no app logic, just the connection.
@MainActor
final class DATTester: ObservableObject {
    @Published var lines: [String] = ["Tap Connect to begin."]
    @Published var busy = false
    @Published var connected = false

    // The DAT SDK discovers/registers glasses over Bluetooth, so the app needs
    // Bluetooth permission. Creating a central manager triggers the iOS prompt;
    // if it's never granted, registration stays .unavailable.
    private let bt = BluetoothProbe()

    init() {
        bt.onUpdate = { [weak self] status in
            Task { @MainActor in self?.log("🔵 Bluetooth: \(status)") }
        }
        bt.start()
    }

    #if canImport(MWDATCore)
    private var session: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var photoToken: (any AnyListenerToken)?
    #endif

    func log(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("[\(t)] \(s)")
    }

    func clear() { lines = [] }

    // MARK: - Connect

    func connect() async {
        #if canImport(MWDATCore)
        busy = true; connected = false
        defer { busy = false }
        do {
            log("⓪ Bluetooth: \(BluetoothProbe.status())")
            if BluetoothProbe.authorization != "allowedAlways" {
                log("   ⚠️ Bluetooth not authorized for this app → registration will be UNAVAILABLE.")
                log("     Allow the Bluetooth prompt, or enable it in Settings ▸ DAT Test ▸ Bluetooth.")
            }
            log("① configure()")
            do { try Wearables.configure(); log("   configured ✓") }
            catch { log("   configure note: \(error) (often safe if already configured)") }

            let w = Wearables.shared

            log("② registration state = \(w.registrationState.description)")
            if w.registrationState != .registered {
                log("   not registered — calling startRegistration() (approve in Meta AI app)")
                try? await withTimeout(30, "registration") {
                    try await self.awaitRegistered(w)
                }
                log("   registration state now = \(w.registrationState.description)")
                if w.registrationState == .unavailable {
                    log("   ⚠️ UNAVAILABLE = Developer Mode is OFF (or not signed in). Enable it in")
                    log("     Meta AI app ▸ Settings ▸ App Info ▸ tap version 5× ▸ Developer Mode ON.")
                }
            }

            log("③ camera permission status…")
            let status = (try? await w.checkPermissionStatus(.camera)).map { "\($0)" } ?? "unknown/error"
            log("   camera permission = \(status)")
            if status != "granted" {
                log("   requesting camera permission (watch for Meta AI prompt)…")
                do {
                    let r = try await w.requestPermission(.camera)
                    log("   requestPermission → \(r)")
                } catch {
                    log("   requestPermission error: \(describe(error))")
                }
            }

            log("④ waiting for device discovery (up to 15s)…")
            for i in 1...15 {
                if !w.devices.isEmpty { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if i % 3 == 0 { log("   …still 0 devices after \(i)s") }
            }
            let ids = w.devices
            log("   devices found: \(ids.count) \(ids)")
            guard let deviceId = ids.first else {
                log("✗ No devices. Glasses must be connected in the Meta AI app (Bluetooth) and worn.")
                return
            }
            if let dev = w.deviceForIdentifier(deviceId) {
                log("   device: name=\(dev.name) type=\(dev.deviceType()) compat=\(dev.compatibility()) link=\(dev.linkState)")
            }

            log("⑤ createSession()")
            let sess = try w.createSession(deviceSelector: SpecificDeviceSelector(device: deviceId))
            log("   session created ✓ (state=\(sess.state))")

            log("⑥ session.start()")
            try sess.start()
            try await withTimeout(20, "session start") {
                for await st in sess.stateStream() {
                    await MainActor.run { self.log("   session state → \(st.description)") }
                    if st == .started { return }
                    if st == .stopped { throw TestError.msg("session stopped") }
                }
            }
            self.session = sess
            log("   session started ✓")

            log("⑦ addStream()")
            let cfg = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 24)
            guard let st = try sess.addStream(config: cfg) else { throw TestError.msg("addStream returned nil") }
            photoToken = st.photoDataPublisher.listen { [weak self] photo in
                Task { @MainActor in self?.log("📸 photo received: \(photo.data.count) bytes (\(photo.format))") }
            }
            _ = st.errorPublisher.listen { [weak self] err in
                Task { @MainActor in self?.log("⚠️ stream error: \(err)") }
            }
            log("⑧ stream.start()")
            try await withTimeout(20, "stream start") { await st.start() }
            self.stream = st
            log("   stream started ✓ (state=\(st.state))")

            connected = true
            log("✅ CONNECTED. Tap 'Capture photo' to test the camera.")
        } catch {
            log("✗ FAILED: \(describe(error))")
        }
        #else
        log("MWDATCore not available — add the meta-wearables-dat package and regenerate.")
        #endif
    }

    func capture() async {
        #if canImport(MWDATCore)
        guard let stream else { log("Not connected."); return }
        log("capturePhoto(.jpeg)…")
        let ok = stream.capturePhoto(format: .jpeg)
        log("   capturePhoto returned \(ok) — waiting for photo callback…")
        #endif
    }

    func disconnect() {
        #if canImport(MWDATCore)
        let s = session; let st = stream; let tok = photoToken
        session = nil; stream = nil; photoToken = nil; connected = false
        Task { await tok?.cancel(); await st?.stop(); s?.stop() }
        log("disconnected.")
        #endif
    }

    // MARK: - Helpers

    #if canImport(MWDATCore)
    private func awaitRegistered(_ w: any WearablesInterface) async throws {
        if w.registrationState == .registered { return }
        for await state in w.registrationStateStream() {
            await MainActor.run { self.log("   reg state → \(state.description)") }
            switch state {
            case .registered: return
            case .available: try? await w.startRegistration()
            case .unavailable: throw TestError.msg("registration unavailable")
            default: continue
            }
        }
    }
    #endif

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(error) [domain=\(ns.domain) code=\(ns.code)]"
    }

    private func withTimeout<T: Sendable>(_ seconds: Double, _ step: String,
                                          _ op: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TestError.msg("timed out during \(step)")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

enum TestError: Error, CustomStringConvertible {
    case msg(String)
    var description: String { if case .msg(let m) = self { return m }; return "error" }
}

/// Triggers the iOS Bluetooth permission prompt (by creating a central manager)
/// and reports state/authorization — the DAT SDK needs BT authorized to register.
final class BluetoothProbe: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    var onUpdate: ((String) -> Void)?

    func start() {
        // Creating this on first launch shows the Bluetooth permission prompt.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        onUpdate?("state=\(BluetoothProbe.name(c.state)) auth=\(BluetoothProbe.authorization)")
    }

    static var authorization: String {
        switch CBCentralManager.authorization {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowedAlways"
        @unknown default: return "unknown"
        }
    }

    static func status() -> String { "auth=\(authorization)" }

    static func name(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
