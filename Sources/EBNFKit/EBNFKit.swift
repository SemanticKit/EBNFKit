//
//  EBNFKit.swift
//  EBNFKit
//
//  Created by Charles Gardner on 2/10/26.
//

import Foundation

public struct EBNFGrammar: Sendable, Equatable {
    public var rules: [String: EBNFRule]

    public init(rules: [String: EBNFRule] = [:]) {
        self.rules = rules
    }
}

public struct EBNFRule: Sendable, Equatable {
    public var name: String
    public var elements: EBNFAlternation

    public init(name: String, elements: EBNFAlternation) {
        self.name = name
        self.elements = elements
    }
}

public struct EBNFAlternation: Sendable, Equatable {
    public var options: [EBNFConcatenation]

    public init(options: [EBNFConcatenation]) {
        self.options = options
    }
}

public struct EBNFConcatenation: Sendable, Equatable {
    public var elements: [EBNFElement]

    public init(elements: [EBNFElement]) {
        self.elements = elements
    }
}

public enum EBNFElement: Sendable, Equatable {
    case ruleReference(String)
    case group(EBNFAlternation)
    case option(EBNFAlternation)
    case repetition(EBNFAlternation)
    case oneOrMore(EBNFAlternation)
    case literal(EBNFLiteral)
    case charCode(UInt32)
    case characterClass(EBNFCharacterClass)
    case externalReference(String)
}

public struct EBNFLiteral: Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct EBNFCharacterClass: Sendable, Equatable {
    public var isNegated: Bool
    public var members: [EBNFCharacterClassMember]

    public init(isNegated: Bool, members: [EBNFCharacterClassMember]) {
        self.isNegated = isNegated
        self.members = members
    }
}

public enum EBNFCharacterClassMember: Sendable, Equatable {
    case value(UInt32)
    case range(min: UInt32, max: UInt32)
}

public enum EBNFParsingError: Error, Sendable, Equatable {
    case emptyInput
    case invalidRuleName(String)
    case invalidDefinedAs
    case duplicateRule(String)
    case invalidLiteral
    case invalidCharacterClass
    case invalidCharCode
    case unterminatedComment
    case unexpectedToken
    case unexpectedEndOfInput
}

public struct EBNFMatchResult: Sendable, Equatable {
    public var consumedScalars: Int
    public var isFullMatch: Bool

    public init(consumedScalars: Int, isFullMatch: Bool) {
        self.consumedScalars = consumedScalars
        self.isFullMatch = isFullMatch
    }
}

public struct EBNFMatchNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case rule(String)
        case group
        case option
        case repetition
        case oneOrMore
        case literal(EBNFLiteral)
        case charCode(UInt32)
        case characterClass(EBNFCharacterClass)
        case externalReference(String)
    }

    public var kind: Kind
    public var range: Range<Int>
    public var children: [EBNFMatchNode]

    public init(kind: Kind, range: Range<Int>, children: [EBNFMatchNode] = []) {
        self.kind = kind
        self.range = range
        self.children = children
    }
}

public struct EBNFMatchTreeResult: Sendable, Equatable {
    public var consumedScalars: Int
    public var isFullMatch: Bool
    public var root: EBNFMatchNode?

    public init(consumedScalars: Int, isFullMatch: Bool, root: EBNFMatchNode?) {
        self.consumedScalars = consumedScalars
        self.isFullMatch = isFullMatch
        self.root = root
    }
}

public enum EBNFMatchError: Error, Sendable, Equatable {
    case unknownRule(String)
    case exceededRecursionDepth
    case exceededStepLimit
}

public struct EBNFMatcher: Sendable {
    public struct Options: Sendable, Equatable {
        public var maxRecursionDepth: Int
        public var maxSteps: Int
        public var enableMemoization: Bool

