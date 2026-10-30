import SwiftSyntax
import SwiftSyntaxBuilder

/// Builds the body of a function that matches an expression over
/// characters: each expression turns the positions that reach its start
/// into the positions that reach its end.
///
/// In ``Mode/ends`` the positions are offsets. In ``Mode/steps`` they are
/// steps, which also record where each production the expression refers to
/// matched; the productions it refers to are matched for their ends only.
struct MatcherEmitter {
    enum Mode {
        case ends
        case steps
    }

    let bySymbol: [String: Production]
    let firstCharacters: [String: FirstCharacters]
    /// The character classes the expression matches, each matched by a
    /// function `class<index>`.
    var classes: [CharacterClass] = []
    /// The strings of more than one character the expression matches, each
    /// held by a constant `string<index>`.
    var strings: [[UInt32]] = []
    /// The statements built so far, in the block being built.
    var statements: [CodeBlockItemSyntax] = []
    var counter = 0

    init(bySymbol: [String: Production], firstCharacters: [String: FirstCharacters]) {
        self.bySymbol = bySymbol
        self.firstCharacters = firstCharacters
    }

    /// The body of a function from the characters `s` and an `offset` to
    /// the positions after `expression`.
    mutating func body(for expression: Expression, mode: Mode) throws(TranslationError) -> CodeBlockItemListSyntax {
        statements = []
        let start = mode == .ends
            ? ExprSyntax.array([.named("offset")])
            : ExprSyntax.array([ExprSyntax.named("Step").call(labeled: [("end", .named("offset")), ("trace", .nil)])])
        add(VariableDeclSyntax.binding("start", type(mode), start))
        let result = try emit(expression, from: "start", mode: mode)
        add(StmtSyntax.return(.named(result)))
        return Self.list(statements)
    }

    // MARK: - Statements

    mutating func add(_ declaration: some DeclSyntaxProtocol) {
        statements.append(CodeBlockItemSyntax(item: .decl(DeclSyntax(declaration))))
    }

    mutating func add(_ statement: some StmtSyntaxProtocol) {
        statements.append(CodeBlockItemSyntax(item: .stmt(StmtSyntax(statement))))
    }

    mutating func add(_ expression: ExprSyntax) {
        statements.append(CodeBlockItemSyntax(item: .expr(expression)))
    }

    /// The statements `build` adds, as a block of their own.
    mutating func block(_ build: (inout MatcherEmitter) throws(TranslationError) -> Void) throws(TranslationError) -> CodeBlockItemListSyntax {
        let outer = statements
        statements = []
        try build(&self)
        let inner = statements
        statements = outer
        return Self.list(inner)
    }

    /// `items`, one to a line.
    static func list(_ items: [CodeBlockItemSyntax]) -> CodeBlockItemListSyntax {
        CodeBlockItemListSyntax {
            for item in items { item }
        }
    }

    /// `for <position> in <input> where <condition> { body }`.
    mutating func forEach(_ position: String, in input: String, where condition: ExprSyntax?, body: CodeBlockItemListSyntax) {
        add(ForStmtSyntax(
            pattern: IdentifierPatternSyntax(identifier: .name(position)),
            sequence: ExprSyntax.named(input),
            whereClause: condition.map { WhereClauseSyntax(condition: $0) },
            body: CodeBlockSyntax(statements: body)
        ))
    }

    mutating func fresh(_ prefix: String = "positions") -> String {
        counter += 1
        return prefix + String(counter)
    }

    // MARK: - Positions

    func type(_ mode: Mode) -> TypeSyntax {
        mode == .ends ? TypeSyntax.swift("Int").array : TypeSyntax.named("Step").array
    }

    /// The offset `position` stands for.
    func end(_ position: ExprSyntax, _ mode: Mode) -> ExprSyntax {
        mode == .ends ? position : position.dot("end")
    }

    /// `position` advanced by `count` characters.
    func advanced(_ position: ExprSyntax, by count: Int, _ mode: Mode) -> ExprSyntax {
        switch mode {
        case .ends:
            position.infix("+", .int(count))
        case .steps:
            ExprSyntax.named("Step").call(labeled: [
                ("end", position.dot("end").infix("+", .int(count))),
                ("trace", position.dot("trace")),
            ])
        }
    }

    /// `positions` without a second copy of a position.
    func unique(_ positions: ExprSyntax, _ mode: Mode) -> ExprSyntax {
        ExprSyntax.named("Step").dot(mode == .ends ? "uniqueEnds" : "unique").call(positions)
    }

