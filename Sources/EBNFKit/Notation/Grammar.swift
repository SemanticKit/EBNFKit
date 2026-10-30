/// A grammar written in the EBNF notation of XML 1.0 §6, the notation the
/// W3C specifications use: a list of productions `symbol ::= expression`.
///
/// The W3C RDF grammars (RDF 1.2 Turtle §6.5, N-Triples §5.3, N-Quads,
/// TriG) publish their productions as text files in this notation, with an
/// `@terminals` line before the productions whose names are in capitals:
/// those productions are the terminals a tokenizer recognizes, and the
/// productions before the line are read over those terminals.
///
///     let grammar = try Grammar(notation: """
///         greeting ::= 'hello' NAME
///         @terminals
///         NAME     ::= [a-z]+
///         """)
public struct Grammar: Sendable, Hashable {
    /// The productions, in the order the grammar writes them.
    public var productions: [Production]

    /// Creates a grammar from its productions.
    public init(productions: [Production]) {
        self.productions = productions
    }

    /// The production that defines `symbol`. When a grammar defines a
    /// symbol twice, the first definition is the one used.
    public subscript(symbol: String) -> Production? {
        productions.first { $0.symbol == symbol }
    }

    /// Whether the grammar has an `@terminals` section, so that some of its
    /// productions are read over terminals rather than characters.
    public var hasTerminals: Bool {
        productions.contains { $0.isTerminal }
    }
}
