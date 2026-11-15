public enum Availability: Equatable, Sendable {
  case stopped
  case available
  case unavailable(SensorError)
}

/// Runs one sensor and keeps its lifecycle and error bookkeeping. Being an actor keeps sensor work
/// off the main actor.
public actor MetricProvider {
  public nonisolated let source: SourceID
  public nonisolated let quantity: MetricQuantity
  private var sensor: any MetricSensor
  private var isOpen = false
  public private(set) var availability: Availability = .stopped
  public private(set) var lastSuccessfulSample: MetricSample?

  public init(sensor: some MetricSensor) {
    self.source = sensor.source
    self.quantity = sensor.quantity
    self.sensor = sensor
  }

  public var errorState: SensorError? {
    if case .unavailable(let error) = availability { error } else { nil }
  }

  /// Opens the sensor. Calling it again after a failed open retries; calling it while open does nothing.
  public func start() {
    guard !isOpen else { return }

    do {
      try sensor.open()
      isOpen = true
      availability = .available
    } catch {
      availability = .unavailable(error)
    }
  }

  public func stop() {
    if isOpen {
      sensor.close()
      isOpen = false
    }

    availability = .stopped
  }

  public func sample() -> MetricSample {
    let acquiredAt = ContinuousClock.now

    let sample = MetricSample(source: source, quantity: quantity, acquiredAt: acquiredAt, state: readSensor())

    if sample.value != nil {
      lastSuccessfulSample = sample
    }

    return sample
  }

  private func readSensor() -> SampleState {
    guard isOpen else { return .unavailable(errorState.map(UnavailableReason.sensorFailed) ?? .notStarted) }

    do {
      let reading = try sensor.read()

      availability = .available

      switch reading {
      case .value(let value): return .valid(value)
      case .noValue(let reason): return .unavailable(.noValue(reason))
      }
    } catch {
      availability = .unavailable(error)

      return .unavailable(.sensorFailed(error))
    }
  }
}
