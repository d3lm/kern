@testable import KernCore

let start = ContinuousClock.now

func sample(_ state: SampleState, at acquiredAt: ContinuousClock.Instant = start) -> MetricSample {
  MetricSample(source: SourceID("test.sensor"), quantity: .utilization, acquiredAt: acquiredAt, state: state)
}

func value(_ value: Double, _ unit: MetricUnit = .percent, cores: CoreUtilization? = nil) -> SampleState {
  .valid(MetricValue(value, unit, cores: cores))
}

let failed = SampleState.unavailable(.sensorFailed(SensorError("read failed")))

@MainActor
func readings(
  _ metric: Metric,
  interval: Duration = .seconds(2),
  after samples: [MetricSample] = [],
  isEnabled: Bool = true
) -> MetricReadings {
  let store = MetricsStore(intervals: [metric: interval])

  for sample in samples {
    store.record(sample, for: metric)
  }

  store.setEnabled(isEnabled, for: metric)

  return store[metric]!
}
