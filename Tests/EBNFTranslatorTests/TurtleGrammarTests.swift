import Testing

/// The parser translated from the RDF 1.2 Turtle grammar as published
/// (`Grammars/turtle.bnf`).
@Suite struct TurtleGrammarTests {
    @Test func readsADocumentIntoItsStatements() throws {
        let document = try TurtleGrammar.TurtleDoc.parse("""
            PREFIX : <http://example/>
            :s :p :o, "x"@en--ltr ; :q 1.5e3 .
            [] :p ( 1 2 ) .
            """)
        #expect(document.statements.count == 3)
        guard case .directive(.sparqlPrefix(let prefix)) = document.statements[0] else {
            Issue.record("expected a PREFIX directive")
            return
        }
        #expect(prefix.pnameNs.text == ":")
        #expect(prefix.iriref.text == "<http://example/>")
    }

    @Test func keepsThePartsOfASequenceInOrder() throws {
        let document = try TurtleGrammar.TurtleDoc.parse("<s> <p> <o1> , <o2> ; <q> <o3> .")
        guard case .triples(.subject(_, let list)) = document.statements[0] else {
            Issue.record("expected triples with a subject")
            return
        }
        #expect(list.verbAndObjectLists.count == 1)
        let objects = [list.objectList.object] + list.objectList.objectAndAnnotations.map(\.object)
        #expect(objects.count == 2)
    }

    @Test func keepsAnnotationsInTheOrderWritten() throws {
        let document = try TurtleGrammar.TurtleDoc.parse("<s> <p> <o> ~ <r> {| <q> <v> |} ~ <t> .")
        guard case .triples(.subject(_, let list)) = document.statements[0] else {
            Issue.record("expected triples with a subject")
            return
        }
        let parts = list.objectList.annotation.reifierOrAnnotationBlocks.map { part -> String in
            switch part {
            case .reifier: "reifier"
            case .annotationBlock: "block"
            }
        }
        #expect(parts == ["reifier", "block", "reifier"])
    }

    @Test(arguments: ["PREFIX", "prefix", "PrEfIx"])
    func readsQuotedKeywordsWithoutRegardToCase(keyword: String) throws {
        _ = try TurtleGrammar.TurtleDoc.parse("\(keyword) ex: <http://example/>")
    }

    @Test func readsApostropheKeywordsWithCase() {
        #expect(throws: TurtleGrammar.SyntaxError.self) {
            _ = try TurtleGrammar.TurtleDoc.parse("@PREFIX ex: <http://example/> .")
        }
    }

    @Test func takesTheLongestMatch() throws {
        // `:o.` is the name `:o` and the end of the statement; `.5` is a
        // decimal, not a dot.
        let document = try TurtleGrammar.TurtleDoc.parse(":s :p :o. :s :p .5 .")
        #expect(document.statements.count == 2)
        #expect(TurtleGrammar.PNAME_LN(parsing: ":o.") == nil)
        #expect(TurtleGrammar.PNAME_LN(parsing: ":o.p") != nil)
    }

    @Test func reportsWhereADocumentStopsMatching() {
        #expect(throws: TurtleGrammar.SyntaxError.self) {
            try TurtleGrammar.TurtleDoc.parse("<a> <b> <c>\n<d> <e> .")
        }
        do {
            _ = try TurtleGrammar.TurtleDoc.parse("<a> <b> .")
            Issue.record("expected an error")
        } catch {
            #expect(error.location == TurtleGrammar.Location(offset: 8, line: 1, column: 9))
            #expect(error.message.hasPrefix("expected "))
        }
    }

    @Test func givesTheProductionsATerminalMatched() throws {
        let name = try #require(TurtleGrammar.PNAME_LN(parsing: #"ex:a%41\.b"#))
        #expect(name.pnameNs.text == "ex:")
        #expect(name.pnameNs.pnPrefix?.text == "ex")
        #expect(name.pnLocal.text == #"a%41\.b"#)
        #expect(name.pnLocal.plxes.map(\.text) == ["%41", #"\."#])
        #expect(name.pnLocal.plxes[1].pnLocalEsc?.text == #"\."#)

        // An escape is a backslash, then u and four digits or U and eight.
        let escape = #"\"# + "u0041"
        let iri = try #require(TurtleGrammar.IRIREF(parsing: "<a" + escape + #"b\U0001F600>"#))
        #expect(iri.uchars.map(\.text) == [escape, #"\U0001F600"#])
        #expect(iri.uchars[0].location.offset == 2)
        #expect(iri.uchars[0].hexes.map(\.text) == ["0", "0", "4", "1"])
    }

    @Test(arguments: [
        ("<http://example/>", true), ("<a b>", false), ("<é>", true), ("<" + #"\"# + "u00E9>", true), ("<a\\b>", false),
    ])
    func matchesIRIREF(text: String, matches: Bool) {
        #expect(TurtleGrammar.IRIREF.matches(text) == matches)
    }

    @Test(arguments: [
        ("1", "INTEGER"), ("-1", "INTEGER"), ("1.0", "DECIMAL"), (".5", "DECIMAL"), ("1e3", "DOUBLE"), ("1.e3", "DOUBLE"),
    ])
    func matchesNumbers(text: String, production: String) {
        #expect(TurtleGrammar.INTEGER.matches(text) == (production == "INTEGER"))
        #expect(TurtleGrammar.DECIMAL.matches(text) == (production == "DECIMAL"))
        #expect(TurtleGrammar.DOUBLE.matches(text) == (production == "DOUBLE"))
    }
}