    /// The offsets of `positions`.
    func ends(_ positions: ExprSyntax, _ mode: Mode) -> ExprSyntax {
        mode == .ends ? positions : positions.dot("map").call(.keyPath("end"))
    }

    /// `end < s.count && <test of s[end]>`, the test of the character at
    /// `position`.
    func character(at position: ExprSyntax, _ mode: Mode, _ test: (ExprSyntax) -> ExprSyntax) -> ExprSyntax {
        let at = end(position, mode)
        return at.infix("<", ExprSyntax.named("s").dot("count"))
            .infix("&&", test(ExprSyntax.named("s").subscripted(at).dot("value")))
    }

    // MARK: - Expressions

    /// Builds the positions after `expression` from the positions in
    /// `input`, and returns the variable that holds them.
    mutating func emit(_ expression: Expression, from input: String, mode: Mode) throws(TranslationError) -> String {
        let position = ExprSyntax.named("position")
        switch expression {
        case .symbol(let symbol):
            guard bySymbol[symbol] != nil else { throw TranslationError("'\(symbol)' is used but not defined") }
            let type = SwiftName.type(symbol)
            let output = fresh()
            add(VariableDeclSyntax.binding(output, self.type(mode), .array([]), mutable: true))
            let condition = firstCharacters[symbol]?.mustAlwaysTry == false
                ? character(at: position, mode) { ExprSyntax.named(type).dot("starts").call($0) }
                : nil
            let ends = ExprSyntax.named(type).dot("ends")
            let body: CodeBlockItemListSyntax
            switch mode {
            case .ends:
                body = [CodeBlockItemSyntax(item: .expr(ExprSyntax.named(output).infix("+=", ends.call(.named("s"), position))))]
            case .steps:
                let step = ExprSyntax.named("Step").call(labeled: [
                    ("end", .named("end")),
                    ("trace", ExprSyntax.named("Trace").call(.dot(type), position.dot("end"), .named("end"), position.dot("trace"))),
                ])
                body = [CodeBlockItemSyntax(item: .stmt(StmtSyntax(ForStmtSyntax(
                    pattern: IdentifierPatternSyntax(identifier: .name("end")),
                    sequence: ends.call(.named("s"), position.dot("end")),
                    body: CodeBlockSyntax(statements: [CodeBlockItemSyntax(item: .expr(ExprSyntax.named(output).dot("append").call(step)))])
                ))))]
            }
            forEach("position", in: input, where: condition, body: body)
            add(ExprSyntax.named(output).assigned(unique(.named(output), mode)))
            return output
        case .string(let text, _):
            let scalars = text.unicodeScalars.map(\.value)
            let condition: ExprSyntax
            if scalars.count == 1 {
                condition = character(at: position, mode) { $0.infix("==", .codePoint(scalars[0])) }
            } else {
                if !strings.contains(scalars) { strings.append(scalars) }
                let constant = ExprSyntax.named("string" + String(strings.firstIndex(of: scalars)!))
                condition = ExprSyntax.named("Step").dot("has").call(.named("s"), end(position, mode), constant)
            }
            return advancing(from: input, by: scalars.count, where: condition, mode)
        case .character(let value):
            return advancing(from: input, by: 1, where: character(at: position, mode) { $0.infix("==", .codePoint(value)) }, mode)
        case .characterClass(let characterClass):
            if !classes.contains(characterClass) { classes.append(characterClass) }
            let function = ExprSyntax.named("class" + String(classes.firstIndex(of: characterClass)!))
            return advancing(from: input, by: 1, where: character(at: position, mode) { function.call($0) }, mode)
        case .sequence(let items):
            var current = input
            for item in items {
                current = try emit(item, from: current, mode: mode)
            }
            return current
        case .choice(let options):
            var outputs: [String] = []
            for option in options {
                outputs.append(try emit(option, from: input, mode: mode))
            }
            let output = fresh()
            add(VariableDeclSyntax.binding(output, nil, .named(outputs[0]), mutable: true))
            for other in outputs.dropFirst() {
                add(ExprSyntax.named(output).infix("+=", .named(other)))
            }
            add(ExprSyntax.named(output).assigned(unique(.named(output), mode)))
            return output
        case .optional(let item):
            let inner = try emit(item, from: input, mode: mode)
            let output = fresh()
            add(VariableDeclSyntax.binding(output, nil, unique(ExprSyntax.named(input).infix("+", .named(inner)), mode)))
            return output
        case .zeroOrMore(let item):
            return try repetition(item, from: input, mode: mode)
        case .oneOrMore(let item):
            let first = try emit(item, from: input, mode: mode)
            return try repetition(item, from: first, mode: mode)
        case .difference(let left, let right):
            return try difference(left, right, from: input, mode: mode)
        }
    }

