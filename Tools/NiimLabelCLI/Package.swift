// swift-tools-version: 5.10
import PackageDescription

// Command-line companion: render label JSON files and print them over Bluetooth.
let package = Package(
    name: "NiimLabelCLI",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/NiimbotKit")],
    targets: [
        .executableTarget(
            name: "niimlabel",
            dependencies: [.product(name: "NiimbotKit", package: "NiimbotKit"), .product(name: "LabelKit", package: "NiimbotKit")],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed an Info.plist so macOS can show the Bluetooth permission prompt.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/niimlabel/Info.plist"]),
            ]
        ),
    ]
)
