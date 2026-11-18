// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Linter",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "lint", targets: ["lint"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", .upToNextMinor(from: "601.0.1"))
  ],
  targets: [
    .target(name: "Linter", dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax")]),
    .executableTarget(name: "lint", dependencies: ["Linter", .product(name: "SwiftParser", package: "swift-syntax")]),
    .testTarget(
      name: "LinterTests", dependencies: ["Linter", .product(name: "SwiftParser", package: "swift-syntax")]),
  ]
)
