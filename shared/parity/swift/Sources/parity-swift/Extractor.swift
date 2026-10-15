import Foundation
import SwiftParser
import SwiftSyntax

private let viewProtocols: Set<String> = ["View", "ViewModifier", "ButtonStyle", "Shape"]

final class FileExtractor {
    let path: String
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter

    var imports: [String] = []
    var types: [[String: Any]] = []
    var extensions: [[String: Any]] = []
    var topFunctions: [[String: Any]] = []
    var topProperties: [[String: Any]] = []
    var views: [[String: Any]] = []
    var debugScripts: [[String: Any]] = []
    var tests: [[String: Any]] = []

    init(path: String, source: String) {
        self.path = path
        tree = Parser.parse(source: source)
        converter = SourceLocationConverter(fileName: path, tree: tree)
    }

    func extract() -> [String: Any] {
        walkTopLevel(tree.statements.map(\.item), debug: false)
        let references = ReferenceCollector(viewMode: .sourceAccurate)
        references.walk(tree)
        return [
            "path": path,
            "imports": imports,
            "types": types,
            "extensions": extensions,
            "functions": topFunctions,
            "properties": topProperties,
            "views": views,
            "accessibility_ids": references.accessibilityIDs.sorted(),
            "references": references.typeNames.sorted(),
            "debug_scripts": debugScripts,
            "tests": tests,
        ]
    }

