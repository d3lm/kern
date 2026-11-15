import Foundation
import KernCore

let usage = """
  usage: kern-probe [cpu | gpu | temperature | temperature-sensors]

    (no mode)            print the chip identity
    cpu                  print the chip identity, then one CPU reading every 2 seconds until interrupted
    gpu                  print the chip identity, then one GPU reading every 2 seconds until interrupted
    temperature          print the chip identity, then one CPU temperature every 10 seconds until interrupted
    temperature-sensors  print the chip identity, then every SMC temperature as comma-separated columns,
                         one row every second until interrupted; for validating sensor maps only
  """

let mode = CommandLine.arguments.dropFirst().first

if let mode, !["cpu", "gpu", "temperature", "temperature-sensors"].contains(mode) {
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
