import Foundation
import PackagePlugin

/// Translates a target's grammars to Swift on every build.
///
/// Each grammar of the target is a `<name>.grammar.json` configuration and
/// the published documents it names, next to it. The translation of each is
/// `<name>Grammar.swift`.
@main
struct EBNFTranslatorPlugin: BuildToolPlugin {
    /// The parts of a configuration the plugin reads: the grammar's name and
    /// its documents.
    struct Configuration: Decodable {
        struct Document: Decodable {
            var file: String
        }
        var name: String
        var documents: [Document]
    }

    func createBuildCommands(context: PluginContext, target: any Target) throws -> [Command] {
        guard let target = target as? any SourceModuleTarget else { return [] }
        let tool = try context.tool(named: "EBNFTranslator")
        let configurations = Self.configurations(in: target.directoryURL)
        return try configurations.map { url in
            let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
            let directory = url.deletingLastPathComponent()
            let output = context.pluginWorkDirectoryURL.appending(path: "\(configuration.name)Grammar.swift")
            return .buildCommand(
                displayName: "Translating the \(configuration.name) grammar to Swift",
                executable: tool.url,
                arguments: [url.path, output.path],
                inputFiles: [url] + configuration.documents.map { directory.appending(path: $0.file) },
                outputFiles: [output]
            )
        }
    }

    /// The `*.grammar.json` files under `directory`, in path order.
    ///
    /// The plugin looks in the target's directory itself rather than in its
    /// source files, so that it finds the grammars whether the target
    /// declares them as sources or as a resource directory, which a package
    /// copies whole (`.copy`), so that its files are not listed one by one.
    static func configurations(in directory: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return files
            .filter { $0.lastPathComponent.hasSuffix(".grammar.json") }
            .sorted { $0.path < $1.path }
    }
}
