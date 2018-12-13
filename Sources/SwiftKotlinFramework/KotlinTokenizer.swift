//
//  KotlinTokenizer.swift
//  SwiftKotlinFramework
//
//  Created by Angel Garcia on 14/09/16.
//  Copyright © 2016 Angel G. Olloqui. All rights reserved.
//

import Foundation
import Transform
import AST
import Source
import Parser

func lastIndexOfTokens(_ tokens:[Token], when:(_ e:Token)->Bool) -> Int? {
    var n:Int? = nil
    for (i, e) in tokens.enumerated() {
        if when(e) {
            n = i
        }
    }
    return n
}

public class KotlinTokenizer: SwiftTokenizer {

    // MARK: - Declarations

    open override func tokenize(_ constant: ConstantDeclaration) -> [Token] {
        return super.tokenize(constant)
            .replacing({ $0.value == "let"},
                       with: [constant.newToken(.keyword, "val")])
    }

    private func removeDefaultArgsFromParameters(tokens:[Token]) -> [Token] {
        var newTokens = [Token]()
        var removing = false
        var bracket = false
        for t in tokens {
            if removing && t.kind == .startOfScope && t.value == "(" {
                bracket = true
            }
            if bracket && t.kind == .endOfScope && t.value == ")" {
                bracket = false
                removing = false
                continue
            }
            if t.kind == .symbol && (t.value.contains("=")) {
                removing = true
            }
            if t.kind == .delimiter && t.value.contains(",") {
                removing = false
            }
            if !bracket && removing && t.kind == .endOfScope && t.value == ")" {
                removing = false
            }
            if !removing {
                newTokens.append(t)
            }
        }
        return newTokens
    }
    
    open override func tokenize(_ declaration: FunctionDeclaration) -> [Token] {
        let attrsTokens = tokenize(declaration.attributes, node: declaration)
        let modifierTokens = declaration.modifiers.map { tokenize($0, node: declaration) }
            .joined(token: declaration.newToken(.space, " "))
        
        let genericParameterClauseTokens = declaration.genericParameterClause.map { tokenize($0, node: declaration) } ?? []
        
        let headTokens = [
            attrsTokens,
            modifierTokens,
            [declaration.newToken(.keyword, "fun")],
            genericParameterClauseTokens
        ].joined(token: declaration.newToken(.space, " "))

        
        var signatureTokens = tokenize(declaration.signature, node: declaration)
        let bodyTokens = declaration.body.map(tokenize) ?? []
        
        if modifierTokens.contains(where:{$0.value == "override" }) {
            // overridden methods can't have default args in kotlin:
            signatureTokens = removeDefaultArgsFromParameters(tokens:signatureTokens)
        }
        var tokens = [
            headTokens,
            [declaration.newToken(.identifier, declaration.name)] + signatureTokens,
            bodyTokens
        ].joined(token: declaration.newToken(.space, " "))
        .prefix(with: declaration.newToken(.linebreak, "\n"))
        
        tokens = IdentifiersTransformPlugin.TransformKotlinFunctionDeclarations(tokens)

        return tokens
    }

    open override func tokenize(_ parameter: FunctionSignature.Parameter, node: ASTNode) -> [Token] {
        let nameTokens = [
            parameter.newToken(.identifier, parameter.localName, node)
        ]
        var typeAnnoTokens = tokenize(parameter.typeAnnotation, node: node)
        let defaultTokens = parameter.defaultArgumentClause.map {
            return parameter.newToken(.symbol, " = ", node) + tokenize($0)
        }
        let varargsTokens = parameter.isVarargs ? [
            parameter.newToken(.keyword, "vararg", node),
            parameter.newToken(.space, " ", node),
        ] : []

        return
            varargsTokens +
            nameTokens +
            typeAnnoTokens +
            defaultTokens
    }

    open override func tokenize(_ result: FunctionResult, node: ASTNode) -> [Token] {
        return super.tokenize(result, node: node)
            .replacing({ $0.value == "->"},
                       with: [result.newToken(.symbol, ":", node)])
    }
    
    open override func tokenize(_ member: ProtocolDeclaration.MethodMember, node: ASTNode) -> [Token] {
        return super.tokenize(member, node: node)
            .replacing({ $0.value == "func"},
                       with: [member.newToken(.keyword, "fun", node)])
    }

    open override func tokenize(_ declaration: ClassDeclaration) -> [Token] {
        let staticMembers = declaration.members.filter({ $0.isStatic })
        let newClass = ClassDeclaration(
            attributes: declaration.attributes,
            accessLevelModifier: declaration.accessLevelModifier,
            isFinal: declaration.isFinal,
            name: declaration.name,
            genericParameterClause: declaration.genericParameterClause,
            typeInheritanceClause: declaration.typeInheritanceClause,
            genericWhereClause: declaration.genericWhereClause,
            members: declaration.members.filter({ !$0.isStatic }))
        newClass.setSourceRange(declaration.sourceRange)
        var tokens = super.tokenize(newClass)
        if !staticMembers.isEmpty, let bodyStart = tokens.index(where: { $0.value == "{"}) {
            let companionTokens = indent(tokenizeCompanion(staticMembers, node: declaration))
                .prefix(with: declaration.newToken(.linebreak, "\n"))
                .suffix(with: declaration.newToken(.linebreak, "\n"))
            tokens.insert(contentsOf: companionTokens, at:tokens.count - 1) // inserting the companion at the bottom causes a lot less problems with sourceRange of code messing up comment-merging, and maybe good to get it out of the way too.
        }
        return tokens
    }

