import XCTest
@testable import NiimbotKit

final class PacketTests: XCTestCase {
    func testEncodeConnect() {
        XCTAssertEqual(NiimbotPacket(.connect, [1]).encoded(), [0x55, 0x55, 0xC1, 0x01, 0x01, 0xC1, 0xAA, 0xAA])
    }

    func testEncodeSetDensity() {
        // checksum = 0x21 ^ 0x01 ^ 0x03
        XCTAssertEqual(NiimbotPacket(.setDensity, [3]).encoded(), [0x55, 0x55, 0x21, 0x01, 0x03, 0x23, 0xAA, 0xAA])
    }

    func testParserHandlesSplitAndMergedFrames() {
        var parser = PacketParser()
        let a = NiimbotPacket(0x31, [1]).encoded()
        let b = NiimbotPacket(0x40 + 8, [0x10, 0x00]).encoded()
        let stream = [0x00, 0x12] + a + b
        XCTAssertEqual(parser.feed(Array(stream[0 ..< 5])), [])
        let packets = parser.feed(Array(stream[5...]))
        XCTAssertEqual(packets, [NiimbotPacket(0x31, [1]), NiimbotPacket(0x48, [0x10, 0x00])])
    }

    func testParserSkipsCorruptFrame() {
        var parser = PacketParser()
        var bad = NiimbotPacket(0x31, [1]).encoded()
        bad[5] ^= 0xFF
        let good = NiimbotPacket(0x33, [1]).encoded()
        XCTAssertEqual(parser.feed(bad + good), [NiimbotPacket(0x33, [1])])
    }
}

final class BitmapTests: XCTestCase {
    func testRotationClockwise() {
        var bitmap = MonoBitmap(width: 3, height: 2)
        bitmap[0, 0] = true // top-left
        let rotated = bitmap.rotated(degrees: 90)
        XCTAssertEqual(rotated.width, 2)
        XCTAssertEqual(rotated.height, 3)
        XCTAssertTrue(rotated[1, 0]) // becomes top-right
        XCTAssertEqual(rotated.blackPixelCount, 1)
        XCTAssertEqual(bitmap.rotated(degrees: 360), bitmap)
        XCTAssertEqual(bitmap.rotated(degrees: 90).rotated(degrees: 270), bitmap)
    }

    func testPlacedCentersAndClips() {
        var bitmap = MonoBitmap(width: 4, height: 1)
        for x in 0 ..< 4 { bitmap[x, 0] = true }
        let wider = bitmap.placed(inWidth: 8, height: 1)
        XCTAssertEqual((0 ..< 8).map { wider[$0, 0] }, [false, false, true, true, true, true, false, false])
        let narrower = bitmap.placed(inWidth: 2, height: 1)
        XCTAssertEqual(narrower.blackPixelCount, 2)
    }

    func testEncoderMergesRows() {
        var bitmap = MonoBitmap(width: 16, height: 6)
        for y in 2 ..< 5 { bitmap[0, y] = true }
        let packets = BitmapEncoder.packets(for: bitmap, printheadPixels: 384)
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets[0], NiimbotPacket(.printEmptyRow, [0, 0, 2]))
        XCTAssertEqual(packets[1], NiimbotPacket(.printBitmapRow, [0, 2, 1, 0, 0, 3, 0x80, 0x00]))
        XCTAssertEqual(packets[2], NiimbotPacket(.printEmptyRow, [0, 5, 1]))
    }

    func testPixelCountsSplitIntoThirds() {
        // B1: 384 dots → 16 bytes per third.
        var row = [UInt8](repeating: 0, count: 48)
        row[0] = 0xFF
        row[16] = 0x0F
        row[47] = 0x01
        let counts = BitmapEncoder.pixelCounts(row: row[...], printheadPixels: 384)
        XCTAssertEqual(counts.0, 8)
        XCTAssertEqual(counts.1, 4)
        XCTAssertEqual(counts.2, 1)
    }
}

