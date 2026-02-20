// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BezelGenerator",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.3.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "BezelGenerator",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/BezelGenerator"
        )
    ]
)