    open override func tokenize(_ declaration: StructDeclaration) -> [Token] {
        var staticMembers: [StructDeclaration.Member] = []
        var declarationMembers: [StructDeclaration.Member] = []
        var otherMembers: [StructDeclaration.Member] = []
        
        declaration.members.forEach { member in
            if member.isStatic {
                staticMembers.append(member)
            } else if member.declaration is ConstantDeclaration ||
                (member.declaration as? VariableDeclaration)?.initializerList != nil {
                declarationMembers.append(member)
            } else {
                otherMembers.append(member)
            }
        }

        let newStruct = StructDeclaration(
            attributes: declaration.attributes,
            accessLevelModifier: declaration.accessLevelModifier,
            name: declaration.name,
            genericParameterClause: declaration.genericParameterClause,
            typeInheritanceClause: declaration.typeInheritanceClause,
            genericWhereClause: declaration.genericWhereClause,
            members: otherMembers)
        newStruct.setSourceRange(declaration.sourceRange)
        
        var (tokens, inheritanceRange) = super.tokenizeWithInheritance(newStruct)
        let isStruct = tokens.contains { $0.kind == .keyword && $0.value == "struct" }
        tokens = tokens.replacing({ $0.kind == .keyword && $0.value == "struct"},
                       with: [declaration.newToken(.keyword, "data class")])

        // this is to allow structs with no variables, typically just a collection of methods/values:
        if isStruct && declarationMembers.isEmpty, let bodyStart = tokens.index(where: { $0.value == "{"}) {
            let space = declaration.newToken(.space, " ")
            let dummyDeclaration = [
                declaration.newToken(.startOfScope, "("),
                declaration.newToken(.keyword, "val"),
                space,
                declaration.newToken(.identifier, "_dummy"),
                declaration.newToken(.symbol, ":"),
                space,
                declaration.newToken(.keyword, "Int"),
                space,
                declaration.newToken(.symbol, "="),
                space,
                declaration.newToken(.number, "0"),
                declaration.newToken(.endOfScope, ")"),
                space
            ]
            tokens.insert(contentsOf:dummyDeclaration, at:bodyStart)
        }
        if !staticMembers.isEmpty, let bodyStart = tokens.index(where: { $0.value == "{"}) {
            let companionTokens = indent(tokenizeCompanion(staticMembers, node: declaration))
                .prefix(with: declaration.newToken(.linebreak, "\n"))
                .suffix(with: declaration.newToken(.linebreak, "\n"))
            tokens.insert(contentsOf: companionTokens, at: bodyStart + 1)
        }

        if !declarationMembers.isEmpty, var bodyStart = tokens.index(where: { $0.value == "{"}) {
            let linebreak = declaration.newToken(.linebreak, "\n")
            var declarationTokens: [Token]
            if declarationMembers.count == 1 {
                declarationTokens = declarationMembers
                        .flatMap { tokenize($0) }
            } else {
                let joinTokens = [
                    declaration.newToken(.delimiter, ","),
                    linebreak
                ]
                declarationTokens = indent(
                    declarationMembers
                        .map { tokenize($0) }
                        .joined(tokens: joinTokens))
                    .prefix(with: linebreak)
            }
            var inheritanceTokens = [Token]()
            if !inheritanceRange.isEmpty {
                inheritanceTokens = Array(tokens[inheritanceRange])
                tokens.removeSubrange(inheritanceRange)
                bodyStart -= inheritanceTokens.count
            }
            inheritanceTokens = [] // clearing this for now, inheritance in data class doesn't seem to work?
            tokens.insert(contentsOf: declarationTokens
                .prefix(with: declaration.newToken(.startOfScope, "("))
                .suffix(with: declaration.newToken(.endOfScope, ")")) + inheritanceTokens,
                          at: bodyStart - 1)
        }
        return tokens
    }

    open override func tokenize(_ declaration: ProtocolDeclaration) -> [Token] {
        return super.tokenize(declaration)
            .replacing({ $0.value == "protocol"},
                       with: [declaration.newToken(.keyword, "interface")])
    }

    open override func tokenize(_ member: ProtocolDeclaration.PropertyMember, node: ASTNode) -> [Token] {
        let attrsTokens = tokenize(member.attributes, node: node)
        let modifiersTokens = tokenize(member.modifiers, node: node)

        return [
            attrsTokens,
            modifiersTokens,
            [member.newToken(.keyword, member.getterSetterKeywordBlock.setter == nil ? "val" : "var", node)],
            member.newToken(.identifier, member.name, node) + tokenize(member.typeAnnotation, node: node),
        ].joined(token: member.newToken(.space, " ", node))
    }

    open override func tokenize(_ modifier: AccessLevelModifier, node: ASTNode) -> [Token] {
        return [modifier.newToken(
            .keyword,
            modifier.rawValue.replacingOccurrences(of: "fileprivate", with: "private"),
            node)]
    }

    private func indexOfBalancingBracket(_ tokens:[Token]) -> Int? {
        var count = 0
        for (i, t) in tokens.enumerated() {
            if t.kind == .startOfScope && t.value == "(" {
                count += 1
            }
            if t.kind == .endOfScope && t.value == ")" {
                count -= 1
                if count <= 0 {
                    return i
                }
            }
        }
        return nil
    }
    
    open override func tokenize(_ declaration: InitializerDeclaration) -> [Token] {
        var tokens = super.tokenize(declaration)

        // Find super.init and move to body start
        let superInitExpression = declaration.body.statements
            .flatMap { ($0 as? FunctionCallExpression)?.postfixExpression as? SuperclassExpression }
            .filter { $0.isInitializer }
            .first

        let selfInitExpression = declaration.body.statements
            .flatMap { ($0 as? FunctionCallExpression)?.postfixExpression as? SelfExpression }
            .filter { $0.isInitializer }
            .first

        let bodyStart = tokens.index(where: { $0.node === declaration.body })

        if let bodyStart = bodyStart,
                let initExpression: ASTNode = superInitExpression ?? selfInitExpression,
                let superIndex = tokens.index(where: { $0.node === initExpression }) {
            // changes here to get last ")"
            let superStart = Array(tokens[superIndex...])
//            if let endOfScopeIndex = lastIndexOfTokens(tokens, when: { $0.kind == .endOfScope && $0.value == ")" }) {
            // indexOfBalancingBracket does a better job of getting the last ) when there are other brackets in arguments:
            if let e = indexOfBalancingBracket(superStart) {
                let endOfScopeIndex = superIndex + e
                let keyword = superInitExpression != nil ? "super" : "this"
                let superCallTokens = Array(tokens[superIndex...endOfScopeIndex])
                    .replacing({ $0.node === initExpression }, with: [])
                    .prefix(with: initExpression.newToken(.keyword, keyword))
                    .prefix(with: initExpression.newToken(.space, " "))
                    .prefix(with: initExpression.newToken(.symbol, ":"))
                    .suffix(with: initExpression.newToken(.space, " "))

                tokens.removeSubrange((superIndex - 1)...(endOfScopeIndex + 1))
                tokens.insert(initExpression.newToken(.linebreak, "\n"), at:bodyStart + 1)
                tokens.insert(contentsOf: superCallTokens, at: bodyStart)
            }
        }

        tokens = tokens.filter({ $0.kind != .keyword || $0.value != "override" })
        return tokens.replacing({ $0.value == "init"},
                                with: [declaration.newToken(.keyword, "constructor")])
    }

    open override func tokenize(_ modifier: DeclarationModifier, node: ASTNode) -> [Token] {
        switch modifier {
        case .static, .unowned, .unownedSafe, .unownedUnsafe, .weak, .convenience, .dynamic, .lazy:
            return []
        default:
            return super.tokenize(modifier, node: node)
        }
    }

    open override func tokenize(_ declaration: ExtensionDeclaration) -> [Token] {
        let inheritanceTokens = declaration.typeInheritanceClause.map {
            self.unsupportedTokens(message: "Kotlin does not support inheritance clauses in extensions:  \($0)", element: $0, node: declaration)
        } ?? []
        let whereTokens = declaration.genericWhereClause.map {
            self.unsupportedTokens(message: "Kotlin does not support where clauses in extensions:  \($0)", element: $0, node: declaration)
        } ?? []
        let modifierTokens = declaration.accessLevelModifier.map { tokenize($0, node: declaration) }?
            .suffix(with: declaration.newToken(.space, " ")) ?? []
        let typeTokens = tokenize(declaration.type, node: declaration)

        let memberTokens = declaration.members.map { member in
            var tokens = tokenize(member)
            let firstToken = tokens.index(where: { $0.kind != .linebreak }) ?? 0
            tokens.insert(contentsOf: modifierTokens, at: firstToken)
            if let index = tokens.index(where: { $0.kind == .identifier }) {
                if member.isStatic {
//                    tokens.insert(contentsOf: [declaration.newToken(.keyword, "Companion"), declaration.newToken(.delimiter, ".")], at: index) -- this does not seem right, extending is just adding functions etc to class
                }
                tokens.insert(contentsOf: typeTokens + declaration.newToken(.delimiter, "."), at: index)
            }
            return tokens
        }.joined(token: declaration.newToken(.linebreak, "\n"))

        return [
            inheritanceTokens,
            whereTokens,
            memberTokens
        ].joined(token: declaration.newToken(.linebreak, "\n"))
    }
    
