// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Brimio",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Brimio",
            path: "Sources/Brimio"
        )
    ]
)
