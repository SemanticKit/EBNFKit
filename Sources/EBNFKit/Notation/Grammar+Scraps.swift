extension Grammar {
    /// Reads the productions of a W3C specification published in HTML, as
    /// the XML 1.0 and Namespaces in XML 1.0 Recommendations are: each
    /// production is a `tbody` of a `table` of class `scrap`, with the number,
    /// the symbol, `::=` and the expression in the cells of its first row,
    /// and the rest of the expression in the fourth cell of the rows after
    /// it. A fifth cell holds a comment or a constraint (`[WFC: …]`), which
    /// the specification states in prose, so it is not read.
    ///
    /// The text of a cell is its characters without the markup, with the
    /// character references and the entities `&lt;`, `&gt;`, `&amp;`,
    /// `&quot;` and `&apos;` replaced, and no-break spaces read as spaces.
    /// Each production is then read as ``init(notation:)`` reads it.
    ///
    /// - Throws: ``NotationError`` when a production is not in the notation;
    ///   its line is the line of the specification's text where the
    ///   production's table body starts.
    public init(scrapsIn html: String) throws(NotationError) {
        var productions: [Production] = []
        let scalars = Array(html.unicodeScalars)
        var index = 0
        while let table = Self.find("<table", in: scalars, from: index) {
            let end = Self.find("</table>", in: scalars, from: table) ?? scalars.count
            let tag = Self.find(">", in: scalars, from: table) ?? end
            guard Self.find("class=\"scrap\"", in: scalars, from: table).map({ $0 < tag }) == true else {
                index = tag
                continue
            }
            var body = table
            while let start = Self.find("<tbody", in: scalars, from: body), start < end {
                let close = Self.find("</tbody>", in: scalars, from: start) ?? end
                let rows = Self.elements("tr", in: scalars, start..<close).map { Self.elements("td", in: scalars, $0) }
                if let first = rows.first, first.count >= 4 {
                    let symbol = Self.text(of: first[1], in: scalars)
                    let expression = rows.compactMap { $0.count >= 4 ? Self.text(of: $0[3], in: scalars) : nil }
                    let notation = symbol + " ::= " + expression.joined(separator: "\n")
                    do {
                        productions += try Grammar(notation: notation).productions
                    } catch {
                        let line = scalars[..<start].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                        throw NotationError(line: line, column: 1, message: "\(symbol): \(error.message)")
                    }
                }
                body = close
            }
            index = end
        }
        self.init(productions: productions)
    }

    /// The offset of the first `text` at or after `offset`.
    static func find(_ text: String, in scalars: [Unicode.Scalar], from offset: Int) -> Int? {
        let pattern = Array(text.unicodeScalars)
        guard pattern.count <= scalars.count else { return nil }
        var position = offset
        while position + pattern.count <= scalars.count {
            if scalars[position..<position + pattern.count].elementsEqual(pattern) { return position }
            position += 1
        }
        return nil
    }

    /// The ranges of the contents of the `name` elements in `range`,
    /// counting an empty `<name/>` as an element with no contents.
    static func elements(_ name: String, in scalars: [Unicode.Scalar], _ range: Range<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var position = range.lowerBound
        while let start = find("<" + name, in: scalars, from: position), start < range.upperBound {
            let after = start + name.unicodeScalars.count + 1
            guard after < scalars.count, scalars[after] == ">" || scalars[after] == " " || scalars[after] == "/" else {
                position = after
                continue
            }
            guard let tagEnd = find(">", in: scalars, from: start) else { break }
            if scalars[tagEnd - 1] == "/" {
                result.append(tagEnd + 1..<tagEnd + 1)
                position = tagEnd + 1
                continue
            }
            let close = find("</" + name + ">", in: scalars, from: tagEnd) ?? range.upperBound
            result.append(tagEnd + 1..<min(close, range.upperBound))
            position = close
        }
        return result
    }

    /// The characters of a cell, without markup, with references replaced.
    static func text(of range: Range<Int>, in scalars: [Unicode.Scalar]) -> String {
        var text = String.UnicodeScalarView()
        var position = range.lowerBound
        while position < range.upperBound {
            let scalar = scalars[position]
            if scalar == "<" {
                while position < range.upperBound, scalars[position] != ">" { position += 1 }
                position += 1
            } else if scalar == "&", let semicolon = find(";", in: scalars, from: position), semicolon < range.upperBound {
                let name = String(String.UnicodeScalarView(scalars[position + 1..<semicolon]))
                if let replacement = reference(name) {
                    text.append(replacement)
                } else {
                    text.append(contentsOf: scalars[position...semicolon])
                }
                position = semicolon + 1
            } else {
                text.append(scalar == "\u{A0}" ? " " : scalar)
                position += 1
            }
        }
        return String(text).trimmingSpaces
    }

    static func reference(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "lt": return "<"
        case "gt": return ">"
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            return value.flatMap(Unicode.Scalar.init)
        }
    }
}

private extension String {
    var trimmingSpaces: String {
        var scalars = Substring(self).unicodeScalars
        while let first = scalars.first, first == " " || first == "\n" || first == "\t" || first == "\r" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\n" || last == "\t" || last == "\r" { scalars.removeLast() }
        return String(scalars)
    }
}
