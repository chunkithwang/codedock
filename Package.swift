// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "codedock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "codedock", targets: ["Codedock"]),
        .executable(name: "codedock-bridge", targets: ["CodedockBridge"]),
    ],
    dependencies: [
        // Sparkle — auto-update framework. Pinned to 2.6+ for stable
        // SPUStandardUpdaterController + ed25519 signature verification.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "CodedockCore",
            path: "Sources/CodedockCore"
        ),
        .executableTarget(
            name: "Codedock",
            dependencies: [
                "CodedockCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/Codedock",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "CodedockBridge",
            dependencies: ["CodedockCore"],
            path: "Sources/CodedockBridge"
        ),
        .testTarget(
            name: "CodedockCoreTests",
            dependencies: ["CodedockCore"],
            path: "Tests/CodedockCoreTests"
        ),
        .testTarget(
            name: "CodedockTests",
            dependencies: [
                "Codedock",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Tests/CodedockTests"
        ),
    ]
)