        public init(maxRecursionDepth: Int = 128, maxSteps: Int = 100_000, enableMemoization: Bool = true) {
            self.maxRecursionDepth = maxRecursionDepth
            self.maxSteps = maxSteps
            self.enableMemoization = enableMemoization
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func match(_ input: String, grammar: EBNFGrammar, startRule: String) throws -> EBNFMatchResult {
        guard let rule = grammar.rules[startRule.lowercased()] else {
            throw EBNFMatchError.unknownRule(startRule)
        }

        var matcher = Matcher(
            scalars: Array(input.unicodeScalars),
            grammar: grammar,
            options: options
        )
        let ends = try matcher.matchAlternation(rule.elements, from: 0, depth: 0)
        guard let best = ends.max() else {
            return EBNFMatchResult(consumedScalars: 0, isFullMatch: false)
        }
        return EBNFMatchResult(consumedScalars: best, isFullMatch: best == matcher.scalars.count)
    }

    public func matchFull(_ input: String, grammar: EBNFGrammar, startRule: String) throws -> Bool {
        let result = try match(input, grammar: grammar, startRule: startRule)
        return result.isFullMatch
    }

    public func matchTree(_ input: String, grammar: EBNFGrammar, startRule: String) throws -> EBNFMatchTreeResult {
        guard let rule = grammar.rules[startRule.lowercased()] else {
            throw EBNFMatchError.unknownRule(startRule)
        }

        var matcher = TreeMatcher(
            scalars: Array(input.unicodeScalars),
            grammar: grammar,
            options: options
        )
        if let (end, node) = try matcher.matchRule(rule, from: 0, depth: 0) {
            let isFull = end == matcher.scalars.count
            return EBNFMatchTreeResult(consumedScalars: end, isFullMatch: isFull, root: node)
        }

        return EBNFMatchTreeResult(consumedScalars: 0, isFullMatch: false, root: nil)
    }
}

public struct EBNFParser: Sendable {
    public struct Options: Sendable, Equatable {
        public var allowLeadingWhitespaceInRuleDefinitions: Bool
        public var rejectDuplicateRuleDefinitions: Bool
        public var enforceLowercaseRuleNames: Bool
        public var strictMode: Bool
        public var allowExtensions: Bool

        public init(
            allowLeadingWhitespaceInRuleDefinitions: Bool = true,
            rejectDuplicateRuleDefinitions: Bool = false,
            enforceLowercaseRuleNames: Bool = true,
            strictMode: Bool = true,
            allowExtensions: Bool = false
        ) {
            self.allowLeadingWhitespaceInRuleDefinitions = allowLeadingWhitespaceInRuleDefinitions
            self.rejectDuplicateRuleDefinitions = rejectDuplicateRuleDefinitions
            self.enforceLowercaseRuleNames = enforceLowercaseRuleNames
            self.strictMode = strictMode
            self.allowExtensions = allowExtensions
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func parse(_ source: String) throws -> EBNFGrammar {
        guard !source.isEmpty else {
            throw EBNFParsingError.emptyInput
        }

        var parser = Parser(source: source, options: options)
        return try parser.parseGrammar()
    }
}

private struct Parser {
    private let scalars: [UnicodeScalar]
    private let options: EBNFParser.Options
    private var index: Int

    init(source: String, options: EBNFParser.Options) {
        self.scalars = Array(source.unicodeScalars)
        self.options = options
        self.index = 0
    }

#if DEBUG
    var debugIndex: Int { index }
    var debugScalars: [UnicodeScalar] { scalars }
#endif

    mutating func parseGrammar() throws -> EBNFGrammar {
        var grammar = EBNFGrammar()
        var lastRuleName: String?

        while true {
            consumeSeparators()
            if isAtEnd {
                break
            }

            if peekScalar() == "|" {
                guard let name = lastRuleName, var existing = grammar.rules[name] else {
                    throw EBNFParsingError.unexpectedToken
                }
                let extraOptions = try parseContinuationAlternation()
                existing.elements.options.append(contentsOf: extraOptions)
                grammar.rules[name] = existing
                continue
            }

            let rule = try parseRule()
            let normalizedName = rule.name.lowercased()
            if options.rejectDuplicateRuleDefinitions, grammar.rules[normalizedName] != nil {
                throw EBNFParsingError.duplicateRule(normalizedName)
            }
            grammar.rules[normalizedName] = EBNFRule(name: normalizedName, elements: rule.elements)
            lastRuleName = normalizedName

            consumeSeparators()
        }

        return grammar
    }

    private mutating func parseRule() throws -> EBNFRule {
        if options.allowLeadingWhitespaceInRuleDefinitions {
            consumeWhitespace()
        }
        let name = try parseRulename()
        consumeSeparators()
        try parseDefinedAs()
        consumeWhitespace()
        let elements = try parseAlternation()
        consumeWhitespace()

        if let scalar = peekScalar(), !isNewline(scalar) {
            throw EBNFParsingError.unexpectedToken
        }
        consumeNewlines()

        return EBNFRule(name: name, elements: elements)
    }

    private mutating func parseDefinedAs() throws {
        if matchString("::=") {
            return
        }
        if options.strictMode {
            throw EBNFParsingError.invalidDefinedAs
        }
        if matchString(":=") {
            return
        }
        if matchScalar("=") {
            return
        }
        throw EBNFParsingError.invalidDefinedAs
    }

