import CoreBluetooth
import Foundation
import ImageIO
import LabelKit
import NiimbotKit

let usage = """
gebruik:
  niimlabel render <label.json> <uit.png> [--model B1] [--scale 3]
  niimlabel scan [--seconds 6]
  niimlabel print <label.json> [--copies 1] [--device B1] [--density 3] [--model B1]
"""

func option(_ name: String, in args: [String]) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadDocument(_ path: String) -> LabelDocument {
    guard let data = FileManager.default.contents(atPath: path) else { fail("Kan \(path) niet lezen") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do { return try decoder.decode(LabelDocument.self, from: data) } catch { fail("Ongeldig label: \(error)") }
}

func writePNG(_ bitmap: MonoBitmap, scale: Int, to path: String) {
    var scaled = MonoBitmap(width: bitmap.width * scale, height: bitmap.height * scale)
    for y in 0 ..< scaled.height { for x in 0 ..< scaled.width where bitmap[x / scale, y / scale] { scaled[x, y] = true } }
    guard let image = scaled.makeCGImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { fail("Kan \(path) niet schrijven") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

@MainActor
func waitForBluetooth(_ bluetooth: BluetoothManager) async {
    for _ in 0 ..< 50 where bluetooth.state == .unknown || bluetooth.state == .resetting {
        try? await Task.sleep(for: .milliseconds(100))
    }
    guard bluetooth.state == .poweredOn else { fail(bluetooth.stateDescription) }
}

@MainActor
func scan(_ bluetooth: BluetoothManager, seconds: Double, until match: ((DiscoveredPrinter) -> Bool)? = nil) async -> [DiscoveredPrinter] {
    bluetooth.startScan()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let match, bluetooth.discovered.contains(where: match) { break }
        try? await Task.sleep(for: .milliseconds(200))
    }
    bluetooth.stopScan()
    return bluetooth.discovered
}

@MainActor
func run() async {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { fail(usage) }

    switch command {
    case "render":
        guard args.count >= 3 else { fail(usage) }
        let document = loadDocument(args[1])
        let model = option("--model", in: args).flatMap(PrinterModel.named) ?? .b1
        let rendered = LabelRenderer.shared.render(document, dotsPerMM: model.dotsPerMM)
        for (id, issue) in rendered.issues {
            let name = document.element(id)?.content.summary ?? id.uuidString
            print("⚠︎ \(name): \(issue)")
        }
        writePNG(rendered.bitmap, scale: Int(option("--scale", in: args) ?? "3") ?? 3, to: args[2])
        print("\(rendered.bitmap.width)×\(rendered.bitmap.height) punten → \(args[2])")

    case "scan":
        let bluetooth = BluetoothManager()
        await waitForBluetooth(bluetooth)
        let found = await scan(bluetooth, seconds: Double(option("--seconds", in: args) ?? "6") ?? 6)
        if found.isEmpty { print("Geen printers gevonden.") }
        for device in found { print("\(device.name)\t\(device.detectedModel?.name ?? "?")\t\(device.rssi) dBm") }

    case "print":
        guard args.count >= 2 else { fail(usage) }
        let document = loadDocument(args[1])
        let copies = Int(option("--copies", in: args) ?? "1") ?? 1
        let wanted = option("--device", in: args)?.uppercased()
        let bluetooth = BluetoothManager()
        await waitForBluetooth(bluetooth)

        print("Zoeken naar printer…")
        let matches: (DiscoveredPrinter) -> Bool = { device in
            wanted.map { device.name.uppercased().hasPrefix($0) } ?? (device.detectedModel != nil)
        }
        guard let device = await scan(bluetooth, seconds: 12, until: matches).first(where: matches) else {
            fail("Geen printer gevonden. Staat hij aan en is hij niet met een ander apparaat verbonden?")
        }
        print("Verbinden met \(device.name)…")
        let connection: BLEConnection
        do { connection = try await bluetooth.connect(to: device.id) } catch { fail(error.localizedDescription) }
        let client = NiimbotClient(transport: connection)
        try? await client.handshake()
        let info = await client.fetchInfo()
        let model = option("--model", in: args).flatMap(PrinterModel.named) ?? info.model ?? device.detectedModel ?? .b1
        if let status = try? await client.heartbeat() {
            if status.isLidOpen == true { fail("Het deksel van de printer is open.") }
            if status.hasPaper == false { fail("De printer meldt geen labels.") }
        }
        if let rfid = try? await client.rfidInfo() {
            print("Labelrol: \(rfid.remainingLabels)/\(rfid.totalLabels) over")
        }
        print("Printer: \(model.name), firmware \(info.softwareVersion ?? "?")")

        let range = model.densityRange
        let density = min(max(Int(option("--density", in: args) ?? "") ?? document.density ?? model.defaultDensity, range.lowerBound), range.upperBound)
        let bitmap = LabelRenderer.shared.printBitmap(for: document, model: model)
        let job = PrintJob(pages: [PrintPage(bitmap: bitmap, quantity: copies)], density: density, labelType: document.labelType,
                           printProtocol: model.printProtocol, printheadPixels: model.printheadPixels)
        do {
            var last = -1
            try await client.print(job) { progress in
                if progress.printedLabels != last { last = progress.printedLabels; print("  \(progress.stage): \(progress.printedLabels)/\(progress.totalLabels)") }
            }
            print("Klaar: \(copies) label(s) afgedrukt.")
        } catch {
            fail("Afdrukken mislukt: \(error.localizedDescription)")
        }
        bluetooth.disconnect(device.id)

    default:
        fail(usage)
    }
}

Task { @MainActor in
    await run()
    exit(0)
}
dispatchMain()
