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
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0")
    ],
    targets: [
        .target(
            name: "EBNFKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                // The translation builds the Swift it writes as syntax nodes.
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftBasicFormat", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
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

        // W3C grammars as published, translated by the plugin or read back,
        // and the parsers the translation gives.
        .testTarget(
            name: "EBNFTranslatorTests",
            dependencies: ["EBNFKit"],
            resources: [.copy("Grammars")],
            plugins: ["EBNFTranslatorPlugin"]
        )
    ]
)
