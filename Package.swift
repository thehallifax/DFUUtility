// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DFUUtility",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DFUCore", targets: ["DFUCore"]),
        .executable(name: "dfuctl", targets: ["dfuctl"]),
    ],
    targets: [
        .target(name: "DFUCore"),
        .executableTarget(name: "dfuctl", dependencies: ["DFUCore"]),
        .testTarget(name: "DFUCoreTests", dependencies: ["DFUCore"]),
    ]
)