    private mutating func parseAlternation() throws -> EBNFAlternation {
        var options = [try parseConcatenation()]
        consumeWhitespace()

        while matchScalar("|") {
            consumeWhitespace()
            options.append(try parseConcatenation())
            consumeWhitespace()
        }

        return EBNFAlternation(options: options)
    }

    private mutating func parseContinuationAlternation() throws -> [EBNFConcatenation] {
        consumeWhitespace()
        guard matchScalar("|") else {
            throw EBNFParsingError.unexpectedToken
        }
        consumeWhitespace()

        var options = [try parseConcatenation()]
        consumeWhitespace()

        while matchScalar("|") {
            consumeWhitespace()
            options.append(try parseConcatenation())
            consumeWhitespace()
        }

        if let scalar = peekScalar(), !isNewline(scalar) {
            throw EBNFParsingError.unexpectedToken
        }
        consumeNewlines()
        return options
    }

    private mutating func parseConcatenation() throws -> EBNFConcatenation {
        var elements: [EBNFElement] = []

        while true {
            guard let scalar = peekScalar() else {
                break
            }
            if isConcatenationTerminator(scalar) {
                break
            }
            elements.append(try parseElement())
            consumeWhitespace()
        }

        if elements.isEmpty {
            throw EBNFParsingError.unexpectedToken
        }

        return EBNFConcatenation(elements: elements)
    }

    private mutating func parseElement() throws -> EBNFElement {
        var element = try parsePrimary()

        if options.strictMode {
            return element
        }

        while let scalar = peekScalar() {
            switch scalar {
            case "?":
                _ = advance()
                element = .option(wrapAsAlternation(element))
            case "*":
                _ = advance()
                element = .repetition(wrapAsAlternation(element))
            case "+":
                _ = advance()
                element = .oneOrMore(wrapAsAlternation(element))
            default:
                return element
            }
        }

        return element
    }

    private mutating func parsePrimary() throws -> EBNFElement {
        guard let scalar = peekScalar() else {
            throw EBNFParsingError.unexpectedEndOfInput
        }

        if matchScalar("(") {
            consumeWhitespace()
            let alternation = try parseAlternation()
            consumeWhitespace()
            guard matchScalar(")") else {
                throw EBNFParsingError.unexpectedToken
            }
            return .group(alternation)
        }

        if matchScalar("[") {
            if options.allowExtensions {
                if let special = try parseBracketedSpecial() {
                    return special
                }
            }
            consumeWhitespace()
            let alternation = try parseAlternation()
            consumeWhitespace()
            guard matchScalar("]") else {
                throw EBNFParsingError.unexpectedToken
            }
            return .option(alternation)
        }

        if matchScalar("{") {
            consumeWhitespace()
            let alternation = try parseAlternation()
            consumeWhitespace()
            guard matchScalar("}") else {
                throw EBNFParsingError.unexpectedToken
            }
            return .repetition(alternation)
        }

        if scalar == "#" {
            if options.allowExtensions, peekScalar(offset: 1) == "x".unicodeScalars.first {
                _ = advance()
                let code = try parseCharCode()
                return .charCode(code)
            }
            _ = advance()
            return .literal(EBNFLiteral(text: "#"))
        }

        if isRuleNameStart(scalar) {
            let name = try parseRulename()
            return .ruleReference(name.lowercased())
        }

        if matchScalar("\"") {
            let literal = try parseQuotedLiteral(quote: "\"")
            return .literal(literal)
        }

        if matchScalar("'") {
            let literal = try parseQuotedLiteral(quote: "'")
            return .literal(literal)
        }

        if matchScalar("\\") {
            guard let escaped = peekScalar() else {
                throw EBNFParsingError.unexpectedEndOfInput
            }
            _ = advance()
            return .literal(EBNFLiteral(text: String(escaped)))
        }

        if !isWhitespace(scalar) && !isMetaCharacter(scalar) {
            _ = advance()
            return .literal(EBNFLiteral(text: String(scalar)))
        }

        throw EBNFParsingError.unexpectedToken
    }

    private func wrapAsAlternation(_ element: EBNFElement) -> EBNFAlternation {
        return EBNFAlternation(options: [EBNFConcatenation(elements: [element])])
    }

