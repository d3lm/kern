import Foundation

struct VolumeCapacity: Equatable, Sendable {
  var totalBytes: Int64
  /// Holds the bytes the volume can store for files the user asks for, including space macOS would free
  /// by purging caches and other purgeable files to make room.
  var availableBytes: Int64
}

protocol VolumeCapacitySource: Sendable {
  mutating func read() throws(SensorError) -> VolumeCapacity
}

/// Measures the volume macOS started from. Every volume of an APFS container shares the container's space,
/// so the share is that of the whole container, which on a Mac with one internal disk is the whole disk.
public struct StorageSensor: MetricSensor {
  public let source = SourceID("storage.volume_capacity")
  public let quantity = MetricQuantity.storageUsage

  public let sourceDescription =
    "Startup disk capacity not available for new files, where purgeable space counts as free"

  public let coreKinds: [CoreKind]? = nil
  private var capacity: any VolumeCapacitySource

  public init() {
    self.init(capacity: StartupVolumeCapacity())
  }

  init(capacity: some VolumeCapacitySource) {
    self.capacity = capacity
  }

  public mutating func open() throws(SensorError) {}

  public mutating func read() throws(SensorError) -> SensorReading {
    let capacity = try capacity.read()

    guard capacity.totalBytes > 0 else {
      throw SensorError("the startup disk's capacity reads as \(capacity.totalBytes) bytes")
    }

    guard (0...capacity.totalBytes).contains(capacity.availableBytes) else {
      throw SensorError(
        "the startup disk has \(capacity.availableBytes) bytes available of its \(capacity.totalBytes) bytes")
    }

    let used = capacity.totalBytes - capacity.availableBytes

    return .value(MetricValue(Double(used) / Double(capacity.totalBytes) * 100, .percent))
  }

  public mutating func close() {}
}

/// Makes a new URL for each read, because a URL caches the resource values it has read and would report them again.
struct StartupVolumeCapacity: VolumeCapacitySource {
  func read() throws(SensorError) -> VolumeCapacity {
    let values: URLResourceValues

    do {
      values = try URL(filePath: "/").resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
      ])
    } catch {
      throw SensorError("reading the startup disk's capacity failed: \(error.localizedDescription)")
    }

    guard let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage else {
      throw SensorError("the startup disk reports no total or available capacity")
    }

    return VolumeCapacity(totalBytes: Int64(total), availableBytes: available)
  }
}
