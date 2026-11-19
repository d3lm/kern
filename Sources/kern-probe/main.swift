import Foundation
import KernCore

let usage = """
  Usage: kern-probe [<mode>]

  Prints the chip identity. With a mode, it then prints readings until interrupted.

  Modes:
    cpu                  Prints a CPU reading every 2 s.
    gpu                  Prints a GPU reading every 2 s.
    temperature          Prints the CPU temperature every 10 s.
    memory               Prints the share of memory in use every 6 s.
    memory-pressure      Prints the memory pressure every 6 s.
    storage              Prints the share of the startup disk in use every 10 s.
    kern                 Prints this process's own CPU use and memory footprint every 6 s.
    temperature-sensors  Prints every SMC temperature as comma-separated columns every 1 s.
                         It exists only for validating sensor maps.
    metrics              Runs every metric through the coordinator and prints a metric's
                         readings from the store each time it is sampled. It also stops when
                         standard input closes. Storage and kern start disabled because the
                         app samples them only while their widget is in the menu bar or
                         Settings is open.

  In metrics mode, kern-probe reads these commands from standard input, one per line.
    enable <metric>
    disable <metric>
    interval <metric> <seconds>
    details on|off       Samples as the app does with its detail popover open or closed.
    sleep                Suspends sampling as the app does when the system announces sleep.
    wake                 Resumes sampling as the app does when the system wakes.
    low-power on|off     Samples as the app does while Low Power Mode is on or off.
    low-power-behavior adaptive|override
                         Slows down in Low Power Mode, or keeps the configured intervals.

    The <metric> argument is cpu, gpu, temperature, memory, memory-pressure, storage, or kern.
  """

let mode = CommandLine.arguments.dropFirst().first

let modes = [
  "cpu", "gpu", "temperature", "memory", "memory-pressure", "storage", "kern", "temperature-sensors", "metrics",
]

if let mode, !modes.contains(mode) {
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
case "cpu": await printReadings(of: CPUSensor(), every: Metric.cpu.defaultInterval)
case "gpu": await printReadings(of: GPUSensor(), every: Metric.gpu.defaultInterval)
case "temperature":
  await printReadings(of: TemperatureSensor(chip: ChipIdentifier.current), every: Metric.temperature.defaultInterval)
case "memory": await printReadings(of: MemorySensor(), every: Metric.memory.defaultInterval)
case "memory-pressure": await printReadings(of: MemoryPressureSensor(), every: Metric.memoryPressure.defaultInterval)
case "storage": await printReadings(of: StorageSensor(), every: Metric.storage.defaultInterval)
case "kern": await printReadings(of: ProcessUsageSensor(), every: Metric.kern.defaultInterval)
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
    .memory: MetricProvider(sensor: MemorySensor()),
    .memoryPressure: MetricProvider(sensor: MemoryPressureSensor()),
    .storage: MetricProvider(sensor: StorageSensor()),
    .kern: MetricProvider(sensor: ProcessUsageSensor()),
  ])

  coordinator.disable(.storage)
  coordinator.disable(.kern)

  let store = coordinator.store

  _ = store.observe { metric in
    guard let readings = store[metric] else { return }

    let name = metric.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)

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

  switch words {
  case ["details", "on"]:
    coordinator.areDetailsVisible = true
    return "details visible"
  case ["details", "off"]:
    coordinator.areDetailsVisible = false
    return "details hidden"
  case ["sleep"]:
    coordinator.powerState.isAsleep = true
    return "asleep"
  case ["wake"]:
    coordinator.powerState.isAsleep = false
    return "awake"
  case ["low-power", "on"]:
    coordinator.powerState.isLowPowerModeEnabled = true
    return "low power mode on"
  case ["low-power", "off"]:
    coordinator.powerState.isLowPowerModeEnabled = false
    return "low power mode off"
  case ["low-power-behavior", "adaptive"]:
    coordinator.lowPowerModeBehavior = .adaptive
    return "low power mode behavior adaptive"
  case ["low-power-behavior", "override"]:
    coordinator.lowPowerModeBehavior = .override
    return "low power mode behavior override"
  default:
    break
  }

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
  case .memoryUsage: "memory in use"
  case .memoryPressure: "memory pressure"
  case .storageUsage: "storage in use"
  case .processUsage: "process usage"
  }
}

func describe(_ state: SampleState) -> String {
  switch state {
  case .valid(let reading):
    switch (reading.unit, reading.split, reading.memory, reading.footprintBytes) {
    case (.percent, let split?, _, _):
      String(format: "%5.1f %%  (user %5.1f %%, system %5.1f %%)", reading.value, split.user, split.system)
    case (.percent, nil, let memory?, _):
      String(
        format: "%5.1f %%  (%.2f of %.2f GiB)", reading.value, Double(memory.usedBytes) / 1_073_741_824,
        Double(memory.installedBytes) / 1_073_741_824)
    case (.percent, nil, nil, let footprint?):
      String(format: "%5.1f %%  (footprint %.1f MiB)", reading.value, Double(footprint) / 1_048_576)
    case (.percent, nil, nil, nil): String(format: "%5.1f %%", reading.value)
    case (.celsius, _, _, _):
      String(format: "%5.1f °C", reading.value)
        + (reading.temperatures ?? []).map {
          String(format: "  (%@ %.1f to %.1f °C)", "\($0.part)", $0.coolest, $0.hottest)
        }.joined()
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
