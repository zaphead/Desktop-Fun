// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskDuck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeskDuck",
            path: "Sources/DeskDuck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
