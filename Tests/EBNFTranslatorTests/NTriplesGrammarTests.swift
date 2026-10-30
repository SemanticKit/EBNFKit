import Testing

/// The parser translated from the RDF 1.2 N-Triples grammar as published
/// (`Grammars/ntriples.bnf`).
@Suite struct NTriplesGrammarTests {
    @Test func readsTriplesOnePerLine() throws {
        let document = try NTriplesGrammar.NtriplesDoc.parse("""
            <http://example/s> <http://example/p> "o"@en .
            # a comment line

            _:b <http://example/p> <<( <http://example/s> <http://example/p> "x"^^<http://example/t> )>> .

            """)
        let statements = [document.statement].compactMap { $0 } + document.eolAndStatements.map(\.statement)
        #expect(statements.count == 2)
    }

    @Test func requiresALineEndBetweenTriples() {
        #expect(throws: NTriplesGrammar.SyntaxError.self) {
            try NTriplesGrammar.NtriplesDoc.parse("<http://a/> <http://b/> <http://c/> . <http://a/> <http://b/> <http://c/> .")
        }
    }

    @Test func readsVersionWithCase() throws {
        _ = try NTriplesGrammar.NtriplesDoc.parse("VERSION \"1.2\"\n")
        #expect(throws: NTriplesGrammar.SyntaxError.self) {
            try NTriplesGrammar.NtriplesDoc.parse("version \"1.2\"\n")
        }
    }
}
