// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIProviderSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AIProviderSwitcherCore", targets: ["AIProviderSwitcherCore"]),
        .executable(name: "AIProviderSwitcher", targets: ["AIProviderSwitcher"])
    ],
    targets: [
        .target(
            name: "AIProviderSwitcherCore",
            path: "Sources/AIProviderSwitcherCore"
        ),
        .executableTarget(
            name: "AIProviderSwitcher",
            dependencies: ["AIProviderSwitcherCore"],
            path: "Sources/AIProviderSwitcher"
        ),
        .testTarget(
            name: "AIProviderSwitcherCoreTests",
            dependencies: ["AIProviderSwitcherCore"],
            path: "Tests/AIProviderSwitcherCoreTests"
        )
    ]
)
