import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

// The shapes of syntax a translation builds over and over, as members of
// the swift-syntax node types they build.

extension TokenSyntax {
    /// The identifier `name`, in backticks where the Swift parser does not
    /// take the name as an identifier (`default`, `true`).
    static func name(_ name: String) -> TokenSyntax {
        name.isValidSwiftIdentifier(for: .variableName) ? .identifier(name) : .identifier("`" + name + "`")
    }

    /// The identifier `name` after a `.` or as an argument label, where
    /// Swift takes more names than it does in a declaration (`in`).
    static func label(_ name: String) -> TokenSyntax {
        name.isValidSwiftIdentifier(for: .memberAccess) ? .identifier(name) : .identifier("`" + name + "`")
    }
}

extension Trivia {
    /// A documentation comment of one `///` line for each of `lines`.
    static func documentation(_ lines: String...) -> Trivia {
        Trivia(pieces: lines.flatMap { [TriviaPiece.docLineComment("/// " + $0), .newlines(1)] })
    }

    /// A comment of one `//` line for each of `lines`.
    static func comment(_ lines: [String]) -> Trivia {
        Trivia(pieces: lines.flatMap { [TriviaPiece.lineComment($0.isEmpty ? "//" : "// " + $0), .newlines(1)] })
    }
}

extension TypeSyntax {
    /// The type named `name`.
    static func named(_ name: String) -> TypeSyntax {
        TypeSyntax(IdentifierTypeSyntax(name: .name(name)))
    }

    /// The type of the standard library named `name`: `Swift.Int`, written
    /// in full because a grammar can name a production `String`.
    static func swift(_ name: String, _ arguments: TypeSyntax...) -> TypeSyntax {
        named("Swift").member(name, arguments)
    }

    /// `[Swift.Unicode.Scalar]`, the characters a document is read as.
    static var scalars: TypeSyntax {
        swift("Unicode").member("Scalar").array
    }

    /// The member type `name` of this type, with generic `arguments`.
    func member(_ name: String, _ arguments: [TypeSyntax] = []) -> TypeSyntax {
        TypeSyntax(MemberTypeSyntax(
            baseType: self,
            name: .name(name),
            genericArgumentClause: arguments.isEmpty ? nil : GenericArgumentClauseSyntax {
                for argument in arguments { GenericArgumentSyntax(argument: .type(argument)) }
            }
        ))
    }

    /// `Self?`.
    var optional: TypeSyntax { TypeSyntax(OptionalTypeSyntax(wrappedType: self)) }

    /// `[Self]`.
    var array: TypeSyntax { TypeSyntax(ArrayTypeSyntax(element: self)) }

    /// A tuple type with a labelled element for each of `fields`.
    static func tuple(_ fields: [(name: String, type: TypeSyntax)]) -> TypeSyntax {
        TypeSyntax(TupleTypeSyntax(elements: TupleTypeElementListSyntax {
            for field in fields {
                TupleTypeElementSyntax(firstName: .name(field.name), colon: .colonToken(), type: field.type)
            }
        }))
    }
}

extension ExprSyntax {
    /// A reference to `name`.
    static func named(_ name: String) -> ExprSyntax {
        ExprSyntax(DeclReferenceExprSyntax(baseName: .name(name)))
    }

    /// `Self`.
    static var selfType: ExprSyntax {
        ExprSyntax(DeclReferenceExprSyntax(baseName: .keyword(.Self)))
    }

    /// `$0`.
    static var firstArgument: ExprSyntax {
        ExprSyntax(DeclReferenceExprSyntax(baseName: .dollarIdentifier("$0")))
    }

    /// `.name`, a member of the type the context expects.
    static func dot(_ name: String) -> ExprSyntax {
        ExprSyntax(MemberAccessExprSyntax(declName: DeclReferenceExprSyntax(baseName: .label(name))))
    }

    /// The integer `value`.
    static func int(_ value: Int) -> ExprSyntax {
        ExprSyntax(IntegerLiteralExprSyntax(value))
    }

    /// The code point `value`, in hexadecimal as the EBNF notation writes it.
    static func codePoint(_ value: UInt32) -> ExprSyntax {
        ExprSyntax(IntegerLiteralExprSyntax(literal: .integerLiteral("0x" + String(value, radix: 16, uppercase: true))))
    }

    /// The code points in `range`: `0x41...0x5A`, or `0x41` for one.
    static func codePoints(_ range: ClosedRange<UInt32>) -> ExprSyntax {
        range.lowerBound == range.upperBound
            ? codePoint(range.lowerBound)
            : codePoint(range.lowerBound).infix("...", codePoint(range.upperBound))
    }

    /// The string `text`.
    static func string(_ text: String) -> ExprSyntax {
        ExprSyntax(StringLiteralExprSyntax(content: text))
    }

    /// `true` or `false`.
    static func bool(_ value: Bool) -> ExprSyntax {
        ExprSyntax(BooleanLiteralExprSyntax(value))
    }

