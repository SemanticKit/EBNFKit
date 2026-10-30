import EBNFKit
import Foundation
import Testing

/// The translation of a grammar into Swift.
@Suite struct SwiftSourceTests {
    @Test(arguments: ["Turtle", "NTriples", "XMLNames"])
    func isDeterministic(name: String) throws {
        let configuration = try NotationTests.configuration(name)
        let grammar = try configuration.grammar(in: NotationTests.grammars)
        let first = try SwiftSource(grammar: grammar, configuration: configuration)
        let second = try SwiftSource(grammar: grammar, configuration: configuration)
        #expect(first == second)
        #expect(first.text.contains("enum \(name)Grammar {}"))
    }

    @Test(arguments: [
        "a ::= b",                              // b is not defined
        "a ::= [a-z]\n@terminals\nb ::= 'b'",   // a character class read over terminals
        "a ::= b - c\n@terminals\nb ::= 'b'\nc ::= 'c'",
        "a ::= 'a'\n@terminals\nb ::= a",       // a terminal refers to a production read over terminals
        "a ::= 'a'\nA ::= 'b'",                 // the same Swift name
        "Token ::= 'a'",                        // a name the translation uses
    ])
    func refusesWhatItCannotTranslate(text: String) throws {
        let grammar = try Grammar(notation: text)
        #expect(throws: TranslationError.self) {
            try SwiftSource(grammar: grammar, configuration: GrammarConfiguration(name: "Test", documents: []))
        }
    }
}
