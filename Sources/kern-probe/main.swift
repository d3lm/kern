import Foundation
import KernCore

let usage = """
  usage: kern-probe [cpu | gpu | temperature | temperature-sensors | metrics]

    (no mode)            print the chip identity
    cpu                  print the chip identity, then one CPU reading every 2 seconds until interrupted
    gpu                  print the chip identity, then one GPU reading every 2 seconds until interrupted
    temperature          print the chip identity, then one CPU temperature every 10 seconds until interrupted
    temperature-sensors  print the chip identity, then every SMC temperature as comma-separated columns,
                         one row every second until interrupted; for validating sensor maps only
    metrics              print the chip identity, then run every metric through the coordinator and print a
                         metric's readings from the store each time it is sampled, until interrupted or until
                         standard input closes; reads these commands from standard input:
                           enable <metric>
                           disable <metric>
                           interval <metric> <seconds>
                         where <metric> is cpu, gpu, or temperature
  """

let mode = CommandLine.arguments.dropFirst().first

if let mode, !["cpu", "gpu", "temperature", "temperature-sensors", "metrics"].contains(mode) {
  print(usage)
  exit(EX_USAGE)
}

let hour = Date.FormatStyle.Symbol.VerbatimHour.twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)

let timeFormat = Date.VerbatimFormatStyle(
  format: "\(hour: hour):\(minute: .twoDigits):\(second: .twoDigits)",
  timeZone: .current,
  calendar: .current
)

switch ChipIdentifier.current {
case .recognized(let chip):
  print("chip: \(chip)")
case .unrecognized(let brandString?):
  print("chip: unrecognized (brand string: \"\(brandString)\")")
case .unrecognized(nil):
  print("chip: unrecognized (no brand string reported)")
}

switch mode {
case "cpu": await printReadings(of: CPUSensor(), every: .seconds(2))
case "gpu": await printReadings(of: GPUSensor(), every: .seconds(2))
case "temperature": await printReadings(of: TemperatureSensor(chip: ChipIdentifier.current), every: .seconds(10))
case "temperature-sensors": await printTemperatureSensors(every: .seconds(1))
case "metrics": await printMetrics()
default: break
}

func printReadings(of sensor: some MetricSensor, every interval: Duration) async {
  let provider = MetricProvider(sensor: sensor)
  await provider.start()

  await repeatEvery(interval) {
    let sample = await provider.sample()

    print("\(timestamp())  \(sample.source)  \(describe(sample.quantity))  \(describe(sample.state))")
  }
}

/// Finds the sensors once, then reads the same ones on every row, so the columns stay aligned.
func printTemperatureSensors(every interval: Duration) async {
  let survey: TemperatureSurvey

  do {
    survey = try TemperatureSurvey()
  } catch {
    print("cannot list the temperature sensors: \(error)")
    exit(EXIT_FAILURE)
  }

  print((["time"] + survey.sensors).joined(separator: ","))

  await repeatEvery(interval) {
    do {
      let reading = try survey.read()
      let values = survey.sensors.map { reading[$0].map { String(format: "%.2f", $0) } ?? "" }

      print(([timestamp()] + values).joined(separator: ","))
    } catch {
      print("\(timestamp()),error: \(error)")
    }
  }
}

@MainActor
func printMetrics() async {
  let coordinator = MetricsCoordinator(providers: [
    .cpu: MetricProvider(sensor: CPUSensor()),
    .gpu: MetricProvider(sensor: GPUSensor()),
    .temperature: MetricProvider(sensor: TemperatureSensor(chip: ChipIdentifier.current)),
  ])

  let store = coordinator.store

  _ = store.observe { metric in
    guard let readings = store[metric] else { return }

    let name = metric.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)

    print("\(timestamp())  \(name)  \(describe(readings))")

    fflush(nil)
  }

  coordinator.start()

  do {
    for try await line in FileHandle.standardInput.bytes.lines {
      print("\(timestamp())  \(apply(line, to: coordinator))")

      fflush(nil)
    }
  } catch {
    print("cannot read standard input: \(error)")
  }
}

@MainActor
func apply(_ command: String, to coordinator: MetricsCoordinator<ContinuousClock>) -> String {
  let words = command.split(separator: " ")

  guard words.count >= 2, let metric = Metric(rawValue: String(words[1])) else {
    return "unknown command \"\(command)\""
  }

  switch (words[0], words.count) {
  case ("enable", 2):
    coordinator.enable(metric)
    return "\(metric.rawValue) enabled"
  case ("disable", 2):
    coordinator.disable(metric)
    return "\(metric.rawValue) disabled"
  case ("interval", 3):
    guard let seconds = Double(words[2]), seconds > 0 else { return "the interval must be a positive number" }

    coordinator.setInterval(.seconds(seconds), for: metric)
    return "\(metric.rawValue) every \(words[2]) s"
  default:
    return "unknown command \"\(command)\""
  }
}

/// Runs `body` on a fixed cadence. A run that ends late skips the missed ticks instead of catching up.
func repeatEvery(_ interval: Duration, _ body: () async -> Void) async {
  let clock = ContinuousClock()

  var deadline = clock.now

  while true {
    await body()

    fflush(nil)

    deadline += interval

    while deadline < clock.now { deadline += interval }

    try? await clock.sleep(until: deadline, tolerance: .milliseconds(100))
  }
}

func timestamp() -> String {
  Date.now.formatted(timeFormat)
}

func describe(_ quantity: MetricQuantity) -> String {
  switch quantity {
  case .utilization: "utilization"
  case .activeResidency: "active residency"
  case .temperature: "temperature"
  }
}

func describe(_ state: SampleState) -> String {
  switch state {
  case .valid(let reading):
    switch reading.unit {
    case .percent: String(format: "%5.1f %%", reading.value)
    case .celsius: String(format: "%5.1f °C", reading.value)
    }
  case .unavailable(.notStarted):
    "unavailable (not started)"
  case .unavailable(.noValue(.awaitingBaseline)):
    "unavailable (awaiting baseline)"
  case .unavailable(.noValue(.countersUnchanged)):
    "unavailable (counters unchanged)"
  case .unavailable(.noValue(.countersWentBackwards)):
    "unavailable (counters went backwards)"
  case .unavailable(.sensorFailed(let error)):
    "unavailable (error: \(error))"
  }
}

func describe(_ readings: MetricReadings) -> String {
  var parts: [String] = []

  if let latest = readings.latest {
    parts.append(describe(latest.state))
  }

  if readings.latest?.value == nil, let lastSuccessful = readings.lastSuccessful {
    let freshness = readings.isStale(at: .now) ? "stale" : "current"

    parts.append("last success \(describe(lastSuccessful.state)), \(freshness)")
  }

  if let history = readings.history {
    let gaps = history.count { $0.value == nil }

    parts.append("history \(history.count)/\(history.capacity), \(gaps) \(gaps == 1 ? "gap" : "gaps")")
  }

  return parts.joined(separator: "  ")
}
