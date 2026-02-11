// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EBNFKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(
            name: "EBNFKit",
            targets: ["EBNFKit"]
        )
    ],
    targets: [
        .target(
            name: "EBNFKit",
            path: "EBNFKit"
        ),
        .testTarget(
            name: "EBNFKitTests",
            dependencies: ["EBNFKit"],
            path: "EBNFKitTests",
            resources: [.copy("Data")]
        )
    ]
)
