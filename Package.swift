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
        ),
        .plugin(
            name: "EBNFTranslatorPlugin",
            targets: ["EBNFTranslatorPlugin"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3")
    ],
    targets: [
        .target(
            name: "EBNFKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),

        // EBNF in, Swift out: the translator and the build tool plugin that
        // runs it over a target's grammars.
        .executableTarget(
            name: "EBNFTranslator",
            dependencies: ["EBNFKit"]
        ),
        .plugin(
            name: "EBNFTranslatorPlugin",
            capability: .buildTool(),
            dependencies: ["EBNFTranslator"]
        ),

        .testTarget(
            name: "EBNFKitTests",
            dependencies: ["EBNFKit"],
            resources: [.copy("Data")]
        ),
        // The W3C RDF 1.2 grammars as published, translated by the plugin,
        // and the parsers the translation gives.
        .testTarget(
            name: "EBNFTranslatorTests",
            dependencies: ["EBNFKit"],
            resources: [.copy("Grammars")],
            plugins: ["EBNFTranslatorPlugin"]
        )
    ]
)
