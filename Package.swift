// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Kern",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "KernCore", targets: ["KernCore"]),
    .library(name: "KernUI", targets: ["KernUI"]),
  ],
  targets: [
    .target(name: "KernCore"),
    .target(name: "KernUI", dependencies: ["KernCore"]),
    .executableTarget(name: "kern-probe", dependencies: ["KernCore"]),
    .executableTarget(name: "kern-popover-bench", dependencies: ["KernUI"]),
    .testTarget(name: "KernCoreTests", dependencies: ["KernCore"]),
    .testTarget(name: "KernUITests", dependencies: ["KernUI", "KernCore"]),
  ]
)
