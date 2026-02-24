// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IndustrialHMI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "IndustrialHMI",
            targets: ["IndustrialHMI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),
    ],
    targets: [
        .systemLibrary(
            name: "COPC",
            path: "Sources/COPC"
        ),
        .executableTarget(
            name: "IndustrialHMI",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                "COPC"
            ],
            path: "Sources/IndustrialHMI",
            swiftSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-lopen62541"])
            ]
        ),
        .testTarget(
            name: "IndustrialHMITests",
            dependencies: ["IndustrialHMI"],
            path: "Tests/IndustrialHMITests"
        )
    ]
)