    private mutating func parseBracketedSpecial() throws -> EBNFElement? {
        let startIndex = index
        guard let endIndex = findClosingBracket(from: startIndex) else {
            throw EBNFParsingError.unexpectedEndOfInput
        }
        let content = String(String.UnicodeScalarView(scalars[startIndex..<endIndex]))
        if content.contains("http://") || content.contains("https://") {
            index = endIndex + 1
            return .externalReference(content)
        }
        if content.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           !content.contains("|") {
            index = startIndex
            let characterClass = try parseCharacterClass()
            return .characterClass(characterClass)
        }

        index = startIndex
        return nil
    }

    private mutating func parseCharacterClass() throws -> EBNFCharacterClass {
        var isNegated = false
        if matchScalar("^") {
            isNegated = true
        }

        var members: [EBNFCharacterClassMember] = []
        while let scalar = peekScalar() {
            if scalar == "]" {
                _ = advance()
                return EBNFCharacterClass(isNegated: isNegated, members: members)
            }

            let startValue = try parseCharacterClassAtom()
            if matchScalar("-"), let next = peekScalar(), next != "]" {
                let endValue = try parseCharacterClassAtom()
                let minValue = min(startValue, endValue)
                let maxValue = max(startValue, endValue)
                members.append(.range(min: minValue, max: maxValue))
            } else {
                members.append(.value(startValue))
            }
        }

        throw EBNFParsingError.invalidCharacterClass
    }

    private mutating func parseCharacterClassAtom() throws -> UInt32 {
        guard let scalar = peekScalar() else {
            throw EBNFParsingError.invalidCharacterClass
        }

        if scalar == "\\" {
            _ = advance()
            guard let escaped = peekScalar() else {
                throw EBNFParsingError.invalidCharacterClass
            }
            _ = advance()
            return escaped.value
        }

        if scalar == "#" {
            if options.allowExtensions, peekScalar(offset: 1) == "x".unicodeScalars.first {
                _ = advance()
                return try parseCharCode()
            }
            _ = advance()
            return scalar.value
        }

        _ = advance()
        return scalar.value
    }

    private mutating func parseCharCode() throws -> UInt32 {
        guard matchScalar("x") else {
            throw EBNFParsingError.invalidCharCode
        }
        guard let value = parseHexValue() else {
            throw EBNFParsingError.invalidCharCode
        }
        return value
    }

    private mutating func parseHexValue() -> UInt32? {
        var digits = ""
        while let scalar = peekScalar(), isHexDigit(scalar) {
            digits.append(Character(advance()))
        }
        guard !digits.isEmpty else {
            return nil
        }
        return UInt32(digits, radix: 16)
    }

    private func findClosingBracket(from startIndex: Int) -> Int? {
        var position = startIndex
        while position < scalars.count {
            if scalars[position] == "]" {
                return position
            }
            position += 1
        }
        return nil
    }

    private mutating func parseQuotedLiteral(quote: Character) throws -> EBNFLiteral {
        guard let quoteScalar = quote.unicodeScalars.first else {
            throw EBNFParsingError.invalidLiteral
        }
        var text = ""
        while let scalar = peekScalar() {
            if scalar == quoteScalar {
                _ = advance()
                if options.strictMode && text.count != 1 {
                    throw EBNFParsingError.invalidLiteral
                }
                return EBNFLiteral(text: text)
            }
            if scalar == "\\" {
                _ = advance()
                guard let escaped = peekScalar() else {
                    throw EBNFParsingError.unexpectedEndOfInput
                }
                _ = advance()
                text.append(Character(escaped))
                continue
            }
            _ = advance()
            text.append(Character(scalar))
        }
        throw EBNFParsingError.invalidLiteral
    }

    private mutating func parseRulename() throws -> String {
        let requiresLowercase = options.enforceLowercaseRuleNames
        guard let scalar = peekScalar(),
              (requiresLowercase ? isLowercaseRuleNameStart(scalar) : isRuleNameStart(scalar)) else {
            throw EBNFParsingError.invalidRuleName(String(peekScalar().map(Character.init) ?? Character("?")))
        }

        var name = ""
        name.append(Character(advance()))

        while let next = peekScalar() {
            if requiresLowercase ? isLowercaseRuleNameBody(next) : isRuleNameBody(next) {
                name.append(Character(advance()))
            } else {
                break
            }
        }

        return name
    }

    private mutating func consumeWhitespace() {
        consumeTrivia(allowNewlines: false)
    }

    private mutating func consumeNewlines() {
        while let scalar = peekScalar(), isNewline(scalar) {
            _ = advance()
            if scalar == "\r", peekScalar() == "\n" {
                _ = advance()
            }
        }
    }

    private mutating func consumeSeparators() {
        consumeTrivia(allowNewlines: true)
    }

