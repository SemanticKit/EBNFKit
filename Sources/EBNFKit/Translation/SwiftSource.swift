import SwiftBasicFormat
import SwiftSyntax
import SwiftSyntaxBuilder

/// The Swift translation of a ``Grammar``: a parser that reads the grammar's
/// language into a typed syntax tree, one Swift type per production.
///
/// The translation builds its declarations as swift-syntax nodes and writes
/// them formatted. It is deterministic: the same grammar and configuration
/// always give the same text. Everything it declares is in the namespace
/// `<name>Grammar`:
///
/// - Each terminal production (one after `@terminals`, or every production
///   of a grammar without that line) becomes a struct holding the text it
///   matched and where the text starts. Its static `matches(_:)` and
///   `longestMatch(in:at:)` match the production over characters, with the
///   minimal deterministic automaton of its expression when the expression
///   is regular (``Automaton``) and by following every position the
///   expression can reach when it refers back to itself; its
///   `init?(parsing:)` reads a whole string as the production, and it has a
///   member for each production its expression refers to, holding the
///   parts of its text those productions matched.
/// - In a grammar with terminals, the productions before `@terminals` are
///   read over terminals. A tokenizer takes, at each position, the longest
///   terminal or string of those productions (RDF 1.2 Turtle §6.5: "When
///   tokenizing the input and choosing grammar rules, the longest match is
///   chosen"); a production whose expression is a choice becomes an enum
///   with a case for each alternative, and any other production a class
///   with a member for each part of its expression that holds something.
///   Each has a static `parse(_:)`. The parser keeps the first alternative
///   of a choice that matches and repeats an item while it matches, so the
///   translation first checks that the next terminals decide each of those
///   choices (``Lookahead``): then the parser reads exactly the grammar's
///   language.
///
/// What a specification states in prose rather than EBNF stays with the
/// code that uses the translation. Before each terminal the tokenizer skips
/// what `<name>Grammar.trivia(_:from:)` returns, a function the code using
/// a grammar with terminals declares: white space and comments, as each
/// specification defines them.
public struct SwiftSource: Sendable, Hashable {
    /// The Swift source text.
    public let text: String

    /// Translates `grammar`.
    ///
    /// - Throws: ``TranslationError`` when a symbol is not defined, a
    ///   production that is read over terminals uses a character class or
    ///   `-`, a terminal refers to a production read over terminals, the
    ///   next two terminals do not decide a choice, `?`, `*` or `+` of the
    ///   productions read over terminals, or two symbols would have the same
    ///   Swift name.
    public init(grammar: Grammar, configuration: GrammarConfiguration) throws(TranslationError) {
        var translation = try Translation(grammar: grammar, configuration: configuration)
        text = try translation.sourceFile().formatted().description
    }
}

/// The state of one translation.
private struct Translation {
    let configuration: GrammarConfiguration
    let namespace: String
    /// The productions translated, in grammar order.
    let productions: [Production]
    let bySymbol: [String: Production]
    /// The symbols read over terminals.
    let tokenLevel: Set<String>
    /// The terminals the tokenizer recognizes, in grammar order.
    let lexerTerminals: [String]
    /// The strings the tokenizer recognizes, in order of first appearance.
    let literals: [Literal]
    /// What the next terminals tell the parser.
    let lookahead: Lookahead

    struct Literal: Hashable {
        var text: String
        var caseInsensitive: Bool
    }

    /// What one expression of a production read over terminals holds.
    struct Part {
        /// Its Swift type.
        var type: TypeSyntax
        /// The member name it is held under.
        var name: String
        /// The labels and types of its parts, when it is a tuple.
        var fields: [(name: String, type: TypeSyntax)]?
    }

    /// A parsing method, and what it returns besides failure.
    struct Compiled {
        var method: String
        var part: Part?
    }

    /// The first characters of each production matched over characters.
    let firstCharacters: [String: FirstCharacters]

    var parserMethods: [FunctionDeclSyntax] = []
    var nested: [String: [EnumDeclSyntax]] = [:]
    var nestedNames: [String: Set<String>] = [:]
    var methodCounter = 0

    static let reserved: Set<String> = ["Location", "SyntaxError", "Token", "Kind", "Lexer", "Parser", "Step", "Trace", "Symbol"]

    init(grammar: Grammar, configuration: GrammarConfiguration) throws(TranslationError) {
        self.configuration = configuration
        namespace = configuration.name + "Grammar"

        var bySymbol: [String: Production] = [:]
        for production in grammar.productions where bySymbol[production.symbol] == nil {
            bySymbol[production.symbol] = production
        }
        self.bySymbol = bySymbol

        // The productions translated: the roots and what they refer to.
        var selected: Set<String> = []
        var pending = configuration.roots ?? grammar.productions.map(\.symbol)
        while let symbol = pending.popLast() {
            guard selected.insert(symbol).inserted else { continue }
            guard let production = bySymbol[symbol] else {
                throw TranslationError("'\(symbol)' is used but not defined")
            }
            pending.append(contentsOf: production.expression.symbols)
        }
        var seen: Set<String> = []
        productions = grammar.productions.filter { selected.contains($0.symbol) && seen.insert($0.symbol).inserted }

        let tokenLevel = Set(productions.filter { !$0.isTerminal && grammar.hasTerminals }.map(\.symbol))
        self.tokenLevel = tokenLevel

        var typeNames: [String: String] = [:]
        for production in productions {
            let name = SwiftName.type(production.symbol)
            if Self.reserved.contains(name) {
                throw TranslationError("'\(production.symbol)' would be named \(name), which the translation uses")
            }
            if let other = typeNames.updateValue(production.symbol, forKey: name.lowercased()) {
                throw TranslationError("'\(other)' and '\(production.symbol)' would have the same Swift name")
            }
        }

        var terminals: Set<String> = []
        var literals: [Literal] = []
        for production in productions {
            if tokenLevel.contains(production.symbol) {
                try Self.checkTokenLevel(production.expression, in: production.symbol, tokenLevel: tokenLevel)
                for symbol in production.expression.symbols where !tokenLevel.contains(symbol) {
                    terminals.insert(symbol)
                }
                Self.collectLiterals(production.expression, caseInsensitive: configuration.caseInsensitiveStrings, into: &literals)
            } else {
                for symbol in production.expression.symbols where tokenLevel.contains(symbol) {
                    throw TranslationError("the terminal '\(production.symbol)' refers to '\(symbol)', which is read over terminals")
                }
            }
        }
        lexerTerminals = productions.map(\.symbol).filter { terminals.contains($0) }
        self.literals = literals
        firstCharacters = FirstCharacters.of(productions.filter { !tokenLevel.contains($0.symbol) }, bySymbol: bySymbol)

        var tokenProductions: [String: Expression] = [:]
        for production in productions where tokenLevel.contains(production.symbol) {
            tokenProductions[production.symbol] = production.expression
        }
        lookahead = Lookahead(productions: tokenProductions, caseInsensitiveStrings: configuration.caseInsensitiveStrings)
        try lookahead.check()
    }

    static func checkTokenLevel(_ expression: Expression, in symbol: String, tokenLevel: Set<String>) throws(TranslationError) {
        switch expression {
        case .symbol, .string:
            return
        case .character, .characterClass:
            throw TranslationError("'\(symbol)' is read over terminals but matches a character: \(expression.notation)")
        case .difference:
            throw TranslationError("'\(symbol)' is read over terminals but uses '-': \(expression.notation)")
        case .sequence(let items), .choice(let items):
            for item in items { try checkTokenLevel(item, in: symbol, tokenLevel: tokenLevel) }
        case .optional(let item), .zeroOrMore(let item), .oneOrMore(let item):
            try checkTokenLevel(item, in: symbol, tokenLevel: tokenLevel)
        }
    }

    static func collectLiterals(_ expression: Expression, caseInsensitive: Expression.Quote?, into literals: inout [Literal]) {
        switch expression {
        case .string(let text, let quote):
            let literal = Literal(text: text, caseInsensitive: quote == caseInsensitive)
            if !literals.contains(literal) { literals.append(literal) }
        case .symbol, .character, .characterClass:
            return
        case .sequence(let items), .choice(let items):
            for item in items { collectLiterals(item, caseInsensitive: caseInsensitive, into: &literals) }
        case .optional(let item), .zeroOrMore(let item), .oneOrMore(let item):
            collectLiterals(item, caseInsensitive: caseInsensitive, into: &literals)
        case .difference(let left, let right):
            collectLiterals(left, caseInsensitive: caseInsensitive, into: &literals)
            collectLiterals(right, caseInsensitive: caseInsensitive, into: &literals)
        }
    }

