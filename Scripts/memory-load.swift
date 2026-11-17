// Fills a given amount of memory with random bytes, holds it for a set time, and frees it, so memory readings can
// be compared before, during, and after. Random bytes cannot be compressed, so the memory stays in use at full size.
//
// Run it as `swift Scripts/memory-load.swift [gibibytes] [seconds]`, which defaults to 4 GiB for 30 seconds.

import Foundation

let usage = "usage: swift Scripts/memory-load.swift [gibibytes] [seconds]"
let arguments = CommandLine.arguments.dropFirst().map(Double.init)

guard arguments.count <= 2, arguments.allSatisfy({ ($0 ?? 0) > 0 }) else {
  print(usage)
  exit(EX_USAGE)
}

let gibibytes = arguments.first.flatMap { $0 } ?? 4
let seconds = arguments.dropFirst().first.flatMap { $0 } ?? 30
let size = Int(gibibytes * Double(1 << 30))

guard let memory = malloc(size) else {
  print("could not allocate \(gibibytes) GiB")
  exit(EXIT_FAILURE)
}

print(String(format: "%@  filling %.1f GiB with random bytes", timestamp(), gibibytes))

fflush(nil)

arc4random_buf(memory, size)

print(String(format: "%@  holding for %.0f s", timestamp(), seconds))

fflush(nil)

Thread.sleep(forTimeInterval: seconds)

free(memory)

print("\(timestamp())  freed")

func timestamp() -> String {
  Date.now.formatted(date: .omitted, time: .standard)
}