    open override func tokenize(_ declaration: VariableDeclaration) -> [Token] {
        let spaceToken = declaration.newToken(.space, " ")
        let mutabilityTokens = [declaration.newToken(.keyword, declaration.isReadOnly ? "val" : "var")]
        let attrsTokenGroups = declaration.attributes.map { tokenize($0, node: declaration) }
        var modifierTokenGroups = declaration.modifiers.map { tokenize($0, node: declaration) }
        var bodyTokens = tokenize(declaration.body, node: declaration)
        
        if declaration.isImplicitlyUnwrapped {
            modifierTokenGroups = [[declaration.newToken(.keyword, "lateinit")]] + modifierTokenGroups
        }
        
        if declaration.isOptional && declaration.initializerList?.last?.initializerExpression == nil {
                bodyTokens = bodyTokens + [
                    spaceToken,
                    declaration.newToken(.symbol, "="),
                    spaceToken,
                    declaration.newToken(.keyword, "null")
                ]
        } else if declaration.isLazy {
            bodyTokens = bodyTokens
                .replacing({ $0.value == " = " }, with: [
                    spaceToken,
                    declaration.newToken(.keyword, "by"),
                    spaceToken,
                    declaration.newToken(.keyword, "lazy"),
                    spaceToken,
                    ], amount: 1)
            if bodyTokens.last?.value == ")" {
                bodyTokens.removeLast()
            }
            if bodyTokens.last?.value == "(" {
                bodyTokens.removeLast()
            }
        }

        return [
            attrsTokenGroups.joined(token: spaceToken),
            modifierTokenGroups.joined(token: spaceToken),
            mutabilityTokens,
            bodyTokens
        ].joined(token: spaceToken)
    }

    open override func tokenize(_ body: VariableDeclaration.Body, node: ASTNode) -> [Token] {
        switch body {
        case let .codeBlock(name, typeAnnotation, codeBlock):
            let getterTokens = [
                body.newToken(.keyword, "get()", node),
                body.newToken(.space, " ", node)
            ]
            return body.newToken(.identifier, name, node) +
                tokenize(typeAnnotation, node: node) +
                body.newToken(.linebreak, "\n", node) +
                indent(
                    getterTokens +
                    tokenize(codeBlock)
                )
            
        case let .willSetDidSetBlock(name, typeAnnotation, initExpr, block):
            let newName = block.willSetClause?.name ?? "newValue"
            let oldName = block.didSetClause?.name ?? "oldValue"
            let fieldAssignmentExpression = AssignmentOperatorExpression(
                leftExpression: IdentifierExpression(kind: IdentifierExpression.Kind.identifier("field", nil)),
                rightExpression: IdentifierExpression(kind: IdentifierExpression.Kind.identifier(newName, nil))
            )
            let oldValueAssignmentExpression = ConstantDeclaration(initializerList: [
                PatternInitializer(pattern: IdentifierPattern(identifier: oldName),
                                   initializerExpression: IdentifierExpression(kind: IdentifierExpression.Kind.identifier("field", nil)))
            ])
            let setterCodeBlock = CodeBlock(statements:
                    (block.didSetClause?.codeBlock.statements.count ?? 0 > 0 ? [oldValueAssignmentExpression] : []) +
                    (block.willSetClause?.codeBlock.statements ?? []) +
                    [fieldAssignmentExpression] +
                    (block.didSetClause?.codeBlock.statements ?? [])
            )
            let setterTokens = tokenize(GetterSetterBlock.SetterClause(name: newName, codeBlock: setterCodeBlock), node: node)            
            let typeAnnoTokens = typeAnnotation.map { tokenize($0, node: node) } ?? []
            let initTokens = initExpr.map { body.newToken(.symbol, " = ", node) + tokenize($0) } ?? []
            return [
                body.newToken(.identifier, name, node)] +
                typeAnnoTokens +
                initTokens +
                [body.newToken(.linebreak, "\n", node)] +
                indent(setterTokens)
            
        default:
            return super.tokenize(body, node: node).removingTrailingSpaces()
        }
    }

    open override func tokenize(_ block: GetterSetterBlock, node: ASTNode) -> [Token] {
        let getterTokens = tokenize(block.getter, node: node)
            .replacing({ $0.kind == .keyword && $0.value == "get" }, with: [block.newToken(.keyword, "get()", node)])
        let setterTokens = block.setter.map { tokenize($0, node: node) } ?? []
        return [
            indent(getterTokens),
            indent(setterTokens),
        ].joined(token: block.newToken(.linebreak, "\n", node))
        .prefix(with: block.newToken(.linebreak, "\n", node))
    }

    open override func tokenize(_ block: GetterSetterBlock.SetterClause, node: ASTNode) -> [Token] {
        let newSetter = GetterSetterBlock.SetterClause(attributes: block.attributes,
                                                       mutationModifier: block.mutationModifier,
                                                       name: block.name ?? "newValue",
                                                       codeBlock: block.codeBlock)        
        return super.tokenize(newSetter, node: node)
    }

    open override func tokenize(_ block: WillSetDidSetBlock, node: ASTNode) -> [Token] {
        let name = block.willSetClause?.name ?? block.didSetClause?.name ?? "newValue"
        let willSetBlock = block.willSetClause.map { tokenize($0.codeBlock) }?.tokensOnScope(depth: 1) ?? []
        let didSetBlock = block.didSetClause.map { tokenize($0.codeBlock) }?.tokensOnScope(depth: 1) ?? []
        let assignmentBlock = [
            block.newToken(.identifier, "field", node),
            block.newToken(.keyword, " = ", node),
            block.newToken(.identifier, name, node)
        ]
        return [
            [block.newToken(.startOfScope, "{", node)],
            willSetBlock,
            indent(assignmentBlock),
            didSetBlock,
            [block.newToken(.endOfScope, "}", node)]
        ].joined(token: block.newToken(.linebreak, "\n", node))
        
    }
    
    open override func tokenize(_ declaration: ImportDeclaration) -> [Token] {
        return []
    }
    
//    this methid adds an extension to add a function <Enum>.fromRaw() to simple enums that have set values.
//    This then needs to be defined somewhere:
//    special helper companion class that is inserted into enums with values, for fromRaw conversion:
//    open class ZEnumCompanion<T, V>(private val valueMap: Map<T, V>) {
//    fun rawValue(type: T) = valueMap[type]
//    }
//    This should be optional of course.

