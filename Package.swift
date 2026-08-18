// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DFUUtility",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DFUCore", targets: ["DFUCore"]),
        .library(name: "DFUAppSupport", targets: ["DFUAppSupport"]),
        .executable(name: "dfuctl", targets: ["dfuctl"]),
        .executable(name: "DFUUtility", targets: ["DFUUtilityApp"]),
    ],
    targets: [
        .target(name: "DFUCore"),
        .target(name: "DFUAppSupport", dependencies: ["DFUCore"]),
        .executableTarget(name: "dfuctl", dependencies: ["DFUCore"]),
        .executableTarget(name: "DFUUtilityApp", dependencies: ["DFUCore", "DFUAppSupport"]),
        .testTarget(name: "DFUCoreTests", dependencies: ["DFUCore"]),
        .testTarget(name: "DFUAppSupportTests", dependencies: ["DFUCore", "DFUAppSupport"]),
    ]
)