    // MARK: - Names and types

    /// The namespace, as a type.
    var namespaceType: TypeSyntax { .named(namespace) }

    /// The type of `symbol`'s production, in the namespace.
    func qualified(_ symbol: String) -> TypeSyntax {
        namespaceType.member(SwiftName.type(symbol))
    }

    static var int: TypeSyntax { .swift("Int") }
    static var bool: TypeSyntax { .swift("Bool") }
    static var string: TypeSyntax { .swift("String") }
    static var uint32: TypeSyntax { .swift("UInt32") }

    // MARK: - The source file

    mutating func sourceFile() throws(TranslationError) -> SourceFileSyntax {
        var declarations: [DeclSyntax] = []
        var header = [
            "The Swift translation of the \(configuration.name) grammar, written by",
            "EBNFTranslator from the EBNF of:",
        ]
        for document in configuration.documents {
            header.append("  \(document.url)")
            header.append("    retrieved \(document.retrieved), SHA-256 \(document.sha256)")
        }
        header.append("Do not edit it: it is translated again from the grammar on every build.")
        declarations.append(DeclSyntax(EnumDeclSyntax(
            leadingTrivia: Trivia.comment(header) + .newlines(1) + .documentation("The \(configuration.name) grammar: one type for each of its productions."),
            name: .name(namespace),
            memberBlock: MemberBlockSyntax(members: [])
        )))
        declarations.append(DeclSyntax(supportDeclarations()))

        for production in productions where !tokenLevel.contains(production.symbol) {
            declarations.append(DeclSyntax(try terminalDeclaration(production)))
        }

        if !tokenLevel.isEmpty {
            var nodeDeclarations: [DeclSyntax] = []
            for production in productions where tokenLevel.contains(production.symbol) {
                nodeDeclarations += try nodeDeclaration(production)
            }
            declarations.append(DeclSyntax(tokenDeclarations()))
            declarations += nodeDeclarations
            for owner in nested.keys.sorted() {
                let enums = nested[owner, default: []]
                declarations.append(DeclSyntax(ExtensionDeclSyntax(extendedType: namespaceType.member(owner)) {
                    for declaration in enums { declaration }
                }))
            }
            declarations.append(DeclSyntax(parserDeclaration()))
        }
        return SourceFileSyntax {
            for declaration in declarations { declaration }
        }
    }

    // MARK: - Support

    /// `Location`, `SyntaxError`, `Symbol`, `Step` and `Trace`.
    func supportDeclarations() -> ExtensionDeclSyntax {
        let symbols = productions.filter { !tokenLevel.contains($0.symbol) }.map { SwiftName.type($0.symbol) }
        let location = TypeSyntax.named("Location")
        let scalar = TypeSyntax.swift("Unicode").member("Scalar")
        return ExtensionDeclSyntax(extendedType: namespaceType) {
            StructDeclSyntax(
                leadingTrivia: .documentation(
                    "A position in a document: the offset in Unicode scalars, and",
                    "the 1-based line and column, in Unicode scalars, a line ending",
                    "at each line feed."
                ),
                name: .name("Location"),
                inheritanceClause: .swift("Sendable", "Hashable")
            ) {
                VariableDeclSyntax.binding("offset", Self.int)
                VariableDeclSyntax.binding("line", Self.int)
                VariableDeclSyntax.binding("column", Self.int)
                VariableDeclSyntax.binding(
                    "start", nil,
                    ExprSyntax.named("Location").call(labeled: [("offset", .int(0)), ("line", .int(1)), ("column", .int(1))]),
                    modifiers: .static,
                    leadingTrivia: .documentation("The start of a document.")
                )
                FunctionDeclSyntax(
                    leadingTrivia: .documentation("The position after `scalars`, which start here."),
                    name: .name("advanced"),
                    signature: .of([.parameter("over", "scalars", .swift("ArraySlice", scalar))], returning: location)
                ) {
                    VariableDeclSyntax.binding("line", nil, .named("line"), mutable: true)
                    VariableDeclSyntax.binding("column", nil, .named("column"), mutable: true)
                    ForStmtSyntax(pattern: IdentifierPatternSyntax(identifier: .name("scalar")), sequence: ExprSyntax.named("scalars")) {
                        IfExprSyntax(
                            conditions: .expression(ExprSyntax.named("scalar").dot("value").infix("==", .codePoint(0x0A))),
                            elseKeyword: .keyword(.else),
                            elseBody: .codeBlock(CodeBlockSyntax {
                                ExprSyntax.named("column").infix("+=", .int(1))
                            })
                        ) {
                            ExprSyntax.named("line").infix("+=", .int(1))
                            ExprSyntax.named("column").assigned(.int(1))
                        }
                    }
                    StmtSyntax.return(ExprSyntax.named("Location").call(labeled: [
                        ("offset", ExprSyntax.named("offset").infix("+", ExprSyntax.named("scalars").dot("count"))),
                        ("line", .named("line")),
                        ("column", .named("column")),
                    ]))
                }
            }
            StructDeclSyntax(
                leadingTrivia: .documentation("A document that does not match the grammar."),
                name: .name("SyntaxError"),
                inheritanceClause: .swift("Error", "Sendable", "Hashable")
            ) {
                VariableDeclSyntax.binding("location", location, leadingTrivia: .documentation("Where the document stops matching."))
                VariableDeclSyntax.binding("message", Self.string, leadingTrivia: .documentation("What the grammar expected there."))
            }
            EnumDeclSyntax(
                leadingTrivia: .documentation("The productions matched over characters."),
                name: .name("Symbol"),
                inheritanceClause: .swift("Sendable", "Hashable")
            ) {
                if !symbols.isEmpty {
                    EnumCaseDeclSyntax {
                        for symbol in symbols { EnumCaseElementSyntax(name: .name(symbol)) }
                    }
                }
            }
            stepDeclaration()
            traceDeclaration()
        }
    }

    func stepDeclaration() -> StructDeclSyntax {
        let ints = Self.int.array
        let steps = TypeSyntax.named("Step").array
        return StructDeclSyntax(
            leadingTrivia: .documentation(
                "One way a production can match: where it ends, and the",
                "productions its expression refers to that it matched on the way."
            ),
            name: .name("Step"),
            inheritanceClause: .swift("Sendable")
        ) {
            VariableDeclSyntax.binding("end", Self.int)
            VariableDeclSyntax.binding("trace", TypeSyntax.named("Trace").optional)
            for (name, values, type, key) in [("uniqueEnds", "ends", ints, nil), ("unique", "steps", steps, "end")] as [(String, String, TypeSyntax, String?)] {
                FunctionDeclSyntax(
                    leadingTrivia: .documentation(key == nil ? "`ends` without a second copy of an end." : "`steps` without a second step to the same end."),
                    modifiers: .static,
                    name: .name(name),
                    signature: .of([.parameter(nil, values, type)], returning: type)
                ) {
                    GuardStmtSyntax(conditions: .expression(ExprSyntax.named(values).dot("count").infix(">", .int(1)))) {
                        StmtSyntax.return(.named(values))
                    }
                    VariableDeclSyntax.binding("seen", nil, ExprSyntax.named("Swift").dot("Set").subscriptedType(Self.int).call(), mutable: true)
                    StmtSyntax.return(ExprSyntax.named(values).dot("filter").call(trailing: ExprSyntax.closure {
                        ExprSyntax.named("seen").dot("insert").call(key.map { ExprSyntax.firstArgument.dot($0) } ?? .firstArgument).dot("inserted")
                    }))
                }
            }
            FunctionDeclSyntax(
                leadingTrivia: .documentation("Whether `scalars` has `literal` at `offset`."),
                modifiers: .static,
                name: .name("has"),
                signature: .of([
                    .parameter(nil, "scalars", .scalars),
                    .parameter(nil, "offset", Self.int),
                    .parameter(nil, "literal", Self.uint32.array),
                ], returning: Self.bool)
            ) {
                literalBoundsGuard()
                ForStmtSyntax(
                    pattern: indexAndValue,
                    sequence: ExprSyntax.named("literal").dot("enumerated").call(),
                    whereClause: WhereClauseSyntax(condition: scalarAtOffsetIndex.dot("value").infix("!=", .named("value")))
                ) {
                    StmtSyntax.return(.bool(false))
                }
                StmtSyntax.return(.bool(true))
            }
        }
    }

