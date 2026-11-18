import Foundation

let usage = """
  Usage: log stream --style ndjson --level debug --predicate 'subsystem == "Kern" && process == "Kern"' \\
           | swift Scripts/schedule-report.swift

  Reads Kern's debug log and prints what Kern did at every sleep and wake: how long it was asleep, the samples
  taken meanwhile, the providers it stopped and started, and how soon each metric was sampled after the wake. Then
  it prints how many schedules each metric has after the last change to the schedules, which is a wake or a change
  of settings, and how often each metric was sampled since. Ctrl-C ends the log and prints the report. The exit
  status is 1 when a check failed.

  The process in the predicate is Kern for the app, and kern-power-bench or kern-settings-bench for the benches.
  """

if CommandLine.arguments.count > 1 {
  print(usage)
  exit(EX_USAGE)
}

/// Ctrl-C must end only `log stream`, so that its end of output reaches this script and the report is printed.
signal(SIGINT, SIG_IGN)

struct Entry {
  let time: Double
  let category: String
  let message: String
}

struct Cycle {
  let sleep: Double
  var wake: Double?
}

/// A sample being read when the sleep is announced still arrives, at most this long after the announcement.
let inFlight = 0.1
let resumeLimit = 5.0
let baselinePair = 0.5

let dateFormat = DateFormatter()

dateFormat.locale = Locale(identifier: "en_US_POSIX")
dateFormat.dateFormat = "yyyy-MM-dd HH:mm:ssZ"

/// `DateFormatter` keeps only milliseconds, so the fraction of the second is read apart from the rest.
func seconds(_ timestamp: String) -> Double? {
  let parts = timestamp.split(separator: ".", maxSplits: 1)

  guard parts.count == 2, let zone = parts[1].firstIndex(where: { $0 == "+" || $0 == "-" }),
    let date = dateFormat.date(from: String(parts[0]) + parts[1][zone...]),
    let fraction = Double("0." + parts[1][..<zone])
  else {
    return nil
  }

  return date.timeIntervalSince1970 + fraction
}

var entries: [Entry] = []

while let line = readLine() {
  guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
    let time = (object["timestamp"] as? String).flatMap(seconds),
    let category = object["category"] as? String,
    let message = object["eventMessage"] as? String
  else {
    continue
  }

  entries.append(Entry(time: time, category: category, message: message))
}

var cycles: [Cycle] = []
var samples: [String: [Double]] = [:]
var starts: [String: [Double]] = [:]
var stops: [String: [Double]] = [:]
var intervals: [String: [(since: Double, seconds: Double)]] = [:]
var lastChange: Double?
var notes: [String] = []
var failures = 0

func check(_ condition: Bool, _ message: String) {
  if !condition {
    failures += 1

    print("FAILED: \(message)")
  }
}

func clock(_ time: Double) -> String {
  let format = DateFormatter()

  format.dateFormat = "HH:mm:ss.SSS"

  return format.string(from: Date(timeIntervalSince1970: time))
}

for entry in entries {
  let words = entry.message.split(separator: " ")

  switch (entry.category, words.first) {
  case ("metrics", "suspending"):
    cycles.append(Cycle(sleep: entry.time))

    lastChange = entry.time
  case ("metrics", "resuming"):
    if let last = cycles.indices.last, cycles[last].wake == nil {
      cycles[last].wake = entry.time
    } else {
      check(false, "a wake at \(clock(entry.time)) follows no sleep")
    }

    lastChange = entry.time
  case ("metrics", "started"), ("metrics", "retimed"):
    let metric = String(words[1].dropLast())

    if words.first == "started" {
      starts[metric, default: []].append(entry.time)
    }

    if words.count >= 4, words[2] == "every", let interval = Double(words[3]) {
      intervals[metric, default: []].append((entry.time, interval))
    }

    lastChange = entry.time
  case ("metrics", "stopped"):
    stops[String(words[1]), default: []].append(entry.time)

    lastChange = entry.time
  case ("metrics", "sampled"):
    samples[String(words[1]), default: []].append(entry.time)
  case ("metrics", _):
    notes.append("\(clock(entry.time))  \(entry.message)")
  default:
    break
  }
}

