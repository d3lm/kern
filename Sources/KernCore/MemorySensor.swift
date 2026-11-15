import Darwin

/// System-wide memory counts at one moment, in pages of `pageSize` bytes.
struct MemoryCounts: Equatable, Sendable {
  var pageSize: UInt64
  /// Memory belonging to processes rather than to files, compressed or not yet.
  var anonymousPages: UInt64
  /// Anonymous memory that its owner has marked as safe to discard when memory is short.
  var purgeablePages: UInt64
  /// Memory that cannot be compressed or paged out, mostly the system's.
  var wiredPages: UInt64
  /// Memory holding compressed data.
  var compressorPages: UInt64
}

/// Where `MemorySensor` gets its counts.
protocol MemoryCountSource: Sendable {
  /// The installed memory in bytes.
  mutating func open() throws(SensorError) -> UInt64
  mutating func read() throws(SensorError) -> MemoryCounts
  mutating func close()
}

/// The share of installed memory in use, 0–100%, counted as Activity Monitor counts its Memory Used: app memory,
/// which is anonymous memory that cannot be discarded, plus wired memory, plus the memory holding compressed data.
/// Memory caching files is not counted, because macOS gives it back as soon as it is needed.
public struct MemorySensor: MetricSensor {
  public let source = SourceID("memory.host_statistics64")
  public let quantity = MetricQuantity.memoryUsage
  private var counts: any MemoryCountSource
  private var installed: UInt64?

  public init() {
    self.init(counts: MachMemoryCounts())
  }

  init(counts: some MemoryCountSource) {
    self.counts = counts
  }

  public mutating func open() throws(SensorError) {
    let installed = try counts.open()

    guard installed > 0 else { throw SensorError("the installed memory reads as 0 bytes") }

    self.installed = installed
  }

  /// A count that does not fit together with the others fails the read, because the share it would give could
  /// not be trusted.
  public mutating func read() throws(SensorError) -> SensorReading {
    guard let installed else { throw SensorError("the memory sensor is not open") }

    let counts = try counts.read()

    guard counts.purgeablePages <= counts.anonymousPages else {
      throw SensorError("\(counts.purgeablePages) purgeable pages exceed \(counts.anonymousPages) anonymous pages")
    }

    let usedPages = counts.anonymousPages - counts.purgeablePages + counts.wiredPages + counts.compressorPages
    let (used, overflow) = usedPages.multipliedReportingOverflow(by: counts.pageSize)

    guard !overflow, used <= installed else {
      throw SensorError("\(usedPages) pages of \(counts.pageSize) bytes exceed the \(installed) bytes installed")
    }

    return .value(MetricValue(Double(used) / Double(installed) * 100, .percent))
  }

  public mutating func close() {
    counts.close()
    installed = nil
  }
}

/// Memory counts from `host_statistics64(HOST_VM_INFO64)` and the installed memory from `hw.memsize`,
/// public interfaces that need no privileges.
struct MachMemoryCounts: MemoryCountSource {
  private var host = mach_port_t(MACH_PORT_NULL)
  private var pageSize: vm_size_t = 0

  mutating func open() throws(SensorError) -> UInt64 {
    if host == MACH_PORT_NULL {
      host = mach_host_self()
    }

    guard host != MACH_PORT_NULL else { throw SensorError("mach_host_self returned no host port") }

    let result = host_page_size(host, &pageSize)

    guard result == KERN_SUCCESS, pageSize > 0 else {
      throw SensorError("host_page_size failed: \(String(cString: mach_error_string(result)))")
    }

    var installed: UInt64 = 0
    var size = MemoryLayout<UInt64>.size

    guard sysctlbyname("hw.memsize", &installed, &size, nil, 0) == 0, size == MemoryLayout<UInt64>.size else {
      throw SensorError("sysctl hw.memsize failed: \(String(cString: strerror(errno)))")
    }

    return installed
  }

  func read() throws(SensorError) -> MemoryCounts {
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

    let result = withUnsafeMutablePointer(to: &statistics) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }

    guard result == KERN_SUCCESS else {
      throw SensorError("host_statistics64 failed: \(String(cString: mach_error_string(result)))")
    }

    return MemoryCounts(
      pageSize: UInt64(pageSize),
      anonymousPages: UInt64(statistics.internal_page_count),
      purgeablePages: UInt64(statistics.purgeable_count),
      wiredPages: UInt64(statistics.wire_count),
      compressorPages: UInt64(statistics.compressor_page_count)
    )
  }

  mutating func close() {
    guard host != MACH_PORT_NULL else { return }

    mach_port_deallocate(mach_task_self_, host)

    host = mach_port_t(MACH_PORT_NULL)
  }
}
