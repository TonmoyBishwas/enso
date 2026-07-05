// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EnsoCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EnsoShared", targets: ["EnsoShared"]),
        .library(name: "EnsoEngine", targets: ["EnsoEngine"]),
        .library(name: "EnsoSMC", targets: ["EnsoSMC"]),
        .library(name: "EnsoBattery", targets: ["EnsoBattery"]),
    ],
    targets: [
        .target(name: "EnsoShared"),
        .target(name: "EnsoEngine", dependencies: ["EnsoShared"]),
        .target(name: "EnsoSMC", dependencies: ["EnsoShared"]),
        .target(name: "EnsoBattery"),
        .testTarget(name: "EnsoEngineTests", dependencies: ["EnsoEngine", "EnsoShared"]),
        .testTarget(name: "EnsoSMCTests", dependencies: ["EnsoSMC"]),
    ]
)
