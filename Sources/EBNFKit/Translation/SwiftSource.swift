/// The Swift translation of a ``Grammar``: a parser that reads the grammar's
/// language into a typed syntax tree, one Swift type per production.
///
/// The translation is deterministic: the same grammar and configuration
/// always give the same text. Everything it declares is in the namespace
/// `<name>Grammar`:
///
/// - Each terminal production (one after `@terminals`, or every production
///   of a grammar without that line) becomes a struct holding the text it
///   matched and where the text starts. Its static `matches(_:)` and
///   `longestMatch(in:at:)` match the production over characters, with the
///   minimal deterministic automaton of its expression when the expression
///   is regular (``Automaton``) and by following every position the
///   expression can reach when it refers back to itself; its
///   `init?(parsing:)` reads a whole string as the production, and it has a
///   member for each production its expression refers to, holding the
///   parts of its text those productions matched.
/// - In a grammar with terminals, the productions before `@terminals` are
///   read over terminals. A tokenizer takes, at each position, the longest
///   terminal or string of those productions (RDF 1.2 Turtle §6.5: "When
///   tokenizing the input and choosing grammar rules, the longest match is
///   chosen"); a production whose expression is a choice becomes an enum
///   with a case for each alternative, and any other production a class
///   with a member for each part of its expression that holds something.
///   Each has a static `parse(_:)`.
///
/// What a specification states in prose rather than EBNF stays with the
/// code that uses the translation. Before each terminal the tokenizer skips
/// what `<name>Grammar.trivia(_:from:)` returns, a function the code using
/// a grammar with terminals declares: white space and comments, as each
/// specification defines them.
public struct SwiftSource: Sendable, Hashable {
    /// The Swift source text.
    public let text: String

    /// Translates `grammar`.
    ///
    /// - Throws: ``TranslationError`` when a symbol is not defined, a
    ///   production that is read over terminals uses a character class or
    ///   `-`, a terminal refers to a production read over terminals, or two
    ///   symbols would have the same Swift name.
    public init(grammar: Grammar, configuration: GrammarConfiguration) throws(TranslationError) {
        var translation = try Translation(grammar: grammar, configuration: configuration)
        text = try translation.render()
    }
}

/// The state of one translation.
private struct Translation {
    let configuration: GrammarConfiguration
    let namespace: String
    /// The productions translated, in grammar order.
    let productions: [Production]
    let bySymbol: [String: Production]
    /// The symbols read over terminals.
    let tokenLevel: Set<String>
    /// The terminals the tokenizer recognizes, in grammar order.
    let lexerTerminals: [String]
    /// The strings the tokenizer recognizes, in order of first appearance.
    let literals: [Literal]

    struct Literal: Hashable {
        var text: String
        var caseInsensitive: Bool
    }

    /// What one expression of a production read over terminals holds.
    struct Part {
        /// Its Swift type.
        var type: String
        /// The member name it is held under.
        var name: String
        /// The labels and types of its parts, when it is a tuple.
        var fields: [(name: String, type: String)]?
    }

    /// A parsing method, and what it returns besides failure.
    struct Compiled {
        var method: String
        var part: Part?
    }

    /// The first characters of each production matched over characters.
    let firstCharacters: [String: FirstCharacters]

    var parserMethods: [String] = []
    var nested: [String: [String]] = [:]
    var nestedNames: [String: Set<String>] = [:]
    var methodCounter = 0

    static let reserved: Set<String> = ["Location", "SyntaxError", "Token", "Kind", "Lexer", "Parser", "Step", "Trace", "Symbol"]

    init(grammar: Grammar, configuration: GrammarConfiguration) throws(TranslationError) {
        self.configuration = configuration
        namespace = configuration.name + "Grammar"

        var bySymbol: [String: Production] = [:]
        for production in grammar.productions where bySymbol[production.symbol] == nil {
            bySymbol[production.symbol] = production
        }
        self.bySymbol = bySymbol

        // The productions translated: the roots and what they refer to.
        var selected: Set<String> = []
        var pending = configuration.roots ?? grammar.productions.map(\.symbol)
        while let symbol = pending.popLast() {
            guard selected.insert(symbol).inserted else { continue }
            guard let production = bySymbol[symbol] else {
                throw TranslationError("'\(symbol)' is used but not defined")
            }
            pending.append(contentsOf: production.expression.symbols)
        }
        var seen: Set<String> = []
        productions = grammar.productions.filter { selected.contains($0.symbol) && seen.insert($0.symbol).inserted }

        let tokenLevel = Set(productions.filter { !$0.isTerminal && grammar.hasTerminals }.map(\.symbol))
        self.tokenLevel = tokenLevel

        var typeNames: [String: String] = [:]
        for production in productions {
            let name = SwiftName.type(production.symbol)
            if Self.reserved.contains(name) {
                throw TranslationError("'\(production.symbol)' would be named \(name), which the translation uses")
            }
            if let other = typeNames.updateValue(production.symbol, forKey: name.lowercased()) {
                throw TranslationError("'\(other)' and '\(production.symbol)' would have the same Swift name")
            }
        }

        var terminals: Set<String> = []
        var literals: [Literal] = []
        for production in productions {
            if tokenLevel.contains(production.symbol) {
                try Self.checkTokenLevel(production.expression, in: production.symbol, tokenLevel: tokenLevel)
                for symbol in production.expression.symbols where !tokenLevel.contains(symbol) {
                    terminals.insert(symbol)
                }
                Self.collectLiterals(production.expression, caseInsensitive: configuration.caseInsensitiveStrings, into: &literals)
            } else {
                for symbol in production.expression.symbols where tokenLevel.contains(symbol) {
                    throw TranslationError("the terminal '\(production.symbol)' refers to '\(symbol)', which is read over terminals")
                }
            }
        }
        lexerTerminals = productions.map(\.symbol).filter { terminals.contains($0) }
        self.literals = literals
        firstCharacters = FirstCharacters.of(productions.filter { !tokenLevel.contains($0.symbol) }, bySymbol: bySymbol)
    }

