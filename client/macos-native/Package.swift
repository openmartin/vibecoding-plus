// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeCodingPlusNative",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "VibeCodingPlusNative",
            path: "Sources/VibeCodingPlusNative",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info-spm.plist"])
            ]
        ),
        .testTarget(
            name: "VibeCodingPlusNativeTests",
            dependencies: ["VibeCodingPlusNative"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
