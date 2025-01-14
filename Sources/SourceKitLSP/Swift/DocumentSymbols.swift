//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import LanguageServerProtocol
import SwiftSyntax
import LSPLogging

extension SwiftLanguageServer {
  public func documentSymbol(_ req: DocumentSymbolRequest) async throws -> DocumentSymbolResponse? {
    let snapshot = try self.documentManager.latestSnapshot(req.textDocument.uri)

    let syntaxTree = await syntaxTreeManager.syntaxTree(for: snapshot)

    try Task.checkCancellation()
    return .documentSymbols(DocumentSymbolsFinder.find(in: [Syntax(syntaxTree)], snapshot: snapshot))
  }
}

// MARK: - DocumentSymbolsFinder

fileprivate final class DocumentSymbolsFinder: SyntaxAnyVisitor {
  /// The snapshot of the document for which we are getting document symbols.
  private let snapshot: DocumentSnapshot

  /// Accumulating the result in here.
  private var result: [DocumentSymbol] = []

  private init(snapshot: DocumentSnapshot) {
    self.snapshot = snapshot
    super.init(viewMode: .sourceAccurate)
  }

  /// Designated entry point for `DocumentSymbolFinder`.
  static func find(in nodes: some Sequence<Syntax>, snapshot: DocumentSnapshot) -> [DocumentSymbol] {
    let visitor = Self(snapshot: snapshot)
    for node in nodes {
      visitor.walk(node)
    }
    return visitor.result
  }

  /// Add a symbol with the given parameters to the `result` array.
  private func record(
    node: some SyntaxProtocol,
    name: String,
    symbolKind: SymbolKind,
    range: Range<AbsolutePosition>,
    selection: Range<AbsolutePosition>
  ) -> SyntaxVisitorContinueKind {
    guard let rangeLowerBound = snapshot.position(of: range.lowerBound),
      let rangeUpperBound = snapshot.position(of: range.upperBound),
      let selectionLowerBound = snapshot.position(of: selection.lowerBound),
      let selectionUpperBound = snapshot.position(of: selection.upperBound)
    else {
      return .skipChildren
    }

    let children = DocumentSymbolsFinder.find(in: node.children(viewMode: .sourceAccurate), snapshot: snapshot)

    result.append(
      DocumentSymbol(
        name: name,
        kind: symbolKind,
        range: rangeLowerBound..<rangeUpperBound,
        selectionRange: selectionLowerBound..<selectionUpperBound,
        children: children
      )
    )
    return .skipChildren
  }

  override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    guard let node = node.asProtocol(NamedDeclSyntax.self) else {
      return .visitChildren
    }
    let symbolKind: SymbolKind? = switch node.kind {
    case .actorDecl: .class
    case .associatedTypeDecl: .typeParameter
    case .classDecl: .class
    case .enumDecl: .enum
    case .macroDecl: .function // LSP doesn't have a macro symbol kind. Function is the closest.
    case .operatorDecl: .operator
    case .precedenceGroupDecl: .operator // LSP doesn't have a precedence group symbol kind. Operator is the closest.
    case .protocolDecl: .interface
    case .structDecl: .struct
    case .typeAliasDecl: .typeParameter // LSP doesn't have a typealias symbol kind. Type parameter is the closest.
    default: nil
    }

    guard let symbolKind else {
      return .visitChildren
    }
    return record(
      node: node,
      name: node.name.text,
      symbolKind: symbolKind,
      range: node.rangeWithoutTrivia,
      selection: node.name.rangeWithoutTrivia
    )
  }

  override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
    let rangeEnd =
      if let parameterClause = node.parameterClause {
        parameterClause.endPositionBeforeTrailingTrivia
      } else {
        node.name.endPositionBeforeTrailingTrivia
      }

    return record(
      node: node,
      name: node.declName,
      symbolKind: .enumMember,
      range: node.name.positionAfterSkippingLeadingTrivia..<rangeEnd,
      selection: node.name.positionAfterSkippingLeadingTrivia..<rangeEnd
    )
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    return record(
      node: node,
      name: node.extendedType.trimmedDescription,
      symbolKind: .namespace,
      range: node.rangeWithoutTrivia,
      selection: node.extendedType.rangeWithoutTrivia
    )
  }

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    let kind: SymbolKind = if node.name.tokenKind.isOperator {
      .operator
    } else if node.parent?.is(MemberBlockItemSyntax.self) ?? false {
      .method
    } else {
      .function
    }
    return record(
      node: node,
      name: node.declName,
      symbolKind: kind,
      range: node.rangeWithoutTrivia,
      selection: node.name
        .positionAfterSkippingLeadingTrivia..<node.signature.parameterClause.endPositionBeforeTrailingTrivia
    )
  }

  override func visit(_ node: GenericParameterSyntax) -> SyntaxVisitorContinueKind {
    return record(
      node: node,
      name: node.name.text,
      symbolKind: .typeParameter,
      range: node.rangeWithoutTrivia,
      selection: node.rangeWithoutTrivia
    )
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    return record(
      node: node,
      name: node.initKeyword.text,
      symbolKind: .constructor,
      range: node.rangeWithoutTrivia,
      selection: node.initKeyword
        .positionAfterSkippingLeadingTrivia..<node.signature.parameterClause.endPositionBeforeTrailingTrivia
    )
  }

  override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
    // If there is only one pattern binding within the variable decl, consider the entire variable decl as the
    // referenced range. If there are multiple, consider each pattern binding separately since the `var` keyword doesn't
    // belong to any pattern binding in particular.
    guard let variableDecl = node.parent?.parent?.as(VariableDeclSyntax.self) else {
      return .visitChildren
    }
    let rangeNode: Syntax = variableDecl.bindings.count == 1  ? Syntax(variableDecl) : Syntax(node)

    return record(
      node: node,
      name: node.pattern.trimmedDescription,
      symbolKind: variableDecl.parent?.is(MemberBlockItemSyntax.self) ?? false ? .property : .variable,
      range: rangeNode.rangeWithoutTrivia,
      selection: node.pattern.rangeWithoutTrivia
    )
  }
}

// MARK: - Syntax Utilities

fileprivate extension EnumCaseElementSyntax {
  var declName: String {
    var result = self.name.text
    if let parameterClause {
      result += "("
      for parameter in parameterClause.parameters {
        result += "\(parameter.firstName?.text ?? "_"):"
      }
      result += ")"
    }
    return result
  }
}

fileprivate extension FunctionDeclSyntax {
  var declName: String {
    var result = self.name.text
    result += "("
    for parameter in self.signature.parameterClause.parameters {
      result += "\(parameter.firstName.text):"
    }
    result += ")"
    return result
  }
}

fileprivate extension SyntaxProtocol {
  /// The position range of this node without its leading and trailing trivia.
  var rangeWithoutTrivia: Range<AbsolutePosition> {
    return positionAfterSkippingLeadingTrivia..<endPositionBeforeTrailingTrivia
  }
}

fileprivate extension TokenKind {
  var isOperator: Bool {
    switch self {
    case .prefixOperator, .binaryOperator, .postfixOperator: return true
    default: return false
    }
  }
}
