import CoreBluetooth
import Foundation
import Observation

public struct DiscoveredPrinter: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    public var lastSeen: Date

    public var detectedModel: PrinterModel? { PrinterModel.detect(advertisedName: name) }
}

public enum BluetoothError: LocalizedError {
    case unavailable(String)
    case unknownPeripheral
    case connectTimeout
    case connectFailed(String)
    case noSuitableCharacteristic
    case disconnected

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): "Bluetooth niet beschikbaar: \(reason)"
        case .unknownPeripheral: "Printer niet gevonden. Zoek opnieuw naar printers."
        case .connectTimeout: "Verbinden duurde te lang. Staat de printer aan en dichtbij?"
        case let .connectFailed(reason): "Verbinden mislukt: \(reason)"
        case .noSuitableCharacteristic: "Dit apparaat heeft geen Niimbot-printservice."
        case .disconnected: "De verbinding met de printer is verbroken."
        }
    }
}

/// Scans for and connects to Niimbot printers over Bluetooth Low Energy.
@MainActor
@Observable
public final class BluetoothManager: NSObject {
    public private(set) var state: CBManagerState = .unknown
    public private(set) var isScanning = false
    public private(set) var discovered: [DiscoveredPrinter] = []
    /// Show every BLE device, not only names that look like Niimbot printers.
    public var showAllDevices = false

    /// Called when a connected peripheral drops.
    @ObservationIgnored public var onDisconnect: ((UUID, Error?) -> Void)?
    /// Called whenever the Bluetooth state changes.
    @ObservationIgnored public var onStateChange: ((CBManagerState) -> Void)?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var connections: [UUID: BLEConnection] = [:]

    override public init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public var stateDescription: String {
        switch state {
        case .poweredOn: "Aan"
        case .poweredOff: "Bluetooth staat uit"
        case .unauthorized: "Geen toestemming voor Bluetooth (Systeeminstellingen › Privacy en beveiliging › Bluetooth)"
        case .unsupported: "Bluetooth LE wordt niet ondersteund op dit apparaat"
        case .resetting: "Bluetooth wordt herstart…"
        case .unknown: "Bluetooth wordt gestart…"
        @unknown default: "Onbekende Bluetooth-status"
        }
    }

    public func startScan() {
        guard state == .poweredOn else { return }
        discovered.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        if central.isScanning { central.stopScan() }
        isScanning = false
    }

    /// Connects and prepares the Niimbot characteristic. Works for devices found by scanning and for
    /// previously connected devices identified by UUID.
    public func connect(to id: UUID, timeout: Duration = .seconds(12)) async throws -> BLEConnection {
        guard state == .poweredOn else { throw BluetoothError.unavailable(stateDescription) }
        let peripheral: CBPeripheral
        if let known = peripherals[id] {
            peripheral = known
        } else if let retrieved = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[id] = retrieved
            peripheral = retrieved
        } else {
            throw BluetoothError.unknownPeripheral
        }