    /// `nil`.
    static var `nil`: ExprSyntax { ExprSyntax(NilLiteralExprSyntax()) }

    /// `()`.
    static var void: ExprSyntax { ExprSyntax(TupleExprSyntax(elements: [])) }

    /// An array of `elements`.
    static func array(_ elements: [ExprSyntax]) -> ExprSyntax {
        ExprSyntax(ArrayExprSyntax(expressions: elements))
    }

    /// A tuple of `elements`, each with its label, if any.
    static func tuple(_ elements: [(label: String?, value: ExprSyntax)]) -> ExprSyntax {
        ExprSyntax(TupleExprSyntax(elements: LabeledExprListSyntax {
            for element in elements { LabeledExprSyntax(label: element.label, expression: element.value) }
        }))
    }

    /// `\.name`.
    static func keyPath(_ name: String) -> ExprSyntax {
        ExprSyntax(KeyPathExprSyntax(components: [
            KeyPathComponentSyntax(period: .periodToken(), component: .property(KeyPathPropertyComponentSyntax(declName: DeclReferenceExprSyntax(baseName: .name(name))))),
        ]))
    }

    /// A closure of `statements`.
    static func closure(@CodeBlockItemListBuilder _ statements: () -> CodeBlockItemListSyntax) -> ClosureExprSyntax {
        ClosureExprSyntax(statements: statements())
    }

    /// The member `name` of this value.
    func dot(_ name: String) -> ExprSyntax {
        ExprSyntax(MemberAccessExprSyntax(base: self, declName: DeclReferenceExprSyntax(baseName: .label(name))))
    }

    /// A call of this function with `arguments`, none labelled.
    func call(_ arguments: ExprSyntax...) -> ExprSyntax {
        call(labeled: arguments.map { (nil, $0) })
    }

    /// A call of this function with `arguments`, each with its label, if any.
    func call(labeled arguments: [(label: String?, value: ExprSyntax)], trailing closure: ClosureExprSyntax? = nil) -> ExprSyntax {
        ExprSyntax(FunctionCallExprSyntax(callee: self, trailingClosure: closure) {
            for argument in arguments { LabeledExprSyntax(label: argument.label, expression: argument.value) }
        })
    }

    /// A call of this function with a trailing `closure` only.
    func call(trailing closure: ClosureExprSyntax) -> ExprSyntax {
        call(labeled: [], trailing: closure)
    }

    /// `self[index]`.
    func subscripted(_ index: ExprSyntax) -> ExprSyntax {
        ExprSyntax(SubscriptCallExprSyntax(calledExpression: self, arguments: [LabeledExprSyntax(expression: index)]))
    }

    /// `self <operator> right`.
    func infix(_ operator: String, _ right: ExprSyntax) -> ExprSyntax {
        ExprSyntax(InfixOperatorExprSyntax(leftOperand: self, operator: BinaryOperatorExprSyntax(text: `operator`), rightOperand: right))
    }

    /// `self = value`.
    func assigned(_ value: ExprSyntax) -> ExprSyntax {
        ExprSyntax(InfixOperatorExprSyntax(leftOperand: self, operator: AssignmentExprSyntax(), rightOperand: value))
    }

    /// `<operator>self`.
    func prefixed(_ operator: String) -> ExprSyntax {
        ExprSyntax(PrefixOperatorExprSyntax(operator: .prefixOperator(`operator`), expression: self))
    }

    /// `(self)`.
    var parenthesized: ExprSyntax { .tuple([(nil, self)]) }

    /// `self?`, which the members after it are chained to.
    var chained: ExprSyntax { ExprSyntax(OptionalChainingExprSyntax(expression: self)) }

    /// `try self`.
    var tried: ExprSyntax { ExprSyntax(TryExprSyntax(expression: self)) }

    /// `condition ? self : other`.
    func when(_ condition: ExprSyntax, else other: ExprSyntax) -> ExprSyntax {
        ExprSyntax(TernaryExprSyntax(condition: condition, thenExpression: self, elseExpression: other))
    }
}

extension ConditionElementListSyntax {
    /// One condition: a Boolean `expression`.
    static func expression(_ expression: ExprSyntax) -> ConditionElementListSyntax {
        [ConditionElementSyntax(condition: .expression(expression))]
    }
}

extension ConditionElementSyntax {
    /// `let name = value`, or `let name` when `value` is `nil`.
    static func binding(_ name: String, _ value: ExprSyntax? = nil) -> ConditionElementSyntax {
        ConditionElementSyntax(condition: .optionalBinding(OptionalBindingConditionSyntax(
            bindingSpecifier: .keyword(.let),
            pattern: IdentifierPatternSyntax(identifier: .name(name)),
            initializer: value.map { InitializerClauseSyntax(value: $0) }
        )))
    }

    /// A Boolean `expression`.
    static func expression(_ expression: ExprSyntax) -> ConditionElementSyntax {
        ConditionElementSyntax(condition: .expression(expression))
    }
}