    /// `guard offset + literal.count <= scalars.count else { return false }`.
    func literalBoundsGuard() -> GuardStmtSyntax {
        GuardStmtSyntax(conditions: .expression(
            ExprSyntax.named("offset").infix("+", ExprSyntax.named("literal").dot("count"))
                .infix("<=", ExprSyntax.named("scalars").dot("count"))
        )) {
            StmtSyntax.return(.bool(false))
        }
    }

    /// `(index, value)`.
    var indexAndValue: TuplePatternSyntax {
        TuplePatternSyntax {
            TuplePatternElementSyntax(pattern: IdentifierPatternSyntax(identifier: .name("index")))
            TuplePatternElementSyntax(pattern: IdentifierPatternSyntax(identifier: .name("value")))
        }
    }

    /// `scalars[offset + index]`.
    var scalarAtOffsetIndex: ExprSyntax {
        ExprSyntax.named("scalars").subscripted(ExprSyntax.named("offset").infix("+", .named("index")))
    }

    func traceDeclaration() -> ClassDeclSyntax {
        let trace = TypeSyntax.named("Trace")
        let symbol = TypeSyntax.named("Symbol")
        let location = TypeSyntax.named("Location")
        let parts = TypeSyntax.tuple([("text", Self.string), ("location", location)]).array
        let fields: [(String, TypeSyntax)] = [("symbol", symbol), ("start", Self.int), ("end", Self.int), ("previous", trace.optional)]
        return ClassDeclSyntax(
            leadingTrivia: .documentation(
                "The matches of referred productions on the way to a step, the",
                "last first."
            ),
            modifiers: [DeclModifierSyntax(name: .keyword(.final))],
            name: .name("Trace"),
            inheritanceClause: .swift("Sendable")
        ) {
            for (name, type) in fields { VariableDeclSyntax.binding(name, type) }
            InitializerDeclSyntax(signature: .of(fields.map { .parameter(nil, $0.0, $0.1) })) {
                for (name, _) in fields {
                    ExprSyntax(MemberAccessExprSyntax(base: DeclReferenceExprSyntax(baseName: .keyword(.self)), declName: DeclReferenceExprSyntax(baseName: .name(name))))
                        .assigned(.named(name))
                }
            }
            FunctionDeclSyntax(
                leadingTrivia: .documentation(
                    "The text and location of each match of `symbol` in",
                    "`scalars`, which start at `location`, in document order."
                ),
                name: .name("parts"),
                signature: .of([
                    .parameter(nil, "symbol", symbol),
                    .parameter("in", "scalars", .scalars),
                    .parameter("at", "location", location),
                ], returning: parts)
            ) {
                VariableDeclSyntax.binding("matches", trace.array, .array([]), mutable: true)
                VariableDeclSyntax.binding("trace", trace.optional, ExprSyntax(DeclReferenceExprSyntax(baseName: .keyword(.self))), mutable: true)
                WhileStmtSyntax(conditions: [.binding("current", .named("trace"))]) {
                    IfExprSyntax(conditions: .expression(ExprSyntax.named("current").dot("symbol").infix("==", .named("symbol")))) {
                        ExprSyntax.named("matches").dot("append").call(.named("current"))
                    }
                    ExprSyntax.named("trace").assigned(ExprSyntax.named("current").dot("previous"))
                }
                let match = ExprSyntax.firstArgument
                let text = Self.text(of: ExprSyntax.named("scalars").subscripted(match.dot("start").infix("..<", match.dot("end"))))
                let start = ExprSyntax.named("location").dot("advanced").call(labeled: [
                    ("over", ExprSyntax.named("scalars").subscripted(ExprSyntax.int(0).infix("..<", match.dot("start")))),
                ])
                StmtSyntax.return(ExprSyntax.named("matches").dot("reversed").call().dot("map").call(trailing: ExprSyntax.closure {
                    ExprSyntax.tuple([(nil, text), (nil, start)])
                }))
            }
        }
    }

    /// `Swift.String(Swift.String.UnicodeScalarView(scalars))`.
    static func text(of scalars: ExprSyntax) -> ExprSyntax {
        let string = ExprSyntax.named("Swift").dot("String")
        return string.call(string.dot("UnicodeScalarView").call(scalars))
    }

    // MARK: - Terminals

    func terminalDeclaration(_ production: Production) throws(TranslationError) -> ExtensionDeclSyntax {
        let type = SwiftName.type(production.symbol)
        var emitter = MatcherEmitter(bySymbol: bySymbol, firstCharacters: firstCharacters)
        // A regular production is matched by its automaton; one that refers
        // back to itself, by following the positions its expression reaches.
        let endsBody: CodeBlockItemListSyntax
        if let automaton = Automaton(production.expression, bySymbol: bySymbol) {
            endsBody = Self.automatonBody(automaton)
        } else {
            endsBody = try emitter.body(for: production.expression, mode: .ends)
        }
        let direct = Self.directSymbols(production.expression)
        let stepsBody = direct.isEmpty ? nil : try emitter.body(for: production.expression, mode: .steps)
        let first = firstCharacters[production.symbol] ?? .unknown
        let location = TypeSyntax.named("Location")
        let text = ExprSyntax.named("text")
        let scalarsOfText = ExprSyntax.named("Swift").dot("Array").call(text.dot("unicodeScalars"))
        let characters: [FunctionParameterSyntax] = [.parameter(nil, "s", .scalars), .parameter(nil, "offset", Self.int)]

        let members = MemberBlockItemListSyntax {
            VariableDeclSyntax.binding("text", Self.string, leadingTrivia: .documentation("The text the production matched."))
            VariableDeclSyntax.binding("location", location, leadingTrivia: .documentation("Where the text starts."))
            InitializerDeclSyntax(signature: .of([.parameter("text", "text", Self.string), .parameter("location", "location", location)])) {
                ExprSyntax(MemberAccessExprSyntax(base: DeclReferenceExprSyntax(baseName: .keyword(.self)), declName: DeclReferenceExprSyntax(baseName: .name("text")))).assigned(text)
                ExprSyntax(MemberAccessExprSyntax(base: DeclReferenceExprSyntax(baseName: .keyword(.self)), declName: DeclReferenceExprSyntax(baseName: .name("location")))).assigned(.named("location"))
            }
            InitializerDeclSyntax(
                leadingTrivia: .documentation("`text` as a match of the production, when all of it matches."),
                optionalMark: .postfixQuestionMarkToken(),
                signature: .of([.parameter("parsing", "text", Self.string)])
            ) {
                GuardStmtSyntax(conditions: .expression(ExprSyntax.selfType.dot("matches").call(text))) {
                    StmtSyntax.return(.nil)
                }
                ExprSyntax(MemberAccessExprSyntax(base: DeclReferenceExprSyntax(baseName: .keyword(.self)), declName: DeclReferenceExprSyntax(baseName: .keyword(.`init`))))
                    .call(labeled: [("text", text), ("location", .dot("start"))])
            }
            FunctionDeclSyntax(
                leadingTrivia: .documentation("Whether all of `text` matches the production."),
                modifiers: .static,
                name: .name("matches"),
                signature: .of([.parameter(nil, "text", Self.string)], returning: Self.bool)
            ) {
                VariableDeclSyntax.binding("scalars", nil, scalarsOfText)
                StmtSyntax.return(ExprSyntax.named("ends").call(.named("scalars"), .int(0)).dot("contains").call(ExprSyntax.named("scalars").dot("count")))
            }
            FunctionDeclSyntax(
                leadingTrivia: .documentation("Whether a match of the production can start with the character", "`value`."),
                modifiers: .static,
                name: .name("starts"),
                signature: .of([.parameter(nil, "value", Self.uint32)], returning: Self.bool)
            ) {
                Self.startsBody(first)
            }
            FunctionDeclSyntax(
                leadingTrivia: .documentation("The end of the longest match of the production at `offset`."),
                modifiers: .static,
                name: .name("longestMatch"),
                signature: .of([.parameter("in", "scalars", .scalars), .parameter("at", "offset", Self.int)], returning: Self.int.optional)
            ) {
                StmtSyntax.return(ExprSyntax.named("ends").call(.named("scalars"), .named("offset")).dot("max").call())
            }
            if !direct.isEmpty {
                VariableDeclSyntax.computed(
                    "trace", TypeSyntax.named("Trace").optional,
                    modifiers: .private,
                    leadingTrivia: .documentation("The trace of the productions the text matched on the way.")
                ) {
                    VariableDeclSyntax.binding("scalars", nil, scalarsOfText)
                    StmtSyntax.return(
                        ExprSyntax.selfType.dot("match").call(.named("scalars"), .int(0)).dot("first")
                            .call(trailing: ExprSyntax.closure { ExprSyntax.firstArgument.dot("end").infix("==", ExprSyntax.named("scalars").dot("count")) })
                            .chained.dot("trace")
                    )
                }
                for symbol in direct {
                    if let member = partMember(symbol, in: production.expression) { member }
                }
            }
            FunctionDeclSyntax(
                leadingTrivia: .documentation("The ends of the matches of the production from `offset`."),
                modifiers: .static,
                name: .name("ends"),
                signature: .of(characters, returning: Self.int.array)
            ) {
                endsBody
            }
            if let stepsBody {
                FunctionDeclSyntax(
                    leadingTrivia: .documentation(
                        "The matches of the production from `offset`, each with where the",
                        "productions it refers to matched on the way."
                    ),
                    modifiers: .static,
                    name: .name("match"),
                    signature: .of(characters, returning: TypeSyntax.named("Step").array)
                ) {
                    stepsBody
                }
            }
            for (index, string) in emitter.strings.enumerated() {
                VariableDeclSyntax.binding("string" + String(index), Self.uint32.array, .array(string.map(ExprSyntax.codePoint)), modifiers: .static)
            }
            for (index, characterClass) in emitter.classes.enumerated() {
                FunctionDeclSyntax(
                    leadingTrivia: .documentation("`\(Expression.characterClass(characterClass).notation)`"),
                    modifiers: .static,
                    name: .name("class" + String(index)),
                    signature: .of([.parameter(nil, "value", Self.uint32)], returning: Self.bool)
                ) {
                    if characterClass.ranges.isEmpty {
                        StmtSyntax.return(.bool(characterClass.isNegated))
                    } else {
                        SwitchExprSyntax(subject: ExprSyntax.named("value")) {
                            SwitchCaseSyntax.matching(characterClass.ranges.map(ExprSyntax.codePoints)) {
                                StmtSyntax.return(.bool(!characterClass.isNegated))
                            }
                            SwitchCaseSyntax.otherwise {
                                StmtSyntax.return(.bool(characterClass.isNegated))
                            }
                        }
                    }
                }
            }
        }
        return ExtensionDeclSyntax(extendedType: namespaceType) {
            StructDeclSyntax(
                leadingTrivia: .documentation("`\(production.symbol) ::= \(production.expression.notation)`"),
                name: .name(type),
                inheritanceClause: .swift("Sendable", "Hashable"),
                memberBlock: MemberBlockSyntax(members: members)
            )
        }
    }