        stopScan()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.failConnect(id, BluetoothError.connectTimeout)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuations[id] = continuation
            central.connect(peripheral, options: nil)
        }

        let connection = BLEConnection(peripheral: peripheral)
        connections[id] = connection
        do {
            try await connection.prepare()
        } catch {
            disconnect(id)
            throw error
        }
        return connection
    }

    public func disconnect(_ id: UUID) {
        if let peripheral = peripherals[id] {
            central.cancelPeripheralConnection(peripheral)
        }
        connections[id]?.handleDisconnect()
        connections[id] = nil
    }

    private func failConnect(_ id: UUID, _ error: Error) {
        guard let continuation = connectContinuations.removeValue(forKey: id) else { return }
        if let peripheral = peripherals[id] { central.cancelPeripheralConnection(peripheral) }
        continuation.resume(throwing: error)
    }

    fileprivate func handleDiscovery(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: Int) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard !name.isEmpty, showAllDevices || PrinterModel.looksLikePrinter(name) else { return }
        peripherals[peripheral.identifier] = peripheral
        let entry = DiscoveredPrinter(id: peripheral.identifier, name: name, rssi: rssi, lastSeen: .now)
        if let index = discovered.firstIndex(where: { $0.id == entry.id }) {
            discovered[index] = entry
        } else {
            discovered.append(entry)
            discovered.sort { $0.rssi > $1.rssi }
        }
    }

    fileprivate func handleConnected(_ peripheral: CBPeripheral) {
        connectContinuations.removeValue(forKey: peripheral.identifier)?.resume()
    }

    fileprivate func handleConnectFailed(_ peripheral: CBPeripheral, error: Error?) {
        let reason = error?.localizedDescription ?? "onbekende fout"
        connectContinuations.removeValue(forKey: peripheral.identifier)?.resume(throwing: BluetoothError.connectFailed(reason))
    }

    fileprivate func handleDisconnected(_ peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        connectContinuations.removeValue(forKey: id)?.resume(throwing: BluetoothError.disconnected)
        connections.removeValue(forKey: id)?.handleDisconnect()
        onDisconnect?(id, error)
    }

    fileprivate func handleStateUpdate(_ newState: CBManagerState) {
        state = newState
        if newState != .poweredOn { isScanning = false }
        onStateChange?(newState)
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        MainActor.assumeIsolated { handleStateUpdate(newState) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { handleDiscovery(peripheral, advertisementData: advertisementData, rssi: rssi) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { handleConnected(peripheral) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { handleConnectFailed(peripheral, error: error) }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { handleDisconnected(peripheral, error: error) }
    }
}

/// Transport abstraction so the protocol client can be tested without Bluetooth.
@MainActor
public protocol NiimbotTransport: AnyObject {
    var onReceive: (([UInt8]) -> Void)? { get set }
    func write(_ bytes: [UInt8]) async throws
}

/// An open BLE link to one printer: finds the notify + write-without-response characteristic and
/// writes with flow control.
@MainActor
public final class BLEConnection: NSObject, NiimbotTransport {
    /// Characteristic used by Niimbot printers (service e7810a71-73ae-499d-8c15-faa9aef0c3f2).
    public static let preferredCharacteristic = CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F")

    public let peripheral: CBPeripheral
    public var onReceive: (([UInt8]) -> Void)?
    public var name: String { peripheral.name ?? "Printer" }
    public var id: UUID { peripheral.identifier }

    private var characteristic: CBCharacteristic?
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var pendingServices = 0
    private var isDisconnected = false

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setupContinuation = continuation
            peripheral.discoverServices(nil)
        }
    }

    func handleDisconnect() {
        isDisconnected = true
        finishSetup(BluetoothError.disconnected)
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard !isDisconnected, let characteristic else { throw BluetoothError.disconnected }
        let withoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = withoutResponse ? .withoutResponse : .withResponse
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: type))

        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + chunkSize)
            if withoutResponse {
                var waited = 0
                while !peripheral.canSendWriteWithoutResponse, waited < 2000 {
                    try await Task.sleep(for: .milliseconds(2))
                    waited += 2
                    if isDisconnected { throw BluetoothError.disconnected }
                }
            }
            peripheral.writeValue(Data(bytes[offset ..< end]), for: characteristic, type: type)
            offset = end
        }
    }

    private func finishSetup(_ error: Error?) {
        guard let continuation = setupContinuation else { return }
        setupContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private func selectCharacteristic() {
        let all = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
        let usable = all.filter {
            $0.properties.contains(.notify) && ($0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write))
        }
        guard let chosen = usable.first(where: { $0.uuid == Self.preferredCharacteristic }) ?? usable.first else {
            finishSetup(BluetoothError.noSuitableCharacteristic)
            return
        }
        characteristic = chosen
        peripheral.setNotifyValue(true, for: chosen)
    }

    fileprivate func didDiscoverServices(_ error: Error?) {
        if let error { finishSetup(BluetoothError.connectFailed(error.localizedDescription)); return }
        let services = peripheral.services ?? []
        guard !services.isEmpty else { finishSetup(BluetoothError.noSuitableCharacteristic); return }
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    fileprivate func didDiscoverCharacteristics() {
        pendingServices -= 1
        if pendingServices == 0 { selectCharacteristic() }
    }

    fileprivate func didUpdateNotificationState(_ characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == self.characteristic else { return }
        if let error { finishSetup(BluetoothError.connectFailed(error.localizedDescription)) } else { finishSetup(nil) }
    }

    fileprivate func didReceive(_ data: Data?) {
        guard let data, !data.isEmpty else { return }
        onReceive?([UInt8](data))
    }
}

extension BLEConnection: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { didDiscoverServices(error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { didDiscoverCharacteristics() }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { didUpdateNotificationState(characteristic, error: error) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        MainActor.assumeIsolated { didReceive(value) }
    }
}
