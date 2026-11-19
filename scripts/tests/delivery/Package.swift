// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeliveryProbe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../.build/native-sdk-package")],
    targets: [
        .executableTarget(
            name: "DeliverySender",
            dependencies: [.product(name: "MatrixRustSDK", package: "native-sdk-package")])
    ])
