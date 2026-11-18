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
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.0"),
        .package(url: "https://github.com/stasel/WebRTC", from: "137.0.0"),
    ],
    targets: [
        .target(name: "MacTalkCore", path: "Sources/MacTalkCore"),
        .executableTarget(
            name: "MacTalk",
            dependencies: [
                "MacTalkCore",
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/MacTalk",
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("CoreAudio")]
        ),
        .testTarget(name: "MacTalkCoreTests", dependencies: ["MacTalkCore"], path: "Tests/MacTalkCoreTests"),
    ]
)
