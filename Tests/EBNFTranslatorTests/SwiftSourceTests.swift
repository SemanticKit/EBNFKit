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
        #expect(first.text.contains("enum \(name)Grammar {"))
    }

    @Test(arguments: [
        "a ::= b",                              // b is not defined
        "a ::= [a-z]\n@terminals\nb ::= 'b'",   // a character class read over terminals
        "a ::= b - c\n@terminals\nb ::= 'b'\nc ::= 'c'",
        "a ::= 'a'\n@terminals\nb ::= a",       // a terminal refers to a production read over terminals
        "a ::= 'a'\nA ::= 'b'",                 // the same Swift name
        "Token ::= 'a'",                        // a name the translation uses
        // The parser keeps the first match of a choice, `?`, `*` and `+`:
        // a grammar where that is not the match the rest needs is refused.
        "doc ::= X* X\n@terminals\nX ::= 'x'",
        "item ::= (X | X Y) Y\n@terminals\nX ::= 'x'\nY ::= 'y'",
        "item ::= (X Y | X) Y\n@terminals\nX ::= 'x'\nY ::= 'y'",
        "doc ::= (X?)*\n@terminals\nX ::= 'x'",
        "doc ::= X? | Y?\n@terminals\nX ::= 'x'\nY ::= 'y'",
    ])
    func refusesWhatItCannotTranslate(text: String) throws {
        let grammar = try Grammar(notation: text)
        #expect(throws: TranslationError.self) {
            try SwiftSource(grammar: grammar, configuration: GrammarConfiguration(name: "Test", documents: []))
        }
    }

    @Test func namesTheDecisionTheNextTerminalsDoNotDecide() throws {
        let grammar = try Grammar(notation: "doc ::= X* X\n@terminals\nX ::= 'x'")
        #expect(throws: TranslationError("'doc' cannot be read by its next 2 terminals: in `X*`, X can start both `X` and what follows it")) {
            try SwiftSource(grammar: grammar, configuration: GrammarConfiguration(name: "Test", documents: []))
        }
    }

    /// Two terminals decide `(EOL statement)* EOL?`, as in N-Triples, and an
    /// alternative that matches nothing is tried after the others.
    @Test(arguments: [
        "doc ::= (X Y)* X?\n@terminals\nX ::= 'x'\nY ::= 'y'",
        "doc ::= (X? | Y) Z\n@terminals\nX ::= 'x'\nY ::= 'y'\nZ ::= 'z'",
    ])
    func translatesWhatTheNextTwoTerminalsDecide(text: String) throws {
        let grammar = try Grammar(notation: text)
        _ = try SwiftSource(grammar: grammar, configuration: GrammarConfiguration(name: "Test", documents: []))
    }
}