    static func checkTokenLevel(_ expression: Expression, in symbol: String, tokenLevel: Set<String>) throws(TranslationError) {
        switch expression {
        case .symbol, .string:
            return
        case .character, .characterClass:
            throw TranslationError("'\(symbol)' is read over terminals but matches a character: \(expression.notation)")
        case .difference:
            throw TranslationError("'\(symbol)' is read over terminals but uses '-': \(expression.notation)")
        case .sequence(let items), .choice(let items):
            for item in items { try checkTokenLevel(item, in: symbol, tokenLevel: tokenLevel) }
        case .optional(let item), .zeroOrMore(let item), .oneOrMore(let item):
            try checkTokenLevel(item, in: symbol, tokenLevel: tokenLevel)
        }
    }

    static func collectLiterals(_ expression: Expression, caseInsensitive: Expression.Quote?, into literals: inout [Literal]) {
        switch expression {
        case .string(let text, let quote):
            let literal = Literal(text: text, caseInsensitive: quote == caseInsensitive)
            if !literals.contains(literal) { literals.append(literal) }
        case .symbol, .character, .characterClass:
            return
        case .sequence(let items), .choice(let items):
            for item in items { collectLiterals(item, caseInsensitive: caseInsensitive, into: &literals) }
        case .optional(let item), .zeroOrMore(let item), .oneOrMore(let item):
            collectLiterals(item, caseInsensitive: caseInsensitive, into: &literals)
        case .difference(let left, let right):
            collectLiterals(left, caseInsensitive: caseInsensitive, into: &literals)
            collectLiterals(right, caseInsensitive: caseInsensitive, into: &literals)
        }
    }

    // MARK: - Rendering

    mutating func render() throws(TranslationError) -> String {
        var out: [String] = []
        out.append("// The Swift translation of the \(configuration.name) grammar, written by")
        out.append("// EBNFTranslator from the EBNF of:")
        for document in configuration.documents {
            out.append("//   \(document.url)")
            out.append("//     retrieved \(document.retrieved), SHA-256 \(document.sha256)")
        }
        out.append("// Do not edit it: it is translated again from the grammar on every build.")
        out.append("")
        out.append("/// The \(configuration.name) grammar: one type for each of its productions.")
        out.append("enum \(namespace) {}")
        out.append("")
        out.append(contentsOf: supportDeclarations())

        for production in productions where !tokenLevel.contains(production.symbol) {
            out.append("")
            out.append(contentsOf: try terminalDeclaration(production))
        }

        guard !tokenLevel.isEmpty else { return out.joined(separator: "\n") + "\n" }

        var nodeDeclarations: [String] = []
        for production in productions where tokenLevel.contains(production.symbol) {
            nodeDeclarations.append(contentsOf: try nodeDeclaration(production))
        }
        out.append("")
        out.append(contentsOf: tokenDeclarations())
        out.append(contentsOf: nodeDeclarations)
        for owner in nested.keys.sorted() {
            out.append("")
            out.append("extension \(namespace).\(owner) {")
            out.append(contentsOf: nested[owner, default: []])
            out.append("}")
        }
        out.append("")
        out.append(contentsOf: parserDeclaration())
        return out.joined(separator: "\n") + "\n"
    }

    func supportDeclarations() -> [String] {
        let symbols = productions.filter { !tokenLevel.contains($0.symbol) }.map { SwiftName.type($0.symbol) }
        return """
        extension \(namespace) {
            /// A position in a document: the offset in Unicode scalars, and
            /// the 1-based line and column, in Unicode scalars, a line ending
            /// at each line feed.
            struct Location: Swift.Sendable, Swift.Hashable {
                let offset: Swift.Int
                let line: Swift.Int
                let column: Swift.Int

                /// The start of a document.
                static let start = Location(offset: 0, line: 1, column: 1)

                /// The position after `scalars`, which start here.
                func advanced(over scalars: Swift.ArraySlice<Swift.Unicode.Scalar>) -> Location {
                    var line = line
                    var column = column
                    for scalar in scalars {
                        if scalar == "\\n" {
                            line += 1
                            column = 1
                        } else {
                            column += 1
                        }
                    }
                    return Location(offset: offset + scalars.count, line: line, column: column)
                }
            }

            /// A document that does not match the grammar.
            struct SyntaxError: Swift.Error, Swift.Sendable, Swift.Hashable {
                /// Where the document stops matching.
                let location: Location
                /// What the grammar expected there.
                let message: Swift.String
            }

            /// The productions matched over characters.
            enum Symbol: Swift.Sendable, Swift.Hashable {
                \(symbols.isEmpty ? "" : "case " + symbols.joined(separator: ", "))
            }

            /// One way a production can match: where it ends, and the
            /// productions its expression refers to that it matched on the way.
            struct Step: Swift.Sendable {
                let end: Swift.Int
                let trace: Trace?

                /// `ends` without a second copy of an end.
                static func uniqueEnds(_ ends: [Swift.Int]) -> [Swift.Int] {
                    guard ends.count > 1 else { return ends }
                    var seen = Swift.Set<Swift.Int>()
                    return ends.filter { seen.insert($0).inserted }
                }

                /// `steps` without a second step to the same end.
                static func unique(_ steps: [Step]) -> [Step] {
                    guard steps.count > 1 else { return steps }
                    var ends = Swift.Set<Swift.Int>()
                    return steps.filter { ends.insert($0.end).inserted }
                }

                /// Whether `scalars` has `literal` at `offset`.
                static func has(_ scalars: [Swift.Unicode.Scalar], _ offset: Swift.Int, _ literal: [Swift.UInt32]) -> Swift.Bool {
                    guard offset + literal.count <= scalars.count else { return false }
                    for (index, value) in literal.enumerated() where scalars[offset + index].value != value {
                        return false
                    }
                    return true
                }
            }

            /// The matches of referred productions on the way to a step, the
            /// last first.
            final class Trace: Swift.Sendable {
                let symbol: Symbol
                let start: Swift.Int
                let end: Swift.Int
                let previous: Trace?

                init(_ symbol: Symbol, _ start: Swift.Int, _ end: Swift.Int, _ previous: Trace?) {
                    self.symbol = symbol
                    self.start = start
                    self.end = end
                    self.previous = previous
                }

                /// The text and location of each match of `symbol` in
                /// `scalars`, which start at `location`, in document order.
                func parts(_ symbol: Symbol, in scalars: [Swift.Unicode.Scalar], at location: Location) -> [(text: Swift.String, location: Location)] {
                    var matches: [Trace] = []
                    var trace: Trace? = self
                    while let current = trace {
                        if current.symbol == symbol { matches.append(current) }
                        trace = current.previous
                    }
                    return matches.reversed().map {
                        (Swift.String(Swift.String.UnicodeScalarView(scalars[$0.start..<$0.end])), location.advanced(over: scalars[0..<$0.start]))
                    }
                }
            }
        }
        """.components(separatedBy: "\n")
    }

