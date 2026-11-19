#if DEBUG
  import KernCore

  struct DebugLaunchOptions: Equatable {
    enum Failure: Equatable {
      case always
      case during(Duration)
    }

    struct InvalidArgument: Error, CustomStringConvertible {
      let description: String
    }

    private(set) var failures: [Metric: Failure] = [:]
    private(set) var chip: ChipIdentity?
    /// Holds how long after launch Settings opens by itself, which it then does without any click that could
    /// let Kern become the active app.
    private(set) var settingsDelay: Duration?

    /// Must skip unknown arguments, because macOS and Xcode pass their own.
    init(arguments: [String]) throws(InvalidArgument) {
      var arguments = arguments.dropFirst()

      while let argument = arguments.popFirst() {
        switch argument {
        case "--fail":
          let (metric, failure) = try Self.failure(from: arguments.popFirst())

          failures[metric] = failure

        case "--chip":
          guard let brandString = arguments.popFirst() else {
            throw InvalidArgument(description: "--chip needs a value")
          }

          chip = ChipIdentity(brandString: brandString)

        case "--settings-after":
          guard let seconds = arguments.popFirst().flatMap(Double.init), seconds >= 0 else {
            throw InvalidArgument(description: "--settings-after needs a number of seconds that is not negative")
          }

          settingsDelay = .seconds(seconds)

        default:
          continue
        }
      }
    }

    private static func failure(from value: String?) throws(InvalidArgument) -> (Metric, Failure) {
      let usage =
        "--fail needs <metric>[:<seconds>], where <metric> is cpu, gpu, temperature, memory, memory-pressure, "
        + "storage, or kern"

      guard let parts = value?.split(separator: ":", omittingEmptySubsequences: false), parts.count <= 2,
        let metric = Metric(rawValue: String(parts[0]))
      else {
        throw InvalidArgument(description: "\(usage), not \"\(value ?? "")\"")
      }

      guard parts.count == 2 else { return (metric, .always) }

      guard let seconds = Double(parts[1]), seconds > 0 else {
        throw InvalidArgument(description: "\(usage), with a positive number of seconds, not \"\(value ?? "")\"")
      }

      return (metric, .during(.seconds(seconds)))
    }

    func sensor(
      _ sensor: any MetricSensor,
      for metric: Metric,
      launchedAt launch: ContinuousClock.Instant
    ) -> any MetricSensor {
      switch failures[metric] {
      case nil: sensor
      case .always: FailingSensor(base: sensor, failsUntil: nil)
      case .during(let duration): FailingSensor(base: sensor, failsUntil: launch + duration)
      }
    }
  }

  struct FailingSensor: MetricSensor {
    var base: any MetricSensor
    let failsUntil: ContinuousClock.Instant?

    var source: SourceID { base.source }
    var quantity: MetricQuantity { base.quantity }
    var sourceDescription: String { base.sourceDescription }
    var coreKinds: [CoreKind]? { base.coreKinds }

    mutating func open() throws(SensorError) {
      try base.open()
    }

    mutating func read() throws(SensorError) -> SensorReading {
      if failsUntil.map({ ContinuousClock.now < $0 }) ?? true {
        throw SensorError("failure forced by --fail")
      }

      return try base.read()
    }

    mutating func close() {
      base.close()
    }
  }
#endif
