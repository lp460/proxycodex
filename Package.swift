// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIProviderSwitcher",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AIProviderSwitcherCore", targets: ["AIProviderSwitcherCore"]),
        .executable(name: "AIProviderSwitcher", targets: ["AIProviderSwitcher"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(
            name: "AIProviderSwitcherCore",
            path: "Sources/AIProviderSwitcherCore"
        ),
        .executableTarget(
            name: "AIProviderSwitcher",
            dependencies: [
                "AIProviderSwitcherCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AIProviderSwitcher"
        ),
        .testTarget(
            name: "AIProviderSwitcherCoreTests",
            dependencies: ["AIProviderSwitcherCore"],
            path: "Tests/AIProviderSwitcherCoreTests"
        )
    ]
)
