import SwiftSyntax

/// Describes a statement or member that needs a blank line above it.
public struct Finding: Equatable, Sendable {
  public let line: Int
  public let column: Int
  public let message: String
}

/// Inserts a blank line between neighbouring statements or members when either one spans more than one line.
public final class BlankLineRewriter: SyntaxRewriter {
  public private(set) var findings: [Finding] = []
  private let converter: SourceLocationConverter

  public init(fileName: String, tree: SourceFileSyntax) {
    converter = SourceLocationConverter(fileName: fileName, tree: tree)

    super.init(viewMode: .sourceAccurate)
  }

  override public func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
    let crowded = crowdedIndices(node.map { ($0, Kind($0.item)) })

    return CodeBlockItemListSyntax(separating(super.visit(node), at: crowded))
  }

  override public func visit(_ node: MemberBlockItemListSyntax) -> MemberBlockItemListSyntax {
    let crowded = crowdedIndices(node.map { ($0, Kind.other) })

    return MemberBlockItemListSyntax(separating(super.visit(node), at: crowded))
  }

  private func crowdedIndices<Item: SyntaxProtocol>(_ items: [(item: Item, kind: Kind)]) -> Set<Int> {
    var crowded = Set<Int>()

    for index in items.indices.dropFirst() {
      let previous = items[index - 1]
      let next = items[index]

      guard !hasBlankLine(next.item.leadingTrivia),
        line(previous.item.endPositionBeforeTrailingTrivia) < line(next.item.positionAfterSkippingLeadingTrivia)
      else { continue }

      let message =
        spansLines(previous.item) || spansLines(next.item)
        ? "separate a statement that spans multiple lines from its neighbours with a blank line"
        : Kind.reason(between: previous.kind, and: next.kind)

      guard let message else { continue }

      let location = converter.location(for: next.item.positionAfterSkippingLeadingTrivia)

      crowded.insert(index)
      findings.append(Finding(line: location.line, column: location.column, message: message))
    }

    return crowded
  }

  private func separating<Item: SyntaxProtocol>(_ items: some Collection<Item>, at indices: Set<Int>) -> [Item] {
    items.enumerated().map { index, item in
      guard indices.contains(index) else { return item }

      var separated = item

      separated.leadingTrivia = .newline + item.leadingTrivia

      return separated
    }
  }

  private func line(_ position: AbsolutePosition) -> Int {
    converter.location(for: position).line
  }

  private func spansLines(_ node: some SyntaxProtocol) -> Bool {
    line(node.positionAfterSkippingLeadingTrivia) != line(node.endPositionBeforeTrailingTrivia)
  }

  private func hasBlankLine(_ trivia: Trivia) -> Bool {
    var newlines = 0

    for piece in trivia {
      switch piece {
      case .newlines(let count), .carriageReturnLineFeeds(let count): newlines += count
      case .spaces, .tabs: break
      default: newlines = 0
      }

      if newlines >= 2 { return true }
    }

    return false
  }
}

private enum Kind: Equatable {
  case constant
  case variable
  case block
  case typeDeclaration
  case call
  case assignment
  case jump
  case `import`
  case other

  private static let compoundAssignments: Set<String> = [
    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "&+=", "&-=", "&*=", "&<<=", "&>>=",
  ]

  static func reason(between previous: Kind, and next: Kind) -> String? {
    switch (previous, next) {
    case (.constant, .constant), (.variable, .variable), (.import, .import):
      nil
    case (.block, _), (_, .block):
      "separate a block such as if, guard, for or a function from its neighbours with a blank line"
    case (_, .typeDeclaration):
      "put a blank line above a type declaration"
    case (.constant, _), (.variable, _), (_, .constant), (_, .variable):
      "separate let and var declarations from other statements with a blank line"
    case (_, .jump):
      "put a blank line above break and continue"
    case (.call, .assignment), (.assignment, .call):
      "separate calls from assignments with a blank line"
    case (.import, _), (_, .import):
      "separate imports from other statements with a blank line"
    default:
      nil
    }
  }

  init(_ item: CodeBlockItemSyntax.Item) {
    switch item {
    case .decl(let decl): self.init(decl)
    case .stmt(let stmt): self.init(stmt)
    case .expr(let expr): self.init(expr)
    }
  }

  private init(_ decl: DeclSyntax) {
    if let variable = decl.as(VariableDeclSyntax.self) {
      self = variable.bindingSpecifier.tokenKind == .keyword(.let) ? .constant : .variable
    } else if decl.is(ImportDeclSyntax.self) {
      self = .import
    } else if decl.asProtocol(DeclGroupSyntax.self) != nil {
      self = .typeDeclaration
    } else if decl.is(MacroExpansionDeclSyntax.self) {
      self = .call
    } else {
      self = Self.endsWithBlock(decl) ? .block : .other
    }
  }

  private init(_ stmt: StmtSyntax) {
    if let expression = stmt.as(ExpressionStmtSyntax.self) {
      self.init(expression.expression)
    } else if stmt.is(BreakStmtSyntax.self) || stmt.is(ContinueStmtSyntax.self) {
      self = .jump
    } else {
      self = stmt.is(RepeatStmtSyntax.self) || Self.endsWithBlock(stmt) ? .block : .other
    }
  }

  private init(_ expr: ExprSyntax) {
    guard !Self.endsWithBlock(expr) else {
      self = .block
      return
    }

    var expr = expr

    while let inner = expr.as(TryExprSyntax.self)?.expression ?? expr.as(AwaitExprSyntax.self)?.expression {
      expr = inner
    }

    if expr.is(FunctionCallExprSyntax.self) || expr.is(MacroExpansionExprSyntax.self) {
      self = .call
    } else if let sequence = expr.as(SequenceExprSyntax.self), sequence.elements.contains(where: Self.isAssignment) {
      self = sequence.elements.first?.is(DiscardAssignmentExprSyntax.self) == true ? .other : .assignment
    } else {
      self = .other
    }
  }

  /// Matches statements whose last token closes a code block or a `switch`, like ESLint's block-like statements,
  /// so a call with a trailing closure stays a call.
  private static func endsWithBlock(_ node: some SyntaxProtocol) -> Bool {
    guard let last = node.lastToken(viewMode: .sourceAccurate), last.tokenKind == .rightBrace else { return false }

    return last.parent?.is(CodeBlockSyntax.self) == true || last.parent?.is(SwitchExprSyntax.self) == true
  }

  private static func isAssignment(_ element: ExprSyntax) -> Bool {
    if element.is(AssignmentExprSyntax.self) { return true }

    return element.as(BinaryOperatorExprSyntax.self).map { compoundAssignments.contains($0.operator.text) } ?? false
  }
}
