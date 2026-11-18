import Linter
import SwiftParser
import Testing

private func separated(_ source: String) -> (source: String, lines: [Int]) {
  let tree = Parser.parse(source: source)
  let rewriter = BlankLineRewriter(fileName: "test.swift", tree: tree)
  let result = rewriter.rewrite(tree).description

  return (result, rewriter.findings.map(\.line))
}

struct BlankLineRewriterTests {
  @Test func callThatSpansLinesIsSetApartFromTheStatementsAroundIt() {
    let result = separated(
      """
      func f() {
        a()
        b(
          1)
        c()
      }
      """)

    #expect(
      result.source == """
        func f() {
          a()

          b(
            1)

          c()
        }
        """)

    #expect(result.lines == [3, 5])
  }

  @Test func declarationThatSpansLinesIsSetApartFromOtherDeclarations() {
    let result = separated(
      """
      func f() {
        let a = 1
        let b = g(
          a)
        let c = 2
      }
      """)

    #expect(
      result.source == """
        func f() {
          let a = 1

          let b = g(
            a)

          let c = 2
        }
        """)
  }

  @Test func declarationIsSetApartFromAnExpressionNextToIt() {
    let result = separated(
      """
      func f() {
        let a = 1
        g(a)
        let b = 2
      }
      """)

    #expect(
      result.source == """
        func f() {
          let a = 1

          g(a)

          let b = 2
        }
        """)
  }

  @Test func blockIsSetApartFromItsNeighboursEvenOnOneLine() {
    let result = separated(
      """
      func f() {
        a()
        if b { return }
        for c in d { e(c) }
        guard f else { return }
        defer { g() }
        func h() { i() }
        do { try j() } catch { k() }
        l()
      }
      """)

    #expect(
      result.source == """
        func f() {
          a()

          if b { return }

          for c in d { e(c) }

          guard f else { return }

          defer { g() }

          func h() { i() }

          do { try j() } catch { k() }

          l()
        }
        """)
  }

  @Test func declarationIsSetApartFromEveryOtherKindOfStatement() {
    let result = separated(
      """
      func f() -> Int {
        let a = 1
        var b = a
        b += 1
        let c = b
        return c
      }
      """)

    #expect(
      result.source == """
        func f() -> Int {
          let a = 1

          var b = a

          b += 1

          let c = b

          return c
        }
        """)
  }

  @Test func callIsSetApartFromAnAssignment() {
    let result = separated(
      """
      func f() {
        a = 1
        try await b()
        c = g()
        d.e = 2
      }
      """)

    #expect(
      result.source == """
        func f() {
          a = 1

          try await b()

          c = g()
          d.e = 2
        }
        """)
  }

  @Test func breakAndContinueHaveABlankLineAbove() {
    let result = separated(
      """
      func f() {
        for a in b {
          c(a)
          continue
        }

        while true {
          d()
          break
        }
      }
      """)

    #expect(
      result.source == """
        func f() {
          for a in b {
            c(a)

            continue
          }

          while true {
            d()

            break
          }
        }
        """)
  }

  @Test func importsAndTypeDeclarationsAreSetApart() {
    let result = separated(
      """
      import A
      import B
      a()
      struct S {}
      """)

    #expect(
      result.source == """
        import A
        import B

        a()

        struct S {}
        """)
  }

  @Test func macroCountsAsAnExpression() {
    let result = separated(
      """
      func f() {
        let a = 1
        #expect(a == 1)
      }
      """)

    #expect(result.lines == [3])
  }

  @Test func blankLineGoesAboveTheCommentOfTheNextStatement() {
    let result = separated(
      """
      func f() {
        a(
          1)
        // Explains b.
        b()
      }
      """)

    #expect(
      result.source == """
        func f() {
          a(
            1)

          // Explains b.
          b()
        }
        """)
  }

  @Test func memberThatSpansLinesIsSetApartFromOtherMembers() {
    let result = separated(
      """
      struct S {
        let a = 1
        var b: Int {
          a
        }
      }
      """)

    #expect(
      result.source == """
        struct S {
          let a = 1

          var b: Int {
            a
          }
        }
        """)
  }

  @Test func statementsInsideAStatementThatSpansLinesAreSeparatedToo() {
    let result = separated(
      """
      func f() {
        g {
          let a = 1
          h(a)
        }
      }
      """)

    #expect(
      result.source == """
        func f() {
          g {
            let a = 1

            h(a)
          }
        }
        """)
  }

  @Test(arguments: [
    """
    func f() {
      a()
      b()

      let c = 1
      let d = 2
    }
    """,
    """
    func f() {
      let a = 1
      let b = 2

      g(
        a, b)
    }
    """,
    """
    func f() {
      guard let a = g(),
        let b = h(a)
      else { return }

      i(b)
    }
    """,
    """
    func f() {
      let a = 1; g(a)
    }
    """,
    """
    func f() {
      a(
        1)

      // Explains b.

      b()
    }
    """,
    """
    @Test(arguments: [
      1,
    ])
    func f(a: Int) {}
    """,
    """
    struct S {
      let a: Int
      private(set) var b: Int
      func c() { d() }
    }
    """,
    """
    func f() {
      a.forEach { b($0) }
      c()

      d = 1
      e = 2
      _ = g()
      h()
    }
    """,
  ])
  func codeThatIsAlreadySeparatedIsLeftAlone(source: String) {
    let result = separated(source)

    #expect(result.source == source)
    #expect(result.lines.isEmpty)
  }
}
