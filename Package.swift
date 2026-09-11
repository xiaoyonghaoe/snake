// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Snake",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Snake", targets: ["SnakeExecutable"]),
        .executable(name: "SnakeMountHelper", targets: ["SnakeMountHelper"]),
        .library(name: "SnakeApp", targets: ["SnakeApp"]),
        .library(name: "SnakeCoreBindings", targets: ["SnakeCoreBindings"])
    ],
    dependencies: [
        .package(path: "Vendor/Bonsplit"),
        .package(path: "Vendor/SwiftTerm")
    ],
    targets: [
        .systemLibrary(
            name: "snake_coreFFI",
            path: "Generated/SnakeCoreFFI"
        ),
        .target(
            name: "SnakeCoreBindings",
            dependencies: ["snake_coreFFI"],
            path: "Generated/SnakeCoreBindings",
            sources: ["snake_core.swift"],
            linkerSettings: [
                .unsafeFlags(["-L", "Rust/snake_core/target/release"]),
                .linkedLibrary("snake_core")
            ]
        ),
        .target(
            name: "SnakeApp",
            dependencies: [
                "Bonsplit",
                "SnakeCoreBindings",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "SnakeExecutable",
            dependencies: ["SnakeApp"]
        ),
        .executableTarget(
            name: "SnakeMountHelper"
        ),
        .testTarget(
            name: "SnakeAppTests",
            dependencies: ["SnakeApp"]
        )
    ]
)
