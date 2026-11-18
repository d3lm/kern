protocol TemperatureSource: Sendable {
  mutating func open(keys: [String]) throws(SensorError)
  mutating func read() throws(SensorError) -> [String: Double]
  mutating func close()
}

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

  /// Sensor keys differ between chip generations and variants, so add a chip only after verifying its keys on it.
  static let validated: [Chip: CPUTemperatureMap] = [
    // each core has three keys and the map uses the middle one, because the first reads as the middle one minus a
    // fixed offset and the third is noisier
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

public struct TemperatureSensor: MetricSensor {
  public let source = SourceID("temperature.smc.cpu")
  public let quantity = MetricQuantity.temperature
  private let chip: ChipIdentity
  private let map: CPUTemperatureMap?
  private var temperatures: any TemperatureSource

  /// SMC sensors without a reading report exactly 0, so the lower bound must stay above 0.
  static let plausibleRange: ClosedRange<Double> = 10...130

  public init(chip: ChipIdentity) {
    self.init(chip: chip, temperatures: SMCTemperatures())
  }

  init(chip: ChipIdentity, temperatures: some TemperatureSource) {
    self.chip = chip
    self.map = CPUTemperatureMap.forChip(chip)
    self.temperatures = temperatures
  }

  public let coreKinds: [CoreKind]? = nil

  public var sourceDescription: String {
    guard let map else { return "No CPU temperature sensors have been validated for this chip (\(chip))" }

    switch map.aggregation {
    case .maximum: return "Hottest of the \(map.sensors.count) CPU core sensors in the SMC validated for the \(chip)"
    }
  }

  public mutating func open() throws(SensorError) {
    try temperatures.open(keys: validatedMap().sensors)
  }

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

    guard let combined = map.aggregation.combine(celsius), let coolest = celsius.min(), let hottest = celsius.max()
    else {
      throw SensorError("the sensor map for \(chip) has no sensors")
    }

    return .value(
      MetricValue(combined, .celsius, temperatures: [PartTemperature(part: .cpu, coolest: coolest, hottest: hottest)]))
  }

  public mutating func close() {
    temperatures.close()
  }

  private func validatedMap() throws(SensorError) -> CPUTemperatureMap {
    guard let map else { throw SensorError("no validated CPU temperature sensor map for chip: \(chip)") }

    return map
  }
}

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
