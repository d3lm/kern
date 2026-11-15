@testable import KernCore

let start = ContinuousClock.now

func sample(_ state: SampleState, at acquiredAt: ContinuousClock.Instant = start) -> MetricSample {
  MetricSample(source: SourceID("test.sensor"), quantity: .utilization, acquiredAt: acquiredAt, state: state)
}

func value(_ value: Double, _ unit: MetricUnit = .percent) -> SampleState {
  .valid(MetricValue(value, unit))
}

let failed = SampleState.unavailable(.sensorFailed(SensorError("read failed")))

/// The readings of `metric` after recording `samples` in a store, as the menu bar receives them.
@MainActor
func readings(
  _ metric: Metric,
  interval: Duration = .seconds(2),
  after samples: [MetricSample] = []
) -> MetricReadings {
  let store = MetricsStore(intervals: [metric: interval])

  for sample in samples {
    store.record(sample, for: metric)
  }

  return store[metric]!
}
