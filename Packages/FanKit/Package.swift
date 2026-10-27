// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "FanCore", targets: ["FanCore"]),
        .library(name: "FanShared", targets: ["FanShared"]),
    ],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "SMCKit", dependencies: ["CSMC"]),
        .target(name: "FanShared"),
        .target(name: "FanCore"),
        .executableTarget(name: "smcprobe", dependencies: ["SMCKit"]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore", "SMCKit"]),
    ]
)