    /// The positions in `input` where `condition` holds, advanced by
    /// `count` characters.
    mutating func advancing(from input: String, by count: Int, where condition: ExprSyntax, _ mode: Mode) -> String {
        let output = fresh()
        add(VariableDeclSyntax.binding(output, type(mode), .array([]), mutable: true))
        forEach("position", in: input, where: condition, body: [
            CodeBlockItemSyntax(item: .expr(ExprSyntax.named(output).dot("append").call(advanced(.named("position"), by: count, mode)))),
        ])
        return output
    }

    /// `item*` from the positions in `input`: each round takes the
    /// positions that reach a new end.
    mutating func repetition(_ item: Expression, from input: String, mode: Mode) throws(TranslationError) -> String {
        let output = fresh()
        let frontier = fresh("frontier")
        let ends = fresh("ends")
        add(VariableDeclSyntax.binding(output, nil, .named(input), mutable: true))
        add(VariableDeclSyntax.binding(frontier, nil, .named(input), mutable: true))
        add(VariableDeclSyntax.binding(ends, nil, ExprSyntax.named("Swift").dot("Set").call(self.ends(.named(input), mode)), mutable: true))
        let body = try block { (emitter: inout MatcherEmitter) throws(TranslationError) in
            let round = emitter.fresh()
            emitter.add(VariableDeclSyntax.binding(round, nil, .named(frontier)))
            let inner = try emitter.emit(item, from: round, mode: mode)
            let isNew = ExprSyntax.closure {
                ExprSyntax.named(ends).dot("insert").call(emitter.end(.firstArgument, mode)).dot("inserted")
            }
            emitter.add(ExprSyntax.named(frontier).assigned(ExprSyntax.named(inner).dot("filter").call(trailing: isNew)))
            emitter.add(ExprSyntax.named(output).infix("+=", .named(frontier)))
        }
        add(WhileStmtSyntax(conditions: .expression(ExprSyntax.named(frontier).dot("isEmpty").prefixed("!")), body: CodeBlockSyntax(statements: body)))
        return output
    }

    /// `left - right` from the positions in `input`: the ends of `left`
    /// that `right` does not reach from the same position.
    mutating func difference(_ left: Expression, _ right: Expression, from input: String, mode: Mode) throws(TranslationError) -> String {
        let output = fresh()
        let position = fresh("position")
        add(VariableDeclSyntax.binding(output, type(mode), .array([]), mutable: true))
        let start = end(.named(position), mode)
        let body = try block { (emitter: inout MatcherEmitter) throws(TranslationError) in
            let leftInput = emitter.fresh()
            emitter.add(VariableDeclSyntax.binding(leftInput, nil, .array([.named(position)])))
            let leftOutput = try emitter.emit(left, from: leftInput, mode: mode)
            // B only needs to match as far as A reaches: it reads the
            // characters up to the end of A's longest match.
            let excluded = emitter.fresh("excluded")
            let reach = emitter.ends(.named(leftOutput), mode).dot("max").call().infix("??", start)
            let rightBody = try emitter.block { (emitter: inout MatcherEmitter) throws(TranslationError) in
                emitter.add(VariableDeclSyntax.binding("s", nil, ExprSyntax.named("Swift").dot("Array").call(
                    ExprSyntax.named("s").subscripted(reach.parenthesized.prefixed("..<"))
                )))
                let rightInput = emitter.fresh()
                emitter.add(VariableDeclSyntax.binding(rightInput, nil, .array([start])))
                let rightOutput = try emitter.emit(right, from: rightInput, mode: .ends)
                emitter.add(StmtSyntax.return(ExprSyntax.named("Swift").dot("Set").call(.named(rightOutput))))
            }
            emitter.add(VariableDeclSyntax.binding(
                excluded,
                TypeSyntax.swift("Set", TypeSyntax.swift("Int")),
                ExprSyntax(ClosureExprSyntax(statements: rightBody)).call()
            ))
            let kept = ExprSyntax.closure {
                ExprSyntax.named(excluded).dot("contains").call(emitter.end(.firstArgument, mode)).prefixed("!")
            }
            emitter.add(ExprSyntax.named(output).infix("+=", ExprSyntax.named(leftOutput).dot("filter").call(trailing: kept)))
        }
        forEach(position, in: input, where: nil, body: body)
        return output
    }
}
