/// What the next terminals tell a parser of the productions read over
/// terminals, and the check that they tell it enough.
///
/// The parser a translation writes reads a production by trying the
/// alternatives of each choice in turn and keeping the first that matches,
/// and by repeating an item for as long as it matches. That reads every
/// string of the grammar's language only when no such decision can take a
/// part the rest of the document then cannot follow. The check makes sure of
/// that from the grammar: at each choice, `?`, `*` and `+`, a match of the
/// part tried first and a match of what is tried after it must differ within
/// their first ``depth`` terminals, where what is tried after it is followed
/// by everything that can follow the decision (its FOLLOW set). An
/// alternative that can match nothing is tried after the others.
///
/// Two terminals decide the RDF 1.2 Turtle and N-Triples grammars.
/// N-Triples needs the second: `ntriplesDoc ::= statement? (EOL statement)*
/// EOL?` repeats `EOL statement` before a final `EOL`.
struct Lookahead {
    /// How many terminals a decision may look at.
    static let depth = 2

    /// A terminal, a string of the productions read over terminals, or the
    /// end of the document.
    enum Terminal: Hashable, CustomStringConvertible {
        case end
        case symbol(String)
        case string(String, caseInsensitive: Bool)

        var description: String {
            switch self {
            case .end: "the end of the document"
            case .symbol(let name): name
            case .string(let text, _): "'\(text)'"
            }
        }
    }

    /// The first ``depth`` terminals of the strings of a language; a string
    /// shorter than that is a whole string, or one that ends the document.
    typealias Prefixes = Set<[Terminal]>

    let productions: [String: Expression]
    let caseInsensitiveStrings: Expression.Quote?
    private(set) var first: [String: Prefixes] = [:]
    private(set) var follow: [String: Prefixes] = [:]

    /// The lookahead of `productions`, the productions read over terminals,
    /// by symbol.
    init(productions: [String: Expression], caseInsensitiveStrings: Expression.Quote?) {
        self.productions = productions
        self.caseInsensitiveStrings = caseInsensitiveStrings
        let symbols = productions.keys.sorted()
        for symbol in symbols { first[symbol] = [] }
        var changed = true
        while changed {
            changed = false
            for symbol in symbols {
                let starts = prefixes(of: productions[symbol]!)
                if starts != first[symbol] {
                    first[symbol] = starts
                    changed = true
                }
            }
        }
        // Each production can be read as a whole document.
        for symbol in symbols { follow[symbol] = [[.end]] }
        changed = true
        while changed {
            changed = false
            var found: [(symbol: String, after: Prefixes)] = []
            for symbol in symbols {
                visit(productions[symbol]!, followedBy: follow[symbol]!) { expression, after in
                    if case .symbol(let name) = expression, productions[name] != nil {
                        found.append((name, after))
                    }
                }
            }
            for (symbol, after) in found where !after.isSubset(of: follow[symbol]!) {
                follow[symbol]!.formUnion(after)
                changed = true
            }
        }
    }

    /// Whether `expression` can match no terminals.
    func isNullable(_ expression: Expression) -> Bool {
        prefixes(of: expression).contains([])
    }

    /// The alternatives of a choice in the order the parser tries them:
    /// those that can match nothing last.
    func order(_ options: [Expression]) -> [Int] {
        let nullable = options.map(isNullable)
        return options.indices.filter { !nullable[$0] } + options.indices.filter { nullable[$0] }
    }

    /// Checks every decision of the productions.
    ///
    /// - Throws: ``TranslationError`` naming the first decision that the
    ///   next ``depth`` terminals do not decide.
    func check() throws(TranslationError) {
        var conflict: TranslationError?
        for symbol in productions.keys.sorted() {
            visit(productions[symbol]!, followedBy: follow[symbol]!) { expression, after in
                guard conflict == nil else { return }
                conflict = self.conflict(in: expression, followedBy: after).map {
                    TranslationError("'\(symbol)' cannot be read by its next \(Self.depth) terminals: in `\(expression.notation)`, \($0)")
                }
            }
            if let conflict { throw conflict }
        }
    }

    // MARK: - Prefixes

