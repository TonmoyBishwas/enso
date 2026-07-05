// swift-tools-version: 5.10
// Root package: builds the app executable, the root daemon, and the CLI.
// `Scripts/make-app.sh` assembles Enso.app from these products.
import PackageDescription

let package = Package(
    name: "Enso",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Enso", targets: ["EnsoApp"]),
        .executable(name: "ensod", targets: ["EnsoDaemon"]),
        .executable(name: "ensoctl", targets: ["ensoctl"]),
    ],
    dependencies: [
        .package(path: "Packages/EnsoCore"),
    ],
    targets: [
        .executableTarget(
            name: "EnsoApp",
            dependencies: [
                .product(name: "EnsoShared", package: "EnsoCore"),
                .product(name: "EnsoBattery", package: "EnsoCore"),
            ],
            path: "Apps/Enso/Sources"
        ),
        .executableTarget(
            name: "EnsoDaemon",
            dependencies: [
                .product(name: "EnsoShared", package: "EnsoCore"),
                .product(name: "EnsoEngine", package: "EnsoCore"),
                .product(name: "EnsoSMC", package: "EnsoCore"),
                .product(name: "EnsoBattery", package: "EnsoCore"),
            ],
            path: "Daemon/EnsoDaemon"
        ),
        .executableTarget(
            name: "ensoctl",
            dependencies: [
                .product(name: "EnsoShared", package: "EnsoCore"),
                .product(name: "EnsoSMC", package: "EnsoCore"),
                .product(name: "EnsoBattery", package: "EnsoCore"),
            ],
            path: "CLI/ensoctl"
        ),
    ]
)
