import Testing

/// The productions translated from the scrap tables of Namespaces in XML 1.0
/// and XML 1.0 as published (`Grammars/xml-names.html`, `Grammars/xml.html`).
@Suite struct XMLNamesGrammarTests {
    @Test(arguments: [
        ("abc", true), ("_x.y-z", true), ("é", true), ("a:b", false), ("1a", false), ("", false), ("-a", false),
    ])
    func matchesNCName(text: String, matches: Bool) {
        #expect(XMLNamesGrammar.NCName.matches(text) == matches)
    }

    @Test func matchesChar() {
        #expect(XMLNamesGrammar.Char.matches("a"))
        #expect(!XMLNamesGrammar.Char.matches("\u{FFFE}"))
        #expect(!XMLNamesGrammar.Char.matches("\u{1}"))
    }
}