    // MARK: - Terminals

    func terminalDeclaration(_ production: Production) throws(TranslationError) -> [String] {
        let type = SwiftName.type(production.symbol)
        var emitter = MatcherEmitter(bySymbol: bySymbol, firstCharacters: firstCharacters)
        // A regular production is matched by its automaton; one that refers
        // back to itself, by following the positions its expression reaches.
        let endsBody: [String]
        if let automaton = Automaton(production.expression, bySymbol: bySymbol) {
            endsBody = Self.automatonBody(automaton)
        } else {
            endsBody = try emitter.function(for: production.expression, mode: .ends)
        }
        let direct = Self.directSymbols(production.expression)
        let stepsBody = direct.isEmpty ? [] : try emitter.function(for: production.expression, mode: .steps)
        var lines: [String] = []
        lines.append("extension \(namespace) {")
        lines.append("    /// `\(production.symbol) ::= \(production.expression.notation)`")
        lines.append("    struct \(type): Swift.Sendable, Swift.Hashable {")
        lines.append("        /// The text the production matched.")
        lines.append("        let text: Swift.String")
        lines.append("        /// Where the text starts.")
        lines.append("        let location: Location")
        lines.append("")
        lines.append("        init(text: Swift.String, location: Location) {")
        lines.append("            self.text = text")
        lines.append("            self.location = location")
        lines.append("        }")
        lines.append("")
        lines.append("        /// `text` as a match of the production, when all of it matches.")
        lines.append("        init?(parsing text: Swift.String) {")
        lines.append("            guard Self.matches(text) else { return nil }")
        lines.append("            self.init(text: text, location: .start)")
        lines.append("        }")
        lines.append("")
        lines.append("        /// Whether all of `text` matches the production.")
        lines.append("        static func matches(_ text: Swift.String) -> Swift.Bool {")
        lines.append("            let scalars = Swift.Array(text.unicodeScalars)")
        lines.append("            return ends(scalars, 0).contains(scalars.count)")
        lines.append("        }")
        lines.append("")
        let first = firstCharacters[production.symbol] ?? .unknown
        lines.append("        /// Whether a match of the production can start with the character")
        lines.append("        /// `value`.")
        lines.append("        static func starts(_ value: Swift.UInt32) -> Swift.Bool {")
        if first.isUnbounded {
            lines.append("            true")
        } else {
            let positive = first.classes.filter { !$0.isNegated }.flatMap(\.ranges)
            let negative = first.classes.filter(\.isNegated)
            var tests: [String] = []
            if !positive.isEmpty {
                tests.append("{ switch value { case \(positive.map(Self.range).joined(separator: ", ")): return true; default: return false } }()")
            }
            for characterClass in negative {
                tests.append("{ switch value { case \(characterClass.ranges.map(Self.range).joined(separator: ", ")): return false; default: return true } }()")
            }
            lines.append("            " + (tests.isEmpty ? "false" : tests.joined(separator: " || ")))
        }
        lines.append("        }")
        lines.append("")
        lines.append("        /// The end of the longest match of the production at `offset`.")
        lines.append("        static func longestMatch(in scalars: [Swift.Unicode.Scalar], at offset: Swift.Int) -> Swift.Int? {")
        lines.append("            ends(scalars, offset).max()")
        lines.append("        }")

        if !direct.isEmpty {
            lines.append("")
            lines.append("        /// The trace of the productions the text matched on the way.")
            lines.append("        private var trace: Trace? {")
            lines.append("            let scalars = Swift.Array(text.unicodeScalars)")
            lines.append("            return Self.match(scalars, 0).first { $0.end == scalars.count }?.trace")
            lines.append("        }")
            for symbol in direct {
                let count = Self.occurrences(of: symbol, in: production.expression)
                guard count.max > 0 else { continue }
                let part = SwiftName.type(symbol)
                lines.append("")
                let member: String
                let returnType: String
                let expression: String
                let all = "(trace?.parts(.\(part), in: Swift.Array(text.unicodeScalars), at: location) ?? []).map { \(part)(text: $0.text, location: $0.location) }"
                if count.max == 1 && count.min == 1 {
                    member = SwiftName.member(symbol)
                    returnType = part
                    expression = "\(all)[0]"
                    lines.append("        /// The `\(symbol)` the text holds.")
                } else if count.max == 1 {
                    member = SwiftName.member(symbol)
                    returnType = part + "?"
                    expression = "\(all).first"
                    lines.append("        /// The `\(symbol)` the text holds, if any.")
                } else {
                    member = SwiftName.plural(SwiftName.member(symbol))
                    returnType = "[\(part)]"
                    expression = all
                    lines.append("        /// The `\(symbol)`s the text holds, in order.")
                }
                lines.append("        var \(member): \(returnType) {")
                if count.min == 0, firstCharacters[symbol]?.mustAlwaysTry == false {
                    // No character of the text can start one: none is there.
                    lines.append("            guard text.unicodeScalars.contains(where: { \(part).starts($0.value) }) else { return \(count.max == 1 ? "nil" : "[]") }")
                    lines.append("            return \(expression)")
                } else {
                    lines.append("            \(expression)")
                }
                lines.append("        }")
            }
        }
        lines.append("")
        lines.append("        /// The ends of the matches of the production from `offset`.")
        lines.append("        static func ends(_ s: [Swift.Unicode.Scalar], _ offset: Swift.Int) -> [Swift.Int] {")
        lines.append(contentsOf: endsBody.map { "            " + $0 })
        lines.append("        }")
        if !stepsBody.isEmpty {
            lines.append("")
            lines.append("        /// The matches of the production from `offset`, each with where the")
            lines.append("        /// productions it refers to matched on the way.")
            lines.append("        static func match(_ s: [Swift.Unicode.Scalar], _ offset: Swift.Int) -> [Step] {")
            lines.append(contentsOf: stepsBody.map { "            " + $0 })
            lines.append("        }")
        }
        for (index, string) in emitter.strings.enumerated() {
            lines.append("")
            lines.append("        static let string\(index): [Swift.UInt32] = [\(string.map(Self.hex).joined(separator: ", "))]")
        }
        for (index, characterClass) in emitter.classes.enumerated() {
            lines.append("")
            lines.append("        /// `\(Expression.characterClass(characterClass).notation)`")
            lines.append("        static func class\(index)(_ value: Swift.UInt32) -> Swift.Bool {")
            let ranges = characterClass.ranges.map { range in
                range.lowerBound == range.upperBound ? Self.hex(range.lowerBound) : Self.hex(range.lowerBound) + "..." + Self.hex(range.upperBound)
            }
            lines.append("            switch value {")
            lines.append("            case \(ranges.joined(separator: ", ")): return \(!characterClass.isNegated)")
            lines.append("            default: return \(characterClass.isNegated)")
            lines.append("            }")
            lines.append("        }")
        }
        lines.append("    }")
        lines.append("}")
        return lines
    }