    /// The member of a terminal's struct that holds the parts of its text
    /// `symbol` matched, `nil` when its expression never holds one.
    func partMember(_ symbol: String, in expression: Expression) -> VariableDeclSyntax? {
        let count = Self.occurrences(of: symbol, in: expression)
        guard count.max > 0 else { return nil }
        let part = SwiftName.type(symbol)
        let match = ExprSyntax.firstArgument
        let all = ExprSyntax.named("trace").chained.dot("parts").call(labeled: [
            (nil, .dot(part)),
            ("in", ExprSyntax.named("Swift").dot("Array").call(ExprSyntax.named("text").dot("unicodeScalars"))),
            ("at", .named("location")),
        ]).infix("??", .array([])).parenthesized.dot("map").call(trailing: ExprSyntax.closure {
            ExprSyntax.named(part).call(labeled: [("text", match.dot("text")), ("location", match.dot("location"))])
        })
        let member: String
        let type: TypeSyntax
        let value: ExprSyntax
        let documentation: Trivia
        if count.max == 1 && count.min == 1 {
            member = SwiftName.member(symbol)
            type = .named(part)
            value = all.subscripted(.int(0))
            documentation = .documentation("The `\(symbol)` the text holds.")
        } else if count.max == 1 {
            member = SwiftName.member(symbol)
            type = TypeSyntax.named(part).optional
            value = all.dot("first")
            documentation = .documentation("The `\(symbol)` the text holds, if any.")
        } else {
            member = SwiftName.plural(SwiftName.member(symbol))
            type = TypeSyntax.named(part).array
            value = all
            documentation = .documentation("The `\(symbol)`s the text holds, in order.")
        }
        let canBeAbsent = count.min == 0 && firstCharacters[symbol]?.mustAlwaysTry == false
        return VariableDeclSyntax.computed(member, type, leadingTrivia: documentation) {
            if canBeAbsent {
                // No character of the text can start one: none is there.
                GuardStmtSyntax(conditions: .expression(
                    ExprSyntax.named("text").dot("unicodeScalars").dot("contains")
                        .call(labeled: [("where", ExprSyntax(ExprSyntax.closure {
                            ExprSyntax.named(part).dot("starts").call(ExprSyntax.firstArgument.dot("value"))
                        }))])
                )) {
                    StmtSyntax.return(count.max == 1 ? .nil : .array([]))
                }
            }
            StmtSyntax.return(value)
        }
    }

    /// The body of `starts(_:)`: whether `value` is in one of the classes a
    /// match can start with.
    static func startsBody(_ first: FirstCharacters) -> CodeBlockItemListSyntax {
        guard !first.isUnbounded else { return [CodeBlockItemSyntax(item: .stmt(.return(.bool(true))))] }
        let positive = first.classes.filter { !$0.isNegated }.flatMap(\.ranges)
        let negative = first.classes.filter(\.isNegated)
        return CodeBlockItemListSyntax {
            if !positive.isEmpty {
                SwitchExprSyntax(subject: ExprSyntax.named("value")) {
                    SwitchCaseSyntax.matching(positive.map(ExprSyntax.codePoints)) { StmtSyntax.return(.bool(true)) }
                    SwitchCaseSyntax.otherwise { StmtSyntax.break }
                }
            }
            for characterClass in negative {
                if characterClass.ranges.isEmpty {
                    StmtSyntax.return(.bool(true))
                } else {
                    SwitchExprSyntax(subject: ExprSyntax.named("value")) {
                        SwitchCaseSyntax.matching(characterClass.ranges.map(ExprSyntax.codePoints)) { StmtSyntax.break }
                        SwitchCaseSyntax.otherwise { StmtSyntax.return(.bool(true)) }
                    }
                }
            }
            StmtSyntax.return(.bool(false))
        }
    }

    /// The body of `ends(_:_:)` for a production matched by `automaton`:
    /// it reads the characters from `offset` and records each position where
    /// the automaton accepts.
    static func automatonBody(_ automaton: Automaton) -> CodeBlockItemListSyntax {
        let accepting = automaton.accepting.indices.filter { automaton.accepting[$0] }
        let state = ExprSyntax.named("state")
        return CodeBlockItemListSyntax {
            VariableDeclSyntax.binding("ends", int.array, .array([]), mutable: true)
            VariableDeclSyntax.binding("state", nil, .int(0), mutable: true)
            VariableDeclSyntax.binding("index", nil, .named("offset"), mutable: true)
            WhileStmtSyntax(conditions: .expression(.bool(true))) {
                if !accepting.isEmpty {
                    SwitchExprSyntax(subject: state) {
                        SwitchCaseSyntax.matching(accepting.map(ExprSyntax.int)) {
                            ExprSyntax.named("ends").dot("append").call(.named("index"))
                        }
                        SwitchCaseSyntax.otherwise { StmtSyntax.break }
                    }
                }
                GuardStmtSyntax(conditions: .expression(ExprSyntax.named("index").infix("<", ExprSyntax.named("s").dot("count")))) {
                    StmtSyntax.return(.named("ends"))
                }
                VariableDeclSyntax.binding("value", nil, ExprSyntax.named("s").subscripted(.named("index")).dot("value"))
                SwitchExprSyntax(subject: state) {
                    for (index, row) in automaton.transitions.enumerated() where !row.isEmpty {
                        SwitchCaseSyntax.matching([.int(index)]) {
                            SwitchExprSyntax(subject: ExprSyntax.named("value")) {
                                for target in Self.targets(row) {
                                    SwitchCaseSyntax.matching(row.filter { $0.target == target }.map { ExprSyntax.codePoints($0.range) }) {
                                        state.assigned(.int(target))
                                    }
                                }
                                SwitchCaseSyntax.otherwise { StmtSyntax.return(.named("ends")) }
                            }
                        }
                    }
                    SwitchCaseSyntax.otherwise { StmtSyntax.return(.named("ends")) }
                }
                ExprSyntax.named("index").infix("+=", .int(1))
            }
        }
    }

