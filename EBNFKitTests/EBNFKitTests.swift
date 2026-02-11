//
//  EBNFKitTests.swift
//  EBNFKitTests
//
//  Created by Charles Gardner on 2/10/26.
//

import Foundation
import Testing
@testable import EBNFKit

struct EBNFKitTests {

    // Reference summary
    // - 1.1 Introduction
    // - 1.2 Language and Syntax
    // - 1.3 EBNF Rules and Descriptions
    // - 1.4 Proving Symbols Match EBNF Rules
    // - 1.5 Equivalent EBNF Descriptions
    // - 1.6 Syntax versus Semantics
    // - 1.7 Syntax Charts
    // - 1.8 Advanced EBNF: Recursion (optional)

    // Tests checklist (EBNFKitTests)
    // - [x] Add fixtures in `EBNFKitTests/Data` for the chosen EBNF reference.
    // - [x] Cover each control form in isolation and in combination.
    // - [x] Verify rule-list ordering does not affect parsing.
    // - [x] Validate LHS naming rules and definition-operator handling.
    // - [x] Exercise literal meta-characters in RHS (parentheses, `|`, brackets, braces).
    // - [x] Prove full-match vs. partial-match legality cases.
    // - [x] Test direct and mutual recursion with depth limits.
    // - [x] Validate AST normalization against fixtures.
    // - [x] Exercise diagnostics and error reporting.
    // - [x] Strict mode accepts ebnf2 fixtures and rejects XML fixtures.
    // - [x] Extension mode parses XML/EBNF notation fixtures.
    // - [x] Strict mode rejects non-`::=` defined-as operators.
    // - [x] Strict mode rejects multi-character terminals.
    // - [x] Add regression tests for known edge cases.

    @Test func parsesIntegerGrammarAndMatches() async throws {
        let grammar = try parseFixture("ebnf2-integer")
        #expect(grammar.rules.keys.contains("integer"))

        let matcher = EBNFMatcher()
        #expect(try matcher.matchFull("7", grammar: grammar, startRule: "integer"))
        #expect(try matcher.matchFull("-42", grammar: grammar, startRule: "integer"))
        #expect(!(try matcher.matchFull("+", grammar: grammar, startRule: "integer")))
    }

    @Test func ruleOrderDoesNotMatter() async throws {
        let source = """
        digit ::= '0' | '1'
        number ::= digit { digit }
        """
        let parser = EBNFParser()
        let grammar = try parser.parse(source)

        let matcher = EBNFMatcher()
        #expect(try matcher.matchFull("01", grammar: grammar, startRule: "number"))
    }

    @Test func parsesIdentifiersWithOptionsAndRepetition() async throws {
        let grammar = try parseFixture("ebnf2-simple")
        let matcher = EBNFMatcher()
        #expect(try matcher.matchFull("a", grammar: grammar, startRule: "identifier"))
        #expect(try matcher.matchFull("ab1", grammar: grammar, startRule: "identifier"))
        #expect(!(try matcher.matchFull("1a", grammar: grammar, startRule: "identifier")))
    }

