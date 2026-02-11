# ``EBNFKit``

EBNF parsing, validation, and tooling.

## Overview

EBNFKit targets a complete, standards-aligned implementation of EBNF. The checklists below track the work for the framework and its tests.

Strict mode follows the ebnf2 RFC (`::=` only, single-character terminals, lowercase rule names). Extension mode keeps those defaults relaxed so XML-family grammars can parse with postfix quantifiers, character classes, `#x` codes, and external references.

### Usage Example

```swift
let source = """
integer ::= [ sign ] digit { digit }
sign ::= '+' | '-'
digit ::= '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9'
"""
let grammar = try EBNFParser().parse(source)
let matcher = EBNFMatcher()
let isValid = try matcher.matchFull("-42", grammar: grammar, startRule: "integer")
```

### Recursive Example

```swift
let source = """
list ::= item | list ',' item
item ::= 'a' | 'b'
"""
let grammar = try EBNFParser().parse(source)
let matcher = EBNFMatcher()
let isValid = try matcher.matchFull("a,b", grammar: grammar, startRule: "list")
```

## Reference Summary

- 1.1 Introduction
- 1.2 Language and Syntax
- 1.3 EBNF Rules and Descriptions
- 1.4 Proving Symbols Match EBNF Rules
- 1.5 Equivalent EBNF Descriptions
- 1.6 Syntax versus Semantics
- 1.7 Syntax Charts
- 1.8 Advanced EBNF: Recursion (optional)

## Framework Checklist (EBNFKit)

- [x] Define the supported dialect: RFC ebnf2 in strict mode with optional extensions.
- [x] Parse rule lists as unordered sets of rules.
- [x] Support rule forms with a LHS name, definition operator, and RHS description (accept `::=`, `:=`, and `=` as extensions).
- [x] Enforce LHS naming rules (lowercase words with underscores in strict mode).
- [x] Implement the four control forms: sequence, choice (`|`), option (`[]`), repetition (`{}`).
- [x] Treat non-italicized characters as terminals and allow literal meta-characters (parentheses, `|`, brackets, braces).
- [x] Add a normalized AST representation for parsed grammars.
- [x] Provide match/parse APIs that prove full-symbol matches (legal vs. illegal).
- [x] Support recursive rules with guardrails (depth/step limits).
- [x] Extensions: postfix `?/*/+`, character classes, `#x` codes, external references.
- [x] Enforce strict defined-as operator (`::=` only) when strict mode is enabled.
- [x] Enforce single-character terminals in strict mode.
- [x] Document syntax vs. semantics boundaries and usage notes in DocC.

## Tests Checklist (EBNFKitTests)

- [x] Add fixtures in `EBNFKitTests/Data` for the chosen EBNF reference.
- [x] Cover each control form in isolation and in combination.
- [x] Verify rule-list ordering does not affect parsing.
- [x] Validate LHS naming rules and definition-operator handling.
- [x] Exercise literal meta-characters in RHS (parentheses, `|`, brackets, braces).
- [x] Prove full-match vs. partial-match legality cases.
- [x] Test direct and mutual recursion with depth limits.
- [x] Validate AST normalization against fixtures.
- [x] Exercise diagnostics and error reporting.
- [x] Strict mode accepts ebnf2 fixtures and rejects XML fixtures.
- [x] Extension mode parses XML/EBNF notation fixtures.
- [x] Strict mode rejects non-`::=` defined-as operators.
- [x] Strict mode rejects multi-character terminals.
- [x] Add regression tests for known edge cases.
