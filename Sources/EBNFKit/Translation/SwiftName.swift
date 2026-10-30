/// The Swift names a translation gives a grammar's symbols.
///
/// A production's type keeps the symbol as written when it is in capitals
/// (`IRIREF`, `PNAME_NS`) and otherwise starts it with a capital
/// (`turtleDoc` becomes `TurtleDoc`). A member named after a symbol is in
/// lower camel case (`IRIREF` becomes `iriref`, `PNAME_NS` becomes `pnameNs`,
/// `RDFLiteral` becomes `rdfLiteral`).
enum SwiftName {
    /// The type of the production that defines `symbol`.
    static func type(_ symbol: String) -> String {
        if isCapitals(symbol) { return symbol }
        return symbol.prefix(1).uppercased() + symbol.dropFirst()
    }

    /// A member named after `symbol`, escaped when it is a keyword.
    static func member(_ symbol: String) -> String {
        escaped(lowerCamel(symbol))
    }

    /// `symbol` in lower camel case, unescaped.
    static func lowerCamel(_ symbol: String) -> String {
        if isCapitals(symbol) {
            let words = symbol.split(separator: "_").map { $0.lowercased() }
            guard let first = words.first else { return symbol.lowercased() }
            return first + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
        let scalars = Array(symbol)
        var leading = 0
        while leading < scalars.count, scalars[leading].isUppercase { leading += 1 }
        switch leading {
        case 0: return symbol
        case 1: return symbol.prefix(1).lowercased() + symbol.dropFirst()
        default:
            // RDFLiteral: the capitals before the last start a word.
            let cut = leading == scalars.count ? leading : leading - 1
            return String(scalars[..<cut]).lowercased() + String(scalars[cut...])
        }
    }

    /// The plural of a member name, for a member that holds several.
    static func plural(_ name: String) -> String {
        let bare = name.hasPrefix("`") ? String(name.dropFirst().dropLast()) : name
        let plural: String
        if bare.hasSuffix("s") || bare.hasSuffix("x") || bare.hasSuffix("ch") || bare.hasSuffix("sh") {
            plural = bare + "es"
        } else {
            plural = bare + "s"
        }
        return escaped(plural)
    }

    /// An upper camel name for a type made of `names`: `ReifierOrAnnotationBlock`.
    static func compound(_ names: [String], separator: String) -> String {
        names.map(unescaped).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: separator)
    }

    /// The case or member name a string stands for when it is the only
    /// thing an alternative holds: its letters and digits, `nil` when it has
    /// none (`'@prefix'` is `prefix`, `'.'` has none).
    static func word(_ text: String) -> String? {
        let letters = text.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
        guard let first = letters.first, !("0"..."9").contains(first) else { return nil }
        return escaped(lowerCamel(String(String.UnicodeScalarView(letters))))
    }

    static func isCapitals(_ symbol: String) -> Bool {
        symbol.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    static func unescaped(_ name: String) -> String {
        name.hasPrefix("`") ? String(name.dropFirst().dropLast()) : name
    }

    static func escaped(_ name: String) -> String {
        keywords.contains(name) ? "`\(name)`" : name
    }

    static let keywords: Set<String> = [
        "Any", "Self", "Type", "actor", "any", "as", "associatedtype", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
        "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal",
        "is", "let", "nil", "open", "operator", "private", "protocol", "public", "repeat", "rethrows",
        "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "where", "while",
    ]
}
