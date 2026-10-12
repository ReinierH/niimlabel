import Foundation

public enum NiimbotError: LocalizedError, Equatable {
    case timeout(command: UInt8)
    case printerError(code: UInt8)
    case notSupported(command: UInt8)
    case disconnected
    case rejected(String)
    case cancelled
    case invalidImage(String)

    public var errorDescription: String? {
        switch self {
        case let .timeout(command): String(format: "Geen antwoord van de printer (commando 0x%02X).", command)
        case let .printerError(code): PrinterErrorCode.describe(code)
        case let .notSupported(command): String(format: "Commando 0x%02X wordt niet ondersteund door deze printer.", command)
        case .disconnected: "De verbinding met de printer is verbroken."
        case let .rejected(reason): reason
        case .cancelled: "Afdrukken geannuleerd."
        case let .invalidImage(reason): reason
        }
    }
}

public struct ProtocolLogEntry: Identifiable, Sendable {
    public enum Direction: String, Sendable { case sent = "→", received = "←", info = "•" }
    public let id = UUID()
    public let date = Date()
    public let direction: Direction
    public let text: String

    public init(direction: Direction, text: String) {
        self.direction = direction
        self.text = text
    }
}

public struct PrintPage: Sendable {
    public var bitmap: MonoBitmap
    public var quantity: Int

    public init(bitmap: MonoBitmap, quantity: Int) {
        self.bitmap = bitmap
        self.quantity = max(1, quantity)
    }
}

public struct PrintJob: Sendable {
    public var pages: [PrintPage]
    public var density: Int
    public var labelType: LabelType
    public var printProtocol: PrintProtocol
    public var printheadPixels: Int

    public init(pages: [PrintPage], density: Int, labelType: LabelType, printProtocol: PrintProtocol, printheadPixels: Int) {
        self.pages = pages
        self.density = density
        self.labelType = labelType
        self.printProtocol = printProtocol
        self.printheadPixels = printheadPixels
    }

    public var totalLabels: Int { pages.reduce(0) { $0 + $1.quantity } }
}

public struct PrintProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case preparing, sending, printing, finishing, done }
    public var stage: Stage
    public var printedLabels: Int
    public var totalLabels: Int

    public init(stage: Stage, printedLabels: Int, totalLabels: Int) {
        self.stage = stage
        self.printedLabels = printedLabels
        self.totalLabels = totalLabels
    }

    public var fraction: Double {
        guard totalLabels > 0 else { return 0 }
        return min(1, Double(printedLabels) / Double(totalLabels))
    }
}

/// Request/response client for the Niimbot protocol on top of any byte transport.
/// All requests are serialised: the printers do not cope well with interleaved commands.
@MainActor
public final class NiimbotClient {
    private final class PendingRequest {
        let expected: Set<UInt8>
        let command: UInt8
        var continuation: CheckedContinuation<NiimbotPacket, Error>?

        init(expected: Set<UInt8>, command: UInt8, continuation: CheckedContinuation<NiimbotPacket, Error>) {
            self.expected = expected
            self.command = command
            self.continuation = continuation
        }

        func resolve(_ result: Result<NiimbotPacket, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    public let transport: NiimbotTransport
    /// Pause between written packets. Some printers drop data when flooded.
    public var packetInterval: Duration = .milliseconds(10)
    public var onLog: ((ProtocolLogEntry) -> Void)?
    /// Logs every image row packet as well (very verbose).
    public var logImageData = false

    private var parser = PacketParser()
    private var pending: [PendingRequest] = []
    private var isLocked = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private var asyncPrintError: UInt8?
    private var isClosed = false

    public init(transport: NiimbotTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] bytes in self?.receive(bytes) }
    }

    /// Fails all outstanding requests; call when the link drops.
    public func close() {
        isClosed = true
        let outstanding = pending
        pending.removeAll()
        outstanding.forEach { $0.resolve(.failure(NiimbotError.disconnected)) }
    }

    // MARK: - Low level

    private func receive(_ bytes: [UInt8]) {
        for packet in parser.feed(bytes) {
            log(.received, packet.description)
            if packet.command == ResponseCommand.error {
                let code = packet.data.first ?? 0
                if let request = pending.first {
                    pending.removeFirst()
                    request.resolve(.failure(NiimbotError.printerError(code: code)))
                } else {
                    asyncPrintError = code
                }
                continue
            }
            if packet.command == ResponseCommand.notSupported, let request = pending.first {
                pending.removeFirst()
                request.resolve(.failure(NiimbotError.notSupported(command: request.command)))
                continue
            }
            if let index = pending.firstIndex(where: { $0.expected.contains(packet.command) }) {
                let request = pending.remove(at: index)
                request.resolve(.success(packet))
            }
        }
    }

    private func log(_ direction: ProtocolLogEntry.Direction, _ text: String) {
        onLog?(ProtocolLogEntry(direction: direction, text: text))
    }

