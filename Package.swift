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
            exclude: ["Resources"],
            swiftSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-lopen62541",
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/IndustrialHMI/Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "IndustrialHMITests",
            dependencies: ["IndustrialHMI"],
            path: "Tests/IndustrialHMITests"
        )
    ]
)