    private func isConcatenationTerminator(_ scalar: UnicodeScalar) -> Bool {
        if isNewline(scalar) {
            return true
        }
        switch scalar {
        case "|", ")", "]", "}":
            return true
        default:
            return false
        }
    }

    private func isMetaCharacter(_ scalar: UnicodeScalar) -> Bool {
        switch scalar {
        case "(", ")", "[", "]", "{", "}", "|", "?", "*", "+":
            return true
        default:
            return false
        }
    }

    private func isRuleNameStart(_ scalar: UnicodeScalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || scalar == "_"
    }

    private func isRuleNameBody(_ scalar: UnicodeScalar) -> Bool {
        (scalar >= "a" && scalar <= "z")
            || (scalar >= "A" && scalar <= "Z")
            || (scalar >= "0" && scalar <= "9")
            || scalar == "_"
    }

    private func isLowercaseRuleNameStart(_ scalar: UnicodeScalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || scalar == "_"
    }

    private func isLowercaseRuleNameBody(_ scalar: UnicodeScalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "_"
    }

    private mutating func consumeTrivia(allowNewlines: Bool) {
        while let scalar = peekScalar() {
            if isWhitespace(scalar) {
                if !allowNewlines && isNewline(scalar) {
                    break
                }
                _ = advance()
                continue
            }
            if consumeCommentIfPresent() {
                continue
            }
            break
        }
    }

    private mutating func consumeCommentIfPresent() -> Bool {
        guard peekScalar() == "/", peekScalar(offset: 1) == "*" else {
            return false
        }
        _ = advance()
        _ = advance()

        while let scalar = peekScalar() {
            if scalar == "*", peekScalar(offset: 1) == "/" {
                _ = advance()
                _ = advance()
                return true
            }
            _ = advance()
        }

        return true
    }

    private func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
    }

    private func isNewline(_ scalar: UnicodeScalar) -> Bool {
        scalar == "\n" || scalar == "\r"
    }

    private func isHexDigit(_ scalar: UnicodeScalar) -> Bool {
        (scalar >= "0" && scalar <= "9")
            || (scalar >= "a" && scalar <= "f")
            || (scalar >= "A" && scalar <= "F")
    }

    private mutating func matchScalar(_ expected: Character) -> Bool {
        guard let scalar = expected.unicodeScalars.first, peekScalar() == scalar else {
            return false
        }
        _ = advance()
        return true
    }

    private mutating func matchString(_ expected: String) -> Bool {
        let expectedScalars = Array(expected.unicodeScalars)
        guard index + expectedScalars.count <= scalars.count else {
            return false
        }
        for (offset, scalar) in expectedScalars.enumerated() {
            if scalars[index + offset] != scalar {
                return false
            }
        }
        index += expectedScalars.count
        return true
    }

    private func peekScalar() -> UnicodeScalar? {
        guard index < scalars.count else {
            return nil
        }
        return scalars[index]
    }

    private func peekScalar(offset: Int) -> UnicodeScalar? {
        let position = index + offset
        guard position >= 0 && position < scalars.count else {
            return nil
        }
        return scalars[position]
    }

    @discardableResult
    private mutating func advance() -> UnicodeScalar {
        defer { index += 1 }
        return scalars[index]
    }

    private var isAtEnd: Bool {
        index >= scalars.count
    }
}

private struct Matcher {
    let scalars: [UnicodeScalar]
    let grammar: EBNFGrammar
    let options: EBNFMatcher.Options
    var steps: Int = 0
    var ruleMemo: [RuleMemoKey: RuleMemoEntry] = [:]

    mutating func matchAlternation(_ alternation: EBNFAlternation, from start: Int, depth: Int) throws -> [Int] {
        try checkLimits(depth: depth)
        var results: [Int] = []
        for option in alternation.options {
            let ends = try matchConcatenation(option, from: start, depth: depth + 1)
            results.append(contentsOf: ends)
        }
        return Array(Set(results)).sorted()
    }

    mutating func matchConcatenation(_ concatenation: EBNFConcatenation, from start: Int, depth: Int) throws -> [Int] {
        try checkLimits(depth: depth)
        var positions: [Int] = [start]
        for element in concatenation.elements {
            var newPositions: [Int] = []
            for position in positions {
                let ends = try matchElement(element, from: position, depth: depth + 1)
                newPositions.append(contentsOf: ends)
            }
            if newPositions.isEmpty {
                return []
            }
            positions = Array(Set(newPositions)).sorted()
        }
        return positions
    }