final class ParsingTests: XCTestCase {
    func testHeartbeat13() {
        let data: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 4, 0, 1]
        let status = HeartbeatStatus.parse(data)
        XCTAssertEqual(status.isLidOpen, true)
        XCTAssertEqual(status.powerLevel, 4)
        XCTAssertEqual(status.hasPaper, true)
        XCTAssertEqual(status.rfidReadState, 1)
    }

    func testRFID() {
        var data: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        data += [4] + Array("6972".utf8)
        data += [3] + Array("ABC".utf8)
        data += [0x00, 0xE6, 0x00, 0x0A, 0x01]
        let info = RFIDInfo.parse(data)
        XCTAssertEqual(info?.barcode, "6972")
        XCTAssertEqual(info?.serial, "ABC")
        XCTAssertEqual(info?.totalLabels, 230)
        XCTAssertEqual(info?.usedLabels, 10)
        XCTAssertEqual(info?.remainingLabels, 220)
        XCTAssertEqual(info?.labelType, .withGaps)
        XCTAssertNil(RFIDInfo.parse([0]))
    }

    func testModelDetection() {
        XCTAssertEqual(PrinterModel.detect(advertisedName: "B1-H811040144")?.name, "B1")
        XCTAssertEqual(PrinterModel.detect(advertisedName: "D110-F5021411")?.name, "D110")
        XCTAssertEqual(PrinterModel.detect(advertisedName: "B21-C2104")?.name, "B21")
        XCTAssertNil(PrinterModel.detect(advertisedName: "AirPods"))
        XCTAssertEqual(PrinterModel.detect(modelId: 4096)?.name, "B1")
    }
}

/// Simulated printer that answers like a B1 and records the command sequence.
@MainActor
final class FakePrinter: NiimbotTransport {
    var onReceive: (([UInt8]) -> Void)?
    var commands: [UInt8] = []
    var pageSizes: [[UInt8]] = []
    var printStartData: [UInt8] = []
    var rows = 0
    private var parser = PacketParser()
    private var printed = 0
    private var expected = 0

    func write(_ bytes: [UInt8]) async throws {
        // Strip the 0x03 prefix of the connect frame.
        let payload = bytes.first == 0x03 ? Array(bytes.dropFirst()) : bytes
        for packet in parser.feed(payload) { handle(packet) }
    }

    private func reply(_ command: UInt8, _ data: [UInt8]) {
        let bytes = NiimbotPacket(command, data).encoded()
        Task { @MainActor in self.onReceive?(bytes) }
    }

    private func handle(_ packet: NiimbotPacket) {
        commands.append(packet.command)
        switch RequestCommand(rawValue: packet.command) {
        case .printBitmapRow:
            rows += Int(packet.data[5])
        case .printEmptyRow:
            rows += Int(packet.data[2])
        case .printStart:
            printStartData = packet.data
            expected = Array(packet.data[0 ..< 2]).bigEndianValue
            reply(0x02, [1])
        case .setPageSize:
            pageSizes.append(packet.data)
            reply(0x14, [1])
        case .pageEnd:
            printed += Array(pageSizes.last![4 ..< 6]).bigEndianValue
            reply(0xE4, [1])
        case .printStatus:
            reply(0xB3, printed.u16Bytes + [100, 100])
        case .connect: reply(0xC2, [1])
        case let command?:
            if let response = command.responses.first { reply(response, [1]) }
        case nil: break
        }
    }
}

@MainActor
final class PrintFlowTests: XCTestCase {
    func testB1PrintSequence() async throws {
        let printer = FakePrinter()
        let client = NiimbotClient(transport: printer)
        client.packetInterval = .zero

        var bitmap = MonoBitmap(width: 384, height: 240)
        for x in 0 ..< 384 { bitmap[x, 10] = true }
        let job = PrintJob(pages: [PrintPage(bitmap: bitmap, quantity: 3)], density: 3, labelType: .withGaps,
                           printProtocol: .modern, printheadPixels: 384)

        var stages: [PrintProgress.Stage] = []
        try await client.print(job) { stages.append($0.stage) }

        XCTAssertEqual(printer.printStartData, [0, 3, 0, 0, 0, 0, 0])
        XCTAssertEqual(printer.pageSizes, [[0, 240, 1, 128, 0, 3]])
        XCTAssertEqual(printer.rows, 240)
        XCTAssertEqual(Array(printer.commands.prefix(5)), [0x21, 0x23, 0x01, 0x03, 0x13])
        XCTAssertEqual(printer.commands.last, 0xF3)
        XCTAssertEqual(stages.last, .done)
    }

    func testTimeoutWhenPrinterSilent() async {
        final class Silent: NiimbotTransport {
            var onReceive: (([UInt8]) -> Void)?
            func write(_ bytes: [UInt8]) async throws {}
        }
        let client = NiimbotClient(transport: Silent())
        client.packetInterval = .zero
        do {
            _ = try await client.request(.heartbeat, timeout: .milliseconds(100))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? NiimbotError, .timeout(command: 0xDC))
        }
    }
}
