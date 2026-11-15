import Foundation
import KernCore

let usage = """
  usage: kern-probe [cpu | gpu]

    (no mode)  print the chip identity
    cpu        print the chip identity, then one CPU reading every 2 seconds until interrupted
    gpu        print the chip identity, then one GPU reading every 2 seconds until interrupted
  """

let mode = CommandLine.arguments.dropFirst().first

guard mode == nil || mode == "cpu" || mode == "gpu" else {
  print(usage)
  exit(EX_USAGE)
}

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
default: break
}

/// Samples on a fixed cadence. A sample that runs late skips the missed ticks instead of catching up.
func printReadings(of sensor: some MetricSensor, every interval: Duration) async {
  let provider = MetricProvider(sensor: sensor)
  await provider.start()

  let clock = ContinuousClock()

  let hour = Date.FormatStyle.Symbol.VerbatimHour.twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)

  let timeFormat = Date.VerbatimFormatStyle(
    format: "\(hour: hour):\(minute: .twoDigits):\(second: .twoDigits)",
    timeZone: .current,
    calendar: .current
  )

  var deadline = clock.now

  while true {
    let sample = await provider.sample()
    let time = Date.now.formatted(timeFormat)

    print("\(time)  \(sample.source)  \(describe(sample.quantity))  \(describe(sample.state))")

    fflush(nil)

    deadline += interval

    while deadline < clock.now { deadline += interval }

    try? await clock.sleep(until: deadline, tolerance: .milliseconds(100))
  }
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
