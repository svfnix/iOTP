// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iOTP",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "iOTP",
            path: "Sources/iOTP"
        )
    ]
)
