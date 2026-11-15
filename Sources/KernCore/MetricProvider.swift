public enum Availability: Equatable, Sendable {
  case stopped
  case available
  case unavailable(SensorError)
}

/// Runs one sensor and keeps its lifecycle and error bookkeeping. Being an actor keeps sensor work
/// off the main actor.
public actor MetricProvider {
  public nonisolated let source: SourceID
  private var sensor: any MetricSensor
  private var isOpen = false
  public private(set) var availability: Availability = .stopped
  public private(set) var lastSuccessfulSample: MetricSample?

  public init(sensor: some MetricSensor) {
    self.source = sensor.source
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

    guard isOpen else {
      let reason: UnavailableReason = errorState.map(UnavailableReason.sensorFailed) ?? .notStarted

      return MetricSample(source: source, acquiredAt: acquiredAt, state: .unavailable(reason))
    }

    do {
      let reading = try sensor.read()

      availability = .available

      switch reading {
      case .value(let value):
        let sample = MetricSample(source: source, acquiredAt: acquiredAt, state: .valid(value))

        lastSuccessfulSample = sample

        return sample
      case .noValue(let reason):
        return MetricSample(source: source, acquiredAt: acquiredAt, state: .unavailable(.noValue(reason)))
      }
    } catch {
      availability = .unavailable(error)

      return MetricSample(source: source, acquiredAt: acquiredAt, state: .unavailable(.sensorFailed(error)))
    }
  }
}
