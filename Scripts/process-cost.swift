// Prints the CPU time and wakeups a process has used since it started, from the same kernel counters
// Activity Monitor and powermetrics read.
//
// Run it as `swift Scripts/process-cost.swift <pid>`.

import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
  print("usage: swift Scripts/process-cost.swift <pid>")
  exit(EX_USAGE)
}

var usage = rusage_info_v4()

let result = withUnsafeMutablePointer(to: &usage) {
  $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
}

guard result == 0 else {
  print("proc_pid_rusage(\(pid)) failed: \(String(cString: strerror(errno)))")
  exit(EXIT_FAILURE)
}

// The CPU times and start time are in Mach absolute time units, which are not nanoseconds on Apple Silicon.
var timebase = mach_timebase_info_data_t()

mach_timebase_info(&timebase)

func seconds(_ machTime: UInt64) -> Double {
  Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

let lifetime = seconds(mach_absolute_time() - usage.ri_proc_start_abstime)
let user = seconds(usage.ri_user_time)
let system = seconds(usage.ri_system_time)
let wakeups = usage.ri_interrupt_wkups + usage.ri_pkg_idle_wkups

print(String(format: "lifetime              %.1f s", lifetime))
print(String(format: "cpu time              %.3f s (user %.3f s, system %.3f s)", user + system, user, system))
print(String(format: "average cpu           %.4f %% of one logical CPU", (user + system) / lifetime * 100))
print("interrupt wakeups     \(usage.ri_interrupt_wkups)")
print("package idle wakeups  \(usage.ri_pkg_idle_wkups)")
print(String(format: "wakeups per second    %.3f", Double(wakeups) / lifetime))