    private func makeFromRawFunc(declaration d: EnumDeclaration, typeToken: Token) -> [Token] {
        //        companion object : ZEnumCompanion<Int, XWeekday>(XWeekday.values().associateBy(XWeekday::rawValue))
        let name = d.newToken(.identifier, d.name)
        let space = d.newToken(.space, " ")
        return [
            d.newToken(.keyword, "companion"),
            space,
            d.newToken(.keyword, "object"),
            space,
            d.newToken(.delimiter, ":"),
            space,
            d.newToken(.identifier, "ZEnumCompanion"),
            d.newToken(.startOfScope, "<"),
            typeToken,
            d.newToken(.delimiter, ","),
            space,
            name,
            d.newToken(.endOfScope, ">"),
            d.newToken(.startOfScope, "("),
            name,
            d.newToken(.delimiter, "."),
            d.newToken(.identifier, "values"),
            d.newToken(.startOfScope, "("),
            d.newToken(.endOfScope, ")"),
            d.newToken(.delimiter, "."),
            d.newToken(.identifier, "associateBy"),
            d.newToken(.startOfScope, "("),
            name,
            d.newToken(.delimiter, "::"),
            d.newToken(.identifier, "rawValue"),
            d.newToken(.endOfScope, ")"),
            d.newToken(.endOfScope, ")")
        ]
    }
    
    // these two methods below allow getting simple, non type enums and single-type enums and outputing their values.
    private func getAssignments(rawCases:[AST.EnumDeclaration.RawValueStyleEnumCase], declaration:EnumDeclaration, typeToken:Token) -> [Token] {
        let space = declaration.newToken(.space, " ")
        var acomps = [[Token]]()
        var intStart = 0
        for r in rawCases {
            for c in r.cases {
                var set = space // just set it to something
                if (c.assignment == nil) {
                    switch typeToken.value {
                    case "String":
                        set = declaration.newToken(.string, "\"\(c.name)\"")
                    default: // Int
                        set = declaration.newToken(.number, "\(intStart)")
                        intStart += 1
                    }
                } else {
                    switch c.assignment! {
                    case .string(let s):
                            set = declaration.newToken(.string, "\"\(s)\"")
                    case .floatingPoint(let f):
                        set = declaration.newToken(.number, "\(f)")
                        intStart = Int(f) + 1
                    case .boolean(let b):
                        set = declaration.newToken(.keyword, "\(b)")
                    case .integer(let i):
                        set = declaration.newToken(.number, "\(i)")
                        intStart = i + 1
                    }
                }
                let c = [
                    declaration.newToken(.identifier, c.name),
                    declaration.newToken(.startOfScope, "("),
                    set,
                    declaration.newToken(.endOfScope, ")")
                ]
                acomps.append(c)
            }
        }
        return acomps.joined(tokens: [ declaration.newToken(.delimiter, ","), space ])
    }
    
    private func getSimpleAssignments(simpleCases:[AST.EnumDeclaration.UnionStyleEnumCase.Case], declaration:EnumDeclaration, typeToken:Token) -> [Token] {
        let space = declaration.newToken(.space, " ")
        var acomps = [[Token]]()
        var intStart = 0
        var boolStart = false
        for s in simpleCases {
            var set = space // hack to set it to space to start
            switch typeToken.value {
            case "Bool":
                set = declaration.newToken(.keyword, "\(boolStart)")
                boolStart = !boolStart
            case "String":
                set = declaration.newToken(.string, "\"\(s.name)\"")
            default:
                set = declaration.newToken(.number, "\(intStart)")
                intStart += 1
            }
            let comp = [
                declaration.newToken(.identifier, s.name),
                declaration.newToken(.startOfScope, "("),
                set,
                declaration.newToken(.endOfScope, ")")
            ]
            acomps.append(comp)
        }
        return acomps.joined(tokens: [ declaration.newToken(.delimiter, ","), space ])
    }

    // this makes a enum with values output. Complex enums not supported.
    private func makeValueEnum(declaration:EnumDeclaration, simpleCases:[AST.EnumDeclaration.UnionStyleEnumCase.Case]) -> [Token] {
        let attrsTokens = tokenize(declaration.attributes, node: declaration)
        let modifierTokens = declaration.accessLevelModifier.map { tokenize($0, node: declaration) } ?? []
        let lineBreak = declaration.newToken(.linebreak, "\n")
        let space = declaration.newToken(.space, " ")
        let inheritanceTokens = declaration.typeInheritanceClause.map { tokenize($0, node: declaration) } ?? []
        let rawCases = declaration.members.flatMap { $0.rawValueStyleEnumCase }
        
        let headTokens = [
            attrsTokens,
            modifierTokens,
            [declaration.newToken(.keyword, "enum")],
            [declaration.newToken(.keyword, "class")],
            [declaration.newToken(.identifier, declaration.name)],
            ].joined(token: space)
        
        let typeToken = inheritanceTokens.first(where: { $0.kind == .identifier })!
        let initTokens = [
            declaration.newToken(.startOfScope, "("),
            declaration.newToken(.keyword, "val"),
            space,
            declaration.newToken(.identifier, "rawValue"),
            declaration.newToken(.delimiter, ":"),
            space,
            IdentifiersTransformPlugin.TransformType(typeToken),
            declaration.newToken(.endOfScope, ")"),
            space
        ]
        var comps = [Token]()
        var fromRawTokens = [Token]()
        if simpleCases.count > 0 {
            comps = getSimpleAssignments(simpleCases:simpleCases, declaration:declaration, typeToken:typeToken)
        } else {
            comps = getAssignments(rawCases:rawCases, declaration:declaration, typeToken:typeToken)
            fromRawTokens = [lineBreak] + indent(makeFromRawFunc(declaration:declaration, typeToken:typeToken))
        }
        let bodyTokens = [ declaration.newToken(.startOfScope, "{"), lineBreak ] +
            indent(comps) + [ declaration.newToken(.delimiter, ";")] +
            fromRawTokens +
            [ lineBreak, declaration.newToken(.endOfScope, "}") ]
        return headTokens + initTokens + bodyTokens
    }