extension VariableDeclSyntax {
    /// `let name: type = value`, or `var` when `mutable`.
    static func binding(
        _ name: String,
        _ type: TypeSyntax? = nil,
        _ value: ExprSyntax? = nil,
        mutable: Bool = false,
        modifiers: DeclModifierListSyntax = [],
        leadingTrivia: Trivia = []
    ) -> VariableDeclSyntax {
        VariableDeclSyntax(
            leadingTrivia: leadingTrivia,
            modifiers: modifiers,
            mutable ? .var : .let,
            name: PatternSyntax(IdentifierPatternSyntax(identifier: .name(name))),
            type: type.map { TypeAnnotationSyntax(type: $0) },
            initializer: value.map { InitializerClauseSyntax(value: $0) }
        )
    }

    /// `var name: type { getter }`.
    static func computed(
        _ name: String,
        _ type: TypeSyntax,
        modifiers: DeclModifierListSyntax = [],
        leadingTrivia: Trivia = [],
        @CodeBlockItemListBuilder getter: () -> CodeBlockItemListSyntax
    ) -> VariableDeclSyntax {
        VariableDeclSyntax(
            leadingTrivia: leadingTrivia,
            modifiers: modifiers,
            .var,
            name: PatternSyntax(IdentifierPatternSyntax(identifier: .name(name))),
            type: TypeAnnotationSyntax(type: type),
            accessorBlock: AccessorBlockSyntax(accessors: .getter(getter()))
        )
    }
}

extension DeclModifierListSyntax {
    /// `static`.
    static var `static`: DeclModifierListSyntax { [DeclModifierSyntax(name: .keyword(.static))] }

    /// `mutating`.
    static var mutating: DeclModifierListSyntax { [DeclModifierSyntax(name: .keyword(.mutating))] }

    /// `private`.
    static var `private`: DeclModifierListSyntax { [DeclModifierSyntax(name: .keyword(.private))] }
}

extension InheritanceClauseSyntax {
    /// Conformance to the standard library protocols `names`.
    static func swift(_ names: String...) -> InheritanceClauseSyntax {
        InheritanceClauseSyntax {
            for name in names { InheritedTypeSyntax(type: TypeSyntax.swift(name)) }
        }
    }
}

extension FunctionParameterSyntax {
    /// A parameter `label name: type`; `label` `nil` writes `_`, and a
    /// label equal to `name` is written once.
    static func parameter(_ label: String?, _ name: String, _ type: TypeSyntax) -> FunctionParameterSyntax {
        guard let label else {
            return FunctionParameterSyntax(firstName: .wildcardToken(), secondName: .name(name), type: type)
        }
        return FunctionParameterSyntax(firstName: .label(label), secondName: label == name ? nil : .name(name), type: type)
    }
}

extension FunctionSignatureSyntax {
    /// A signature with `parameters`, returning `type` and throwing
    /// `error`, when given.
    static func of(_ parameters: [FunctionParameterSyntax], returning type: TypeSyntax? = nil, throwing error: TypeSyntax? = nil) -> FunctionSignatureSyntax {
        FunctionSignatureSyntax(
            parameterClause: FunctionParameterClauseSyntax { for parameter in parameters { parameter } },
            effectSpecifiers: error.map {
                FunctionEffectSpecifiersSyntax(throwsClause: ThrowsClauseSyntax(
                    throwsSpecifier: .keyword(.throws), leftParen: .leftParenToken(), type: $0, rightParen: .rightParenToken()
                ))
            },
            returnClause: type.map { ReturnClauseSyntax(type: $0) }
        )
    }
}

extension StmtSyntax {
    /// `return value`.
    static func `return`(_ value: ExprSyntax? = nil) -> StmtSyntax {
        StmtSyntax(ReturnStmtSyntax(expression: value))
    }

    /// `break`.
    static var `break`: StmtSyntax { StmtSyntax(BreakStmtSyntax()) }

    /// `throw error`.
    static func `throw`(_ error: ExprSyntax) -> StmtSyntax {
        StmtSyntax(ThrowStmtSyntax(expression: error))
    }
}

extension SwitchCaseSyntax {
    /// `case patterns: statements`.
    static func matching(_ patterns: [ExprSyntax], @CodeBlockItemListBuilder _ statements: () -> CodeBlockItemListSyntax) -> SwitchCaseSyntax {
        SwitchCaseSyntax(label: .case(SwitchCaseLabelSyntax {
            for pattern in patterns { SwitchCaseItemSyntax(pattern: ExpressionPatternSyntax(expression: pattern)) }
        }), statements: statements())
    }

    /// `default: statements`.
    static func otherwise(@CodeBlockItemListBuilder _ statements: () -> CodeBlockItemListSyntax) -> SwitchCaseSyntax {
        SwitchCaseSyntax(label: .default(SwitchDefaultLabelSyntax()), statements: statements())
    }
}