    private func write(_ packet: NiimbotPacket, prefix: [UInt8] = []) async throws {
        guard !isClosed else { throw NiimbotError.disconnected }
        if logImageData || !RequestCommand.imageCommands.contains(packet.command) {
            log(.sent, packet.description)
        }
        try await transport.write(prefix + packet.encoded())
        if packetInterval > .zero { try await Task.sleep(for: packetInterval) }
    }

    private func transceive(_ command: RequestCommand, _ data: [UInt8] = [1], prefix: [UInt8] = [],
                            timeout: Duration = .seconds(2)) async throws -> NiimbotPacket {
        let packet = NiimbotPacket(command, data)
        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(expected: command.responses, command: command.rawValue, continuation: continuation)
            pending.append(request)
            Task {
                do {
                    try await write(packet, prefix: prefix)
                } catch {
                    pending.removeAll { $0 === request }
                    request.resolve(.failure(error))
                    return
                }
                try? await Task.sleep(for: timeout)
                if request.continuation != nil {
                    pending.removeAll { $0 === request }
                    request.resolve(.failure(NiimbotError.timeout(command: command.rawValue)))
                }
            }
        }
    }

    private func lock() async {
        if !isLocked { isLocked = true; return }
        await withCheckedContinuation { lockWaiters.append($0) }
    }

    private func unlock() {
        if lockWaiters.isEmpty { isLocked = false } else { lockWaiters.removeFirst().resume() }
    }

    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }

    /// Sends an arbitrary request and waits for its response (for diagnostics).
    public func request(_ command: RequestCommand, _ data: [UInt8] = [1], timeout: Duration = .seconds(2)) async throws -> NiimbotPacket {
        try await exclusive { try await transceive(command, data, timeout: timeout) }
    }

    // MARK: - Device information

    /// Initial handshake. The connect frame is prefixed with a single 0x03 byte.
    public func handshake() async throws {
        _ = try await exclusive { try await transceive(.connect, [1], prefix: [0x03], timeout: .seconds(3)) }
    }

    public func info(_ key: PrinterInfoKey) async throws -> [UInt8] {
        try await exclusive { try await transceive(.printerInfo, [key.rawValue]).data }
    }

    /// Reads everything the printer is willing to report. Unsupported keys are skipped.
    public func fetchInfo() async -> PrinterInfo {
        var result = PrinterInfo()
        if let data = try? await info(.modelId) { result.modelId = data.bigEndianValue }
        if let data = try? await info(.serialNumber) { result.serialNumber = PrinterInfo.parseText(data) }
        if let data = try? await info(.softwareVersion) { result.softwareVersion = PrinterInfo.parseVersion(data) }
        if let data = try? await info(.hardwareVersion) { result.hardwareVersion = PrinterInfo.parseVersion(data) }
        if let data = try? await info(.batteryLevel) { result.batteryLevel = data.bigEndianValue }
        if let data = try? await info(.density) { result.density = data.bigEndianValue }
        if let data = try? await info(.labelType) { result.labelType = data.bigEndianValue }
        if let data = try? await info(.autoShutdownTime) { result.autoShutdownTime = data.bigEndianValue }
        if let data = try? await info(.bluetoothAddress) { result.bluetoothAddress = PrinterInfo.parseAddress(data) }
        return result
    }

    public func heartbeat() async throws -> HeartbeatStatus {
        try await exclusive { HeartbeatStatus.parse(try await transceive(.heartbeat, [1]).data) }
    }

    public func rfidInfo() async throws -> RFIDInfo? {
        try await exclusive { RFIDInfo.parse(try await transceive(.rfidInfo, [1]).data) }
    }

    public func setAutoShutdown(_ time: AutoShutdownTime) async throws {
        let response = try await exclusive { try await transceive(.setAutoShutdownTime, [time.rawValue]) }
        guard response.data.first == 1 else { throw NiimbotError.rejected("De printer weigerde de uitschakeltijd.") }
    }

    public func printTestPage() async throws {
        _ = try await exclusive { try await transceive(.printTestPage, [1], timeout: .seconds(5)) }
    }

    // MARK: - Printing

    /// Prints a job and reports progress. Cancel the surrounding task to abort.
    public func print(_ job: PrintJob, progress: @escaping (PrintProgress) -> Void) async throws {
        guard !job.pages.isEmpty else { return }
        for page in job.pages where page.bitmap.width > job.printheadPixels {
            throw NiimbotError.invalidImage("Afbeelding is \(page.bitmap.width) punten breed, de printkop maar \(job.printheadPixels).")
        }

        try await exclusive {
            asyncPrintError = nil
            let total = job.totalLabels
            progress(PrintProgress(stage: .preparing, printedLabels: 0, totalLabels: total))
            log(.info, "Afdruktaak: \(job.pages.count) pagina('s), \(total) label(s), protocol \(job.printProtocol.rawValue)")

            do {
                try await expectSuccess(.setDensity, [UInt8(clamping: job.density)], "Kon de densiteit niet instellen.")
                try await expectSuccess(.setLabelType, [job.labelType.rawValue], "Kon het labeltype niet instellen.")

                switch job.printProtocol {
                case .modern:
                    try await expectSuccess(.printStart, total.u16Bytes + [0, 0, 0, 0, 0],
                                            "De printer weigert af te drukken. Controleer deksel en labelrol.")
                case .legacy:
                    try await expectSuccess(.printStart, [1], "De printer weigert af te drukken. Controleer deksel en labelrol.")
                }

                var sent = 0
                for (index, page) in job.pages.enumerated() {
                    try Task.checkCancellation()
                    progress(PrintProgress(stage: .sending, printedLabels: sent, totalLabels: total))
                    try await sendPage(page, job: job)
                    sent += page.quantity

                    if index < job.pages.count - 1 {
                        try await waitUntilPrinted(sent, total: total, progress: progress)
                    }
                }

                try await waitUntilPrinted(total, total: total, progress: progress)
                progress(PrintProgress(stage: .finishing, printedLabels: total, totalLabels: total))
                try await endPrint()
                progress(PrintProgress(stage: .done, printedLabels: total, totalLabels: total))
            } catch {
                let reportedError = error is CancellationError ? NiimbotError.cancelled : error
                log(.info, "Afdrukken afgebroken: \(reportedError.localizedDescription)")
                // Leave the printer in a clean state.
                _ = try? await transceive(.printEnd, [1], timeout: .milliseconds(800))
                throw reportedError
            }
        }
    }

    private func sendPage(_ page: PrintPage, job: PrintJob) async throws {
        let bitmap = page.bitmap
        // Page level responses are not sent by every firmware; tolerate missing replies.
        _ = try? await transceive(.pageStart, [1])
        switch job.printProtocol {
        case .modern:
            _ = try? await transceive(.setPageSize, bitmap.height.u16Bytes + bitmap.width.u16Bytes + page.quantity.u16Bytes)
        case .legacy:
            _ = try? await transceive(.setPageSize, bitmap.height.u16Bytes + bitmap.width.u16Bytes)
            _ = try? await transceive(.setQuantity, page.quantity.u16Bytes)
        }

        for packet in BitmapEncoder.packets(for: bitmap, printheadPixels: job.printheadPixels) {
            try Task.checkCancellation()
            if let code = asyncPrintError { throw NiimbotError.printerError(code: code) }
            try await write(packet)
        }

        for attempt in 0 ..< 10 {
            let response = try? await transceive(.pageEnd, [1], timeout: .seconds(3))
            if response == nil || response?.data.first == 1 { break }
            if attempt == 9 { throw NiimbotError.rejected("De printer accepteerde de pagina niet.") }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func waitUntilPrinted(_ target: Int, total: Int, progress: (PrintProgress) -> Void) async throws {
        var lastPage = -1
        var lastChange = ContinuousClock.now
        var unsupported = 0
        while true {
            try Task.checkCancellation()
            if let code = asyncPrintError { throw NiimbotError.printerError(code: code) }

            do {
                let response = try await transceive(.printStatus, [1], timeout: .seconds(2))
                if let status = PrintStatus.parse(response.data) {
                    if status.page != lastPage {
                        lastPage = status.page
                        lastChange = .now
                        progress(PrintProgress(stage: .printing, printedLabels: min(status.page, total), totalLabels: total))
                    }
                    if status.page >= target { return }
                }
            } catch let error as NiimbotError {
                switch error {
                case .printerError: throw error
                case .notSupported:
                    // No status polling on this firmware: give the printer time and rely on PrintEnd.
                    unsupported += 1
                    if unsupported > 2 {
                        try await Task.sleep(for: .seconds(1))
                        return
                    }
                default: break
                }
            }

            if ContinuousClock.now - lastChange > .seconds(30) {
                throw NiimbotError.rejected("De printer reageert niet meer tijdens het afdrukken.")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func endPrint() async throws {
        for _ in 0 ..< 30 {
            if let response = try? await transceive(.printEnd, [1]), response.data.first == 1 { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        log(.info, "PrintEnd werd niet bevestigd")
    }

    private func expectSuccess(_ command: RequestCommand, _ data: [UInt8], _ failure: String) async throws {
        let response = try await transceive(command, data)
        if let first = response.data.first, first == 0 {
            throw NiimbotError.rejected(failure)
        }
    }
}

extension RequestCommand {
    static let imageCommands: Set<UInt8> = [
        RequestCommand.printBitmapRow.rawValue,
        RequestCommand.printEmptyRow.rawValue,
        RequestCommand.printBitmapRowIndexed.rawValue,
    ]
}
