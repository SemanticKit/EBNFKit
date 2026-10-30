extension Grammar {
    /// Reads a grammar written in the EBNF notation of XML 1.0 §6.
    ///
    /// The text is a list of productions `symbol ::= expression`, each
    /// optionally numbered `[n]`. An expression runs until the next
    /// production starts, so it can continue over several lines. Comments
    /// `/* … */` may appear between any two tokens. A line `@terminals`
    /// marks the productions after it as terminals (``Production/isTerminal``),
    /// as the W3C RDF grammar files do.
    ///
    /// - Throws: ``NotationError`` when the text is not in the notation.
    public init(notation text: String) throws(NotationError) {
        var reader = NotationReader(text)
        self.init(productions: try reader.productions())
    }
}

/// Reads the productions of a grammar in the EBNF notation of XML 1.0 §6.
private struct NotationReader {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    // MARK: - Productions

    mutating func productions() throws(NotationError) -> [Production] {
        var productions: [Production] = []
        var isTerminal = false
        while true {
            skipTrivia()
            guard index < scalars.count else { return productions }
            if peek() == "@" {
                index += 1
                let directive = readName()
                guard directive == "terminals" else {
                    throw error("unknown directive '@\(directive)'")
                }
                isTerminal = true
                continue
            }
            skipNumber()
            skipTrivia()
            let symbol = readName()
            guard !symbol.isEmpty else { throw error("expected a production") }
            skipTrivia()
            guard consume("::=") else { throw error("expected '::=' after '\(symbol)'") }
            let expression = try choice()
            productions.append(Production(symbol: symbol, expression: expression, isTerminal: isTerminal))
        }
    }

    /// `[n]`, the number some specifications give a production.
    mutating func skipNumber() {
        guard peek() == "[" else { return }
        var end = index + 1
        while end < scalars.count, ("0"..."9").contains(scalars[end]) { end += 1 }
        if end > index + 1, end < scalars.count, scalars[end] == "]" { index = end + 1 }
    }

    /// Whether a production, or a directive, starts at the cursor: what
    /// ends the expression before it.
    func isAtProductionStart() -> Bool {
        var probe = self
        probe.skipTrivia()
        if probe.peek() == "@" { return true }
        probe.skipNumber()
        probe.skipTrivia()
        guard !probe.readName().isEmpty else { return false }
        probe.skipTrivia()
        return probe.consume("::=")
    }

    // MARK: - Expressions

    /// `A | B | …`
    mutating func choice() throws(NotationError) -> Expression {
        var options = [try sequence()]
        while true {
            skipTrivia()
            guard peek() == "|" else { break }
            index += 1
            options.append(try sequence())
        }
        return options.count == 1 ? options[0] : .choice(options)
    }

    /// `A B …`, up to `|`, `)`, or the next production.
    mutating func sequence() throws(NotationError) -> Expression {
        var items: [Expression] = []
        while true {
            skipTrivia()
            guard let scalar = peek(), scalar != "|", scalar != ")", !isAtProductionStart() else { break }
            items.append(try item())
        }
        guard !items.isEmpty else { throw error("expected an expression") }
        return items.count == 1 ? items[0] : .sequence(items)
    }

    /// A primary with its `?`, `*` and `+`, and `A - B` between two of
    /// them.
    mutating func item() throws(NotationError) -> Expression {
        let left = try postfixed()
        var probe = self
        probe.skipTrivia()
        guard probe.peek() == "-" else { return left }
        self = probe
        index += 1
        skipTrivia()
        return .difference(left, try postfixed())
    }

    mutating func postfixed() throws(NotationError) -> Expression {
        var expression = try primary()
        while true {
            // RDF 1.2 Turtle writes `PN_LOCAL ::= … ) ?`, with a space before
            // the operator.
            var probe = self
            probe.skipTrivia()
            switch probe.peek() {
            case "?": expression = .optional(expression)
            case "*": expression = .zeroOrMore(expression)
            case "+": expression = .oneOrMore(expression)
            default: return expression
            }
            self = probe
            index += 1
        }
    }

