import Testing

/// A parser whose decisions need a second terminal, or try an alternative
/// that matches nothing after the others (`Grammars/lookahead.ebnf`).
@Suite struct LookaheadGrammarTests {
    @Test func repeatsAnItemThatStartsWithTheTerminalAfterIt() throws {
        let document = try LookaheadGrammar.Doc.parse("x z\ny z\nz\n")
        #expect(document.line != nil)
        #expect(document.eolAndLines.count == 2)
        #expect(document.eol != nil)
    }

    @Test func triesTheAlternativeThatMatchesNothingLast() throws {
        guard case .y = try LookaheadGrammar.Line.parse("y z").xOrY else {
            Issue.record("expected the alternative Y")
            return
        }
        guard case .x(nil) = try LookaheadGrammar.Line.parse("z").xOrY else {
            Issue.record("expected the alternative that matches nothing")
            return
        }
    }
}