    /// The states `row` leads to, in order of first appearance.
    static func targets(_ row: [Automaton.Transition]) -> [Int] {
        var targets: [Int] = []
        for transition in row where !targets.contains(transition.target) { targets.append(transition.target) }
        return targets
    }

    /// The symbols an expression refers to outside the right side of a
    /// `-`: the parts a match records.
    static func directSymbols(_ expression: Expression) -> [String] {
        var result: [String] = []
        func visit(_ expression: Expression) {
            switch expression {
            case .symbol(let name):
                if !result.contains(name) { result.append(name) }
            case .string, .character, .characterClass:
                break
            case .sequence(let items), .choice(let items):
                items.forEach(visit)
            case .optional(let item), .zeroOrMore(let item), .oneOrMore(let item):
                visit(item)
            case .difference(let left, _):
                visit(left)
            }
        }
        visit(expression)
        return result
    }

    /// How many times a match of `expression` holds a match of `symbol`:
    /// at least `min`, at most `max`, where 2 stands for more than one.
    static func occurrences(of symbol: String, in expression: Expression) -> (min: Int, max: Int) {
        switch expression {
        case .symbol(let name):
            return name == symbol ? (1, 1) : (0, 0)
        case .string, .character, .characterClass:
            return (0, 0)
        case .sequence(let items):
            return items.map { occurrences(of: symbol, in: $0) }.reduce((0, 0)) { (min($0.0 + $1.0, 2), min($0.1 + $1.1, 2)) }
        case .choice(let options):
            let counts = options.map { occurrences(of: symbol, in: $0) }
            return (counts.map(\.min).min() ?? 0, counts.map(\.max).max() ?? 0)
        case .optional(let item):
            return (0, occurrences(of: symbol, in: item).max)
        case .zeroOrMore(let item):
            return (0, occurrences(of: symbol, in: item).max > 0 ? 2 : 0)
        case .oneOrMore(let item):
            let count = occurrences(of: symbol, in: item)
            return (count.min, count.max > 0 ? 2 : 0)
        case .difference(let left, _):
            return occurrences(of: symbol, in: left)
        }
    }

    // MARK: - Tokens

    /// `Kind`, `Token` and `Lexer`.
    func tokenDeclarations() -> ExtensionDeclSyntax {
        let kind = TypeSyntax.named("Kind")
        let token = TypeSyntax.named("Token")
        let location = TypeSyntax.named("Location")
        let s = ExprSyntax.named("s")
        let offset = ExprSyntax.named("offset")
        let end = ExprSyntax.named("end")
        let span = s.subscripted(offset.infix("..<", end))
        return ExtensionDeclSyntax(extendedType: namespaceType) {
            EnumDeclSyntax(
                leadingTrivia: .documentation("A terminal or string of the productions read over terminals."),
                name: .name("Kind"),
                inheritanceClause: .swift("Sendable", "Hashable")
            ) {
                if !lexerTerminals.isEmpty {
                    EnumCaseDeclSyntax {
                        for terminal in lexerTerminals { EnumCaseElementSyntax(name: .name(SwiftName.type(terminal))) }
                    }
                }
                EnumCaseDeclSyntax(leadingTrivia: .documentation("The string at this index of `Lexer.literals`.")) {
                    EnumCaseElementSyntax(name: .name("literal"), parameterClause: EnumCaseParameterClauseSyntax(parameters: [EnumCaseParameterSyntax(type: Self.int)]))
                }
            }
            StructDeclSyntax(
                leadingTrivia: .documentation("A terminal or string read from a document."),
                name: .name("Token"),
                inheritanceClause: .swift("Sendable")
            ) {
                VariableDeclSyntax.binding("kind", kind)
                VariableDeclSyntax.binding("text", Self.string)
                VariableDeclSyntax.binding("location", location)
            }
            EnumDeclSyntax(
                leadingTrivia: .documentation(
                    "Splits a document into tokens, the longest match at each",
                    "position, after what `\(namespace).trivia(_:from:)` skips."
                ),
                name: .name("Lexer")
            ) {
                VariableDeclSyntax.binding(
                    "literals", Self.string.array, ExprSyntax(literal: literals.map(\.text)),
                    modifiers: .static,
                    leadingTrivia: .documentation("The strings of the productions read over terminals.")
                )
                VariableDeclSyntax.binding(
                    "literalScalars", Self.uint32.array.array, .array(literals.map { .array($0.text.unicodeScalars.map { .codePoint($0.value) }) }),
                    modifiers: .static,
                    leadingTrivia: .documentation("The code points of each string.")
                )
                VariableDeclSyntax.binding(
                    "caseInsensitive", Self.bool.array, .array(literals.map { .bool($0.caseInsensitive) }),
                    modifiers: .static,
                    leadingTrivia: .documentation("Whether each string matches without regard to case.")
                )
                FunctionDeclSyntax(
                    modifiers: .static,
                    name: .name("tokens"),
                    signature: .of(
                        [.parameter("in", "s", .scalars)],
                        returning: .tuple([("tokens", token.array), ("end", location)]),
                        throwing: .named("SyntaxError")
                    )
                ) {
                    VariableDeclSyntax.binding("tokens", token.array, .array([]), mutable: true)
                    VariableDeclSyntax.binding("offset", nil, .int(0), mutable: true)
                    VariableDeclSyntax.binding("location", nil, ExprSyntax.named("Location").dot("start"), mutable: true)
                    WhileStmtSyntax(conditions: .expression(.bool(true))) {
                        VariableDeclSyntax.binding("next", nil, ExprSyntax.named(namespace).dot("trivia").call(labeled: [(nil, s), ("from", offset)]))
                        ExprSyntax.named("location").assigned(ExprSyntax.named("location").dot("advanced").call(labeled: [("over", s.subscripted(offset.infix("..<", .named("next"))))]))
                        offset.assigned(.named("next"))
                        GuardStmtSyntax(conditions: .expression(offset.infix("<", s.dot("count")))) {
                            StmtSyntax.return(.tuple([(nil, .named("tokens")), (nil, .named("location"))]))
                        }
                        VariableDeclSyntax.binding("end", nil, offset, mutable: true)
                        VariableDeclSyntax.binding("kind", kind.optional, mutable: true)
                        let scalars = ExprSyntax.named("literalScalars").subscripted(.named("index"))
                        ForStmtSyntax(
                            pattern: IdentifierPatternSyntax(identifier: .name("index")),
                            sequence: ExprSyntax.named("literals").dot("indices"),
                            whereClause: WhereClauseSyntax(condition: offset.infix("+", scalars.dot("count")).infix(">", end).infix(
                                "&&",
                                ExprSyntax.named("has").call(s, offset, scalars, ExprSyntax.named("caseInsensitive").subscripted(.named("index")))
                            ))
                        ) {
                            end.assigned(offset.infix("+", scalars.dot("count")))
                            ExprSyntax.named("kind").assigned(ExprSyntax.dot("literal").call(.named("index")))
                        }
                        for terminal in lexerTerminals {
                            let type = ExprSyntax.named(SwiftName.type(terminal))
                            IfExprSyntax(conditions: ConditionElementListSyntax {
                                if firstCharacters[terminal]?.mustAlwaysTry == false {
                                    ConditionElementSyntax.expression(type.dot("starts").call(s.subscripted(offset).dot("value")))
                                }
                                ConditionElementSyntax.binding("match", type.dot("longestMatch").call(labeled: [("in", s), ("at", offset)]))
                                ConditionElementSyntax.expression(ExprSyntax.named("match").infix(">", end))
                            }) {
                                end.assigned(.named("match"))
                                ExprSyntax.named("kind").assigned(.dot(SwiftName.type(terminal)))
                            }
                        }
                        GuardStmtSyntax(conditions: [.binding("kind")]) {
                            StmtSyntax.throw(ExprSyntax.named("SyntaxError").call(labeled: [
                                ("location", .named("location")),
                                ("message", ExprSyntax.string("unexpected character U+").infix("+", ExprSyntax.named("Swift").dot("String").call(labeled: [
                                    (nil, s.subscripted(offset).dot("value")), ("radix", .int(16)), ("uppercase", .bool(true)),
                                ]))),
                            ]))
                        }
                        ExprSyntax.named("tokens").dot("append").call(ExprSyntax.named("Token").call(labeled: [
                            ("kind", .named("kind")), ("text", Self.text(of: span)), ("location", .named("location")),
                        ]))
                        ExprSyntax.named("location").assigned(ExprSyntax.named("location").dot("advanced").call(labeled: [("over", span)]))
                        offset.assigned(end)
                    }
                }
                FunctionDeclSyntax(
                    leadingTrivia: .documentation("Whether `scalars` has `literal` at `offset`, without regard to case when `caseInsensitive`."),
                    modifiers: .static,
                    name: .name("has"),
                    signature: .of([
                        .parameter(nil, "scalars", .scalars),
                        .parameter(nil, "offset", Self.int),
                        .parameter(nil, "literal", Self.uint32.array),
                        .parameter(nil, "caseInsensitive", Self.bool),
                    ], returning: Self.bool)
                ) {
                    literalBoundsGuard()
                    ForStmtSyntax(
                        pattern: indexAndValue,
                        sequence: ExprSyntax.named("literal").dot("enumerated").call(),
                        whereClause: WhereClauseSyntax(condition: scalarAtOffsetIndex.dot("value").infix("!=", .named("value")))
                    ) {
                        let lowercased = { (scalar: ExprSyntax) in ExprSyntax.named("Swift").dot("String").call(scalar).dot("lowercased").call() }
                        GuardStmtSyntax(conditions: ConditionElementListSyntax {
                            ConditionElementSyntax.expression(.named("caseInsensitive"))
                            ConditionElementSyntax.binding("expected", ExprSyntax.named("Swift").dot("Unicode").dot("Scalar").call(.named("value")))
                            ConditionElementSyntax.expression(lowercased(scalarAtOffsetIndex).infix("==", lowercased(.named("expected"))))
                        }) {
                            StmtSyntax.return(.bool(false))
                        }
                    }
                    StmtSyntax.return(.bool(true))
                }
            }
        }
    }

