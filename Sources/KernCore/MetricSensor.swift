public struct SensorError: Error, Equatable, Sendable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

/// What one successful read of a sensor produced.
public enum SensorReading: Equatable, Sendable {
  case value(MetricValue)
  /// The source answered, but its data cannot give a trustworthy value this time. This is not a failure, so it
  /// does not set the provider's error state.
  case noValue(NoValueReason)
}

/// The hardware-facing adapter for one metric. Any undocumented macOS interface stays inside its sensor.
public protocol MetricSensor: Sendable {
  var source: SourceID { get }

  mutating func open() throws(SensorError)
  mutating func read() throws(SensorError) -> SensorReading
  mutating func close()
}