    /// The body of `ends(_:_:)` for a production matched by `automaton`:
    /// it reads the characters from `offset` and records each position where
    /// the automaton accepts.
    static func automatonBody(_ automaton: Automaton) -> [String] {
        var lines = ["var ends: [Swift.Int] = []", "var state = 0", "var index = offset", "while true {"]
        let accepting = automaton.accepting.indices.filter { automaton.accepting[$0] }
        if !accepting.isEmpty {
            lines.append("    switch state {")
            lines.append("    case \(accepting.map(String.init).joined(separator: ", ")): ends.append(index)")
            lines.append("    default: break")
            lines.append("    }")
        }
        lines.append("    guard index < s.count else { return ends }")
        lines.append("    let value = s[index].value")
        lines.append("    switch state {")
        for (state, row) in automaton.transitions.enumerated() where !row.isEmpty {
            lines.append("    case \(state):")
            lines.append("        switch value {")
            var targets: [Int] = []
            for transition in row where !targets.contains(transition.target) { targets.append(transition.target) }
            for target in targets {
                let ranges = row.filter { $0.target == target }.map { range($0.range) }
                lines.append("        case \(ranges.joined(separator: ", ")): state = \(target)")
            }
            lines.append("        default: return ends")
            lines.append("        }")
        }
        lines.append("    default: return ends")
        lines.append("    }")
        lines.append("    index += 1")
        lines.append("}")
        return lines
    }

    static func range(_ range: ClosedRange<UInt32>) -> String {
        range.lowerBound == range.upperBound ? hex(range.lowerBound) : hex(range.lowerBound) + "..." + hex(range.upperBound)
    }

    static func hex(_ value: UInt32) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    /// The symbols an expression refers to outside the right side of a
    /// `-`: the parts a match records.
    static func directSymbols(_ expression: Expression) -> [String] {
        var result: [String] = []
        func visit(_ expression: Expression) {
            switch expression {
            case .symbol(let name):
                if !result.contains(name) { result.append(name) }
            case .string, .character, .characterClass:
                break
            case .sequence(let items), .choice(let items):
                items.forEach(visit)
            case .optional(let item), .zeroOrMore(let item), .oneOrMore(let item):
                visit(item)
            case .difference(let left, _):
                visit(left)
            }
        }
        visit(expression)
        return result
    }

    /// How many times a match of `expression` holds a match of `symbol`:
    /// at least `min`, at most `max`, where 2 stands for more than one.
    static func occurrences(of symbol: String, in expression: Expression) -> (min: Int, max: Int) {
        switch expression {
        case .symbol(let name):
            return name == symbol ? (1, 1) : (0, 0)
        case .string, .character, .characterClass:
            return (0, 0)
        case .sequence(let items):
            return items.map { occurrences(of: symbol, in: $0) }.reduce((0, 0)) { (min($0.0 + $1.0, 2), min($0.1 + $1.1, 2)) }
        case .choice(let options):
            let counts = options.map { occurrences(of: symbol, in: $0) }
            return (counts.map(\.min).min() ?? 0, counts.map(\.max).max() ?? 0)
        case .optional(let item):
            return (0, occurrences(of: symbol, in: item).max)
        case .zeroOrMore(let item):
            return (0, occurrences(of: symbol, in: item).max > 0 ? 2 : 0)
        case .oneOrMore(let item):
            let count = occurrences(of: symbol, in: item)
            return (count.min, count.max > 0 ? 2 : 0)
        case .difference(let left, _):
            return occurrences(of: symbol, in: left)
        }
    }

    // MARK: - Tokens

