import Testing

/// A terminal that refers to itself, matched without an automaton, and a
/// difference (`Grammars/nested.ebnf`).
@Suite struct NestedGrammarTests {
    @Test(arguments: [("()", true), ("(()())", true), ("(()", false), (")(", false), ("", false)])
    func matchesARecursiveTerminal(text: String, matches: Bool) {
        #expect(NestedGrammar.Group.matches(text) == matches)
    }

    @Test func givesTheMatchesOfARecursiveTerminal() throws {
        let group = try #require(NestedGrammar.Group(parsing: "(()(()))"))
        #expect(group.groups.map(\.text) == ["()", "(())"])
        #expect(group.groups[1].groups.map(\.text) == ["()"])
    }

    @Test(arguments: [("word", true), ("no", false), ("on", false), ("nope", true), ("", false)])
    func matchesADifference(text: String, matches: Bool) {
        #expect(NestedGrammar.Word.matches(text) == matches)
        #expect(NestedGrammar.Word.longestMatch(in: Array(text.unicodeScalars), at: 0) == (matches ? text.unicodeScalars.count : (text.isEmpty ? nil : text.unicodeScalars.count - 1)))
    }
}
