import KernCore
import Testing

@testable import KernUI

@MainActor
struct SampleBatchTests {
  final class Deliveries {
    var all: [Set<Metric>] = []
  }

  @Test func samplesArrivingWithinTheWindowAreDeliveredTogether() async throws {
    let deliveries = Deliveries()
    let batch = SampleBatch(window: .milliseconds(100)) { deliveries.all.append($0) }

    batch.add(.cpu)

    try await Task.sleep(for: .milliseconds(20))

    batch.add(.gpu)
    batch.add(.cpu)

    #expect(deliveries.all.isEmpty)

    await waitUntil { !deliveries.all.isEmpty }

    try await Task.sleep(for: .milliseconds(150))

    #expect(deliveries.all == [[.cpu, .gpu]])
  }

  @Test func sampleAfterADeliveryStartsANewBatch() async throws {
    let deliveries = Deliveries()
    let batch = SampleBatch(window: .milliseconds(20)) { deliveries.all.append($0) }

    batch.add(.cpu)

    await waitUntil { deliveries.all.count == 1 }

    batch.add(.temperature)

    await waitUntil { deliveries.all.count == 2 }

    #expect(deliveries.all == [[.cpu], [.temperature]])
  }

  /// Samples arrive 30 ms apart for 150 ms, past the 100 ms window, so a window that restarted with every
  /// sample would not close until they stopped and would deliver them all at once.
  @Test func windowCountsFromTheFirstSampleSoABatchIsNeverHeldBackLonger() async throws {
    let deliveries = Deliveries()
    let batch = SampleBatch(window: .milliseconds(100)) { deliveries.all.append($0) }

    batch.add(.cpu)

    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(30))
      batch.add(.gpu)
    }

    await waitUntil { deliveries.all.count == 2 }

    #expect(deliveries.all == [[.cpu, .gpu], [.gpu]])
  }

  @Test func cancellingPendingBatchDeliversNothing() async throws {
    let deliveries = Deliveries()
    let batch = SampleBatch(window: .milliseconds(50)) { deliveries.all.append($0) }

    batch.add(.cpu)
    batch.cancel()

    try await Task.sleep(for: .milliseconds(80))

    #expect(deliveries.all.isEmpty)
  }

  @Test func zeroWindowDeliversAtOnce() {
    let deliveries = Deliveries()
    let batch = SampleBatch(window: .zero) { deliveries.all.append($0) }

    batch.add(.cpu)
    batch.add(.gpu)

    #expect(deliveries.all == [[.cpu], [.gpu]])
  }
}