    func tokenDeclarations() -> [String] {
        var lines: [String] = []
        lines.append("extension \(namespace) {")
        lines.append("    /// A terminal or string of the productions read over terminals.")
        lines.append("    enum Kind: Swift.Sendable, Swift.Hashable {")
        if !lexerTerminals.isEmpty {
            lines.append("        case \(lexerTerminals.map(SwiftName.type).joined(separator: ", "))")
        }
        lines.append("        /// The string at this index of `Lexer.literals`.")
        lines.append("        case literal(Swift.Int)")
        lines.append("    }")
        lines.append("")
        lines.append("    /// A terminal or string read from a document.")
        lines.append("    struct Token: Swift.Sendable {")
        lines.append("        let kind: Kind")
        lines.append("        let text: Swift.String")
        lines.append("        let location: Location")
        lines.append("    }")
        lines.append("")
        lines.append("    /// Splits a document into tokens, the longest match at each")
        lines.append("    /// position, after what `\(namespace).trivia(_:from:)` skips.")
        lines.append("    enum Lexer {")
        lines.append("        /// The strings of the productions read over terminals, with")
        lines.append("        /// whether each matches without regard to case.")
        lines.append("        static let literals: [(text: Swift.String, scalars: [Swift.UInt32], caseInsensitive: Swift.Bool)] = [")
        for literal in literals {
            let scalars = literal.text.unicodeScalars.map { Self.hex($0.value) }.joined(separator: ", ")
            lines.append("            (\(Self.stringLiteral(literal.text)), [\(scalars)], \(literal.caseInsensitive)),")
        }
        lines.append("        ]")
        lines.append("")
        lines.append("        static func tokens(in s: [Swift.Unicode.Scalar]) throws(SyntaxError) -> (tokens: [Token], end: Location) {")
        lines.append("            var tokens: [Token] = []")
        lines.append("            var offset = 0")
        lines.append("            var location = Location.start")
        lines.append("            while true {")
        lines.append("                let next = \(namespace).trivia(s, from: offset)")
        lines.append("                location = location.advanced(over: s[offset..<next])")
        lines.append("                offset = next")
        lines.append("                guard offset < s.count else { return (tokens, location) }")
        lines.append("                var end = offset")
        lines.append("                var kind: Kind?")
        lines.append("                for (index, literal) in literals.enumerated() where offset + literal.scalars.count > end && has(s, offset, literal.scalars, literal.caseInsensitive) {")
        lines.append("                    end = offset + literal.scalars.count")
        lines.append("                    kind = .literal(index)")
        lines.append("                }")
        for terminal in lexerTerminals {
            let type = SwiftName.type(terminal)
            let filter = firstCharacters[terminal]?.mustAlwaysTry == false ? "\(type).starts(s[offset].value), " : ""
            lines.append("                if \(filter)let match = \(type).longestMatch(in: s, at: offset), match > end {")
            lines.append("                    end = match")
            lines.append("                    kind = .\(type)")
            lines.append("                }")
        }
        lines.append("                guard let kind else {")
        lines.append("                    throw SyntaxError(location: location, message: \"unexpected character U+\" + Swift.String(s[offset].value, radix: 16, uppercase: true))")
        lines.append("                }")
        lines.append("                let text = Swift.String(Swift.String.UnicodeScalarView(s[offset..<end]))")
        lines.append("                tokens.append(Token(kind: kind, text: text, location: location))")
        lines.append("                location = location.advanced(over: s[offset..<end])")
        lines.append("                offset = end")
        lines.append("            }")
        lines.append("        }")
        lines.append("")
        lines.append("        /// Whether `scalars` has `literal` at `offset`.")
        lines.append("        static func has(_ scalars: [Swift.Unicode.Scalar], _ offset: Swift.Int, _ literal: [Swift.UInt32], _ caseInsensitive: Swift.Bool) -> Swift.Bool {")
        lines.append("            guard offset + literal.count <= scalars.count else { return false }")
        lines.append("            for (index, value) in literal.enumerated() where scalars[offset + index].value != value {")
        lines.append("                guard caseInsensitive, let expected = Swift.Unicode.Scalar(value),")
        lines.append("                      Swift.String(scalars[offset + index]).lowercased() == Swift.String(expected).lowercased() else { return false }")
        lines.append("            }")
        lines.append("            return true")
        lines.append("        }")
        lines.append("    }")
        lines.append("")
        lines.append("    /// Reads `text` as the production `read` reads.")
        lines.append("    static func parse<Node>(_ text: Swift.String, _ read: (inout Parser) -> Node?) throws(SyntaxError) -> Node {")
        lines.append("        let lexed = try Lexer.tokens(in: Swift.Array(text.unicodeScalars))")
        lines.append("        var parser = Parser(tokens: lexed.tokens, end: lexed.end)")
        lines.append("        if let node = read(&parser), parser.index == lexed.tokens.count { return node }")
        lines.append("        parser.expectEnd()")
        lines.append("        throw parser.failure()")
        lines.append("    }")
        lines.append("}")
        return lines
    }

