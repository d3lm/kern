/// Where `TemperatureSensor` gets its readings.
protocol TemperatureSource: Sendable {
  /// Prepares to read `keys`, and only those, on every `read()`.
  mutating func open(keys: [String]) throws(SensorError)
  /// The current temperature of each key passed to `open`, in degrees Celsius.
  mutating func read() throws(SensorError) -> [String: Double]
  mutating func close()
}

/// The verified CPU die sensors of one chip, and how their readings combine into one CPU temperature.
struct CPUTemperatureMap: Equatable, Sendable {
  enum Aggregation: Sendable {
    case maximum

    func combine(_ celsius: [Double]) -> Double? {
      switch self {
      case .maximum: celsius.max()
      }
    }
  }

  let sensors: [String]
  let aggregation: Aggregation

  /// Sensor names differ between chip generations and variants, so a chip is listed only after its sensors have
  /// been verified on that chip. Every other chip has no temperature rather than one read from guessed sensors.
  static let validated: [Chip: CPUTemperatureMap] = [
    // One key per CPU core, the middle one of each core's three. The first of the three is always this one minus
    // a fixed offset, and the third is a separate, noisier value; see docs/sensors.md.
    Chip(family: .m1, variant: .max): CPUTemperatureMap(
      sensors: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b"],
      aggregation: .maximum
    )
  ]

  static func forChip(_ identity: ChipIdentity) -> CPUTemperatureMap? {
    guard case .recognized(let chip) = identity else { return nil }

    return validated[chip]
  }
}

/// CPU temperature in degrees Celsius, combined from the verified CPU die sensors in the chip's sensor map.
///
/// A chip without a validated sensor map has no temperature. Opening the sensor then fails without touching the
/// hardware.
public struct TemperatureSensor: MetricSensor {
  public let source = SourceID("temperature.smc.cpu")
  public let quantity = MetricQuantity.temperature
  private let chip: ChipIdentity
  private let map: CPUTemperatureMap?
  private var temperatures: any TemperatureSource

  /// A value outside this range means the source is broken, not the chip. A running chip is never colder than the
  /// coolest room Apple specifies its Macs to work in, and SMC sensors without a reading report exactly 0. The
  /// upper end leaves a wide margin over the hottest readings measured under full load (docs/sensors.md).
  static let plausibleRange: ClosedRange<Double> = 10...130

  public init(chip: ChipIdentity) {
    self.init(chip: chip, temperatures: SMCTemperatures())
  }

  init(chip: ChipIdentity, temperatures: some TemperatureSource) {
    self.chip = chip
    self.map = CPUTemperatureMap.forChip(chip)
    self.temperatures = temperatures
  }

  public mutating func open() throws(SensorError) {
    try temperatures.open(keys: validatedMap().sensors)
  }

  /// One implausible or missing sensor fails the whole read. Combining the others would hide that the source no
  /// longer means what was verified.
  public mutating func read() throws(SensorError) -> SensorReading {
    let map = try validatedMap()
    let readings = try temperatures.read()

    var celsius: [Double] = []

    for sensor in map.sensors {
      guard let value = readings[sensor] else { throw SensorError("the read has no value for \(sensor)") }

      guard Self.plausibleRange.contains(value) else {
        throw SensorError("\(sensor) read \(value) °C, outside the plausible range \(Self.plausibleRange) °C")
      }

      celsius.append(value)
    }

    guard let combined = map.aggregation.combine(celsius) else {
      throw SensorError("the sensor map for \(chip) has no sensors")
    }

    return .value(MetricValue(combined, .celsius))
  }

  public mutating func close() {
    temperatures.close()
  }

  private func validatedMap() throws(SensorError) -> CPUTemperatureMap {
    guard let map else { throw SensorError("no validated CPU temperature sensor map for chip: \(chip)") }

    return map
  }
}

/// Temperatures from SMC keys of type `flt `, a 32-bit float in degrees Celsius.
///
/// Each key's type is checked once in `open()`, so a read makes exactly one SMC call per key.
struct SMCTemperatures: TemperatureSource {
  private var connection: SMCConnection?
  private var keys: [SMCKey] = []

  mutating func open(keys names: [String]) throws(SensorError) {
    guard connection == nil else { return }

    var keys: [SMCKey] = []

    for name in names {
      guard let key = SMCKey(name) else { throw SensorError("\"\(name)\" is not a four-character SMC key") }

      keys.append(key)
    }

    var connection = try SMCConnection()

    do throws(SensorError) {
      for key in keys {
        let info = try connection.info(for: key)

        guard info == .float else { throw SensorError("SMC key \(key) holds \(info), not \(SMCKeyInfo.float)") }
      }
    } catch {
      connection.close()
      throw error
    }

    self.connection = connection
    self.keys = keys
  }

  func read() throws(SensorError) -> [String: Double] {
    guard let connection else { throw SensorError("the SMC connection is not open") }

    var celsius: [String: Double] = [:]

    for key in keys {
      let bits = try connection.read(key, .float).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }

      celsius[key.description] = Double(Float(bitPattern: UInt32(littleEndian: bits)))
    }

    return celsius
  }

  mutating func close() {
    connection?.close()
    connection = nil
    keys = []
  }
}

/// Every temperature the SMC reports as a float, for validation work only: finding them takes one SMC call for each
/// of its roughly 2,000 keys. The app reads just the sensors in the chip's sensor map.
public struct TemperatureSurvey: Sendable {
  public let sensors: [String]
  private var temperatures = SMCTemperatures()

  public init() throws(SensorError) {
    var connection = try SMCConnection()

    defer { connection.close() }

    var sensors: [String] = []

    for key in try connection.allKeys() where key.description.hasPrefix("T") {
      if try connection.info(for: key) == .float {
        sensors.append(key.description)
      }
    }

    self.sensors = sensors

    try temperatures.open(keys: sensors)
  }

  public func read() throws(SensorError) -> [String: Double] {
    try temperatures.read()
  }

  public mutating func close() {
    temperatures.close()
  }
}
