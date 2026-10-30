import EBNFKit
import Foundation
import Testing

/// The EBNF notation of XML 1.0 §6, over the W3C grammars as published.
@Suite struct NotationTests {
    static let grammars = Bundle.module.url(forResource: "Grammars", withExtension: nil)!

    static func configuration(_ name: String) throws -> GrammarConfiguration {
        try JSONDecoder().decode(GrammarConfiguration.self, from: Data(contentsOf: grammars.appending(path: "\(name).grammar.json")))
    }

    @Test func readsTheTurtleGrammar() throws {
        let grammar = try Self.configuration("Turtle").grammar(in: Self.grammars)
        #expect(grammar.productions.first?.symbol == "turtleDoc")
        #expect(grammar.productions.filter { !$0.isTerminal }.count == 36)
        #expect(grammar["IRIREF"]?.isTerminal == true)
        #expect(grammar["sparqlPrefix"]?.expression == .sequence([
            .string("PREFIX", .quotationMark), .symbol("PNAME_NS"), .symbol("IRIREF"),
        ]))
        // `[^#x00-#x20<>"{}|^`\]`: the notation has no escapes.
        #expect(grammar["IRIREF"]?.expression == .sequence([
            .string("<", .apostrophe),
            .zeroOrMore(.choice([
                .characterClass(CharacterClass(isNegated: true, ranges: [0x00...0x20] + "<>\"{}|^`\\".unicodeScalars.map { $0.value...$0.value })),
                .symbol("UCHAR"),
            ])),
            .string(">", .apostrophe),
        ]))
        // `PN_LOCAL ::= … ) ?`, with a space before the operator.
        guard case .sequence(let local) = grammar["PN_LOCAL"]?.expression, case .optional = local.last else {
            Issue.record("PN_LOCAL does not end in an optional group")
            return
        }
    }

    @Test(arguments: ["Turtle", "NTriples", "XMLNames"])
    func writesWhatItReads(name: String) throws {
        let grammar = try Self.configuration(name).grammar(in: Self.grammars)
        for production in grammar.productions {
            let text = "\(production.symbol) ::= \(production.expression.notation)"
            #expect(try Grammar(notation: text).productions == [Production(symbol: production.symbol, expression: production.expression)])
        }
    }

    /// The grammars of XML 1.0, Namespaces in XML 1.0, XPath 2.0 and 3.0
    /// and XQuery 1.0, as extracted from the Recommendations
    /// (`Grammars/Notation`), read and written back.
    ///
    /// The extraction of the XPath and XQuery grammars follows their
    /// productions with a line `<?TOKENS?>` and terminals that link to the
    /// productions of other Recommendations
    /// (`[http://www.w3.org/TR/REC-xml#NT-Char]`). Both are the extraction
    /// tool's, not the notation's, so only the productions before the line
    /// are read.
    @Test(arguments: ["xml", "xml-names", "xpath20", "xpath30", "xquery10"])
    func writesWhatItReadsOfAW3CGrammar(file: String) throws {
        let text = try String(contentsOf: Self.grammars.appending(path: "Notation/\(file).ebnf"), encoding: .utf8)
        let productions = text.components(separatedBy: "\n<?TOKENS?>\n")[0]
        let grammar = try Grammar(notation: productions)
        #expect(grammar.productions.count > 20)
        let written = grammar.productions.map { "\($0.symbol) ::= \($0.expression.notation)" }.joined(separator: "\n")
        #expect(try Grammar(notation: written) == grammar)
    }

    @Test func readsTheScrapsOfTheXMLRecommendations() throws {
        let grammar = try Self.configuration("XMLNames").grammar(in: Self.grammars)
        #expect(grammar["NCName"]?.expression == .difference(
            .symbol("Name"),
            .sequence([.zeroOrMore(.symbol("Char")), .string(":", .apostrophe), .zeroOrMore(.symbol("Char"))])
        ))
        #expect(grammar["Name"]?.expression == .sequence([.symbol("NameStartChar"), .zeroOrMore(.symbol("NameChar"))]))
    }

    @Test func refusesADocumentThatIsNotAsPublished() throws {
        let configuration = try Self.configuration("Turtle")
        var bytes = try Data(contentsOf: Self.grammars.appending(path: "turtle.bnf"))
        bytes.append(contentsOf: Array("\n".utf8))
        #expect(throws: TranslationError.self) {
            try configuration.documents[0].grammar(from: bytes)
        }
    }

    @Test(arguments: [
        "a ::= 'b", "a 'b'", "a ::= [b", "a ::= (b", "@pass\na ::= b", "a ::= #x",
    ])
    func refusesTextNotInTheNotation(text: String) {
        #expect(throws: NotationError.self) { try Grammar(notation: text) }
    }

    @Test func readsAnExpressionOverSeveralLines() throws {
        let grammar = try Grammar(notation: """
            /* numbered, as XML 1.0 writes them */
            [1] a ::= b
                    | c /* a comment */ d
            [2] b ::= #x41 | [^#x22\\]
            @terminals
            c ::= "c"+
            d ::= b - c?
            """)
        #expect(grammar.productions.map(\.symbol) == ["a", "b", "c", "d"])
        #expect(grammar.productions.map(\.isTerminal) == [false, false, true, true])
        #expect(grammar["a"]?.expression == .choice([.symbol("b"), .sequence([.symbol("c"), .symbol("d")])]))
        #expect(grammar["b"]?.expression == .choice([.character(0x41), .characterClass(CharacterClass(isNegated: true, ranges: [0x22...0x22, 0x5C...0x5C]))]))
        #expect(grammar["d"]?.expression == .difference(.symbol("b"), .optional(.symbol("c"))))
    }
}
