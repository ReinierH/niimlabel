import CoreBluetooth
import Foundation
import NiimbotKit
import Observation

/// Owns the Bluetooth link and protocol client, keeps printer status fresh and runs print jobs.
@MainActor
@Observable
final class PrinterController {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting(String)
        case connected
        case printing
    }

    let bluetooth = BluetoothManager()

    private(set) var state: ConnectionState = .disconnected
    private(set) var deviceName: String?
    private(set) var deviceID: UUID?
    private(set) var info = PrinterInfo()
    private(set) var heartbeat: HeartbeatStatus?
    private(set) var rfid: RFIDInfo?
    private(set) var progress: PrintProgress?
    private(set) var log: [ProtocolLogEntry] = []
    var lastError: String?

    // MARK: Settings

    var autoReconnect: Bool { didSet { defaults.set(autoReconnect, forKey: "autoReconnect") } }
    /// Model chosen manually when no printer is connected, or to override detection.
    var preferredModelName: String { didSet { defaults.set(preferredModelName, forKey: "preferredModel") } }
    var forceModel: Bool { didSet { defaults.set(forceModel, forKey: "forceModel") } }
    var protocolOverride: PrintProtocol? { didSet { defaults.set(protocolOverride?.rawValue, forKey: "protocolOverride") } }
    var packetIntervalMs: Int {
        didSet {
            defaults.set(packetIntervalMs, forKey: "packetInterval")
            client?.packetInterval = .milliseconds(packetIntervalMs)
        }
    }
    var logImageData: Bool {
        didSet {
            defaults.set(logImageData, forKey: "logImageData")
            client?.logImageData = logImageData
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var connection: BLEConnection?
    @ObservationIgnored private var client: NiimbotClient?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var printTask: Task<Void, Error>?
    @ObservationIgnored private var userInitiatedDisconnect = false
    @ObservationIgnored private var reconnectAttempts = 0

    init() {
        autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        preferredModelName = defaults.string(forKey: "preferredModel") ?? PrinterModel.b1.name
        forceModel = defaults.bool(forKey: "forceModel")
        protocolOverride = defaults.string(forKey: "protocolOverride").flatMap(PrintProtocol.init(rawValue:))
        packetIntervalMs = defaults.object(forKey: "packetInterval") as? Int ?? 10
        logImageData = defaults.bool(forKey: "logImageData")

        bluetooth.onDisconnect = { [weak self] id, error in self?.handleDisconnect(id: id, error: error) }
        bluetooth.onStateChange = { [weak self] state in
            if state == .poweredOn { self?.attemptAutoReconnect() }
        }
    }

    // MARK: Derived state

    var isConnected: Bool { state == .connected || state == .printing }
    var isPrinting: Bool { state == .printing }

    var model: PrinterModel {
        let preferred = PrinterModel.named(preferredModelName) ?? .b1
        if forceModel { return preferred }
        return info.model ?? deviceName.flatMap(PrinterModel.detect(advertisedName:)) ?? preferred
    }

    var printProtocol: PrintProtocol { protocolOverride ?? model.printProtocol }

    /// Battery in bars (1…4) from heartbeat or info.
    var batteryLevel: Int? { heartbeat?.powerLevel ?? info.batteryLevel }

    var lastDeviceID: UUID? { defaults.string(forKey: "lastDevice").flatMap(UUID.init(uuidString:)) }
    var lastDeviceName: String? { defaults.string(forKey: "lastDeviceName") }

    var statusSummary: String {
        switch state {
        case .disconnected: "Niet verbonden"
        case let .connecting(name): "Verbinden met \(name)…"
        case .connected:
            if heartbeat?.isLidOpen == true { "Deksel open" } else if heartbeat?.hasPaper == false { "Geen labels" } else { "Gereed" }
        case .printing:
            progress.map { "Afdrukken \($0.printedLabels)/\($0.totalLabels)" } ?? "Afdrukken…"
        }
    }

    // MARK: Connection

    func connect(to id: UUID, name: String) async {
        guard !isConnected else { return }
        userInitiatedDisconnect = false
        lastError = nil
        state = .connecting(name)
        appendLog(.info, "Verbinden met \(name)")
        do {
            let connection = try await bluetooth.connect(to: id)
            let client = NiimbotClient(transport: connection)
            client.packetInterval = .milliseconds(packetIntervalMs)
            client.logImageData = logImageData
            client.onLog = { [weak self] entry in self?.append(entry) }
            self.connection = connection
            self.client = client
            deviceID = id
            deviceName = name

            do { try await client.handshake() } catch { appendLog(.info, "Geen antwoord op handshake, ga verder") }
            info = await client.fetchInfo()
            heartbeat = try? await client.heartbeat()
            rfid = try? await client.rfidInfo()

            state = .connected
            reconnectAttempts = 0
            defaults.set(id.uuidString, forKey: "lastDevice")
            defaults.set(name, forKey: "lastDeviceName")
            appendLog(.info, "Verbonden: \(model.name), firmware \(info.softwareVersion ?? "?")")
            startHeartbeat()
        } catch {
            appendLog(.info, "Verbinden mislukt: \(error.localizedDescription)")
            lastError = error.localizedDescription
            teardown()
            bluetooth.disconnect(id)
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        printTask?.cancel()
        if let deviceID { bluetooth.disconnect(deviceID) }
        teardown()
    }

    private func teardown() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        client?.close()
        client = nil
        connection = nil
        heartbeat = nil
        state = .disconnected
    }

    private func handleDisconnect(id: UUID, error: Error?) {
        guard id == deviceID, state != .disconnected else { return }
        appendLog(.info, "Verbinding verbroken\(error.map { ": \($0.localizedDescription)" } ?? "")")
        let wasUser = userInitiatedDisconnect
        teardown()
        if !wasUser {
            lastError = "De verbinding met de printer is verbroken."
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard autoReconnect, reconnectAttempts < 5, let id = deviceID, let name = deviceName else { return }
        reconnectAttempts += 1
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard state == .disconnected, !userInitiatedDisconnect else { return }
            await connect(to: id, name: name)
            if state == .disconnected { scheduleReconnect() }
        }
    }

    func attemptAutoReconnect() {
        guard autoReconnect, state == .disconnected, let id = lastDeviceID else { return }
        Task { await connect(to: id, name: lastDeviceName ?? "printer") }
    }

    // MARK: Status

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                guard self.state == .connected, let client = self.client else { continue }
                if let status = try? await client.heartbeat() { self.heartbeat = status }
                tick += 1
                if tick % 6 == 0, let data = try? await client.info(.batteryLevel) {
                    self.info.batteryLevel = data.bigEndianValue
                }
            }
        }
    }

    func refresh() async {
        guard let client, state == .connected else { return }
        info = await client.fetchInfo()
        heartbeat = try? await client.heartbeat()
        rfid = try? await client.rfidInfo()
    }

    func readRFID() async {
        guard let client, state == .connected else { return }
        rfid = try? await client.rfidInfo()
    }

    func setAutoShutdown(_ time: AutoShutdownTime) async {
        guard let client, state == .connected else { return }
        do {
            try await client.setAutoShutdown(time)
            info.autoShutdownTime = Int(time.rawValue)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func printTestPage() async {
        guard let client, state == .connected else { return }
        do { try await client.printTestPage() } catch { lastError = error.localizedDescription }
    }

    // MARK: Printing

    func print(_ job: PrintJob) async throws {
        guard let client, state == .connected else { throw NiimbotError.disconnected }
        state = .printing
        progress = PrintProgress(stage: .preparing, printedLabels: 0, totalLabels: job.totalLabels)
        defer {
            if self.client != nil { state = .connected }
            printTask = nil
        }
        let task = Task { [weak self] in
            try await client.print(job) { progress in self?.progress = progress }
        }
        printTask = task
        try await task.value
        rfid = try? await client.rfidInfo()
    }

    func cancelPrint() {
        printTask?.cancel()
    }

    // MARK: Log

    func clearLog() { log.removeAll() }

    private func appendLog(_ direction: ProtocolLogEntry.Direction, _ text: String) {
        append(ProtocolLogEntry(direction: direction, text: text))
    }

    private func append(_ entry: ProtocolLogEntry) {
        log.append(entry)
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }
}
