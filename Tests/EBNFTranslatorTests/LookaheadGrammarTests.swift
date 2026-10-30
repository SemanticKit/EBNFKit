import Testing

/// A parser whose decisions need a second terminal, try an alternative that
/// matches nothing after the others, or try an alternative after one that
/// matches a prefix of the input (`Grammars/lookahead.ebnf`).
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

    /// `pair ::= (X Y | X) Z`: on "x z" the first alternative reads `X` and
    /// then fails on `Z`, so the parser goes back and reads the second,
    /// which the rest of the production can follow.
    @Test func triesTheNextAlternativeWhenTheFirstMatchesOnlyAPrefix() throws {
        guard case .x2 = try LookaheadGrammar.Pair.parse("x z").xOrX2 else {
            Issue.record("expected the alternative X")
            return
        }
        guard case .x = try LookaheadGrammar.Pair.parse("x y z").xOrX2 else {
            Issue.record("expected the alternative X Y")
            return
        }
    }
}
