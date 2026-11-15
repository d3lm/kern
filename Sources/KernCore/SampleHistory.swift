/// The most recent samples of one metric, oldest first.
///
/// The storage is allocated once and then overwritten in a circle, so a history kept for days never grows.
public struct SampleHistory: RandomAccessCollection, Sendable {
  public let capacity: Int
  private var storage: ContiguousArray<MetricSample> = []
  private var oldest = 0

  init(capacity: Int) {
    precondition(capacity > 0, "a history must hold at least one sample")

    self.capacity = capacity

    storage.reserveCapacity(capacity)
  }

  public var startIndex: Int { 0 }
  public var endIndex: Int { storage.count }

  public subscript(position: Int) -> MetricSample {
    storage[(oldest + position) % storage.count]
  }

  mutating func append(_ sample: MetricSample) {
    if storage.count < capacity {
      storage.append(sample)
    } else {
      storage[oldest] = sample
      oldest = (oldest + 1) % capacity
    }
  }

  var storageCapacity: Int { storage.capacity }
}
