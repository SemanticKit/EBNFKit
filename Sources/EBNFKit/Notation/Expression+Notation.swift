extension Expression {
    /// The expression written in the EBNF notation of XML 1.0 §6.
    ///
    /// Reading the text back with ``Grammar/init(notation:)`` gives the same
    /// expression. Characters a class cannot hold as themselves are
    /// written `#xN`.
    public var notation: String {
        switch self {
        case .symbol(let name):
            return name
        case .string(let text, let quote):
            let mark = quote == .apostrophe ? "'" : "\""
            return mark + text + mark
        case .character(let value):
            return Self.codePoint(value)
        case .characterClass(let characterClass):
            var text = characterClass.isNegated ? "[^" : "["
            for range in characterClass.ranges {
                text += Self.classMember(range.lowerBound)
                if range.upperBound != range.lowerBound { text += "-" + Self.classMember(range.upperBound) }
            }
            return text + "]"
        case .sequence(let items):
            return items.map { $0.precedence <= 1 ? "(\($0.notation))" : $0.notation }.joined(separator: " ")
        case .choice(let options):
            return options.map { $0.precedence == 0 ? "(\($0.notation))" : $0.notation }.joined(separator: " | ")
        case .optional(let item):
            return item.postfixOperand + "?"
        case .zeroOrMore(let item):
            return item.postfixOperand + "*"
        case .oneOrMore(let item):
            return item.postfixOperand + "+"
        case .difference(let left, let right):
            return left.postfixOperand + " - " + right.postfixOperand
        }
    }

    /// 0 for a choice, 1 for a sequence or a difference, 2 for the rest.
    var precedence: Int {
        switch self {
        case .choice: 0
        case .sequence, .difference: 1
        default: 2
        }
    }

    var postfixOperand: String {
        precedence < 2 ? "(\(notation))" : notation
    }

    static func codePoint(_ value: UInt32) -> String {
        "#x" + String(value, radix: 16, uppercase: true)
    }

    static func classMember(_ value: UInt32) -> String {
        guard let scalar = Unicode.Scalar(value), (0x21...0x7E).contains(value),
              !["]", "-", "^", "#"].contains(scalar) else { return codePoint(value) }
        return String(scalar)
    }
}
