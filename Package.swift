// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Kern",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "KernCore", targets: ["KernCore"])
  ],
  targets: [
    .target(name: "KernCore"),
    .executableTarget(name: "kern-probe", dependencies: ["KernCore"]),
    .testTarget(name: "KernCoreTests", dependencies: ["KernCore"]),
  ]
)