    open override func tokenize(_ declaration: EnumDeclaration) -> [Token] {
        let unionCases = declaration.members.flatMap { $0.unionStyleEnumCase }
        let simpleCases = unionCases.flatMap { $0.cases }
        let lineBreak = declaration.newToken(.linebreak, "\n")
        let space = declaration.newToken(.space, " ")

//        guard unionCases.count == declaration.members.count &&
//            declaration.genericParameterClause == nil &&
//            declaration.genericWhereClause == nil else {
//                return self.unsupportedTokens(message: "Complex enums not supported yet", element: declaration, node: declaration).suffix(with: lineBreak) +
//                    super.tokenize(declaration)
//        }
//
        // Simple enums (no tuples)
        if !simpleCases.contains(where: { $0.tuple != nil }) && declaration.typeInheritanceClause == nil {
            let attrsTokens = tokenize(declaration.attributes, node: declaration)
            let modifierTokens = declaration.accessLevelModifier.map { tokenize($0, node: declaration) } ?? []
            let headTokens = [
                attrsTokens,
                modifierTokens,
                [declaration.newToken(.keyword, "enum")],
                [declaration.newToken(.keyword, "class")],
                [declaration.newToken(.identifier, declaration.name)],
                ].joined(token: space)

            let membersTokens = simpleCases.map { c in
                return [c.newToken(.identifier, c.name, declaration)]
                }.joined(tokens: [
                    declaration.newToken(.delimiter, ","),
                    lineBreak
                    ])

            return headTokens +
                [space, declaration.newToken(.startOfScope, "{"), lineBreak] +
                indent(membersTokens) +
                [lineBreak, declaration.newToken(.endOfScope, "}")]
        }
        // Tuples or inhertance required sealed classes
        else {
            return makeValueEnum(declaration:declaration, simpleCases:simpleCases)
            
            let attrsTokens = tokenize(declaration.attributes, node: declaration)
            let modifierTokens = declaration.accessLevelModifier.map { tokenize($0, node: declaration) } ?? []
            let inheritanceTokens = declaration.typeInheritanceClause.map { tokenize($0, node: declaration) } ?? []
            let headTokens = [
                attrsTokens,
                modifierTokens,
                [declaration.newToken(.keyword, "sealed")],
                [declaration.newToken(.keyword, "class")],
                [declaration.newToken(.identifier, declaration.name)],
                inheritanceTokens
            ].joined(token: space)

            let membersTokens = simpleCases.map { c in
                var tokenSections: [[Token]]
                if let tuple = c.tuple {
                    tokenSections = [
                        [c.newToken(.keyword, "data", declaration)],
                        [c.newToken(.keyword, "class", declaration)],
                        [c.newToken(.identifier, c.name, declaration)] + tokenize(tuple, node: declaration)
                    ]
                } else {
                    tokenSections = [
                        [c.newToken(.keyword, "object", declaration)],
                        [c.newToken(.identifier, c.name, declaration)]
                    ]
                }
                tokenSections += [
                    [c.newToken(.symbol, ":", declaration)],
                    [c.newToken(.identifier, declaration.name, declaration), c.newToken(.startOfScope, "(", declaration), c.newToken(.endOfScope, ")", declaration)]
                ]
                return tokenSections.joined(token: space)
            }.joined(token: lineBreak)

            return headTokens +
                [space, declaration.newToken(.startOfScope, "{"), lineBreak] +
                indent(membersTokens) +
                [lineBreak, declaration.newToken(.endOfScope, "}")]
        }

    }
    
    open override func tokenize(_ codeBlock: CodeBlock) -> [Token] {
        guard codeBlock.statements.count == 1,
            let returnStatement = codeBlock.statements.first as? ReturnStatement,
            let parent = codeBlock.lexicalParent as? Declaration else {
            return super.tokenize(codeBlock)
        }
        let sameLine = parent is VariableDeclaration
        let separator = sameLine ? codeBlock.newToken(.space, " ") : codeBlock.newToken(.linebreak, "\n")
        let tokens = Array(tokenize(returnStatement).dropFirst(2))
        return [
            [codeBlock.newToken(.symbol, "=")],
            sameLine ? tokens : indent(tokens)
        ].joined(token: separator)
    }
    
    // MARK: - Statements

    open override func tokenize(_ statement: GuardStatement) -> [Token] {
        let declarationTokens = tokenizeDeclarationConditions(statement.conditionList, node: statement)
        if statement.isUnwrappingGuard, let body = statement.codeBlock.statements.first {
            return [
                Array(declarationTokens.dropLast()),
                [statement.newToken(.symbol, "?:")],
                tokenize(body),
            ].joined(token: statement.newToken(.space, " "))
        } else {
            let invertedConditions = statement.conditionList.map(InvertedCondition.init)
            return declarationTokens + [
                [statement.newToken(.keyword, "if")],
                tokenize(invertedConditions, node: statement),
                tokenize(statement.codeBlock)
            ].joined(token: statement.newToken(.space, " "))
        }
    }

    open override func tokenize(_ statement: IfStatement) -> [Token] {
        return tokenizeDeclarationConditions(statement.conditionList, node: statement) +
            super.tokenize(statement)
    }

    open override func tokenize(_ statement: SwitchStatement) -> [Token] {
        var casesTokens = statement.newToken(.startOfScope, "{") + statement.newToken(.endOfScope, "}")
        if !statement.cases.isEmpty {
            casesTokens = [
                [statement.newToken(.startOfScope, "{")],
                indent(
                    statement.cases.map { tokenize($0, node: statement) }
                    .joined(token: statement.newToken(.linebreak, "\n"))),
                [statement.newToken(.endOfScope, "}")]
                ].joined(token: statement.newToken(.linebreak, "\n"))
        }

        return [
            [statement.newToken(.keyword, "when")],
            tokenize(statement.expression)
                .prefix(with: statement.newToken(.startOfScope, "("))
                .suffix(with: statement.newToken(.endOfScope, ")")),
            casesTokens
            ].joined(token: statement.newToken(.space, " "))
    }

    open override func tokenize(_ statement: SwitchStatement.Case, node: ASTNode) -> [Token] {
        let separatorTokens =  [
            statement.newToken(.space, " ", node),
            statement.newToken(.delimiter, "->", node),
            statement.newToken(.space, " ", node),
        ]
        switch statement {
        case let .case(itemList, stmts):
            // removed prefix, don't think it works like this anymore?
//            let prefix = itemList.count > 1 ? [statement.newToken(.keyword, "in", node), statement.newToken(.space, " ", node)] : []
            let conditions = itemList.map { tokenize($0, node: node) }.joined(token: statement.newToken(.delimiter, ", ", node))
            var statements = tokenize(stmts, node: node)
            if stmts.count > 1 || statements.filter({ $0.kind == .linebreak }).count > 1 {
                let linebreak = statement.newToken(.linebreak, "\n", node)
                statements = [statement.newToken(.startOfScope, "{", node), linebreak] +
                    indent(statements) +
                    [linebreak, statement.newToken(.endOfScope, "}", node)]
            }
            return conditions + separatorTokens + statements // prefix +

        case .default(let stmts):
            let defStatements = tokenize(stmts, node: node)
            // if just break, don't output else?
            if defStatements.count == 1 && defStatements[0].kind == .keyword && defStatements[0].value == "break" {
                return []
            }
            return
                [statement.newToken(.keyword, "else", node)] +
                    separatorTokens + defStatements
            
        }
    }

    open override func tokenize(_ statement: SwitchStatement.Case.Item, node: ASTNode) -> [Token] {
        guard let enumCasePattern = statement.pattern as? EnumCasePattern else {
            return super.tokenize(statement, node: node)
        }
        let patternWithoutTuple = EnumCasePattern(typeIdentifier: enumCasePattern.typeIdentifier, name: enumCasePattern.name, tuplePattern: nil)
        return [
            tokenize(patternWithoutTuple, node: node),
            statement.whereExpression.map { _ in [statement.newToken(.keyword, "where", node)] } ?? [],
            statement.whereExpression.map { tokenize($0) } ?? []
            ].joined(token: statement.newToken(.space, " ", node))
    }


    open override func tokenize(_ statement: ForInStatement) -> [Token] {
        var tokens = super.tokenize(statement)
        if let endIndex = tokens.index(where: { $0.value == "{"}) {
            tokens.insert(statement.newToken(.endOfScope, ")"), at: endIndex - 1)
            tokens.insert(statement.newToken(.startOfScope, "("), at: 2)
        }
        return tokens
    }

