import Darwin

/// Cumulative scheduler ticks one logical CPU has spent in each state since boot.
struct CPUTicks: Equatable, Sendable {
  var user: UInt32
  var system: UInt32
  var idle: UInt32
  var nice: UInt32
}

/// Where `CPUSensor` gets its counters.
protocol CPUTickSource: Sendable {
  mutating func open() throws(SensorError)
  /// One entry per logical CPU.
  mutating func read() throws(SensorError) -> [CPUTicks]
  mutating func close()
}

/// Total system CPU utilization: the share of time all logical CPUs together spent busy between
/// two reads, 0–100%.
public struct CPUSensor: MetricSensor {
  public let source = SourceID("cpu.host_processor_info")
  private var ticks: any CPUTickSource
  private var previous: [CPUTicks]?

  public init() {
    self.init(ticks: MachProcessorTicks())
  }

  init(ticks: some CPUTickSource) {
    self.ticks = ticks
  }

  public mutating func open() throws(SensorError) {
    previous = nil
    try ticks.open()
  }

  /// A read that cannot be compared with the one before still becomes the baseline for the next read.
  public mutating func read() throws(SensorError) -> SensorReading {
    let current = try ticks.read()
    let baseline = previous

    previous = current

    guard let baseline, baseline.count == current.count else { return .noValue(.awaitingBaseline) }

    return Self.utilization(from: baseline, to: current)
  }

  public mutating func close() {
    ticks.close()
    previous = nil
  }

  static func utilization(from old: [CPUTicks], to new: [CPUTicks]) -> SensorReading {
    var busy: UInt64 = 0
    var total: UInt64 = 0

    for (old, new) in zip(old, new) {
      guard new.user >= old.user, new.system >= old.system, new.idle >= old.idle, new.nice >= old.nice else {
        return .noValue(.countersWentBackwards)
      }

      let cpuBusy = UInt64(new.user - old.user) + UInt64(new.system - old.system) + UInt64(new.nice - old.nice)

      busy += cpuBusy
      total += cpuBusy + UInt64(new.idle - old.idle)
    }

    guard total > 0 else { return .noValue(.countersUnchanged) }

    return .value(MetricValue(Double(busy) / Double(total) * 100, .percent))
  }
}

/// Per-CPU load counters from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, a public Mach interface
/// that needs no privileges.
struct MachProcessorTicks: CPUTickSource {
  private var host = mach_port_t(MACH_PORT_NULL)

  mutating func open() throws(SensorError) {
    guard host == MACH_PORT_NULL else { return }

    host = mach_host_self()

    guard host != MACH_PORT_NULL else { throw SensorError("mach_host_self returned no host port") }
  }

  func read() throws(SensorError) -> [CPUTicks] {
    var cpuCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0

    let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)

    guard result == KERN_SUCCESS, let info else {
      throw SensorError("host_processor_info failed: \(String(cString: mach_error_string(result)))")
    }

    defer {
      let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)

      vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
    }

    let stride = Int(CPU_STATE_MAX)

    guard cpuCount > 0, Int(infoCount) == Int(cpuCount) * stride else {
      throw SensorError("host_processor_info returned \(infoCount) values for \(cpuCount) CPUs")
    }

    return (0..<Int(cpuCount)).map { cpu in
      let counters = info + cpu * stride

      return CPUTicks(
        user: UInt32(bitPattern: counters[Int(CPU_STATE_USER)]),
        system: UInt32(bitPattern: counters[Int(CPU_STATE_SYSTEM)]),
        idle: UInt32(bitPattern: counters[Int(CPU_STATE_IDLE)]),
        nice: UInt32(bitPattern: counters[Int(CPU_STATE_NICE)])
      )
    }
  }

  mutating func close() {
    guard host != MACH_PORT_NULL else { return }

    mach_port_deallocate(mach_task_self_, host)

    host = mach_port_t(MACH_PORT_NULL)
  }
}
