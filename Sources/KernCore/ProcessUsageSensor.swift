import Darwin

struct ProcessCounters: Equatable, Sendable {
  var cpuTime: Duration
  /// Holds the time since boot without sleep, during which a process cannot use the CPU either.
  var uptime: Duration
  var footprintBytes: UInt64
}

protocol ProcessCounterSource: Sendable {
  mutating func read() throws(SensorError) -> ProcessCounters
}

/// Measures the process it runs in, which in the app is Kern itself.
public struct ProcessUsageSensor: MetricSensor {
  public let source = SourceID("kern.getrusage_task_info")
  public let quantity = MetricQuantity.processUsage
  public let sourceDescription = "Kern's own CPU time and physical footprint, as Activity Monitor counts them"
  public let coreKinds: [CoreKind]? = nil
  private var counters: any ProcessCounterSource
  private var previous: ProcessCounters?

  public init() {
    self.init(counters: TaskCounters())
  }

  init(counters: some ProcessCounterSource) {
    self.counters = counters
  }

  public mutating func open() throws(SensorError) {
    previous = nil
  }

  /// Every read must become the baseline, even one that cannot be compared, or a mismatch would never clear.
  public mutating func read() throws(SensorError) -> SensorReading {
    let current = try counters.read()
    let baseline = previous

    previous = current

    guard let baseline else { return .noValue(.awaitingBaseline) }

    let busy = current.cpuTime - baseline.cpuTime
    let elapsed = current.uptime - baseline.uptime

    guard busy >= .zero, elapsed >= .zero else { return .noValue(.countersWentBackwards) }

    guard elapsed > .zero else { return .noValue(.countersUnchanged) }

    return .value(MetricValue(busy / elapsed * 100, .percent, footprintBytes: current.footprintBytes))
  }

  public mutating func close() {
    previous = nil
  }
}

/// `proc_pid_rusage` would give both numbers in one call, but on Apple Silicon its CPU times are in Mach absolute
/// time units rather than the nanoseconds its header promises, so the CPU time comes from `getrusage` instead.
struct TaskCounters: ProcessCounterSource {
  func read() throws(SensorError) -> ProcessCounters {
    var usage = rusage()

    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
      throw SensorError("getrusage failed: \(String(cString: strerror(errno)))")
    }

    let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }

    guard result == KERN_SUCCESS else {
      throw SensorError("task_info failed: \(String(cString: mach_error_string(result)))")
    }

    return ProcessCounters(
      cpuTime: Duration(usage.ru_utime) + Duration(usage.ru_stime),
      uptime: .nanoseconds(uptime),
      footprintBytes: info.phys_footprint
    )
  }
}

extension Duration {
  fileprivate init(_ time: timeval) {
    self = .seconds(time.tv_sec) + .microseconds(time.tv_usec)
  }
}
