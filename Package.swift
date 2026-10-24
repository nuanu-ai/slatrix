// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Slatrix",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Slatrix", targets: ["Slatrix"])],
    dependencies: [
        .package(path: ".build/native-sdk-package"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Slatrix",
            dependencies: [
                .product(name: "MatrixRustSDK", package: "native-sdk-package"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Slatrix", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SlatrixTests", dependencies: ["Slatrix"]),
    ]
)