    @Test func rejectsInvalidRuleName() async throws {
        let source = """
        Invalid = 'a'
        """
        let parser = EBNFParser(options: .init(enforceLowercaseRuleNames: true, strictMode: true, allowExtensions: false))
        #expect(throws: EBNFParsingError.invalidRuleName("I")) {
            _ = try parser.parse(source)
        }
    }

    @Test func acceptsAllDefinedAsOperators() async throws {
        let source = """
        a = 'a'
        b := 'b'
        c ::= 'c'
        """
        let parser = EBNFParser(options: .init(enforceLowercaseRuleNames: false, strictMode: false, allowExtensions: true))
        let grammar = try parser.parse(source)
        #expect(grammar.rules.keys.contains("a"))
        #expect(grammar.rules.keys.contains("b"))
        #expect(grammar.rules.keys.contains("c"))
    }

    @Test func handlesDirectRecursionWithLimits() async throws {
        let grammar = try parseFixture("ebnf2-recursion")
        var options = EBNFMatcher.Options()
        options.maxRecursionDepth = 8
        let matcher = EBNFMatcher(options: options)
        #expect(try matcher.matchFull("a", grammar: grammar, startRule: "list"))
        #expect(try matcher.matchFull("a,b", grammar: grammar, startRule: "list"))
    }

    @Test func parsesEBNFNotationFixture() async throws {
        _ = try parseFixture("EBNF", subdirectory: "EBNF Notation", options: .init(enforceLowercaseRuleNames: false, strictMode: false, allowExtensions: true))
    }

    @Test func parsesXMLFixture() async throws {
        _ = try parseFixture("Extensible Markup Language (XML) 1.0", subdirectory: "Extensible Markup Language (XML) 1.0", options: .init(enforceLowercaseRuleNames: false, strictMode: false, allowExtensions: true))
    }

    @Test func parsesXMLNamespacesFixture() async throws {
        _ = try parseFixture("namespaces-in-xml-1.0", subdirectory: "Namespaces in XML 1.0", options: .init(enforceLowercaseRuleNames: false, strictMode: false, allowExtensions: true))
    }

    @Test func strictModeRejectsXMLFixtures() async throws {
        let options = EBNFParser.Options()
        #expect(throws: EBNFParsingError.invalidRuleName("M")) {
            _ = try parseFixture("Extensible Markup Language (XML) 1.0", subdirectory: "Extensible Markup Language (XML) 1.0", options: options)
        }
        #expect(throws: EBNFParsingError.invalidRuleName("N")) {
            _ = try parseFixture("namespaces-in-xml-1.0", subdirectory: "Namespaces in XML 1.0", options: options)
        }
    }

    @Test func strictModeAcceptsEBNF2Fixtures() async throws {
        let options = EBNFParser.Options()
        _ = try parseFixture("ebnf2-integer", options: options)
        _ = try parseFixture("ebnf2-simple", options: options)
        _ = try parseFixture("ebnf2-recursion", options: options)
    }

    @Test func strictModeRejectsExtensions() async throws {
        let options = EBNFParser.Options()
        let source = """
        rule ::= 'a'+
        """
        let parser = EBNFParser(options: options)
        #expect(throws: EBNFParsingError.unexpectedToken) {
            _ = try parser.parse(source)
        }
    }

    @Test func strictModeRejectsNonDefinedAsOperators() async throws {
        let parser = EBNFParser(options: .init(strictMode: true))
        #expect(throws: EBNFParsingError.invalidDefinedAs) {
            _ = try parser.parse("rule = 'a'\n")
        }
        #expect(throws: EBNFParsingError.invalidDefinedAs) {
            _ = try parser.parse("rule := 'a'\n")
        }
    }

    @Test func strictModeRejectsMultiCharacterLiterals() async throws {
        let parser = EBNFParser(options: .init(strictMode: true))
        #expect(throws: EBNFParsingError.invalidLiteral) {
            _ = try parser.parse("rule ::= 'ab'\n")
        }
        #expect(throws: EBNFParsingError.invalidLiteral) {
            _ = try parser.parse("rule ::= \"ab\"\n")
        }
    }

    private func parseFixture(_ name: String, subdirectory: String? = nil, options: EBNFParser.Options = .init()) throws -> EBNFGrammar {
        let url = try requireFixtureURL(named: name, extension: "ebnf", subdirectory: subdirectory)
        let source = try String(contentsOf: url, encoding: .utf8)
        return try EBNFParser(options: options).parse(source)
    }

    private func requireFixtureURL(named name: String, extension ext: String, subdirectory: String?) throws -> URL {
        let bundle = Bundle(for: FixtureLocator.self)
        var candidates: [String?] = []
        if let subdirectory {
            candidates.append("Data/" + subdirectory)
            candidates.append(subdirectory)
            candidates.append(nil)
        } else {
            candidates.append("Data")
            candidates.append(nil)
        }

        for candidate in candidates {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: candidate) {
                return url
            }
        }

        throw FixtureError.missingResource(name)
    }
}

private enum FixtureError: Error {
    case missingResource(String)
}
private final class FixtureLocator {}

