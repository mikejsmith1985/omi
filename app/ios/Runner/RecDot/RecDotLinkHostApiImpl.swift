import ExternalAccessory
import Flutter
import Foundation

/// Pigeon host API for the viaim RecDot link on iOS.
///
/// The RecDot is an MFi accessory; iOS speaks to it over an `EASession` on the
/// `com.vision.voyager` protocol, which is iAP2 over the same Classic Bluetooth link the
/// buds already hold for A2DP/HFP. This impl is a dumb byte pipe: it lists accessories that
/// advertise the protocol, opens a session, writes raw bytes, and forwards received bytes to
/// Dart. It never frames or interprets the STAROT protocol — that all lives in Dart.
///
/// NOTE: iOS compilation of this file is verified by the Codemagic build and TestFlight, not
/// on the Windows development machine.
final class RecDotLinkHostApiImpl: NSObject, RecDotLinkHostAPI {
    private static let protocolString = "com.vision.voyager"

    private let flutterAPI: RecDotLinkFlutterAPI
    private let manager = EAAccessoryManager.shared()
    private var sessions: [String: EASession] = [:]
    private var readers: [String: RecDotStreamReader] = [:]

    init(flutterAPI: RecDotLinkFlutterAPI) {
        self.flutterAPI = flutterAPI
        super.init()
        manager.registerForLocalNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessoriesChanged),
            name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessoriesChanged),
            name: .EAAccessoryDidDisconnect, object: nil)
    }

    /// A stable id for an accessory: its connection id is unique for the session lifetime.
    private func deviceId(for accessory: EAAccessory) -> String {
        return String(accessory.connectionID)
    }

    private func recDotAccessories() -> [EAAccessory] {
        return manager.connectedAccessories.filter { $0.protocolStrings.contains(Self.protocolString) }
    }

    func listAccessories(completion: @escaping (Result<[RecDotAccessory], Error>) -> Void) {
        // DIAGNOSTIC (build-branch only): report EVERY connected accessory and the protocol
        // strings iOS says it supports, so we can see what the RecDot actually exposes rather
        // than silently filtering to com.vision.voyager. The name carries the protocols.
        let all = manager.connectedAccessories
        if all.isEmpty {
            let marker = RecDotAccessory(deviceId: "diag-empty", name: "EA: none connected", serialNumber: nil, firmwareRevision: nil)
            completion(.success([marker]))
            return
        }
        let accessories = all.map { accessory in
            let protocols = accessory.protocolStrings.isEmpty ? "no-protocols" : accessory.protocolStrings.joined(separator: ",")
            return RecDotAccessory(
                deviceId: deviceId(for: accessory),
                name: "\(accessory.name) | \(protocols)",
                serialNumber: accessory.serialNumber.isEmpty ? nil : accessory.serialNumber,
                firmwareRevision: accessory.firmwareRevision.isEmpty ? nil : accessory.firmwareRevision)
        }
        completion(.success(accessories))
    }

    func connect(deviceId: String) throws {
        guard let accessory = recDotAccessories().first(where: { self.deviceId(for: $0) == deviceId }) else {
            emitState(deviceId, "disconnected")
            return
        }
        guard let session = EASession(accessory: accessory, forProtocol: Self.protocolString) else {
            emitState(deviceId, "disconnected")
            return
        }
        emitState(deviceId, "connecting")
        let reader = RecDotStreamReader(session: session)
        reader.onBytes = { [weak self] data in
            self?.flutterAPI.onBytes(deviceId: deviceId, bytes: FlutterStandardTypedData(bytes: data)) { _ in }
        }
        reader.onClosed = { [weak self] in
            self?.teardown(deviceId)
            self?.emitState(deviceId, "disconnected")
        }
        sessions[deviceId] = session
        readers[deviceId] = reader
        reader.start()
        emitState(deviceId, "connected")
    }

    func disconnect(deviceId: String) throws {
        emitState(deviceId, "disconnecting")
        teardown(deviceId)
        emitState(deviceId, "disconnected")
    }

    func write(deviceId: String, bytes: FlutterStandardTypedData, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let reader = readers[deviceId] else {
            completion(.success(()))
            return
        }
        reader.write(bytes.data)
        completion(.success(()))
    }

    private func teardown(_ deviceId: String) {
        readers[deviceId]?.stop()
        readers[deviceId] = nil
        sessions[deviceId] = nil
    }

    private func emitState(_ deviceId: String, _ state: String) {
        flutterAPI.onConnectionStateChanged(deviceId: deviceId, state: state) { _ in }
    }

    @objc private func accessoriesChanged() {
        flutterAPI.onAccessoryListChanged { _ in }
    }
}