    private func line(_ node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    private func walkTopLevel(_ items: [CodeBlockItemSyntax.Item], debug: Bool) {
        for item in items {
            guard case .decl(let decl) = item else { continue }
            topLevelDecl(decl, debug: debug)
        }
    }

    private func topLevelDecl(_ decl: DeclSyntax, debug: Bool) {
        if let node = decl.as(ImportDeclSyntax.self) {
            imports.append(node.path.map(\.name.text).joined(separator: "."))
        } else if let node = decl.as(IfConfigDeclSyntax.self) {
            for clause in node.clauses {
                let clauseDebug = debug || isDebugCondition(clause)
                switch clause.elements {
                case .statements(let items): walkTopLevel(items.map(\.item), debug: clauseDebug)
                case .decls(let members): members.forEach { topLevelDecl($0.decl, debug: clauseDebug) }
                default: break
                }
            }
        } else if let node = decl.as(ExtensionDeclSyntax.self) {
            extensions.append(extensionInfo(node, debug: debug))
        } else if let node = decl.as(FunctionDeclSyntax.self) {
            topFunctions.append(functionInfo(node, debug: debug))
        } else if let node = decl.as(VariableDeclSyntax.self) {
            topProperties.append(contentsOf: propertyInfos(node, debug: debug))
        } else if let info = typeInfo(decl, parent: nil, debug: debug) {
            types.append(info)
            noteSpecialType(decl, info: info)
        }
    }

    private func noteSpecialType(_ decl: DeclSyntax, info: [String: Any]) {
        let name = info["name"] as? String ?? ""
        let conformances = info["conformances"] as? [String] ?? []
        let access = info["access"] as? String ?? "internal"
        if let kind = conformances.first(where: { viewProtocols.contains($0) }), access != "private", access != "fileprivate" {
            views.append(["name": name, "kind": kind, "access": access, "line": info["line"] ?? 0])
        }
        if conformances.contains("DebugScript"), let scriptName = staticStringMember(decl, named: "name") {
            debugScripts.append(["name": scriptName, "type": name, "line": info["line"] ?? 0])
        }
        if conformances.contains("XCTestCase") {
            let methods = (info["functions"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .filter { $0.hasPrefix("test") }
            tests.append(["class": name, "methods": methods])
        }
    }

    private func staticStringMember(_ decl: DeclSyntax, named member: String) -> String? {
        guard let block = decl.asProtocol(DeclGroupSyntax.self)?.memberBlock else { return nil }
        for item in block.members {
            guard let variable = item.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == member,
                      let literal = binding.initializer?.value.as(StringLiteralExprSyntax.self)
                else { continue }
                return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
            }
        }
        return nil
    }

    // MARK: Types

    private func typeInfo(_ decl: DeclSyntax, parent: String?, debug: Bool) -> [String: Any]? {
        let kind: String
        let name: String
        let modifiers: DeclModifierListSyntax
        let attributes: AttributeListSyntax
        let inheritance: InheritanceClauseSyntax?
        let members: MemberBlockSyntax?
        if let node = decl.as(StructDeclSyntax.self) {
            (kind, name, modifiers, attributes, inheritance, members) = ("struct", node.name.text, node.modifiers, node.attributes, node.inheritanceClause, node.memberBlock)
        } else if let node = decl.as(ClassDeclSyntax.self) {
            (kind, name, modifiers, attributes, inheritance, members) = ("class", node.name.text, node.modifiers, node.attributes, node.inheritanceClause, node.memberBlock)
        } else if let node = decl.as(EnumDeclSyntax.self) {
            (kind, name, modifiers, attributes, inheritance, members) = ("enum", node.name.text, node.modifiers, node.attributes, node.inheritanceClause, node.memberBlock)
        } else if let node = decl.as(ProtocolDeclSyntax.self) {
            (kind, name, modifiers, attributes, inheritance, members) = ("protocol", node.name.text, node.modifiers, node.attributes, node.inheritanceClause, node.memberBlock)
        } else if let node = decl.as(ActorDeclSyntax.self) {
            (kind, name, modifiers, attributes, inheritance, members) = ("actor", node.name.text, node.modifiers, node.attributes, node.inheritanceClause, node.memberBlock)
        } else if let node = decl.as(TypeAliasDeclSyntax.self) {
            (kind, name, modifiers, attributes, inheritance, members) = ("typealias", node.name.text, node.modifiers, node.attributes, nil, nil)
        } else {
            return nil
        }
        let qualified = parent.map { "\($0).\(name)" } ?? name
        var info: [String: Any] = [
            "name": name,
            "qualified": qualified,
            "kind": kind,
            "attributes": attributeNames(attributes),
            "access": accessLevel(modifiers),
            "final": modifiers.contains { $0.name.text == "final" },
            "conformances": conformanceNames(inheritance),
            "line": line(decl),
            "debug": debug,
            "hash": fingerprint(decl),
        ]
        if let parent { info["parent"] = parent }
        var body = MemberCollector()
        if let members {
            collectMembers(members.members, owner: qualified, debug: debug, into: &body)
        }
        info["properties"] = body.properties
        info["functions"] = body.functions
        info["cases"] = body.cases
        info["types"] = body.types
        info["reset_assigns"] = body.resetAssigns
        return info
    }

    private func extensionInfo(_ node: ExtensionDeclSyntax, debug: Bool) -> [String: Any] {
        let extended = node.extendedType.trimmedDescription.replacingOccurrences(of: " ", with: "")
        var body = MemberCollector()
        collectMembers(node.memberBlock.members, owner: extended, debug: debug, into: &body)
        if extended == "View" {
            for function in body.functions {
                let access = function["access"] as? String ?? "internal"
                guard access != "private", access != "fileprivate" else { continue }
                views.append(["name": function["name"] ?? "", "kind": "ViewExtension", "access": access, "line": function["line"] ?? 0, "key": function["key"] ?? ""])
            }
        }
        types.append(contentsOf: body.types)
        return [
            "of": extended,
            "conformances": conformanceNames(node.inheritanceClause),
            "line": line(node),
            "debug": debug,
            "sections": body.sections.map { ["mark": $0.mark, "functions": $0.functions] },
            "functions": body.functions,
            "properties": body.properties,
            "types": body.types.map { $0["name"] ?? "" },
        ]
    }

    private func collectMembers(_ members: MemberBlockItemListSyntax, owner: String, debug: Bool, into body: inout MemberCollector) {
        for item in members {
            if let mark = markText(item.leadingTrivia) {
                body.sections.append(Section(mark: mark, functions: []))
            }
            let decl = item.decl
            if let node = decl.as(IfConfigDeclSyntax.self) {
                for clause in node.clauses {
                    guard case .decls(let nested) = clause.elements else { continue }
                    collectMembers(nested, owner: owner, debug: debug || isDebugCondition(clause), into: &body)
                }
            } else if let node = decl.as(FunctionDeclSyntax.self) {
                let info = functionInfo(node, debug: debug)
                body.functions.append(info)
                body.appendToSection(info)
                if node.name.text == "reset", node.signature.parameterClause.parameters.isEmpty, let code = node.body {
                    body.resetAssigns = assignedNames(code)
                }
            } else if let node = decl.as(InitializerDeclSyntax.self) {
                let params = parameters(node.signature.parameterClause)
                body.functions.append([
                    "name": "init",
                    "key": "init/\(params.count)",
                    "labels": params.map(\.label),
                    "params": params.map(\.name),
                    "access": accessLevel(node.modifiers),
                    "static": false,
                    "line": line(node),
                    "debug": debug,
                    "hash": fingerprint(node),
                ])
            } else if let node = decl.as(VariableDeclSyntax.self) {
                body.properties.append(contentsOf: propertyInfos(node, debug: debug))
            } else if let node = decl.as(EnumCaseDeclSyntax.self) {
                for element in node.elements {
                    let arity = element.parameterClause?.parameters.count ?? 0
                    let labels = element.parameterClause?.parameters.map { $0.firstName?.text ?? "_" } ?? []
                    body.cases.append(["name": element.name.text, "arity": arity, "labels": labels, "line": line(element), "debug": debug, "hash": fingerprint(element)])
                }
            } else if let info = typeInfo(decl, parent: owner, debug: debug) {
                body.types.append(info)
                noteSpecialType(decl, info: info)
            }
        }
    }

    private func functionInfo(_ node: FunctionDeclSyntax, debug: Bool) -> [String: Any] {
        let params = parameters(node.signature.parameterClause)
        let name = node.name.text
        let effects = node.signature.effectSpecifiers
        return [
            "name": name,
            "key": "\(name)/\(params.count)",
            "labels": params.map(\.label),
            "params": params.map(\.name),
            "access": accessLevel(node.modifiers),
            "static": node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" },
            "mutating": node.modifiers.contains { $0.name.text == "mutating" },
            "async": effects?.asyncSpecifier != nil,
            "throws": effects?.throwsClause != nil,
            "attributes": attributeNames(node.attributes),
            "returns": node.signature.returnClause?.type.trimmedDescription ?? "",
            "line": line(node),
            "debug": debug,
            "hash": fingerprint(node),
        ]
    }

    private func propertyInfos(_ node: VariableDeclSyntax, debug: Bool) -> [[String: Any]] {
        let isStatic = node.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
        let setter = node.modifiers.first { $0.detail?.detail.text == "set" }?.name.text
        var infos: [[String: Any]] = []
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
            var computed = false
            if let accessors = binding.accessorBlock {
                switch accessors.accessors {
                case .getter: computed = true
                case .accessors(let list):
                    computed = list.contains { $0.accessorSpecifier.text == "get" || $0.accessorSpecifier.text == "set" }
                }
            }
            var info: [String: Any] = [
                "name": name,
                "mutable": node.bindingSpecifier.text == "var" && !computed,
                "computed": computed,
                "static": isStatic,
                "access": accessLevel(node.modifiers),
                "type": binding.typeAnnotation?.type.trimmedDescription ?? "",
                "attributes": attributeNames(node.attributes),
                "line": line(binding),
                "debug": debug,
                "hash": fingerprint(node),
            ]
            if let setter { info["setter"] = setter }
            infos.append(info)
        }
        return infos
    }

    private struct Parameter {
        let label: String
        let name: String
    }

    private func parameters(_ clause: FunctionParameterClauseSyntax) -> [Parameter] {
        clause.parameters.map { param in
            let first = param.firstName.text
            let second = param.secondName?.text
            return Parameter(label: first, name: second ?? first)
        }
    }

    // MARK: Helpers

    private func accessLevel(_ modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers where modifier.detail == nil {
            switch modifier.name.text {
            case "private", "fileprivate", "internal", "public", "open", "package": return modifier.name.text
            default: continue
            }
        }
        return "internal"
    }

    private func attributeNames(_ attributes: AttributeListSyntax) -> [String] {
        attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
    }

    private func conformanceNames(_ clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.map { inherited in
            var type = inherited.type
            while let attributed = type.as(AttributedTypeSyntax.self) {
                type = attributed.baseType
            }
            if let identifier = type.as(IdentifierTypeSyntax.self) {
                return identifier.name.text
            }
            if let member = type.as(MemberTypeSyntax.self) {
                return member.name.text
            }
            return type.trimmedDescription
        }
    }

    private func isDebugCondition(_ clause: IfConfigClauseSyntax) -> Bool {
        guard let condition = clause.condition else { return false }
        let text = condition.trimmedDescription
        return text.contains("DEBUG") && !text.contains("!DEBUG")
    }

    private func markText(_ trivia: Trivia) -> String? {
        var found: String?
        for piece in trivia {
            if case .lineComment(let text) = piece, let range = text.range(of: "MARK:") {
                found = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return found
    }

    private func assignedNames(_ body: CodeBlockSyntax) -> [String] {
        let collector = AssignmentCollector(viewMode: .sourceAccurate)
        collector.walk(body)
        return collector.names
    }

    private func fingerprint(_ node: some SyntaxProtocol) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in node.trimmedDescription.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

private struct Section {
    let mark: String
    var functions: [[String: Any]]
}

private struct MemberCollector {
    var properties: [[String: Any]] = []
    var functions: [[String: Any]] = []
    var cases: [[String: Any]] = []
    var types: [[String: Any]] = []
    var sections: [Section] = []
    var resetAssigns: [String] = []

    mutating func appendToSection(_ function: [String: Any]) {
        if sections.isEmpty {
            sections.append(Section(mark: "", functions: []))
        }
        sections[sections.count - 1].functions.append(function)
    }
}

private final class AssignmentCollector: SyntaxVisitor {
    var names: [String] = []

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count >= 3, elements[1].is(AssignmentExprSyntax.self) else { return .visitChildren }
        let target = elements[0]
        if let reference = target.as(DeclReferenceExprSyntax.self) {
            names.append(reference.baseName.text)
        } else if let member = target.as(MemberAccessExprSyntax.self),
                  member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            names.append(member.declName.baseName.text)
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }
}

private final class ReferenceCollector: SyntaxVisitor {
    var typeNames: Set<String> = []
    var accessibilityIDs: Set<String> = []

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        typeNames.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if let first = name.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
            typeNames.insert(name)
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "accessibilityIdentifier",
           let literal = node.arguments.first?.expression.as(StringLiteralExprSyntax.self) {
            let segments = literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
            if segments.count == literal.segments.count {
                accessibilityIDs.insert(segments.joined())
            }
        }
        return .visitChildren
    }
}