    mutating func matchElement(_ element: EBNFElement, from start: Int, depth: Int) throws -> [Int] {
        try checkLimits(depth: depth)
        steps += 1

        switch element {
        case .ruleReference(let name):
            guard let rule = grammar.rules[name.lowercased()] else {
                throw EBNFMatchError.unknownRule(name)
            }
            return try matchRule(rule, from: start, depth: depth + 1)
        case .group(let alternation):
            return try matchAlternation(alternation, from: start, depth: depth + 1)
        case .option(let alternation):
            var ends = try matchAlternation(alternation, from: start, depth: depth + 1)
            ends.append(start)
            return Array(Set(ends)).sorted()
        case .repetition(let alternation):
            return try matchRepetition(alternation, from: start, depth: depth + 1)
        case .oneOrMore(let alternation):
            return try matchOneOrMore(alternation, from: start, depth: depth + 1)
        case .literal(let literal):
            return matchLiteral(literal, from: start)
        case .charCode(let value):
            return matchCharCode(value, from: start)
        case .characterClass(let characterClass):
            return matchCharacterClass(characterClass, from: start)
        case .externalReference:
            return []
        }
    }

    mutating func matchRepetition(_ alternation: EBNFAlternation, from start: Int, depth: Int) throws -> [Int] {
        try checkLimits(depth: depth)

        var currentPositions: [Int] = [start]
        var allEnds: [Int] = [start]

        while true {
            let nextPositions = try expandPositions(currentPositions, alternation: alternation, depth: depth + 1)
            if nextPositions.isEmpty {
                break
            }
            if nextPositions == currentPositions {
                break
            }
            currentPositions = Array(Set(nextPositions)).sorted()
            allEnds.append(contentsOf: currentPositions)
        }

        return Array(Set(allEnds)).sorted()
    }

    mutating func matchOneOrMore(_ alternation: EBNFAlternation, from start: Int, depth: Int) throws -> [Int] {
        try checkLimits(depth: depth)
        var results: [Int] = []
        let firstEnds = try matchAlternation(alternation, from: start, depth: depth + 1)
        for end in firstEnds {
            let tails = try matchRepetition(alternation, from: end, depth: depth + 1)
            results.append(contentsOf: tails)
        }
        return Array(Set(results)).sorted()
    }

    mutating func expandPositions(_ positions: [Int], alternation: EBNFAlternation, depth: Int) throws -> [Int] {
        try checkLimits(depth: depth)
        var results: [Int] = []
        for position in positions {
            let ends = try matchAlternation(alternation, from: position, depth: depth + 1)
            results.append(contentsOf: ends)
        }
        return Array(Set(results)).sorted()
    }

    mutating func matchRule(_ rule: EBNFRule, from start: Int, depth: Int) throws -> [Int] {
        if options.enableMemoization {
            let key = RuleMemoKey(name: rule.name, position: start)
            if let entry = ruleMemo[key] {
                switch entry {
                case .inProgress:
                    return []
                case .result(let ends):
                    return ends
                }
            }
            ruleMemo[key] = .inProgress
            let ends = try matchAlternation(rule.elements, from: start, depth: depth + 1)
            ruleMemo[key] = .result(ends)
            return ends
        }

        return try matchAlternation(rule.elements, from: start, depth: depth + 1)
    }

    mutating func matchLiteral(_ literal: EBNFLiteral, from start: Int) -> [Int] {
        let literalScalars = Array(literal.text.unicodeScalars)
        guard start + literalScalars.count <= scalars.count else {
            return []
        }

        for (offset, scalar) in literalScalars.enumerated() {
            let inputScalar = scalars[start + offset]
            if scalar != inputScalar {
                return []
            }
        }

        return [start + literalScalars.count]
    }

    mutating func matchCharCode(_ value: UInt32, from start: Int) -> [Int] {
        guard start < scalars.count else {
            return []
        }
        return scalars[start].value == value ? [start + 1] : []
    }

    mutating func matchCharacterClass(_ characterClass: EBNFCharacterClass, from start: Int) -> [Int] {
        guard start < scalars.count else {
            return []
        }
        let value = scalars[start].value
        let matches = matchesCharacterClass(characterClass, value: value)
        return matches ? [start + 1] : []
    }

    func matchesCharacterClass(_ characterClass: EBNFCharacterClass, value: UInt32) -> Bool {
        var contains = false
        for member in characterClass.members {
            switch member {
            case .value(let entry):
                if value == entry {
                    contains = true
                }
            case .range(let min, let max):
                if value >= min && value <= max {
                    contains = true
                }
            }
            if contains {
                break
            }
        }
        return characterClass.isNegated ? !contains : contains
    }

