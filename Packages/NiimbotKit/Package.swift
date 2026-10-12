// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NiimbotKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NiimbotKit", targets: ["NiimbotKit"]),
        .library(name: "LabelKit", targets: ["LabelKit"]),
    ],
    targets: [
        // Bluetooth transport + Niimbot wire protocol.
        .target(name: "NiimbotKit"),
        // Label document model, barcode encoders and 1-bit rendering.
        .target(name: "LabelKit", dependencies: ["NiimbotKit"]),
        .testTarget(name: "NiimbotKitTests", dependencies: ["NiimbotKit"]),
        .testTarget(name: "LabelKitTests", dependencies: ["LabelKit"]),
    ]
)
