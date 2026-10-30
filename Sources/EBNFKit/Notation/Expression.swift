/// The right-hand side of a ``Production``: the expressions of the EBNF
/// notation of XML 1.0 §6.
public indirect enum Expression: Sendable, Hashable {
    /// `symbol`: the expression of the production that defines the symbol.
    case symbol(String)

    /// `'string'` or `"string"`: the literal string between the quotes,
    /// which has no escapes. The quote is kept because some specifications
    /// give it a meaning; RDF 1.2 Turtle §6.5 makes the keywords in
    /// quotation marks case-insensitive.
    case string(String, Quote)

    /// `#xN`: the character whose code point is the hexadecimal number N.
    case character(UInt32)

    /// `[a-zA-Z]`, `[#xN-#xN]`, `[^abc]` and their combinations.
    case characterClass(CharacterClass)

    /// `A B`: A followed by B.
    case sequence([Expression])

    /// `A | B`: A or B.
    case choice([Expression])

    /// `A?`: A or nothing.
    case optional(Expression)

    /// `A*`: zero or more occurrences of A.
    case zeroOrMore(Expression)

    /// `A+`: one or more occurrences of A.
    case oneOrMore(Expression)

    /// `A - B`: any string that matches A but does not match B.
    case difference(Expression, Expression)

    /// The quote a string is written between.
    public enum Quote: String, Sendable, Hashable, Codable {
        /// `'`
        case apostrophe
        /// `"`
        case quotationMark
    }

    /// The symbols the expression refers to, in the order they first
    /// appear.
    public var symbols: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        func visit(_ expression: Expression) {
            switch expression {
            case .symbol(let name):
                if seen.insert(name).inserted { result.append(name) }
            case .string, .character, .characterClass:
                break
            case .sequence(let items), .choice(let items):
                items.forEach(visit)
            case .optional(let item), .zeroOrMore(let item), .oneOrMore(let item):
                visit(item)
            case .difference(let left, let right):
                visit(left)
                visit(right)
            }
        }
        visit(self)
        return result
    }
}
