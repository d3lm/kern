public struct SensorError: Error, Equatable, Sendable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

/// The hardware-facing adapter for one metric. Any undocumented macOS interface stays inside its sensor.
public protocol MetricSensor: Sendable {
  var source: SourceID { get }

  mutating func open() throws(SensorError)
  mutating func read() throws(SensorError) -> MetricValue
  mutating func close()
}
