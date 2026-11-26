// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DaybreakCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "DaybreakCore", targets: ["DaybreakCore"])
    ],
    targets: [
        .target(name: "DaybreakCore"),
        .testTarget(name: "DaybreakCoreTests", dependencies: ["DaybreakCore"])
    ],
    swiftLanguageModes: [.v6]
)
