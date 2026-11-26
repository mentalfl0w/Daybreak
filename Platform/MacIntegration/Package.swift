// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacIntegration",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacIntegration", targets: ["MacIntegration"])
    ],
    dependencies: [
        .package(path: "../../Packages/DaybreakCore")
    ],
    targets: [
        .target(
            name: "MacIntegration",
            dependencies: [
                .product(name: "DaybreakCore", package: "DaybreakCore")
            ]
        ),
        .testTarget(
            name: "MacIntegrationTests",
            dependencies: ["MacIntegration"]
        )
    ],
    swiftLanguageModes: [.v6]
)