    // MARK: - Productions read over terminals

    mutating func nodeDeclaration(_ production: Production) throws(TranslationError) -> [DeclSyntax] {
        let type = SwiftName.type(production.symbol)
        let documentation = Trivia.documentation("`\(production.symbol) ::= \(production.expression.notation)`")
        let declaration: DeclSyntax
        if case .choice(let options) = production.expression {
            let cases = try compileCases(options, owner: type)
            declaration = DeclSyntax(Self.enumDeclaration(type, cases: cases, leadingTrivia: documentation))
            parserMethods.append(choiceMethod(name: "parse" + type, type: .named(type), options: options, cases: cases))
        } else {
            let items: [Expression]
            if case .sequence(let parts) = production.expression { items = parts } else { items = [production.expression] }
            var compiled: [Compiled] = []
            for item in items { compiled.append(try compile(item, owner: type)) }
            let fields = Self.uniqueNames(compiled.compactMap(\.part))
            declaration = DeclSyntax(ClassDeclSyntax(
                leadingTrivia: documentation,
                modifiers: [DeclModifierSyntax(name: .keyword(.final))],
                name: .name(type),
                inheritanceClause: .swift("Sendable")
            ) {
                for field in fields { VariableDeclSyntax.binding(field.name, field.type) }
                InitializerDeclSyntax(signature: .of(fields.map { .parameter($0.name, $0.name, $0.type) })) {
                    for field in fields {
                        ExprSyntax(MemberAccessExprSyntax(base: DeclReferenceExprSyntax(baseName: .keyword(.self)), declName: DeclReferenceExprSyntax(baseName: .name(field.name))))
                            .assigned(.named(field.name))
                    }
                }
            })
            parserMethods.append(sequenceMethod(name: "parse" + type, type: .named(type), items: compiled) { values in
                ExprSyntax.named(type).call(labeled: zip(fields, values).map { ($0.name, $1) })
            })
        }
        let parse = ExtensionDeclSyntax(extendedType: qualified(production.symbol)) {
            FunctionDeclSyntax(
                leadingTrivia: .documentation("Reads all of `text` as `\(production.symbol)`."),
                modifiers: .static,
                name: .name("parse"),
                signature: .of([.parameter(nil, "text", Self.string)], returning: qualified(production.symbol), throwing: namespaceType.member("SyntaxError"))
            ) {
                VariableDeclSyntax.binding("parser", nil, ExprSyntax.named(namespace).dot("Parser").call(.named("text")).tried, mutable: true)
                IfExprSyntax(conditions: ConditionElementListSyntax {
                    ConditionElementSyntax.binding("node", ExprSyntax.named("parser").dot("parse" + type).call())
                    ConditionElementSyntax.expression(ExprSyntax.named("parser").dot("isAtEnd"))
                }) {
                    StmtSyntax.return(.named("node"))
                }
                StmtSyntax.throw(ExprSyntax.named("parser").dot("failure").call())
            }
        }
        return [DeclSyntax(ExtensionDeclSyntax(extendedType: namespaceType) { declaration }), DeclSyntax(parse)]
    }

    /// An enum with a case for each of `cases`.
    static func enumDeclaration(_ name: String, cases: [Case], leadingTrivia: Trivia = []) -> EnumDeclSyntax {
        EnumDeclSyntax(
            leadingTrivia: leadingTrivia,
            modifiers: [DeclModifierSyntax(name: .keyword(.indirect))],
            name: .name(name),
            inheritanceClause: .swift("Sendable")
        ) {
            for item in cases {
                EnumCaseDeclSyntax {
                    EnumCaseElementSyntax(name: .name(item.name), parameterClause: item.compiled.part.map(Self.associatedValues))
                }
            }
        }
    }

    /// The associated values of a case that holds `part`: one for each of
    /// its fields when it is a tuple.
    static func associatedValues(_ part: Part) -> EnumCaseParameterClauseSyntax {
        EnumCaseParameterClauseSyntax(parameters: EnumCaseParameterListSyntax {
            if let fields = part.fields {
                for field in fields {
                    EnumCaseParameterSyntax(firstName: .name(field.name), colon: .colonToken(), type: field.type)
                }
            } else {
                EnumCaseParameterSyntax(type: part.type)
            }
        })
    }

    /// Gives parts with the same name distinct names, in order.
    static func uniqueNames(_ parts: [Part]) -> [Part] {
        var used: [String: Int] = [:]
        return parts.map { part in
            var part = part
            let count = used[part.name, default: 0] + 1
            used[part.name] = count
            if count > 1 { part.name += String(count) }
            return part
        }
    }

    mutating func nextMethod() -> String {
        methodCounter += 1
        return "read" + String(methodCounter)
    }