    mutating func checkLimits(depth: Int) throws {
        if depth > options.maxRecursionDepth {
            throw EBNFMatchError.exceededRecursionDepth
        }
        if steps > options.maxSteps {
            throw EBNFMatchError.exceededStepLimit
        }
    }
}

private struct TreeMatcher {
    let scalars: [UnicodeScalar]
    let grammar: EBNFGrammar
    let options: EBNFMatcher.Options
    var steps: Int = 0
    var ruleMemo: [RuleMemoKey: TreeMemoEntry] = [:]

    mutating func matchRule(_ rule: EBNFRule, from start: Int, depth: Int) throws -> (Int, EBNFMatchNode)? {
        try checkLimits(depth: depth)
        if options.enableMemoization {
            let key = RuleMemoKey(name: rule.name, position: start)
            if let entry = ruleMemo[key] {
                switch entry {
                case .inProgress:
                    return nil
                case .result(let value):
                    return value
                }
            }
            ruleMemo[key] = .inProgress
            let value = try matchRuleInternal(rule, from: start, depth: depth + 1)
            ruleMemo[key] = .result(value)
            return value
        }

        return try matchRuleInternal(rule, from: start, depth: depth + 1)
    }

    private mutating func matchRuleInternal(_ rule: EBNFRule, from start: Int, depth: Int) throws -> (Int, EBNFMatchNode)? {
        guard let (end, children) = try matchAlternation(rule.elements, from: start, depth: depth + 1) else {
            return nil
        }
        let node = EBNFMatchNode(kind: .rule(rule.name), range: start..<end, children: children)
        return (end, node)
    }

    mutating func matchAlternation(_ alternation: EBNFAlternation, from start: Int, depth: Int) throws -> (Int, [EBNFMatchNode])? {
        try checkLimits(depth: depth)
        for option in alternation.options {
            if let (end, nodes) = try matchConcatenation(option, from: start, depth: depth + 1) {
                return (end, nodes)
            }
        }
        return nil
    }

    mutating func matchConcatenation(_ concatenation: EBNFConcatenation, from start: Int, depth: Int) throws -> (Int, [EBNFMatchNode])? {
        try checkLimits(depth: depth)
        return try matchConcatenationElements(concatenation.elements, index: 0, position: start, depth: depth + 1)
    }

    private mutating func matchConcatenationElements(_ elements: [EBNFElement], index: Int, position: Int, depth: Int) throws -> (Int, [EBNFMatchNode])? {
        try checkLimits(depth: depth)
        if index >= elements.count {
            return (position, [])
        }

        let element = elements[index]
        let variants = try matchElementVariants(element, from: position, depth: depth + 1)
        for (end, node) in variants {
            if let (finalEnd, rest) = try matchConcatenationElements(elements, index: index + 1, position: end, depth: depth + 1) {
                return (finalEnd, [node] + rest)
            }
        }

        return nil
    }

    private mutating func matchElementVariants(_ element: EBNFElement, from start: Int, depth: Int) throws -> [(Int, EBNFMatchNode)] {
        try checkLimits(depth: depth)
        steps += 1

        switch element {
        case .ruleReference(let name):
            guard let rule = grammar.rules[name.lowercased()] else {
                throw EBNFMatchError.unknownRule(name)
            }
            if let value = try matchRule(rule, from: start, depth: depth + 1) {
                return [value]
            }
            return []
        case .group(let alternation):
            if let (end, children) = try matchAlternation(alternation, from: start, depth: depth + 1) {
                let node = EBNFMatchNode(kind: .group, range: start..<end, children: children)
                return [(end, node)]
            }
            return []
        case .option(let alternation):
            var results: [(Int, EBNFMatchNode)] = []
            if let (end, children) = try matchAlternation(alternation, from: start, depth: depth + 1) {
                let node = EBNFMatchNode(kind: .option, range: start..<end, children: children)
                results.append((end, node))
            }
            let empty = EBNFMatchNode(kind: .option, range: start..<start, children: [])
            results.append((start, empty))
            return results
        case .repetition(let alternation):
            return try matchRepetitionVariants(alternation, from: start, depth: depth + 1)
        case .oneOrMore(let alternation):
            return try matchOneOrMoreVariants(alternation, from: start, depth: depth + 1)
        case .literal(let literal):
            if let end = matchLiteral(literal, from: start) {
                let node = EBNFMatchNode(kind: .literal(literal), range: start..<end, children: [])
                return [(end, node)]
            }
            return []
        case .charCode(let value):
            if let end = matchCharCode(value, from: start) {
                let node = EBNFMatchNode(kind: .charCode(value), range: start..<end, children: [])
                return [(end, node)]
            }
            return []
        case .characterClass(let characterClass):
            if let end = matchCharacterClass(characterClass, from: start) {
                let node = EBNFMatchNode(kind: .characterClass(characterClass), range: start..<end, children: [])
                return [(end, node)]
            }
            return []
        case .externalReference:
            return []
        }
    }