    func prefixes(of expression: Expression) -> Prefixes {
        switch expression {
        case .symbol(let name):
            if productions[name] != nil { return first[name] ?? [] }
            return [[.symbol(name)]]
        case .string(let text, let quote):
            return text.isEmpty ? [[]] : [[.string(text, caseInsensitive: quote == caseInsensitiveStrings)]]
        case .character, .characterClass, .difference:
            // Not read over terminals; refused before the lookahead.
            return []
        case .sequence(let items):
            return items.reduce([[]]) { Self.concatenate($0, prefixes(of: $1)) }
        case .choice(let options):
            return options.reduce([]) { $0.union(prefixes(of: $1)) }
        case .optional(let item):
            return prefixes(of: item).union([[]])
        case .zeroOrMore(let item):
            return repeated(prefixes(of: item))
        case .oneOrMore(let item):
            let once = prefixes(of: item)
            return Self.concatenate(once, repeated(once))
        }
    }

    /// The prefixes of any number of strings with the prefixes `item`.
    func repeated(_ item: Prefixes) -> Prefixes {
        var result: Prefixes = [[]]
        for _ in 0..<Self.depth {
            result = result.union(Self.concatenate(item, result))
        }
        return result
    }

    /// The prefixes of a string with the prefixes `left` followed by one
    /// with the prefixes `right`.
    static func concatenate(_ left: Prefixes, _ right: Prefixes) -> Prefixes {
        var result: Prefixes = []
        for prefix in left {
            if prefix.count >= depth || prefix.last == .end {
                result.insert(prefix)
                continue
            }
            for next in right {
                result.insert(Array((prefix + next).prefix(depth)))
            }
        }
        return result
    }

    // MARK: - Decisions

    /// Calls `body` with each expression in `expression`, outermost first,
    /// and the prefixes of what can follow it.
    func visit(_ expression: Expression, followedBy after: Prefixes, _ body: (Expression, Prefixes) -> Void) {
        body(expression, after)
        switch expression {
        case .symbol, .string, .character, .characterClass, .difference:
            return
        case .sequence(let items):
            var following = after
            var contexts: [Prefixes] = []
            for item in items.reversed() {
                contexts.append(following)
                following = Self.concatenate(prefixes(of: item), following)
            }
            for (item, context) in zip(items, contexts.reversed()) {
                visit(item, followedBy: context, body)
            }
        case .choice(let options):
            for option in options { visit(option, followedBy: after, body) }
        case .optional(let item):
            visit(item, followedBy: after, body)
        case .zeroOrMore(let item), .oneOrMore(let item):
            visit(item, followedBy: Self.concatenate(repeated(prefixes(of: item)), after), body)
        }
    }

    /// Why the parser's decision at `expression`, followed by what has the
    /// prefixes `after`, can take a part the rest cannot follow; `nil` when
    /// it cannot.
    func conflict(in expression: Expression, followedBy after: Prefixes) -> String? {
        switch expression {
        case .choice(let options):
            let order = order(options)
            for (position, earlier) in order.enumerated() {
                for later in order[(position + 1)...] {
                    let rest = Self.concatenate(prefixes(of: options[later]), after)
                    if let shared = Self.overlap(prefixes(of: options[earlier]), rest) {
                        return "\(Self.describe(shared)) can start both `\(options[earlier].notation)` and `\(options[later].notation)`"
                    }
                }
            }
            return nil
        case .optional(let item), .zeroOrMore(let item), .oneOrMore(let item):
            if let shared = Self.overlap(prefixes(of: item), after) {
                return "\(Self.describe(shared)) can start both `\(item.notation)` and what follows it"
            }
            return nil
        case .symbol, .string, .character, .characterClass, .sequence, .difference:
            return nil
        }
    }

    /// A prefix of `tried` that starts a prefix of `other`, or that one of
    /// `other` starts: the parser cannot tell the two apart by it.
    static func overlap(_ tried: Prefixes, _ other: Prefixes) -> [Terminal]? {
        for prefix in sorted(tried) {
            for candidate in sorted(other)
            where candidate.starts(with: prefix) || prefix.starts(with: candidate) {
                return prefix.count <= candidate.count ? prefix : candidate
            }
        }
        return nil
    }

    /// `prefixes` in a fixed order, so that a refusal names the same
    /// terminals on every translation.
    static func sorted(_ prefixes: Prefixes) -> [[Terminal]] {
        prefixes.sorted { $0.map(\.description).lexicographicallyPrecedes($1.map(\.description)) }
    }

    static func describe(_ terminals: [Terminal]) -> String {
        terminals.isEmpty ? "nothing" : terminals.map(\.description).joined(separator: " ")
    }
}