    static func stringLiteral(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case " "..."~": result.unicodeScalars.append(scalar)
            default: result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }
        return result + "\""
    }

    // MARK: - Productions read over terminals

    mutating func nodeDeclaration(_ production: Production) throws(TranslationError) -> [String] {
        let type = SwiftName.type(production.symbol)
        var lines: [String] = [""]
        lines.append("extension \(namespace) {")
        lines.append("    /// `\(production.symbol) ::= \(production.expression.notation)`")
        if case .choice(let options) = production.expression {
            let cases = try compileCases(options, owner: type)
            lines.append("    indirect enum \(type): Swift.Sendable {")
            lines.append(contentsOf: cases.declarations.map { "        " + $0 })
            lines.append("    }")
            parserMethods.append(contentsOf: choiceMethod(name: "parse\(type)", type: type, cases: cases.compiled))
        } else {
            let items: [Expression]
            if case .sequence(let parts) = production.expression { items = parts } else { items = [production.expression] }
            var compiled: [Compiled] = []
            for item in items { compiled.append(try compile(item, owner: type)) }
            let fields = Self.uniqueNames(compiled.compactMap(\.part))
            lines.append("    final class \(type): Swift.Sendable {")
            for field in fields {
                lines.append("        let \(field.name): \(field.type)")
            }
            lines.append("")
            let parameters = fields.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
            lines.append("        init(\(parameters)) {")
            for field in fields {
                lines.append("            self.\(field.name) = \(field.name)")
            }
            lines.append("        }")
            lines.append("    }")
            parserMethods.append(contentsOf: sequenceMethod(name: "parse\(type)", type: type, items: compiled, fieldNames: fields.map(\.name), construct: { values in
                "\(type)(" + zip(fields, values).map { "\($0.name): \($1)" }.joined(separator: ", ") + ")"
            }))
        }
        lines.append("}")
        lines.append("")
        lines.append("extension \(namespace).\(type) {")
        lines.append("    /// Reads all of `text` as `\(production.symbol)`.")
        lines.append("    static func parse(_ text: Swift.String) throws(\(namespace).SyntaxError) -> \(namespace).\(type) {")
        lines.append("        try \(namespace).parse(text) { $0.parse\(type)() }")
        lines.append("    }")
        lines.append("}")
        return lines
    }

    /// Gives parts with the same name distinct names, in order.
    static func uniqueNames(_ parts: [Part]) -> [Part] {
        var used: [String: Int] = [:]
        return parts.map { part in
            var part = part
            let count = used[part.name, default: 0] + 1
            used[part.name] = count
            if count > 1 { part.name = SwiftName.escaped(SwiftName.unescaped(part.name) + String(count)) }
            return part
        }
    }

    mutating func nextMethod() -> String {
        methodCounter += 1
        return "read\(methodCounter)"
    }

    mutating func compile(_ expression: Expression, owner: String) throws(TranslationError) -> Compiled {
        switch expression {
        case .symbol(let symbol):
            let type = SwiftName.type(symbol)
            let part = Part(type: "\(namespace).\(type)", name: SwiftName.member(symbol))
            return Compiled(method: tokenLevel.contains(symbol) ? "parse\(type)" : "take\(type)", part: part)
        case .string(let text, let quote):
            let literal = Literal(text: text, caseInsensitive: quote == configuration.caseInsensitiveStrings)
            guard let index = literals.firstIndex(of: literal) else { throw TranslationError("internal: string \(text) not collected") }
            return Compiled(method: "takeLiteral\(index)", part: nil)
        case .sequence(let items):
            var compiled: [Compiled] = []
            for item in items { compiled.append(try compile(item, owner: owner)) }
            let parts = Self.uniqueNames(compiled.compactMap(\.part))
            let method = nextMethod()
            let part: Part?
            switch parts.count {
            case 0: part = nil
            case 1: part = parts[0]
            default:
                part = Part(
                    type: "(" + parts.map { "\($0.name): \($0.type)" }.joined(separator: ", ") + ")",
                    name: SwiftName.escaped(SwiftName.lowerCamel(SwiftName.compound(parts.map(\.name), separator: "And"))),
                    fields: parts.map { ($0.name, $0.type) }
                )
            }
            parserMethods.append(contentsOf: sequenceMethod(name: method, type: part?.type ?? "()", items: compiled, fieldNames: parts.map(\.name), construct: { values in
                switch values.count {
                case 0: "()"
                case 1: values[0]
                default: "(" + zip(parts, values).map { "\($0.name): \($1)" }.joined(separator: ", ") + ")"
                }
            }))
            return Compiled(method: method, part: part)
        case .choice(let options):
            let cases = try compileCases(options, owner: owner)
            var name = SwiftName.compound(cases.compiled.map(\.name), separator: "Or")
            if nestedNames[owner, default: []].contains(name) {
                var index = 2
                while nestedNames[owner, default: []].contains(name + String(index)) { index += 1 }
                name += String(index)
            }
            nestedNames[owner, default: []].insert(name)
            let qualified = "\(namespace).\(owner).\(name)"
            var declaration = ["", "    indirect enum \(name): Swift.Sendable {"]
            declaration.append(contentsOf: cases.declarations.map { "        " + $0 })
            declaration.append("    }")
            nested[owner, default: []].append(contentsOf: declaration)
            let method = nextMethod()
            parserMethods.append(contentsOf: choiceMethod(name: method, type: qualified, cases: cases.compiled))
            return Compiled(method: method, part: Part(type: qualified, name: SwiftName.member(SwiftName.lowerCamel(name))))
        case .optional(let item):
            let inner = try compile(item, owner: owner)
            let method = nextMethod()
            let part: Part
            var body: [String] = ["let start = index"]
            if let innerPart = inner.part {
                part = Part(type: innerPart.type.hasSuffix("?") ? innerPart.type : "\(innerPart.type)?", name: innerPart.name)
                body += ["if let value = \(inner.method)() { return .some(value) }", "index = start", "return .some(nil)"]
            } else {
                part = Part(type: "Swift.Bool", name: Self.wordName(item) ?? "isPresent")
                body += ["if \(inner.method)() != nil { return true }", "index = start", "return false"]
            }
            parserMethods.append(contentsOf: Self.method(method, returning: part.type, body: body))
            return Compiled(method: method, part: part)
        case .zeroOrMore(let item), .oneOrMore(let item):
            let inner = try compile(item, owner: owner)
            let method = nextMethod()
            let atLeastOne: Bool
            if case .oneOrMore = expression { atLeastOne = true } else { atLeastOne = false }
            let part: Part
            var body: [String]
            if let innerPart = inner.part {
                part = Part(type: "[\(innerPart.type)]", name: SwiftName.plural(innerPart.name))
                body = [
                    "var items: \(part.type) = []",
                    "while true {",
                    "    let start = index",
                    "    guard let item = \(inner.method)() else { index = start; break }",
                    "    if index == start { break }",
                    "    items.append(item)",
                    "}",
                ]
                if atLeastOne { body.append("if items.isEmpty { return nil }") }
                body.append("return items")
            } else {
                part = Part(type: "Swift.Int", name: (Self.wordName(item).map(SwiftName.unescaped) ?? "item") + "Count")
                body = [
                    "var count = 0",
                    "while true {",
                    "    let start = index",
                    "    guard \(inner.method)() != nil else { index = start; break }",
                    "    if index == start { break }",
                    "    count += 1",
                    "}",
                ]
                if atLeastOne { body.append("if count == 0 { return nil }") }
                body.append("return count")
            }
            parserMethods.append(contentsOf: Self.method(method, returning: part.type, body: body))
            return Compiled(method: method, part: part)
        case .character, .characterClass, .difference:
            throw TranslationError("internal: \(expression.notation) is read over terminals")
        }
    }

    static func wordName(_ expression: Expression) -> String? {
        if case .string(let text, _) = expression { return SwiftName.word(text) }
        return nil
    }

    struct Case {
        var name: String
        var compiled: Compiled
    }

    mutating func compileCases(_ options: [Expression], owner: String) throws(TranslationError) -> (declarations: [String], compiled: [Case]) {
        var cases: [Case] = []
        var used: Set<String> = []
        for (index, option) in options.enumerated() {
            let compiled = try compile(option, owner: owner)
            // An alternative is named after the first thing it holds.
            var name = compiled.part?.fields?.first?.name ?? compiled.part?.name ?? Self.wordName(option) ?? "alternative\(index + 1)"
            if used.contains(name) {
                var suffix = 2
                while used.contains(SwiftName.escaped(SwiftName.unescaped(name) + String(suffix))) { suffix += 1 }
                name = SwiftName.escaped(SwiftName.unescaped(name) + String(suffix))
            }
            used.insert(name)
            cases.append(Case(name: name, compiled: compiled))
        }
        let declarations = cases.map { item -> String in
            guard let part = item.compiled.part else { return "case \(item.name)" }
            if let fields = part.fields {
                return "case \(item.name)(" + fields.map { "\($0.name): \($0.type)" }.joined(separator: ", ") + ")"
            }
            return "case \(item.name)(\(part.type))"
        }
        return (declarations, cases)
    }

    func choiceMethod(name: String, type: String, cases: [Case]) -> [String] {
        var body = ["let start = index"]
        for item in cases {
            if let part = item.compiled.part {
                if let fields = part.fields {
                    let arguments = fields.map { "\($0.name): value.\($0.name)" }.joined(separator: ", ")
                    body.append("if let value = \(item.compiled.method)() { return .\(item.name)(\(arguments)) }")
                } else {
                    body.append("if let value = \(item.compiled.method)() { return .\(item.name)(value) }")
                }
            } else {
                body.append("if \(item.compiled.method)() != nil { return .\(item.name) }")
            }
            body.append("index = start")
        }
        body.append("return nil")
        return Self.method(name, returning: type, body: body)
    }

    func sequenceMethod(name: String, type: String, items: [Compiled], fieldNames: [String], construct: ([String]) -> String) -> [String] {
        var body = ["let start = index"]
        var values: [String] = []
        for (index, item) in items.enumerated() {
            if item.part != nil {
                body.append("guard let value\(index) = \(item.method)() else { index = start; return nil }")
                values.append("value\(index)")
            } else {
                body.append("guard \(item.method)() != nil else { index = start; return nil }")
            }
        }
        body.append("return " + construct(values))
        return Self.method(name, returning: type, body: body)
    }

    static func method(_ name: String, returning type: String, body: [String]) -> [String] {
        ["", "    mutating func \(name)() -> \(type)? {"] + body.map { "        " + $0 } + ["    }"]
    }

    func parserDeclaration() -> [String] {
        var lines: [String] = []
        lines.append("extension \(namespace) {")
        lines.append("    /// Reads tokens as the productions read over terminals, trying the")
        lines.append("    /// alternatives of a choice in order.")
        lines.append("    struct Parser {")
        lines.append("        let tokens: [Token]")
        lines.append("        let end: Location")
        lines.append("        var index = 0")
        lines.append("        var farthest = 0")
        lines.append("        var expected: Swift.Set<Swift.String> = []")
        lines.append("")
        lines.append("        init(tokens: [Token], end: Location) {")
        lines.append("            self.tokens = tokens")
        lines.append("            self.end = end")
        lines.append("        }")
        lines.append("")
        lines.append("        mutating func take(_ kind: Kind) -> Token? {")
        lines.append("            if index < tokens.count, tokens[index].kind == kind {")
        lines.append("                index += 1")
        lines.append("                return tokens[index - 1]")
        lines.append("            }")
        lines.append("            expect(Self.describe(kind))")
        lines.append("            return nil")
        lines.append("        }")
        lines.append("")
        lines.append("        mutating func expect(_ description: Swift.String) {")
        lines.append("            if index > farthest {")
        lines.append("                farthest = index")
        lines.append("                expected = []")
        lines.append("            }")
        lines.append("            if index == farthest { expected.insert(description) }")
        lines.append("        }")
        lines.append("")
        lines.append("        mutating func expectEnd() {")
        lines.append("            expect(\"the end of the document\")")
        lines.append("        }")
        lines.append("")
        lines.append("        func failure() -> SyntaxError {")
        lines.append("            let found = farthest < tokens.count ? \"'\" + tokens[farthest].text + \"'\" : \"the end of the document\"")
        lines.append("            let location = farthest < tokens.count ? tokens[farthest].location : end")
        lines.append("            return SyntaxError(location: location, message: \"expected \" + expected.sorted().joined(separator: \" or \") + \", found \" + found)")
        lines.append("        }")
        lines.append("")
        lines.append("        static func describe(_ kind: Kind) -> Swift.String {")
        lines.append("            switch kind {")
        for terminal in lexerTerminals {
            lines.append("            case .\(SwiftName.type(terminal)): \(Self.stringLiteral(terminal))")
        }
        lines.append("            case .literal(let index): \"'\" + Lexer.literals[index].text + \"'\"")
        lines.append("            }")
        lines.append("        }")
        for terminal in lexerTerminals {
            let type = SwiftName.type(terminal)
            lines.append("")
            lines.append("        mutating func take\(type)() -> \(type)? {")
            lines.append("            take(.\(type)).map { \(type)(text: $0.text, location: $0.location) }")
            lines.append("        }")
        }
        for (index, literal) in literals.enumerated() {
            lines.append("")
            lines.append("        /// \(Self.stringLiteral(literal.text))")
            lines.append("        mutating func takeLiteral\(index)() -> ()? {")
            lines.append("            take(.literal(\(index))).map { _ in () }")
            lines.append("        }")
        }
        lines.append(contentsOf: parserMethods.map { $0.isEmpty ? $0 : "    " + $0 })
        lines.append("    }")
        lines.append("}")
        return lines
    }
}

