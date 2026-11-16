public struct SensorError: Error, Equatable, Sendable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

public enum SensorReading: Equatable, Sendable {
  case value(MetricValue)
  case noValue(NoValueReason)
}

public protocol MetricSensor: Sendable {
  var source: SourceID { get }
  var quantity: MetricQuantity { get }
  var sourceDescription: String { get }
  var coreKinds: [CoreKind]? { get }

  mutating func open() throws(SensorError)
  mutating func read() throws(SensorError) -> SensorReading
  mutating func close()
}
