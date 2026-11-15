// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LegadoCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LegadoCore", targets: ["LegadoCore"])],
    targets: [
        .target(name: "LegadoCore"),
        .testTarget(name: "LegadoCoreTests", dependencies: ["LegadoCore"])
    ]
)
