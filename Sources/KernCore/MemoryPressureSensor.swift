import Darwin

/// Where `MemoryPressureSensor` gets the share of memory that is still available.
protocol MemoryAvailabilitySource: Sendable {
  /// The share of memory available to apps without reclaiming any, in whole percent.
  func availablePercent() throws(SensorError) -> Int
}

/// Memory pressure, 0–100%: the share of memory that macOS cannot give to an app without first reclaiming it,
/// by compressing or swapping memory or by evicting cached files.
///
/// Used memory stops rising once memory is full, because macOS makes room by compressing and swapping.
/// Pressure keeps rising and falling with how much work that takes.
public struct MemoryPressureSensor: MetricSensor {
  public let source = SourceID("memory.memorystatus_level")
  public let quantity = MetricQuantity.memoryPressure
  private let availability: any MemoryAvailabilitySource

  public init() {
    self.init(availability: SysctlMemoryAvailability())
  }

  init(availability: some MemoryAvailabilitySource) {
    self.availability = availability
  }

  /// Reads once, so a system without the counter reports the sensor unavailable from the start.
  public mutating func open() throws(SensorError) {
    _ = try availablePercent()
  }

  public mutating func read() throws(SensorError) -> SensorReading {
    .value(MetricValue(Double(100 - (try availablePercent())), .percent))
  }

  public mutating func close() {}

  private func availablePercent() throws(SensorError) -> Int {
    let percent = try availability.availablePercent()

    guard (0...100).contains(percent) else {
      throw SensorError("the available memory reads as \(percent)%, outside 0–100%")
    }

    return percent
  }
}

/// `kern.memorystatus_level`, the available share of memory that the `memory_pressure` tool prints as its
/// System-wide memory free percentage. A public sysctl that needs no privileges.
struct SysctlMemoryAvailability: MemoryAvailabilitySource {
  func availablePercent() throws(SensorError) -> Int {
    var level: Int32 = 0
    var size = MemoryLayout<Int32>.size

    guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
      throw SensorError("sysctl kern.memorystatus_level failed: \(String(cString: strerror(errno)))")
    }

    return Int(level)
  }
}
