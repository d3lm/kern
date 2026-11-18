import AppKit
import KernUI

let usage = """
  Usage: kern-power-bench [<cycles>] [<seconds asleep>] [<seconds awake>]

  Runs Kern as the app does, then announces sleep and wake <cycles> times (default 10) by posting the workspace's
  sleep and wake notifications inside the process, where Kern hears them as it does when the Mac really sleeps.
  The Mac stays awake. Each cycle stays asleep for 8 seconds and awake for 12 unless told otherwise, and the last
  wake is followed by 30 more seconds awake. Build it with -c release to measure a Release build.

  Kern's debug log says what it did. Pipe it to Scripts/schedule-report.swift for a table of the cycles:

    log stream --style ndjson --level debug --predicate 'subsystem == "Kern" && process == "kern-power-bench"' \\
      | swift Scripts/schedule-report.swift

  A Debug build also accepts Kern's own launch arguments, such as --fail gpu.
  """

let numbers = CommandLine.arguments.dropFirst().prefix { !$0.hasPrefix("-") }.map { Double($0) }

guard numbers.count <= 3, numbers.allSatisfy({ $0.map { $0 >= 1 } ?? false }) else {
  print(usage)
  exit(EX_USAGE)
}

let cycles = Int(numbers.first.flatMap { $0 } ?? 10)
let asleep = Duration.seconds(numbers.dropFirst().first.flatMap { $0 } ?? 8)
let awake = Duration.seconds(numbers.dropFirst(2).first.flatMap { $0 } ?? 12)

@MainActor
func announce(_ name: Notification.Name, _ event: String, cycle: Int) {
  NSWorkspace.shared.notificationCenter.post(name: name, object: NSWorkspace.shared)

  print("cycle \(cycle): announced \(event)")
  fflush(stdout)
}

let application = NSApplication.shared
let delegate = AppDelegate()

application.delegate = delegate

application.setActivationPolicy(.accessory)

Task { @MainActor in
  try? await Task.sleep(for: awake)

  for cycle in 1...cycles {
    announce(NSWorkspace.willSleepNotification, "sleep", cycle: cycle)

    try? await Task.sleep(for: asleep)

    announce(NSWorkspace.didWakeNotification, "wake", cycle: cycle)

    try? await Task.sleep(for: cycle == cycles ? .seconds(30) : awake)
  }

  exit(0)
}

withExtendedLifetime(delegate) {
  application.run()
}