    // MARK: - Expressions
    open override func tokenize(_ expression: ExplicitMemberExpression) -> [Token] {
        switch expression.kind {
        case let .namedType(postfixExpr, identifier):
            let postfixTokens = tokenize(postfixExpr)
            var delimiters = [expression.newToken(.delimiter, ".")]

            if postfixTokens.last?.value != "?" &&
                postfixTokens.removingOtherScopes().contains(where: {
                    $0.value == "?" && $0.origin is OptionalChainingExpression
                }) {
                delimiters = delimiters.prefix(with: expression.newToken(.symbol, "?"))
            }
            return postfixTokens + delimiters + expression.newToken(.identifier, identifier)
        default:
            return super.tokenize(expression)
        }
    }

    open override func tokenize(_ expression: AssignmentOperatorExpression) -> [Token] {
        guard expression.leftExpression is WildcardExpression else {
            return super.tokenize(expression)
        }
        return tokenize(expression.rightExpression)
    }

    open override func tokenize(_ expression: LiteralExpression) -> [Token] {
        switch expression.kind {
        case .nil:
            return [expression.newToken(.keyword, "null")]
        case let .interpolatedString(_, rawText):
            return tokenizeInterpolatedString(rawText, node: expression)
        case .array(let exprs):
            // Trying to output example mutableListOf<String> if it's a declartion, or mutableListOf("xx", "yy") if it's an instance with values, not great
            var hasType = false
            for e in exprs {
                switch e {
                case let _ as IdentifierExpression:
                    hasType = true
                default:
                    break
                }
            }
            if hasType && exprs.count == 1 && !firstCharIsUpper(str:exprs[0].description) {
                hasType = false
            }
            let middle = exprs.map { tokenize($0) }.joined(token: expression.newToken(.delimiter, ", "))
            let mutable = [ expression.newToken(.identifier, "mutableListOf") ]
            if hasType {
                return
                    mutable +
                    [ expression.newToken(.startOfScope, "<") ] +
                    middle +
                    [ expression.newToken(.endOfScope, ">") ]
            } else {
                return
                    mutable +
                        [ expression.newToken(.startOfScope, "(") ] +
                        middle +
                        [ expression.newToken(.endOfScope, ")") ]
            }
            // have to output mutableMap since all swift arrays are mutable. Not great.
//                expression.newToken(.identifier, "listOf") +
//                expression.newToken(.startOfScope, "(") +
//                exprs.map { tokenize($0) }.joined(token: expression.newToken(.delimiter, ", ")) +
//                expression.newToken(.endOfScope, ")")
        case .dictionary(let entries):
            return
                expression.newToken(.identifier, "mutableMapOf") +
                expression.newToken(.startOfScope, "<") +
                entries.map { tokenize($0, node: expression) }
                    .joined(token: expression.newToken(.delimiter, ", ")) +
                expression.newToken(.endOfScope, ">")
//                expression.newToken(.startOfScope, "(") +
//                expression.newToken(.endOfScope, ")")
        default:
            return super.tokenize(expression)
        }
    }

    open override func tokenize(_ entry: DictionaryEntry, node: ASTNode) -> [Token] {
        return tokenize(entry.key) +
//            entry.newToken(.space, " ", node) +
            entry.newToken(.delimiter, ", ", node) +
  //          entry.newToken(.space, " ", node) +
            tokenize(entry.value)
    }

    open override func tokenize(_ expression: SelfExpression) -> [Token] {
        return super.tokenize(expression)
            .replacing({ $0.value == "self"},
                       with: [expression.newToken(.keyword, "this")])
    }

    open override func tokenize(_ expression: IdentifierExpression) -> [Token] {
        switch expression.kind {
        case let .implicitParameterName(i, generic) where i == 0:
            return expression.newToken(.identifier, "it") +
                generic.map { tokenize($0, node: expression) }
        default:
            return super.tokenize(expression)
        }
    }

    open override func tokenize(_ expression: BinaryOperatorExpression) -> [Token] {
        let binaryOperator: Operator
        switch expression.binaryOperator {
        case "..<": binaryOperator = "until"
        case "...": binaryOperator = ".."
        case "??": binaryOperator = "?:"
        default: binaryOperator = expression.binaryOperator
        }
        return super.tokenize(expression)
            .replacing({ $0.kind == .symbol && $0.value == expression.binaryOperator },
                       with: [expression.newToken(.symbol, binaryOperator)])
    }

    open override func tokenize(_ expression: FunctionCallExpression) -> [Token] {
        var tokens = super.tokenize(expression)
        if (expression.postfixExpression is OptionalChainingExpression || expression.postfixExpression is ForcedValueExpression),
            let startIndex = tokens.indexOf(kind: .startOfScope, after: 0) {
            tokens.insert(contentsOf: [
                expression.newToken(.symbol, "."),
                expression.newToken(.keyword, "invoke")
            ], at: startIndex)
        }
        tokens = IdentifiersTransformPlugin.TransformKotlinFunctionCallExpression(tokens)

        return tokens // good place for debugging
    }
    
    open override func tokenize(_ expression: FunctionCallExpression.Argument, node: ASTNode) -> [Token] {
        return super.tokenize(expression, node: node)
            .replacing({ $0.value == ": " && $0.kind == .delimiter },
                       with: [expression.newToken(.delimiter, " = ", node)])
    }

    open override func tokenize(_ expression: ClosureExpression) -> [Token] {
        var tokens = super.tokenize(expression)
        if expression.signature != nil {
            let arrowTokens = expression.signature?.parameterClause != nil ? [expression.newToken(.symbol, " -> ")] : []
            tokens = tokens.replacing({ $0.value == "in" },
                                      with: arrowTokens,
                                      amount: 1)
        }
        
        // Last return can be removed
        if let lastReturn = expression.statements?.last as? ReturnStatement,
            let index = tokens.index(where: { $0.node === lastReturn && $0.value == "return" }) {
            tokens.remove(at: index)
            tokens.remove(at: index)
        }
        
        // Other returns must be suffixed with call name
        if let callExpression = expression.lexicalParent as? FunctionCallExpression { //,
        //    let memberExpression = callExpression.postfixExpression as? ExplicitMemberExpression {
            while let returnIndex = tokens.index(where: { $0.value == "return" }) {
                tokens.remove(at: returnIndex)
                tokens.insert(expression.newToken(.keyword, "return@"), at: returnIndex)
//                tokens.insert(expression.newToken(.identifier, memberExpression.identifier), at: returnIndex + 1)
                tokens.insert(expression.newToken(.identifier, callExpression.postfixExpression.description), at: returnIndex + 1)
            }
        }
        return tokens
    }

    open override func tokenize(_ expression: ClosureExpression.Signature, node: ASTNode) -> [Token] {
        return expression.parameterClause.map { tokenize($0, node: node) } ?? []
    }

    open override func tokenize(_ expression: ClosureExpression.Signature.ParameterClause, node: ASTNode) -> [Token] {
        switch expression {
        case .parameterList(let params):
            return params.map { tokenize($0, node: node) }.joined(token: expression.newToken(.delimiter, ", ", node))
        default:
            return super.tokenize(expression, node: node)
        }
    }

