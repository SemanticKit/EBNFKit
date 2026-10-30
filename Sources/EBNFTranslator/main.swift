import EBNFKit
import Foundation

// EBNFTranslator <name>.grammar.json <output.swift>
//
// Reads the grammar a configuration describes from the published documents
// next to it, each checked against the SHA-256 digest the configuration
// records, and writes the grammar's Swift translation to the output.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: EBNFTranslator <name>.grammar.json <output.swift>\n".utf8))
    exit(2)
}
let configurationURL = URL(fileURLWithPath: arguments[1])
do {
    let configuration = try JSONDecoder().decode(GrammarConfiguration.self, from: Data(contentsOf: configurationURL))
    let grammar = try configuration.grammar(in: configurationURL.deletingLastPathComponent())
    let source = try SwiftSource(grammar: grammar, configuration: configuration)
    try Data(source.text.utf8).write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("\(configurationURL.path): error: \(error)\n".utf8))
    exit(1)
}