    mutating func primary() throws(NotationError) -> Expression {
        guard let scalar = peek() else { throw error("expected an expression") }
        switch scalar {
        case "(":
            index += 1
            let inner = try choice()
            skipTrivia()
            guard consume(")") else { throw error("expected ')'") }
            return inner
        case "'", "\"":
            return try string(quote: scalar)
        case "[":
            return .characterClass(try characterClass())
        case "#":
            guard let value = try codePoint() else { throw error("expected '#x' and a hexadecimal number") }
            return .character(value)
        default:
            let name = readName()
            guard !name.isEmpty else { throw error("unexpected '\(scalar)'") }
            return .symbol(name)
        }
    }

    /// `'…'` or `"…"`: the text between the quotes, which has no escapes.
    mutating func string(quote: Unicode.Scalar) throws(NotationError) -> Expression {
        let start = index
        index += 1
        var text = String.UnicodeScalarView()
        while let scalar = peek(), scalar != quote {
            text.append(scalar)
            index += 1
        }
        guard consume(String(quote)) else {
            index = start
            throw error("unterminated string")
        }
        guard !text.isEmpty else {
            index = start
            throw error("empty string")
        }
        return .string(String(text), quote == "'" ? .apostrophe : .quotationMark)
    }

    /// `#xN`, or `nil` when the cursor is on a `#` that does not start one.
    mutating func codePoint() throws(NotationError) -> UInt32? {
        guard peek() == "#", index + 1 < scalars.count, scalars[index + 1] == "x" else { return nil }
        let start = index
        index += 2
        var value: UInt32 = 0
        var digits = 0
        while let scalar = peek(), let digit = Self.hexValue(scalar) {
            guard value <= 0x10FFFF else { break }
            value = value * 16 + digit
            digits += 1
            index += 1
        }
        guard digits > 0, value <= 0x10FFFF else {
            index = start
            throw error("'#x' must be followed by a code point")
        }
        return value
    }

    /// `[…]` and `[^…]`.
    mutating func characterClass() throws(NotationError) -> CharacterClass {
        let start = index
        index += 1
        let isNegated = consume("^")
        var ranges: [ClosedRange<UInt32>] = []
        while true {
            guard let scalar = peek() else {
                index = start
                throw error("unterminated character class")
            }
            if scalar == "]", !ranges.isEmpty {
                index += 1
                return CharacterClass(isNegated: isNegated, ranges: ranges)
            }
            let low = try classMember()
            if peek() == "-", index + 1 < scalars.count, scalars[index + 1] != "]" {
                index += 1
                let high = try classMember()
                guard low <= high else { throw error("empty range in a character class") }
                ranges.append(low...high)
            } else {
                ranges.append(low...low)
            }
        }
    }

    /// One member of a character class: `#xN` or the character itself.
    mutating func classMember() throws(NotationError) -> UInt32 {
        if let value = try codePoint() { return value }
        guard let scalar = peek() else { throw error("unterminated character class") }
        index += 1
        return scalar.value
    }

    // MARK: - Tokens

    /// A symbol: a letter or `_`, then letters, digits and `_`.
    mutating func readName() -> String {
        let start = index
        while let scalar = peek(), Self.isNameScalar(scalar, first: index == start) { index += 1 }
        return String(String.UnicodeScalarView(scalars[start..<index]))
    }

    static func isNameScalar(_ scalar: Unicode.Scalar, first: Bool) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "_": true
        case "0"..."9": !first
        default: false
        }
    }

    static func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar {
        case "0"..."9": scalar.value - 0x30
        case "a"..."f": scalar.value - 0x57
        case "A"..."F": scalar.value - 0x37
        default: nil
        }
    }

    /// White space and `/* … */` comments.
    mutating func skipTrivia() {
        while let scalar = peek() {
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                index += 1
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                index += 2
                while index < scalars.count, !(scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, scalars.count)
            } else {
                return
            }
        }
    }

    func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    mutating func consume(_ text: String) -> Bool {
        var offset = index
        for scalar in text.unicodeScalars {
            guard offset < scalars.count, scalars[offset] == scalar else { return false }
            offset += 1
        }
        index = offset
        return true
    }

    func error(_ message: String) -> NotationError {
        var line = 1
        var column = 1
        for scalar in scalars[..<min(index, scalars.count)] {
            if scalar == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return NotationError(line: line, column: column, message: message)
    }
}
