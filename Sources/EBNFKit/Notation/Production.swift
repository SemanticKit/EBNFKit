/// One production of a ``Grammar``: `symbol ::= expression` (XML 1.0 §6).
public struct Production: Sendable, Hashable {
    /// The symbol the production defines, as written: symbols are
    /// case-sensitive.
    public var symbol: String

    /// The expression the symbol matches.
    public var expression: Expression

    /// Whether the production comes after the grammar's `@terminals` line:
    /// a terminal is matched over characters, by the longest match, and the
    /// productions before the line are matched over terminals.
    public var isTerminal: Bool

    /// Creates a production.
    public init(symbol: String, expression: Expression, isTerminal: Bool = false) {
        self.symbol = symbol
        self.expression = expression
        self.isTerminal = isTerminal
    }
}