    open override func tokenize(_ expression: ClosureExpression.Signature.ParameterClause.Parameter, node: ASTNode) -> [Token] {
        return [expression.newToken(.identifier, expression.name, node)]
    }

    open override func tokenize(_ expression: TryOperatorExpression) -> [Token] {
        switch expression.kind {
        case .try(let expr):
            return tokenize(expr)
        case .forced(let expr):
            return tokenize(expr)
        case .optional(let expr):
            let catchSignature = [
                expression.newToken(.startOfScope, "("),
                expression.newToken(.identifier, "e"),
                expression.newToken(.delimiter, ":"),
                expression.newToken(.space, " "),
                expression.newToken(.identifier, "Throwable"),
                expression.newToken(.endOfScope, ")"),
            ]
            let catchBodyTokens = [
                expression.newToken(.startOfScope, "{"),
                expression.newToken(.space, " "),
                expression.newToken(.keyword, "null"),
                expression.newToken(.space, " "),
                expression.newToken(.endOfScope, "}"),
            ]
            return [
                [expression.newToken(.keyword, "try")],
                [expression.newToken(.startOfScope, "{")],
                tokenize(expr),
                [expression.newToken(.endOfScope, "}")],
                [expression.newToken(.keyword, "catch")],
                catchSignature,
                catchBodyTokens
            ].joined(token: expression.newToken(.space, " "))
        }
    }

    open override func tokenize(_ expression: ForcedValueExpression) -> [Token] {
        return tokenize(expression.postfixExpression) + expression.newToken(.symbol, "!!")
    }

    open override func tokenize(_ expression: TernaryConditionalOperatorExpression) -> [Token] {
        return [
            [expression.newToken(.keyword, "if")],
            tokenize(expression.conditionExpression)
                .prefix(with: expression.newToken(.startOfScope, "("))
                .suffix(with: expression.newToken(.endOfScope, ")")),
            tokenize(expression.trueExpression),
            [expression.newToken(.keyword, "else")],
            tokenize(expression.falseExpression),
            ].joined(token: expression.newToken(.space, " "))
    }


    open override func tokenize(_ expression: SequenceExpression) -> [Token] {
        var elementTokens = expression.elements.map({ tokenize($0, node: expression) })

        //If there is a ternary, then prefix with if
        if let ternaryOperatorIndex = expression.elements.index(where: { $0.isTernaryConditionalOperator }),
            ternaryOperatorIndex > 0 {
            let assignmentIndex = expression.elements.index(where: { $0.isAssignmentOperator }) ?? -1
            let prefixTokens = [
                expression.newToken(.keyword, "if"),
                expression.newToken(.space, " "),
                expression.newToken(.startOfScope, "("),
            ]
            elementTokens[assignmentIndex + 1] =
                prefixTokens +
                elementTokens[assignmentIndex + 1]
            elementTokens[ternaryOperatorIndex - 1] = elementTokens[ternaryOperatorIndex - 1]
                .suffix(with: expression.newToken(.endOfScope, ")"))
        }
        return elementTokens.joined(token: expression.newToken(.space, " "))
    }

    open override func tokenize(_ element: SequenceExpression.Element, node: ASTNode) -> [Token] {
        switch element {
        case .ternaryConditionalOperator(let expr):
            return [
                tokenize(expr),
                [node.newToken(.keyword, "else")],
                ].joined(token: node.newToken(.space, " "))
        default:
            return super.tokenize(element, node: node)
        }
    }

    open override func tokenize(_ expression: OptionalChainingExpression) -> [Token] {
        var tokens = tokenize(expression.postfixExpression)
        if tokens.last?.value != "this" {
            tokens.append(expression.newToken(.symbol, "?"))
        }
        return tokens
    }
    
    // MARK: - Types
    open override func tokenize(_ type: ArrayType, node: ASTNode) -> [Token] {
        return
            // need mutable list here since it swift code assums it's mutable
            type.newToken(.identifier, "MutableList", node) +
//            type.newToken(.identifier, "List", node) +
            type.newToken(.startOfScope, "<", node) +
            tokenize(type.elementType, node: node) +
            type.newToken(.endOfScope, ">", node)
    }

    open override func tokenize(_ type: DictionaryType, node: ASTNode) -> [Token] {
        let keyTokens = tokenize(type.keyType, node: node)
        let valueTokens = tokenize(type.valueType, node: node)
        return
//            [type.newToken(.identifier, "Map", node), type.newToken(.startOfScope, "<", node)] +
            // needs mutable here too, swift code things all maps are mutable
            [type.newToken(.identifier, "MutableMap", node), type.newToken(.startOfScope, "<", node)] +
            keyTokens +
            [type.newToken(.delimiter, ", ", node)] +
            valueTokens +
            [type.newToken(.endOfScope, ">", node)]
    }

    open override func tokenize(_ type: FunctionType, node: ASTNode) -> [Token] {
        var tokens = super.tokenize(type, node: node)
            .replacing({ $0.value == "Void" && $0.kind == .identifier },
                       with: [type.newToken(.identifier, "Unit", node)])
        while true { // remove _ in function type's parameters
            if let i = tokens.index(where:{ $0.kind == .identifier && $0.value == "_"  }) {
                tokens.remove(at:i)
                tokens.remove(at:i)
                continue
            }
            break
        }
        return tokens
    }

    open override func tokenize(_ type: TypeIdentifier.TypeName, node: ASTNode) -> [Token] {
        return type.newToken(.identifier, typeConversions[type.name] ?? type.name, node) +
            type.genericArgumentClause.map { tokenize($0, node: node) }
    }

    open override func tokenize(_ type: ImplicitlyUnwrappedOptionalType, node: ASTNode) -> [Token] {
        return tokenize(type.wrappedType, node: node)
    }

    open override func tokenize(_ attribute: Attribute, node: ASTNode) -> [Token] {
        if ["escaping", "autoclosure", "discardableResult"].contains(attribute.name) {
            return []
        }
        return super.tokenize(attribute, node: node)
    }

    open override func tokenize(_ type: TupleType, node: ASTNode) -> [Token] {
        var typeWithNames = [TupleType.Element]()

        if type.elements.count > 1 && type.elements.index(where:{ $0.type is FunctionType}) == nil {
            // handle Pair/Triple
            for e in type.elements {
                typeWithNames.append(e)
            }
            let name = (typeWithNames.count == 2 ? "Pair" : "Triple")
            return type.newToken(.keyword, name, node) +
                type.newToken(.startOfScope, "<", node) +
                typeWithNames.map { tokenize($0, node: node) }.joined(token: type.newToken(.delimiter, ", ", node)) +
                type.newToken(.endOfScope, ">", node)
        }
        for (index, element) in type.elements.enumerated() {
            if element.name != nil || element.type is FunctionType {
                typeWithNames.append(element)
            } else {
                typeWithNames.append(TupleType.Element(type: element.type, name: "v\(index + 1)", attributes: element.attributes, isInOutParameter: element.isInOutParameter))
            }
        }
        return type.newToken(.startOfScope, "(", node) +
            typeWithNames.map { tokenize($0, node: node) }.joined(token: type.newToken(.delimiter, ", ", node)) +
            type.newToken(.endOfScope, ")", node)
    }

