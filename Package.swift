// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTalk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacTalk", targets: ["MacTalk"]),
        .library(name: "MacTalkCore", targets: ["MacTalkCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", from: "137.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "MacTalkCore", path: "Sources/MacTalkCore"),
        .executableTarget(
            name: "MacTalk",
            dependencies: [
                "MacTalkCore",
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MacTalk",
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("CoreAudio")]
        ),
        .testTarget(name: "MacTalkCoreTests", dependencies: ["MacTalkCore"], path: "Tests/MacTalkCoreTests"),
    ]
)
