// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OuraProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "OuraProtocol", targets: ["OuraProtocol"]),
    ],
    targets: [
        .target(name: "OuraProtocol"),
        .testTarget(
            name: "OuraProtocolTests",
            dependencies: ["OuraProtocol"]
        ),
    ]
)
