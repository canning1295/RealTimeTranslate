// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RealTimeTranslateApp",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .executable(name: "RealTimeTranslateApp", targets: ["RealTimeTranslateApp"])
    ],
    targets: [
        .executableTarget(
            name: "RealTimeTranslateApp",
            path: "Sources/RealTimeTranslateApp",
            resources: [
                .copy("Info.plist")
            ]
        )
    ]
)