/// Writes the body of a function that matches an expression over
/// characters: each expression turns the positions that reach its start
/// into the positions that reach its end.
///
/// In ``Mode/ends`` the positions are offsets. In ``Mode/steps`` they are
/// steps, which also record where each production the expression refers to
/// matched; the productions it refers to are matched for their ends only.
private struct MatcherEmitter {
    enum Mode {
        case ends
        case steps
    }

    let bySymbol: [String: Production]
    let firstCharacters: [String: FirstCharacters]
    var classes: [CharacterClass] = []
    /// The strings of more than one character the expression matches.
    var strings: [[UInt32]] = []
    var lines: [String] = []
    var counter = 0

    init(bySymbol: [String: Production], firstCharacters: [String: FirstCharacters]) {
        self.bySymbol = bySymbol
        self.firstCharacters = firstCharacters
    }

    mutating func function(for expression: Expression, mode: Mode) throws(TranslationError) -> [String] {
        lines = [mode == .ends ? "let start: [Swift.Int] = [offset]" : "let start: [Step] = [Step(end: offset, trace: nil)]"]
        let result = try emit(expression, from: "start", mode: mode, indent: 0)
        lines.append("return \(result)")
        return lines
    }

    mutating func fresh(_ prefix: String = "positions") -> String {
        counter += 1
        return "\(prefix)\(counter)"
    }

    mutating func line(_ text: String, _ indent: Int) {
        lines.append(String(repeating: "    ", count: indent) + text)
    }

    func type(_ mode: Mode) -> String {
        mode == .ends ? "[Swift.Int]" : "[Step]"
    }

    /// `position` advanced by `count` characters, in `mode`.
    func advanced(_ position: String, by count: String, _ mode: Mode) -> String {
        mode == .ends ? "\(position) + \(count)" : "Step(end: \(position).end + \(count), trace: \(position).trace)"
    }

