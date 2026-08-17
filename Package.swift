// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MemoryClip",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "MemoryClip",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/MemoryClip",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MemoryClipTests",
            dependencies: ["MemoryClip"],
            path: "Tests/MemoryClipTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
