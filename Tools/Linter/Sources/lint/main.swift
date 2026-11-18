import Linter
import Foundation
import SwiftParser

let arguments = Array(CommandLine.arguments.dropFirst())
let fixes = arguments.contains("--fix")
let paths = arguments.filter { $0 != "--fix" }

guard !paths.isEmpty else {
  FileHandle.standardError.write(Data("usage: lint [--fix] <file or directory>...\n".utf8))
  exit(64)
}

func swiftFiles(at path: String) -> [String] {
  var isDirectory: ObjCBool = false

  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
    FileHandle.standardError.write(Data("\(path): no such file or directory\n".utf8))
    exit(66)
  }

  guard isDirectory.boolValue else { return path.hasSuffix(".swift") ? [path] : [] }

  let enumerator = FileManager.default.enumerator(atPath: path)

  var files: [String] = []

  while let relative = enumerator?.nextObject() as? String {
    if (relative as NSString).lastPathComponent.hasPrefix(".") {
      enumerator?.skipDescendants()
    } else if relative.hasSuffix(".swift") {
      files.append((path as NSString).appendingPathComponent(relative))
    }
  }

  return files.sorted()
}

var total = 0

for file in paths.flatMap(swiftFiles) {
  guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
    FileHandle.standardError.write(Data("\(file): cannot be read\n".utf8))
    exit(66)
  }

  let tree = Parser.parse(source: source)
  let rewriter = BlankLineRewriter(fileName: file, tree: tree)
  let separated = rewriter.rewrite(tree).description

  total += rewriter.findings.count

  if fixes {
    if separated != source {
      try separated.write(toFile: file, atomically: true, encoding: .utf8)

      let count = rewriter.findings.count

      print("\(file): added \(count) blank line\(count == 1 ? "" : "s")")
    }
  } else {
    for finding in rewriter.findings {
      print("\(file):\(finding.line):\(finding.column): error: \(finding.message)")
    }
  }
}

exit(total > 0 && !fixes ? 1 : 0)