    mutating func compile(_ expression: Expression, owner: String) throws(TranslationError) -> Compiled {
        switch expression {
        case .symbol(let symbol):
            let type = SwiftName.type(symbol)
            let part = Part(type: qualified(symbol), name: SwiftName.member(symbol))
            return Compiled(method: (tokenLevel.contains(symbol) ? "parse" : "take") + type, part: part)
        case .string(let text, let quote):
            let literal = Literal(text: text, caseInsensitive: quote == configuration.caseInsensitiveStrings)
            guard let index = literals.firstIndex(of: literal) else { throw TranslationError("internal: string \(text) not collected") }
            return Compiled(method: "takeLiteral" + String(index), part: nil)
        case .sequence(let items):
            var compiled: [Compiled] = []
            for item in items { compiled.append(try compile(item, owner: owner)) }
            let parts = Self.uniqueNames(compiled.compactMap(\.part))
            let method = nextMethod()
            let part: Part?
            switch parts.count {
            case 0: part = nil
            case 1: part = parts[0]
            default:
                let fields = parts.map { (name: $0.name, type: $0.type) }
                part = Part(
                    type: .tuple(fields),
                    name: SwiftName.lowerCamel(SwiftName.compound(parts.map(\.name), separator: "And")),
                    fields: fields
                )
            }
            parserMethods.append(sequenceMethod(name: method, type: part?.type ?? TypeSyntax(TupleTypeSyntax(elements: [])), items: compiled) { values in
                switch values.count {
                case 0: .void
                case 1: values[0]
                default: .tuple(zip(parts, values).map { ($0.name, $1) })
                }
            })
            return Compiled(method: method, part: part)
        case .choice(let options):
            let cases = try compileCases(options, owner: owner)
            var name = SwiftName.compound(cases.map(\.name), separator: "Or")
            if nestedNames[owner, default: []].contains(name) {
                var index = 2
                while nestedNames[owner, default: []].contains(name + String(index)) { index += 1 }
                name += String(index)
            }
            nestedNames[owner, default: []].insert(name)
            let qualified = namespaceType.member(owner).member(name)
            nested[owner, default: []].append(Self.enumDeclaration(name, cases: cases))
            let method = nextMethod()
            parserMethods.append(choiceMethod(name: method, type: qualified, options: options, cases: cases))
            return Compiled(method: method, part: Part(type: qualified, name: SwiftName.lowerCamel(name)))
        case .optional(let item):
            let inner = try compile(item, owner: owner)
            let method = nextMethod()
            let part: Part
            let start = VariableDeclSyntax.binding("start", nil, .named("index"))
            let reset = ExprSyntax.named("index").assigned(.named("start"))
            let call = ExprSyntax.named(inner.method).call()
            let body: CodeBlockItemListSyntax
            if let innerPart = inner.part {
                part = Part(type: innerPart.type.is(OptionalTypeSyntax.self) ? innerPart.type : innerPart.type.optional, name: innerPart.name)
                body = CodeBlockItemListSyntax {
                    start
                    IfExprSyntax(conditions: [.binding("value", call)]) {
                        StmtSyntax.return(ExprSyntax.dot("some").call(.named("value")))
                    }
                    reset
                    StmtSyntax.return(ExprSyntax.dot("some").call(.nil))
                }
            } else {
                part = Part(type: Self.bool, name: Self.wordName(item) ?? "isPresent")
                body = CodeBlockItemListSyntax {
                    start
                    IfExprSyntax(conditions: .expression(call.infix("!=", .nil))) {
                        StmtSyntax.return(.bool(true))
                    }
                    reset
                    StmtSyntax.return(.bool(false))
                }
            }
            parserMethods.append(Self.method(method, returning: part.type, body: body))
            return Compiled(method: method, part: part)
        case .zeroOrMore(let item), .oneOrMore(let item):
            let inner = try compile(item, owner: owner)
            let method = nextMethod()
            let atLeastOne: Bool
            if case .oneOrMore = expression { atLeastOne = true } else { atLeastOne = false }
            let part: Part
            let collected: String
            let none: ExprSyntax
            let take: CodeBlockItemListSyntax
            let call = ExprSyntax.named(inner.method).call()
            let back = CodeBlockItemListSyntax {
                ExprSyntax.named("index").assigned(.named("start"))
                StmtSyntax.break
            }
            if let innerPart = inner.part {
                part = Part(type: innerPart.type.array, name: SwiftName.plural(innerPart.name))
                collected = "items"
                none = ExprSyntax.named("items").dot("isEmpty")
                take = CodeBlockItemListSyntax {
                    GuardStmtSyntax(conditions: [.binding("item", call)], body: CodeBlockSyntax(statements: back))
                    unchangedBreak
                    ExprSyntax.named("items").dot("append").call(.named("item"))
                }
            } else {
                part = Part(type: Self.int, name: (Self.wordName(item) ?? "item") + "Count")
                collected = "count"
                none = ExprSyntax.named("count").infix("==", .int(0))
                take = CodeBlockItemListSyntax {
                    GuardStmtSyntax(conditions: .expression(call.infix("!=", .nil)), body: CodeBlockSyntax(statements: back))
                    unchangedBreak
                    ExprSyntax.named("count").infix("+=", .int(1))
                }
            }
            let body = CodeBlockItemListSyntax {
                if inner.part != nil {
                    VariableDeclSyntax.binding("items", part.type, .array([]), mutable: true)
                } else {
                    VariableDeclSyntax.binding("count", nil, .int(0), mutable: true)
                }
                WhileStmtSyntax(conditions: .expression(.bool(true))) {
                    VariableDeclSyntax.binding("start", nil, .named("index"))
                    take
                }
                if atLeastOne {
                    IfExprSyntax(conditions: .expression(none)) { StmtSyntax.return(.nil) }
                }
                StmtSyntax.return(.named(collected))
            }
            parserMethods.append(Self.method(method, returning: part.type, body: body))
            return Compiled(method: method, part: part)
        case .character, .characterClass, .difference:
            throw TranslationError("internal: \(expression.notation) is read over terminals")
        }
    }

    /// `if index == start { break }`: an item that matched nothing ends a
    /// repetition.
    var unchangedBreak: IfExprSyntax {
        IfExprSyntax(conditions: .expression(ExprSyntax.named("index").infix("==", .named("start")))) { StmtSyntax.break }
    }

    static func wordName(_ expression: Expression) -> String? {
        if case .string(let text, _) = expression { return SwiftName.word(text) }
        return nil
    }

    struct Case {
        var name: String
        var compiled: Compiled
    }

    mutating func compileCases(_ options: [Expression], owner: String) throws(TranslationError) -> [Case] {
        var cases: [Case] = []
        var used: Set<String> = []
        for (index, option) in options.enumerated() {
            let compiled = try compile(option, owner: owner)
            // An alternative is named after the first thing it holds.
            var name = compiled.part?.fields?.first?.name ?? compiled.part?.name ?? Self.wordName(option) ?? "alternative" + String(index + 1)
            if used.contains(name) {
                var suffix = 2
                while used.contains(name + String(suffix)) { suffix += 1 }
                name += String(suffix)
            }
            used.insert(name)
            cases.append(Case(name: name, compiled: compiled))
        }
        return cases
    }

    /// The method that reads one of `options`, trying them in the order
    /// ``Lookahead/order(_:)`` gives.
    func choiceMethod(name: String, type: TypeSyntax, options: [Expression], cases: [Case]) -> FunctionDeclSyntax {
        let body = CodeBlockItemListSyntax {
            VariableDeclSyntax.binding("start", nil, .named("index"))
            for index in lookahead.order(options) {
                let item = cases[index]
                let call = ExprSyntax.named(item.compiled.method).call()
                if let part = item.compiled.part {
                    IfExprSyntax(conditions: [.binding("value", call)]) { StmtSyntax.return(Self.caseValue(item.name, holding: part)) }
                } else {
                    IfExprSyntax(conditions: .expression(call.infix("!=", .nil))) { StmtSyntax.return(.dot(item.name)) }
                }
                ExprSyntax.named("index").assigned(.named("start"))
            }
            StmtSyntax.return(.nil)
        }
        return Self.method(name, returning: type, body: body)
    }

    /// `.name(value)`, or `.name(a: value.a, b: value.b)` for a tuple.
    static func caseValue(_ name: String, holding part: Part) -> ExprSyntax {
        guard let fields = part.fields else { return ExprSyntax.dot(name).call(.named("value")) }
        return ExprSyntax.dot(name).call(labeled: fields.map { ($0.name, ExprSyntax.named("value").dot($0.name)) })
    }

