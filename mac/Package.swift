// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NelsonBox",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Google WebRTC 预编译包，用于 P2P 文件传输
        .package(url: "https://github.com/stasel/WebRTC.git", from: "154.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "NelsonBox",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")],
            path: "Sources",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