guard let first = entries.first, let last = entries.last else {
  print("no log entries of Kern were read")
  exit(EXIT_FAILURE)
}

func count(_ times: [Double]?, from start: Double, to end: Double) -> Int {
  (times ?? []).count { $0 >= start && $0 < end }
}

func interval(of metric: String, at time: Double) -> Double? {
  intervals[metric]?.last { $0.since <= time }?.seconds
}

let metrics = starts.keys.sorted()

print("log from \(clock(first.time)) to \(clock(last.time)), \(cycles.count) sleeps, metrics: \(metrics)")
print("")
print("cycle  asleep s  stopped  in flight  sampled asleep  started  first sample after the wake, s")

for (index, cycle) in cycles.enumerated() {
  let number = index + 1

  guard let wake = cycle.wake else {
    check(false, "cycle \(number): no wake follows the sleep at \(clock(cycle.sleep))")

    continue
  }

  let end = cycles.dropFirst(number).first?.sleep ?? last.time + 1
  let stopped = metrics.filter { count(stops[$0], from: cycle.sleep, to: wake) > 0 }
  let started = metrics.filter { count(starts[$0], from: wake, to: end) > 0 }
  let flying = metrics.map { count(samples[$0], from: cycle.sleep, to: cycle.sleep + inFlight) }.reduce(0, +)
  let asleep = metrics.map { count(samples[$0], from: cycle.sleep + inFlight, to: wake) }.reduce(0, +)

  var delays: [String] = []

  for metric in started {
    let after = (samples[metric] ?? []).filter { $0 >= wake && $0 < end }

    guard let firstSample = after.first, let interval = interval(of: metric, at: end) else {
      check(false, "cycle \(number): \(metric) was not sampled after the wake")

      continue
    }

    let early = after.filter { $0 < wake + interval - inFlight }
    let isPair = early.count == 2 && early[1] - early[0] < baselinePair

    delays.append(String(format: "%@ %.2f", metric, firstSample - wake))

    check(firstSample - wake <= resumeLimit, "cycle \(number): \(metric) was first sampled after \(resumeLimit) s")
    check(early.count == 1 || isPair, "cycle \(number): \(metric) took \(early.count) samples in its first interval")
    check(count(starts[metric], from: wake, to: end) == 1, "cycle \(number): \(metric) started more than once")
  }

  check(asleep == 0, "cycle \(number): \(asleep) samples were taken during the sleep")
  check(stopped == started, "cycle \(number): stopped \(stopped) but started \(started)")
  check(!started.isEmpty, "cycle \(number): no provider was started after the wake")

  print(
    String(
      format: "%5d  %8.1f  %7d  %9d  %14d  %7d  %@", number, wake - cycle.sleep, stopped.count, flying, asleep,
      started.count, delays.joined(separator: ", ")))
}

if let change = lastChange, change < last.time {
  let window = last.time - change

  print("")
  print(String(format: "after the last change to the schedules, at %@, over %.1f s", clock(change), window))
  print("metric           interval s  samples  expected  live schedules")

  for metric in metrics {
    let live = (starts[metric]?.count ?? 0) - (stops[metric]?.count ?? 0)
    let taken = count(samples[metric], from: change, to: last.time + 1)

    check(live == 0 || live == 1, "\(metric) has \(live) schedules")

    guard live == 1, let interval = interval(of: metric, at: last.time) else {
      check(taken == 0, "\(metric) was sampled \(taken) times without a schedule")

      print(
        String(
          format: "%@  %10@  %7d  %8d  %14d", metric.padding(toLength: 15, withPad: " ", startingAt: 0), "-", taken, 0,
          live))

      continue
    }

    let expected = window / interval

    check(Double(taken) <= expected + 2.5, "\(metric) was sampled \(taken) times, more than one schedule takes")
    check(Double(taken) >= expected - 1, "\(metric) was sampled only \(taken) times")

    print(
      String(
        format: "%@  %10.1f  %7d  %8.1f  %14d", metric.padding(toLength: 15, withPad: " ", startingAt: 0), interval,
        taken, expected, live))
  }
}

if !notes.isEmpty {
  print("")
  print("other entries of the coordinator")

  for note in notes {
    print("  \(note)")
  }
}

print("")
print("\(cycles.count) sleeps, \(failures) failed checks")

exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
