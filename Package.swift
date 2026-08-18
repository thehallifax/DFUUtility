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
        .executable(name: "macvdmtool", targets: ["macvdmtool"]),
        .executable(name: "DFUPrivilegedHelper", targets: ["DFUPrivilegedHelper"]),
    ],
    targets: [
        .target(name: "DFUCore", linkerSettings: [.linkedFramework("Security"), .linkedFramework("ServiceManagement")]),
        .target(name: "DFUAppSupport", dependencies: ["DFUCore"]),
        .executableTarget(name: "dfuctl", dependencies: ["DFUCore"]),
        .executableTarget(name: "DFUUtilityApp", dependencies: ["DFUCore", "DFUAppSupport"]),
        .executableTarget(name: "DFUPrivilegedHelper", dependencies: ["DFUCore"]),
        .executableTarget(
            name: "macvdmtool",
            path: "Vendor/macvdmtool",
            exclude: ["LICENSE", "README.upstream.md", "UPSTREAM_REVISION"],
            cxxSettings: [.unsafeFlags(["-std=c++14"])],
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit"), .linkedLibrary("c++")]
        ),
        .testTarget(name: "DFUCoreTests", dependencies: ["DFUCore"]),
        .testTarget(name: "DFUAppSupportTests", dependencies: ["DFUCore", "DFUAppSupport"]),
    ]
)
