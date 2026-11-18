import Foundation
import IOKit

struct CPUTicks: Equatable, Sendable {
  var user: UInt32
  var system: UInt32
  var idle: UInt32
  var nice: UInt32
}

public enum CoreKind: Equatable, Sendable {
  case performance
  case efficiency
}

protocol CPUTickSource: Sendable {
  /// Must be in the order `read()` lists the CPUs.
  var coreKinds: [CoreKind]? { get }
  mutating func open() throws(SensorError)
  mutating func read() throws(SensorError) -> [CPUTicks]
  mutating func close()
}

public struct CPUSensor: MetricSensor {
  public let source = SourceID("cpu.host_processor_info")
  public let quantity = MetricQuantity.utilization
  public let sourceDescription = "Busy time of every logical CPU, from the Mach processor load counters"
  public let coreKinds: [CoreKind]?
  private var ticks: any CPUTickSource
  private var previous: [CPUTicks]?

  public init() {
    self.init(ticks: MachProcessorTicks())
  }

  init(ticks: some CPUTickSource) {
    self.ticks = ticks
    self.coreKinds = ticks.coreKinds
  }

  public mutating func open() throws(SensorError) {
    previous = nil

    try ticks.open()
  }

  /// Every read must become the baseline, even one that cannot be compared, or a mismatch would never clear.
  public mutating func read() throws(SensorError) -> SensorReading {
    let current = try ticks.read()
    let baseline = previous

    previous = current

    guard let baseline, baseline.count == current.count else { return .noValue(.awaitingBaseline) }

    return Self.utilization(from: baseline, to: current, kinds: coreKinds)
  }

  public mutating func close() {
    ticks.close()

    previous = nil
  }

  static func utilization(from old: [CPUTicks], to new: [CPUTicks], kinds: [CoreKind]?) -> SensorReading {
    var user: UInt64 = 0
    var system: UInt64 = 0
    var total: UInt64 = 0
    var shares: [Double?] = []

    for (old, new) in zip(old, new) {
      guard new.user >= old.user, new.system >= old.system, new.idle >= old.idle, new.nice >= old.nice else {
        return .noValue(.countersWentBackwards)
      }

      let cpuUser = UInt64(new.user - old.user) + UInt64(new.nice - old.nice)
      let cpuSystem = UInt64(new.system - old.system)
      let cpuTotal = cpuUser + cpuSystem + UInt64(new.idle - old.idle)

      user += cpuUser
      system += cpuSystem
      total += cpuTotal

      shares.append(cpuTotal > 0 ? Double(cpuUser + cpuSystem) / Double(cpuTotal) * 100 : nil)
    }

    guard total > 0 else { return .noValue(.countersUnchanged) }

    func percent(_ ticks: UInt64) -> Double {
      Double(ticks) / Double(total) * 100
    }

    let cores = kinds.flatMap { CoreUtilization(shares: shares, kinds: $0) }
    let split = CPUTimeSplit(user: percent(user), system: percent(system))

    return .value(MetricValue(percent(user + system), .percent, cores: cores, split: split))
  }
}

extension CoreUtilization {
  init?(shares: [Double?], kinds: [CoreKind]) {
    guard shares.count == kinds.count else { return nil }

    var performance: [Double] = []
    var efficiency: [Double] = []

    for (share, kind) in zip(shares, kinds) {
      guard let share else { return nil }

      switch kind {
      case .performance: performance.append(share)
      case .efficiency: efficiency.append(share)
      }
    }

    self.init(performance: performance, efficiency: efficiency)
  }
}

struct MachProcessorTicks: CPUTickSource {
  let coreKinds = Self.deviceTreeCoreKinds()
  private var host = mach_port_t(MACH_PORT_NULL)

  mutating func open() throws(SensorError) {
    if host == MACH_PORT_NULL {
      host = mach_host_self()
    }

    guard host != MACH_PORT_NULL else { throw SensorError("mach_host_self returned no host port") }
  }

  /// `logical-cpu-id` is the CPU's index in `host_processor_info`. It and `cluster-type` are undocumented,
  /// so anything unexpected must return `nil` rather than guess.
  static func deviceTreeCoreKinds() -> [CoreKind]? {
    let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")

    guard cpus != IO_OBJECT_NULL else { return nil }

    defer { IOObjectRelease(cpus) }

    var iterator = io_iterator_t(IO_OBJECT_NULL)

    guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }

    defer { IOObjectRelease(iterator) }

    var kinds: [Int: CoreKind] = [:]

    while true {
      let entry = IOIteratorNext(iterator)

      guard entry != IO_OBJECT_NULL else { break }

      defer { IOObjectRelease(entry) }

      guard text(of: "device_type", in: entry) == "cpu" else { continue }

      guard let id = property("logical-cpu-id", of: entry) as? Int, kinds[id] == nil else { return nil }

      switch text(of: "cluster-type", in: entry) {
      case "P": kinds[id] = .performance
      case "E": kinds[id] = .efficiency
      default: return nil
      }
    }

    guard !kinds.isEmpty, kinds.keys.sorted() == Array(0..<kinds.count) else { return nil }

    return kinds.keys.sorted().map { kinds[$0]! }
  }

  private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }

  /// Device tree strings are `Data` ending in a zero byte.
  private static func text(of key: String, in entry: io_registry_entry_t) -> String? {
    guard let data = property(key, of: entry) as? Data else { return nil }

    return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
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
