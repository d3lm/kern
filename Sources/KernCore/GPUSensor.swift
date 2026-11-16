import Foundation

protocol GPUStateResidencySource: Sendable {
  mutating func open() throws(SensorError)
  mutating func read() throws(SensorError) -> [String: UInt64]
  mutating func close()
}

public struct GPUSensor: MetricSensor {
  public let source = SourceID("gpu.ioreport.gpuph")
  public let quantity = MetricQuantity.activeResidency
  public let sourceDescription = "Time the GPU spent in its performance states rather than off, from IOReport"
  public let coreKinds: [CoreKind]? = nil
  private var residency: any GPUStateResidencySource
  private var previous: [String: UInt64]?

  public init() {
    self.init(residency: IOReportGPUStateResidency())
  }

  init(residency: some GPUStateResidencySource) {
    self.residency = residency
  }

  public mutating func open() throws(SensorError) {
    previous = nil
    try residency.open()
  }

  /// Every read must become the baseline, even one that cannot be compared, or a mismatch would never clear.
  public mutating func read() throws(SensorError) -> SensorReading {
    let current = try residency.read()

    try Self.checkStates(of: current)

    let baseline = previous

    previous = current

    guard let baseline else { return .noValue(.awaitingBaseline) }

    return Self.activeResidency(from: baseline, to: current)
  }

  public mutating func close() {
    residency.close()
    previous = nil
  }

  private static let offState = "OFF"

  /// Only `OFF` is known to be inactive, so an unknown state must fail the read rather than count as active.
  static func checkStates(of residency: [String: UInt64]) throws(SensorError) {
    guard residency[offState] != nil else {
      throw SensorError("the GPU power states have no \(offState) state: \(residency.keys.sorted())")
    }

    let unfamiliar = residency.keys.filter { $0 != offState && !isPerformanceState($0) }

    guard unfamiliar.isEmpty else { throw SensorError("unfamiliar GPU power states: \(unfamiliar.sorted())") }
  }

  private static func isPerformanceState(_ state: String) -> Bool {
    let number = state.dropFirst()

    return state.first == "P" && !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
  }

  static func activeResidency(from old: [String: UInt64], to new: [String: UInt64]) -> SensorReading {
    guard old.count == new.count else { return .noValue(.awaitingBaseline) }

    var active: Double = 0
    var total: Double = 0

    for (state, ticks) in new {
      guard let oldTicks = old[state] else { return .noValue(.awaitingBaseline) }
      guard ticks >= oldTicks else { return .noValue(.countersWentBackwards) }

      let elapsed = Double(ticks - oldTicks)

      total += elapsed

      if state != offState {
        active += elapsed
      }
    }

    guard total > 0 else { return .noValue(.countersUnchanged) }

    return .value(MetricValue(active / total * 100, .percent))
  }
}

/// `@unchecked Sendable` is sound only while the non-`Sendable` IOReport objects are created in `open()`
/// and used only by the sensor's owner.
struct IOReportGPUStateResidency: GPUStateResidencySource, @unchecked Sendable {
  private var subscription: CFTypeRef?
  private var channels: CFMutableDictionary?

  mutating func open() throws(SensorError) {
    guard subscription == nil else { return }

    let library = try IOReportLibrary.shared.get()

    guard
      let group = library.copyChannelsInGroup("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)
    else {
      throw SensorError("IOReport has no \"GPU Performance States\" channels")
    }

    let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, group.takeRetainedValue())

    var subscribed: Unmanaged<CFMutableDictionary>?

    guard let desired, let subscription = library.createSubscription(nil, desired, &subscribed, 0, nil),
      let subscribed: Unmanaged<CFMutableDictionary>
    else {
      throw SensorError("IOReportCreateSubscription failed")
    }

    self.subscription = subscription.takeRetainedValue()
    self.channels = subscribed.takeRetainedValue()
  }

  func read() throws(SensorError) -> [String: UInt64] {
    let library: IOReportLibrary = try IOReportLibrary.shared.get()

    guard let subscription, let channels, let samples = library.createSamples(subscription, channels, nil) else {
      throw SensorError("IOReportCreateSamples failed")
    }

    let sampled = (samples.takeRetainedValue() as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? []

    guard let channel = sampled.first(where: { library.channelName($0)?.takeUnretainedValue() == "GPUPH" as CFString })
    else {
      throw SensorError("IOReport samples have no GPUPH channel")
    }

    let stateCount = library.stateCount(channel)

    guard stateCount > 0 else { throw SensorError("the GPUPH channel reports \(stateCount) states") }

    var residency: [String: UInt64] = [:]

    for index in 0..<stateCount {
      guard
        let name = library.stateName(channel, index)?.takeUnretainedValue(),
        let ticks = UInt64(exactly: library.stateResidency(channel, index))
      else {
        throw SensorError("GPUPH state \(index) has no name or a negative residency")
      }

      residency[name as String] = ticks
    }

    return residency
  }

  mutating func close() {
    subscription = nil
    channels = nil
  }
}

private struct IOReportLibrary: Sendable {
  /// Never unloaded, because the function pointers taken from it must stay valid for the life of the process.
  static let shared = Result { () throws(SensorError) in try IOReportLibrary() }

  let copyChannelsInGroup: @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?

  let createSubscription:
    @convention(c) (
      UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64,
      CFTypeRef?
    ) -> Unmanaged<CFTypeRef>?

  let createSamples: @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
  let channelName: @convention(c) (CFDictionary) -> Unmanaged<CFString>?
  let stateCount: @convention(c) (CFDictionary) -> Int32
  let stateName: @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
  let stateResidency: @convention(c) (CFDictionary, Int32) -> Int64

  private init() throws(SensorError) {
    guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL) else {
      throw SensorError("could not load libIOReport: \(dlerror().map { String(cString: $0) } ?? "unknown error")")
    }

    copyChannelsInGroup = try Self.function("IOReportCopyChannelsInGroup", in: handle)
    createSubscription = try Self.function("IOReportCreateSubscription", in: handle)
    createSamples = try Self.function("IOReportCreateSamples", in: handle)
    channelName = try Self.function("IOReportChannelGetChannelName", in: handle)
    stateCount = try Self.function("IOReportStateGetCount", in: handle)
    stateName = try Self.function("IOReportStateGetNameForIndex", in: handle)
    stateResidency = try Self.function("IOReportStateGetResidency", in: handle)
  }

  private static func function<Function>(_ name: String, in handle: UnsafeMutableRawPointer) throws(SensorError)
    -> Function
  {
    guard let address = dlsym(handle, name) else { throw SensorError("libIOReport has no \(name)") }

    return unsafeBitCast(address, to: Function.self)
  }
}
