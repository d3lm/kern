import Testing

@testable import KernCore

func sample(
  _ state: SampleState,
  at acquiredAt: ContinuousClock.Instant = .now,
  source: SourceID = SourceID("test.sensor")
) -> MetricSample {
  MetricSample(source: source, quantity: .utilization, acquiredAt: acquiredAt, state: state)
}

func percent(_ value: Double) -> SampleState {
  .valid(MetricValue(value, .percent))
}

let sensorFailure = SampleState.unavailable(.sensorFailed(SensorError("read failed")))

struct SampleHistoryTests {
  @Test func keepsTheMostRecentSamplesOldestFirst() {
    var history = SampleHistory(capacity: 3)

    for value in 1...5 {
      history.append(sample(percent(Double(value))))
    }

    #expect(history.map(\.value?.value) == [3, 4, 5])
  }

  @Test func holdsSixtySamplesAfterTenThousandWithoutGrowingItsStorage() {
    var history = SampleHistory(capacity: 60)

    for value in 0..<60 {
      history.append(sample(percent(Double(value))))
    }

    let storageWhenFull = history.storageCapacity

    for value in 60..<10_000 {
      history.append(sample(percent(Double(value % 100))))
    }

    #expect(history.count == 60)
    #expect(history.storageCapacity == storageWhenFull)
    #expect(history.map(\.value?.value) == (9_940..<10_000).map { Double($0 % 100) })
  }
}

@MainActor
struct MetricsStoreTests {
  let start = ContinuousClock.now

  func store(cpuInterval: Duration = .seconds(2)) -> MetricsStore {
    MetricsStore(intervals: [.cpu: cpuInterval, .gpu: .seconds(2), .temperature: .seconds(10), .memory: .seconds(5)])
  }

  @Test func cpuAndGPUKeepSixtySamplesOfHistoryAndTemperatureAndMemoryNone() {
    let store = store()

    #expect(store[.cpu]?.history?.capacity == 60)
    #expect(store[.gpu]?.history?.capacity == 60)
    #expect(store[.temperature] != nil)
    #expect(store[.temperature]?.history == nil)
    #expect(store[.memory] != nil)
    #expect(store[.memory]?.history == nil)
  }

  @Test func unavailableSampleEntersTheHistoryAsAGapNotAsZero() {
    let store = store()

    store.record(sample(percent(40)), for: .cpu)
    store.record(sample(.unavailable(.noValue(.countersUnchanged))), for: .cpu)
    store.record(sample(sensorFailure), for: .cpu)
    store.record(sample(percent(0)), for: .cpu)

    #expect(store[.cpu]?.history?.map(\.value?.value) == [40, nil, nil, 0])
  }

  @Test func failedSampleBecomesTheLatestButKeepsTheLastSuccess() {
    let store = store()
    let good = sample(percent(12), at: start)
    let failed = sample(sensorFailure, at: start + .seconds(2))

    store.record(good, for: .cpu)
    store.record(failed, for: .cpu)

    #expect(store[.cpu]?.latest == failed)
    #expect(store[.cpu]?.lastSuccessful == good)
    #expect(store[.gpu]?.latest == nil)
  }

  @Test func readingGoesStaleTwoIntervalsAndOneSecondAfterTheLastSuccess() {
    let store = store()

    store.record(sample(percent(12), at: start), for: .cpu)

    let readings = store[.cpu]!

    #expect(readings.staleAt == start + .seconds(5))
    #expect(!readings.isStale(at: start + .seconds(5) - .nanoseconds(1)))
    #expect(readings.isStale(at: start + .seconds(5)))
  }

  @Test func failedSamplesDoNotKeepAReadingCurrent() {
    let store = store()

    store.record(sample(percent(12), at: start), for: .cpu)
    store.record(sample(sensorFailure, at: start + .seconds(2)), for: .cpu)
    store.record(sample(.unavailable(.noValue(.countersUnchanged)), at: start + .seconds(4)), for: .cpu)

    #expect(store[.cpu]!.isStale(at: start + .seconds(5)))
  }

  @Test func nextSuccessfulSampleMakesAStaleReadingCurrentAgain() {
    let store = store()

    store.record(sample(percent(12), at: start), for: .cpu)

    #expect(store[.cpu]!.isStale(at: start + .seconds(8)))

    store.record(sample(percent(20), at: start + .seconds(8)), for: .cpu)

    #expect(!store[.cpu]!.isStale(at: start + .seconds(8)))
    #expect(store[.cpu]!.staleAt == start + .seconds(13))
  }

  @Test func stalenessFollowsTheConfiguredInterval() {
    let store = store()

    store.record(sample(percent(12), at: start), for: .cpu)
    store.setInterval(.seconds(10), for: .cpu)

    #expect(store[.cpu]!.staleAt == start + .seconds(21))
    #expect(!store[.cpu]!.isStale(at: start + .seconds(20)))
  }

  @Test func metricWithoutASuccessfulSampleHasNothingToGoStale() {
    let store = store()

    store.record(sample(sensorFailure, at: start), for: .temperature)

    #expect(store[.temperature]!.staleAt == nil)
    #expect(!store[.temperature]!.isStale(at: start + .seconds(3600)))
  }

  @Test func observersHearOnceForEachSampleAndAtNoOtherTime() {
    let store = store()
    var first: [Metric] = []
    var second: [Metric] = []

    _ = store.observe { first.append($0) }
    _ = store.observe { second.append($0) }

    store.record(sample(percent(1)), for: .cpu)
    store.setInterval(.seconds(5), for: .cpu)
    store.record(sample(sensorFailure), for: .gpu)
    store.record(sample(percent(1)), for: .cpu)

    #expect(first == [.cpu, .gpu, .cpu])
    #expect(second == [.cpu, .gpu, .cpu])
  }

  @Test func removedObserverHearsNothingMore() {
    let store = store()
    var heard: [Metric] = []

    let id = store.observe { heard.append($0) }

    store.record(sample(percent(1)), for: .cpu)
    store.removeObserver(id)
    store.record(sample(percent(2)), for: .cpu)

    #expect(heard == [.cpu])
  }
}