    func end(_ position: String, _ mode: Mode) -> String {
        mode == .ends ? position : "\(position).end"
    }

    func unique(_ mode: Mode) -> String {
        mode == .ends ? "Step.uniqueEnds" : "Step.unique"
    }

    /// Writes the positions after `expression` from the positions in
    /// `input`, and returns the variable that holds them.
    mutating func emit(_ expression: Expression, from input: String, mode: Mode, indent: Int) throws(TranslationError) -> String {
        switch expression {
        case .symbol(let symbol):
            guard bySymbol[symbol] != nil else { throw TranslationError("'\(symbol)' is used but not defined") }
            let type = SwiftName.type(symbol)
            let output = fresh()
            let at = end("position", mode)
            line("var \(output): \(self.type(mode)) = []", indent)
            if firstCharacters[symbol]?.mustAlwaysTry == false {
                line("for position in \(input) where \(at) < s.count && \(type).starts(s[\(at)].value) {", indent)
            } else {
                line("for position in \(input) {", indent)
            }
            switch mode {
            case .ends:
                line("    \(output) += \(type).ends(s, position)", indent)
            case .steps:
                line("    for end in \(type).ends(s, position.end) {", indent)
                line("        \(output).append(Step(end: end, trace: Trace(.\(type), position.end, end, position.trace)))", indent)
                line("    }", indent)
            }
            line("}", indent)
            line("\(output) = \(unique(mode))(\(output))", indent)
            return output
        case .string(let text, _):
            let scalars = text.unicodeScalars.map(\.value)
            let output = fresh()
            let at = end("position", mode)
            line("var \(output): \(type(mode)) = []", indent)
            if scalars.count == 1 {
                line("for position in \(input) where \(at) < s.count && s[\(at)].value == \(Translation.hex(scalars[0])) {", indent)
            } else {
                if !strings.contains(scalars) { strings.append(scalars) }
                line("for position in \(input) where Step.has(s, \(at), string\(strings.firstIndex(of: scalars)!)) {", indent)
            }
            line("    \(output).append(\(advanced("position", by: String(scalars.count), mode)))", indent)
            line("}", indent)
            return output
        case .character(let value):
            let output = fresh()
            let at = end("position", mode)
            line("var \(output): \(type(mode)) = []", indent)
            line("for position in \(input) where \(at) < s.count && s[\(at)].value == \(Translation.hex(value)) {", indent)
            line("    \(output).append(\(advanced("position", by: "1", mode)))", indent)
            line("}", indent)
            return output
        case .characterClass(let characterClass):
            let index: Int
            if let existing = classes.firstIndex(of: characterClass) {
                index = existing
            } else {
                classes.append(characterClass)
                index = classes.count - 1
            }
            let output = fresh()
            let at = end("position", mode)
            line("var \(output): \(type(mode)) = []", indent)
            line("for position in \(input) where \(at) < s.count && class\(index)(s[\(at)].value) {", indent)
            line("    \(output).append(\(advanced("position", by: "1", mode)))", indent)
            line("}", indent)
            return output
        case .sequence(let items):
            var current = input
            for item in items {
                current = try emit(item, from: current, mode: mode, indent: indent)
            }
            return current
        case .choice(let options):
            var outputs: [String] = []
            for option in options {
                outputs.append(try emit(option, from: input, mode: mode, indent: indent))
            }
            let output = fresh()
            line("var \(output) = \(outputs[0])", indent)
            for other in outputs.dropFirst() {
                line("\(output) += \(other)", indent)
            }
            line("\(output) = \(unique(mode))(\(output))", indent)
            return output
        case .optional(let item):
            let inner = try emit(item, from: input, mode: mode, indent: indent)
            let output = fresh()
            line("let \(output) = \(unique(mode))(\(input) + \(inner))", indent)
            return output
        case .zeroOrMore(let item):
            return try repetition(item, from: input, mode: mode, indent: indent)
        case .oneOrMore(let item):
            let first = try emit(item, from: input, mode: mode, indent: indent)
            return try repetition(item, from: first, mode: mode, indent: indent)
        case .difference(let left, let right):
            let output = fresh()
            let position = fresh("position")
            line("var \(output): \(type(mode)) = []", indent)
            line("for \(position) in \(input) {", indent)
            let leftInput = fresh()
            line("    let \(leftInput) = [\(position)]", indent)
            let leftOutput = try emit(left, from: leftInput, mode: mode, indent: indent + 1)
            // B only needs to match as far as A reaches: it reads the
            // characters up to the end of A's longest match.
            let excluded = fresh("excluded")
            let leftEnds = mode == .ends ? leftOutput : "\(leftOutput).map(\\.end)"
            line("    let \(excluded): Swift.Set<Swift.Int> = {", indent)
            line("        let s = Swift.Array(s[..<(\(leftEnds).max() ?? \(end(position, mode)))])", indent)
            let rightInput = fresh()
            line("        let \(rightInput) = [\(end(position, mode))]", indent)
            let rightOutput = try emit(right, from: rightInput, mode: .ends, indent: indent + 2)
            line("        return Swift.Set(\(rightOutput))", indent)
            line("    }()", indent)
            line("    \(output) += \(leftOutput).filter { !\(excluded).contains(\(end("$0", mode))) }", indent)
            line("}", indent)
            return output
        }
    }

    /// `item*` from the positions in `input`: each round takes the
    /// positions that reach a new end.
    mutating func repetition(_ item: Expression, from input: String, mode: Mode, indent: Int) throws(TranslationError) -> String {
        let output = fresh()
        let frontier = fresh("frontier")
        let ends = fresh("ends")
        line("var \(output) = \(input)", indent)
        line("var \(frontier) = \(input)", indent)
        line("var \(ends) = Swift.Set(\(mode == .ends ? input : "\(input).map(\\.end)"))", indent)
        line("while !\(frontier).isEmpty {", indent)
        let round = fresh()
        line("    let \(round) = \(frontier)", indent)
        let inner = try emit(item, from: round, mode: mode, indent: indent + 1)
        line("    \(frontier) = \(inner).filter { \(ends).insert(\(end("$0", mode))).inserted }", indent)
        line("    \(output) += \(frontier)", indent)
        line("}", indent)
        return output
    }
}