    /// The method that reads `items` in order; `construct` makes what it
    /// returns from the values of the items that hold something.
    func sequenceMethod(name: String, type: TypeSyntax, items: [Compiled], construct: ([ExprSyntax]) -> ExprSyntax) -> FunctionDeclSyntax {
        let values = items.indices.filter { items[$0].part != nil }.map { "value" + String($0) }
        let back = CodeBlockItemListSyntax {
            ExprSyntax.named("index").assigned(.named("start"))
            StmtSyntax.return(.nil)
        }
        let body = CodeBlockItemListSyntax {
            VariableDeclSyntax.binding("start", nil, .named("index"))
            for (index, item) in items.enumerated() {
                let call = ExprSyntax.named(item.method).call()
                if item.part != nil {
                    GuardStmtSyntax(conditions: [.binding("value" + String(index), call)], body: CodeBlockSyntax(statements: back))
                } else {
                    GuardStmtSyntax(conditions: .expression(call.infix("!=", .nil)), body: CodeBlockSyntax(statements: back))
                }
            }
            StmtSyntax.return(construct(values.map(ExprSyntax.named)))
        }
        return Self.method(name, returning: type, body: body)
    }

    /// `mutating func name() -> type? { body }`.
    static func method(_ name: String, returning type: TypeSyntax, body: CodeBlockItemListSyntax) -> FunctionDeclSyntax {
        FunctionDeclSyntax(
            modifiers: .mutating,
            name: .name(name),
            signature: .of([], returning: type.optional),
            body: CodeBlockSyntax(statements: body)
        )
    }

    // MARK: - The parser

    func parserDeclaration() -> ExtensionDeclSyntax {
        let token = TypeSyntax.named("Token")
        let tokens = ExprSyntax.named("tokens")
        let index = ExprSyntax.named("index")
        let farthest = ExprSyntax.named("farthest")
        let endOfDocument = ExprSyntax.string("the end of the document")
        return ExtensionDeclSyntax(extendedType: namespaceType) {
            StructDeclSyntax(
                leadingTrivia: .documentation(
                    "Reads tokens as the productions read over terminals, trying the",
                    "alternatives of a choice in turn, those that can match nothing last."
                ),
                name: .name("Parser")
            ) {
                VariableDeclSyntax.binding("tokens", token.array)
                VariableDeclSyntax.binding("end", .named("Location"))
                VariableDeclSyntax.binding("index", nil, .int(0), mutable: true)
                VariableDeclSyntax.binding("farthest", nil, .int(0), mutable: true)
                VariableDeclSyntax.binding("expected", TypeSyntax.swift("Set", Self.string), .array([]), mutable: true)
                InitializerDeclSyntax(
                    leadingTrivia: .documentation("A parser of the tokens of `text`."),
                    signature: .of([.parameter(nil, "text", Self.string)], throwing: .named("SyntaxError"))
                ) {
                    VariableDeclSyntax.binding("lexed", nil, ExprSyntax.named("Lexer").dot("tokens").call(labeled: [
                        ("in", ExprSyntax.named("Swift").dot("Array").call(ExprSyntax.named("text").dot("unicodeScalars"))),
                    ]).tried)
                    tokens.assigned(ExprSyntax.named("lexed").dot("tokens"))
                    ExprSyntax.named("end").assigned(ExprSyntax.named("lexed").dot("end"))
                }
                VariableDeclSyntax.computed("isAtEnd", Self.bool, leadingTrivia: .documentation("Whether every token has been read.")) {
                    StmtSyntax.return(index.infix("==", tokens.dot("count")))
                }
                FunctionDeclSyntax(modifiers: .mutating, name: .name("take"), signature: .of([.parameter(nil, "kind", .named("Kind"))], returning: token.optional)) {
                    IfExprSyntax(conditions: ConditionElementListSyntax {
                        ConditionElementSyntax.expression(index.infix("<", tokens.dot("count")))
                        ConditionElementSyntax.expression(tokens.subscripted(index).dot("kind").infix("==", .named("kind")))
                    }) {
                        index.infix("+=", .int(1))
                        StmtSyntax.return(tokens.subscripted(index.infix("-", .int(1))))
                    }
                    ExprSyntax.named("expect").call(ExprSyntax.selfType.dot("describe").call(.named("kind")))
                    StmtSyntax.return(.nil)
                }
                FunctionDeclSyntax(modifiers: .mutating, name: .name("expect"), signature: .of([.parameter(nil, "description", Self.string)])) {
                    IfExprSyntax(conditions: .expression(index.infix(">", farthest))) {
                        farthest.assigned(index)
                        ExprSyntax.named("expected").assigned(.array([]))
                    }
                    IfExprSyntax(conditions: .expression(index.infix("==", farthest))) {
                        ExprSyntax.named("expected").dot("insert").call(.named("description"))
                    }
                }
                FunctionDeclSyntax(
                    leadingTrivia: .documentation("The error at the farthest token read, which the end of the document can also be expected at."),
                    modifiers: .mutating,
                    name: .name("failure"),
                    signature: .of([], returning: .named("SyntaxError"))
                ) {
                    ExprSyntax.named("expect").call(endOfDocument)
                    let within = farthest.infix("<", tokens.dot("count"))
                    VariableDeclSyntax.binding("found", nil, ExprSyntax.string("'").infix("+", tokens.subscripted(farthest).dot("text")).infix("+", .string("'")).when(within, else: endOfDocument))
                    VariableDeclSyntax.binding("location", nil, tokens.subscripted(farthest).dot("location").when(within, else: .named("end")))
                    StmtSyntax.return(ExprSyntax.named("SyntaxError").call(labeled: [
                        ("location", .named("location")),
                        ("message", ExprSyntax.string("expected ")
                            .infix("+", ExprSyntax.named("expected").dot("sorted").call().dot("joined").call(labeled: [("separator", .string(" or "))]))
                            .infix("+", .string(", found "))
                            .infix("+", .named("found"))),
                    ]))
                }
                FunctionDeclSyntax(modifiers: .static, name: .name("describe"), signature: .of([.parameter(nil, "kind", .named("Kind"))], returning: Self.string)) {
                    SwitchExprSyntax(subject: ExprSyntax.named("kind")) {
                        for terminal in lexerTerminals {
                            SwitchCaseSyntax.matching([.dot(SwiftName.type(terminal))]) { StmtSyntax.return(.string(terminal)) }
                        }
                        SwitchCaseSyntax.matching([ExprSyntax.dot("literal").call(ExprSyntax(PatternExprSyntax(pattern: ValueBindingPatternSyntax(
                            bindingSpecifier: .keyword(.let),
                            pattern: IdentifierPatternSyntax(identifier: .name("index"))
                        ))))]) {
                            StmtSyntax.return(ExprSyntax.string("'").infix("+", ExprSyntax.named("Lexer").dot("literals").subscripted(index)).infix("+", .string("'")))
                        }
                    }
                }
                for terminal in lexerTerminals {
                    let type = SwiftName.type(terminal)
                    FunctionDeclSyntax(modifiers: .mutating, name: .name("take" + type), signature: .of([], returning: TypeSyntax.named(type).optional)) {
                        GuardStmtSyntax(conditions: [.binding("token", ExprSyntax.named("take").call(.dot(type)))]) {
                            StmtSyntax.return(.nil)
                        }
                        StmtSyntax.return(ExprSyntax.named(type).call(labeled: [
                            ("text", ExprSyntax.named("token").dot("text")),
                            ("location", ExprSyntax.named("token").dot("location")),
                        ]))
                    }
                }
                for (literalIndex, literal) in literals.enumerated() {
                    FunctionDeclSyntax(
                        leadingTrivia: .documentation("`'\(literal.text)'`"),
                        modifiers: .mutating,
                        name: .name("takeLiteral" + String(literalIndex)),
                        signature: .of([], returning: token.optional)
                    ) {
                        StmtSyntax.return(ExprSyntax.named("take").call(ExprSyntax.dot("literal").call(.int(literalIndex))))
                    }
                }
                for method in parserMethods { method }
            }
        }
    }
}

extension ExprSyntax {
    /// `Self<argument>`, a generic type used as a value: `Swift.Set<Swift.Int>`.
    fileprivate func subscriptedType(_ argument: TypeSyntax) -> ExprSyntax {
        ExprSyntax(GenericSpecializationExprSyntax(expression: self, genericArgumentClause: GenericArgumentClauseSyntax {
            GenericArgumentSyntax(argument: .type(argument))
        }))
    }
}
