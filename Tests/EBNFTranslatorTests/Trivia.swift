// What the RDF 1.2 Turtle and N-Triples specifications state in prose
// rather than in their EBNF: the white space and comments between terminals.

extension TurtleGrammar {
    /// RDF 1.2 Turtle §6.1-6.2: white space (production `WS`) and comments,
    /// from `#` to the end of the line, between terminals.
    static func trivia(_ scalars: [Unicode.Scalar], from offset: Int) -> Int {
        var index = offset
        while index < scalars.count {
            if let end = WS.longestMatch(in: scalars, at: index), end > index {
                index = end
            } else if scalars[index] == "#" {
                while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" { index += 1 }
            } else {
                break
            }
        }
        return index
    }
}

extension NTriplesGrammar {
    /// RDF 1.2 N-Triples §5.1-5.2: spaces, tabs and comments between
    /// terminals, and blank lines, which "are treated as white space".
    static func trivia(_ scalars: [Unicode.Scalar], from offset: Int) -> Int {
        var index = lineSpace(scalars, from: offset)
        // A line end followed by a blank line: the blank line is white space.
        while let end = EOL.longestMatch(in: scalars, at: index), end > index {
            let next = lineSpace(scalars, from: end)
            guard next == scalars.count || EOL.longestMatch(in: scalars, at: next).map({ $0 > next }) == true else { break }
            index = next
        }
        return index
    }

    static func lineSpace(_ scalars: [Unicode.Scalar], from offset: Int) -> Int {
        var index = offset
        while index < scalars.count {
            if scalars[index] == " " || scalars[index] == "\t" {
                index += 1
            } else if scalars[index] == "#" {
                while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" { index += 1 }
            } else {
                break
            }
        }
        return index
    }
}
