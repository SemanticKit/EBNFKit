/// The characters a match of an expression can start with, and whether it
/// can match nothing: what lets a parser skip a production at a character
/// that cannot start it.
struct FirstCharacters: Hashable {
    /// The classes the first character is in; any one of them.
    var classes: [CharacterClass] = []
    /// Whether the expression matches the empty string.
    var isNullable = false
    /// Whether the first character can be any character.
    var isUnbounded = false

    /// Whether a parser must try the expression at every character.
    var mustAlwaysTry: Bool { isNullable || isUnbounded }

    static let unknown = FirstCharacters(isNullable: true, isUnbounded: true)

    mutating func formUnion(_ other: FirstCharacters) {
        for characterClass in other.classes where !classes.contains(characterClass) { classes.append(characterClass) }
        isUnbounded = isUnbounded || other.isUnbounded
    }

    /// The first characters of every production in `bySymbol`, by symbol.
    static func of(_ productions: [Production], bySymbol: [String: Production]) -> [String: FirstCharacters] {
        var memo: [String: FirstCharacters] = [:]
        var inProgress: Set<String> = []
        func symbol(_ name: String) -> FirstCharacters {
            if let known = memo[name] { return known }
            // A production that refers back to itself before a character:
            // try it everywhere.
            guard let production = bySymbol[name], inProgress.insert(name).inserted else { return .unknown }
            let result = expression(production.expression)
            inProgress.remove(name)
            memo[name] = result
            return result
        }
        func expression(_ value: Expression) -> FirstCharacters {
            switch value {
            case .symbol(let name):
                return symbol(name)
            case .string(let text, _):
                guard let first = text.unicodeScalars.first else { return FirstCharacters(isNullable: true) }
                return FirstCharacters(classes: [CharacterClass(isNegated: false, ranges: [first.value...first.value])])
            case .character(let value):
                return FirstCharacters(classes: [CharacterClass(isNegated: false, ranges: [value...value])])
            case .characterClass(let characterClass):
                return FirstCharacters(classes: [characterClass])
            case .sequence(let items):
                var result = FirstCharacters()
                for item in items {
                    let first = expression(item)
                    result.formUnion(first)
                    guard first.isNullable else { return result }
                }
                result.isNullable = true
                return result
            case .choice(let options):
                var result = FirstCharacters()
                for option in options {
                    let first = expression(option)
                    result.formUnion(first)
                    result.isNullable = result.isNullable || first.isNullable
                }
                return result
            case .optional(let item), .zeroOrMore(let item):
                var result = expression(item)
                result.isNullable = true
                return result
            case .oneOrMore(let item):
                return expression(item)
            case .difference(let left, _):
                return expression(left)
            }
        }
        for production in productions { _ = symbol(production.symbol) }
        return memo
    }
}