    private mutating func matchRepetitionVariants(_ alternation: EBNFAlternation, from start: Int, depth: Int) throws -> [(Int, EBNFMatchNode)] {
        try checkLimits(depth: depth)

        var variants: [(Int, EBNFMatchNode)] = []
        var visited: Set<String> = []

        func key(_ pos: Int, _ count: Int) -> String {
            return "\(count):\(pos)"
        }

        func explore(count: Int, pos: Int, nodes: [EBNFMatchNode]) throws {
            try checkLimits(depth: depth)

            let node = EBNFMatchNode(kind: .repetition, range: start..<pos, children: nodes)
            variants.append((pos, node))

            let cacheKey = key(pos, count)
            if visited.contains(cacheKey) {
                return
            }
            visited.insert(cacheKey)

            guard let (end, children) = try matchAlternation(alternation, from: pos, depth: depth + 1) else {
                return
            }
            if end == pos {
                return
            }
            let childNode = EBNFMatchNode(kind: .group, range: pos..<end, children: children)
            try explore(count: count + 1, pos: end, nodes: nodes + [childNode])
        }

        try explore(count: 0, pos: start, nodes: [])

        return variants.sorted { $0.0 > $1.0 }
    }

    private mutating func matchOneOrMoreVariants(_ alternation: EBNFAlternation, from start: Int, depth: Int) throws -> [(Int, EBNFMatchNode)] {
        try checkLimits(depth: depth)
        guard let (firstEnd, firstChildren) = try matchAlternation(alternation, from: start, depth: depth + 1) else {
            return []
        }

        let firstNode = EBNFMatchNode(kind: .group, range: start..<firstEnd, children: firstChildren)
        let tailVariants = try matchRepetitionVariants(alternation, from: firstEnd, depth: depth + 1)

        var results: [(Int, EBNFMatchNode)] = []
        for (end, tailNode) in tailVariants {
            let combinedChildren = [firstNode] + tailNode.children
            let node = EBNFMatchNode(kind: .oneOrMore, range: start..<end, children: combinedChildren)
            results.append((end, node))
        }

        return results.sorted { $0.0 > $1.0 }
    }

    private func matchLiteral(_ literal: EBNFLiteral, from start: Int) -> Int? {
        let literalScalars = Array(literal.text.unicodeScalars)
        guard start + literalScalars.count <= scalars.count else {
            return nil
        }

        for (offset, scalar) in literalScalars.enumerated() {
            let inputScalar = scalars[start + offset]
            if scalar != inputScalar {
                return nil
            }
        }

        return start + literalScalars.count
    }

    private func matchCharCode(_ value: UInt32, from start: Int) -> Int? {
        guard start < scalars.count else {
            return nil
        }
        return scalars[start].value == value ? start + 1 : nil
    }

    private func matchCharacterClass(_ characterClass: EBNFCharacterClass, from start: Int) -> Int? {
        guard start < scalars.count else {
            return nil
        }
        let value = scalars[start].value
        let matches = matchesCharacterClass(characterClass, value: value)
        return matches ? start + 1 : nil
    }

    private func matchesCharacterClass(_ characterClass: EBNFCharacterClass, value: UInt32) -> Bool {
        var contains = false
        for member in characterClass.members {
            switch member {
            case .value(let entry):
                if value == entry {
                    contains = true
                }
            case .range(let min, let max):
                if value >= min && value <= max {
                    contains = true
                }
            }
            if contains {
                break
            }
        }
        return characterClass.isNegated ? !contains : contains
    }

    mutating func checkLimits(depth: Int) throws {
        if depth > options.maxRecursionDepth {
            throw EBNFMatchError.exceededRecursionDepth
        }
        if steps > options.maxSteps {
            throw EBNFMatchError.exceededStepLimit
        }
    }
}

private struct RuleMemoKey: Hashable {
    let name: String
    let position: Int
}

private enum RuleMemoEntry {
    case inProgress
    case result([Int])
}

private enum TreeMemoEntry {
    case inProgress
    case result((Int, EBNFMatchNode)?)
}