    open override func tokenize(_ type: TupleType.Element, node: ASTNode) -> [Token] {
        var nameTokens = [Token]()
        if let name = type.name {
            nameTokens = type.newToken(.keyword, "val", node) +
                type.newToken(.space, " ", node) +
                type.newToken(.identifier, name, node) +
                type.newToken(.delimiter, ":", node)
        }
        return [
            nameTokens,
            tokenize(type.attributes, node: node),
            tokenize(type.type, node: node)
        ].joined(token: type.newToken(.space, " ", node))
    }

    // MARK: - Patterns


    // MARK: - Utils

    open override func tokenize(_ conditions: ConditionList, node: ASTNode) -> [Token] {
        return conditions.map { tokenize($0, node: node) }
            .joined(token: node.newToken(.delimiter, " && "))
            .prefix(with: node.newToken(.startOfScope, "("))
            .suffix(with: node.newToken(.endOfScope, ")"))
    }

    open override func tokenize(_ condition: Condition, node: ASTNode) -> [Token] {
        switch condition {
        case let .let(pattern, _):
            return tokenizeNullCheck(pattern: pattern, condition: condition, node: node)
        case let .var(pattern, _):
            return tokenizeNullCheck(pattern: pattern, condition: condition, node: node)
        default:
            return super.tokenize(condition, node: node)
        }
    }

    open override func tokenize(_ origin: ThrowsKind, node: ASTNode) -> [Token] {
        return []
    }

    open func unsupportedTokens(message: String, element: ASTTokenizable, node: ASTNode) -> [Token] {
        return [element.newToken(.comment, "//FIXME: @SwiftKotlin - \(message)", node)]
    }

    // MARK: - Private helpers

    private func tokenizeDeclarationConditions(_ conditions: ConditionList, node: ASTNode) -> [Token] {
        var declarationTokens = [Token]()
        for condition in conditions {
            switch condition {
            case .let, .var:
                declarationTokens.append(contentsOf:
                    super.tokenize(condition, node: node)
                        .replacing({ $0.value == "let" },
                                   with: [condition.newToken(.keyword, "val", node)]))
                declarationTokens.append(condition.newToken(.linebreak, "\n", node))
            default: continue
            }
        }
        return declarationTokens
    }

    private func tokenizeNullCheck(pattern: AST.Pattern, condition: Condition, node: ASTNode) -> [Token] {
        return [
            tokenize(pattern, node: node),
            [condition.newToken(.symbol, "!=", node)],
            [condition.newToken(.keyword, "null", node)],
        ].joined(token: condition.newToken(.space, " ", node))
    }


    open func tokenize(_ conditions: InvertedConditionList, node: ASTNode) -> [Token] {
        return conditions.map { tokenize($0, node: node) }
            .joined(token: node.newToken(.delimiter, " || "))
            .prefix(with: node.newToken(.startOfScope, "("))
            .suffix(with: node.newToken(.endOfScope, ")"))
    }

    private func tokenize(_ condition: InvertedCondition, node: ASTNode) -> [Token] {
        let tokens = tokenize(condition.condition, node: node)
        var invertedTokens = [Token]()
        var inverted = false
        var lastExpressionIndex = 0
        for token in tokens {
            if let origin = token.origin, let node = token.node {
                if origin is SequenceExpression || origin is BinaryExpression || origin is Condition {
                    let inversionMap = [
                        "==": "!=",
                        "!=": "==",
                        ">": "<=",
                        ">=": "<",
                        "<": ">=",
                        "<=": ">",
                        "is": "!is",
                    ]
                    if let newValue = inversionMap[token.value] {
                        inverted = true
                        invertedTokens.append(origin.newToken(token.kind, newValue, node))
                        continue
                    } else if token.value == "&&" || token.value == "||" {
                        if !inverted {
                            invertedTokens.insert(origin.newToken(.symbol, "!", node), at: lastExpressionIndex)
                        }
                        inverted = false
                        invertedTokens.append(origin.newToken(token.kind, token.value == "&&" ? "||" : "&&", node))
                        lastExpressionIndex = invertedTokens.count + 1
                        continue
                    }
                } else if origin is PrefixOperatorExpression {
                    if token.value == "!" {
                        inverted = true
                        continue
                    }
                }
            }
            invertedTokens.append(token)
        }
        if !inverted {
            invertedTokens.insert(condition.newToken(.symbol, "!", node), at: lastExpressionIndex)
        }
        return invertedTokens
    }


    private func tokenizeCompanion(_ members: [StructDeclaration.Member], node: ASTNode) -> [Token] {
        return tokenizeCompanion(members.flatMap { $0.declaration }, node: node)
    }

    private func tokenizeCompanion(_ members: [ClassDeclaration.Member], node: ASTNode) -> [Token] {
        return tokenizeCompanion(members.flatMap { $0.declaration }, node: node)
    }

    private func tokenizeCompanion(_ members: [Declaration], node: ASTNode) -> [Token] {
        let membersTokens = indent(members.map(tokenize)
            // joinedWithTokenRangeSetToSame is to try and make sure linebreak has sourceRange near each item it is joined too. Needed so comments sync up nicely
            .joinedWithTokenRangeSetToSame(token:node.newToken(.linebreak, "\n")))

        // below is also to add tokens nearer to token they will be closest to:
        let first = membersTokens.first!.node!
        let last = membersTokens.last!.node!
        let tokens = [
            [
                first.newToken(.keyword, "companion"),
                first.newToken(.space, " "),
                first.newToken(.keyword, "object"),
                first.newToken(.space, " "),
                first.newToken(.startOfScope, "{")
            ],
            membersTokens,
            [
                last.newToken(.endOfScope, "}")
            ]
        ].joinedWithTokenRangeSetToSame(token: node.newToken(.linebreak, "\n"))
//        for t in tokens {
//            if let r = t.sourceRange {
//                print(t.value.replacingOccurrences(of:"\n", with:"\\n"), r.start.line, r.end.line)
//            }
//        }
        return tokens
    }

    private func tokenizeInterpolatedString(_ rawText: String, node: ASTNode) -> [Token] {
        var remainingText = rawText
        var interpolatedString = ""

        while let startRange = remainingText.range(of: "\\(") {
            interpolatedString += remainingText[..<startRange.lowerBound]
            remainingText = String(remainingText[startRange.upperBound...])

            var scopes = 1
            var i = 1
            while i < remainingText.count && scopes > 0 {
                let index = remainingText.index(remainingText.startIndex, offsetBy: i)
                i += 1
                switch remainingText[index] {
                case "(": scopes += 1
                case ")": scopes -= 1
                default: continue
                }
            }
            let expression = String(remainingText[..<remainingText.index(remainingText.startIndex, offsetBy: i - 1)])
            let computedExpression = translate(content: expression).tokens?.joinedValues().replacingOccurrences(of: "\n", with: "")
            
            interpolatedString += "${\(computedExpression ?? expression)}"
            remainingText = String(remainingText[remainingText.index(remainingText.startIndex, offsetBy: i)...])
        }

        interpolatedString += remainingText
        return [node.newToken(.string, interpolatedString)]
    }
}

public typealias InvertedConditionList = [InvertedCondition]
public struct InvertedCondition: ASTTokenizable {
    public let condition: Condition
}

