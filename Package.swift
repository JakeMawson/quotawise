// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "QuotaWise",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "QuotaWise", targets: ["QuotaWise"]),
        .executable(name: "QuotaWiseLauncher", targets: ["QuotaWiseLauncher"]),
        .executable(name: "codexusage-native", targets: ["QuotaWiseCLI"]),
    ],
    targets: [
        .target(name: "QuotaWiseKit"),
        .executableTarget(
            name: "QuotaWise",
            dependencies: ["QuotaWiseKit"]
        ),
        .executableTarget(name: "QuotaWiseLauncher"),
        .executableTarget(
            name: "QuotaWiseCLI",
            dependencies: ["QuotaWiseKit"]
        ),
        .testTarget(
            name: "QuotaWiseKitTests",
            dependencies: ["QuotaWiseKit"]
        ),
    ]
)
