import Testing

@testable import KernCore

extension MetricsCoordinatorTests {
  @Test func everyMetricHasALowPowerInterval() {
    #expect(Metric.cpu.lowPowerInterval == .seconds(5))
    #expect(Metric.gpu.lowPowerInterval == .seconds(5))
    #expect(Metric.temperature.lowPowerInterval == .seconds(20))
    #expect(Metric.memory.lowPowerInterval == .seconds(10))
    #expect(Metric.memoryPressure.lowPowerInterval == .seconds(10))
    #expect(Metric.kern.lowPowerInterval == .seconds(5))
  }

  @Test func lowPowerModeSlowsEveryMetricAndTurningItOffRestoresThemWithoutARestart() async {
    let coordinator = coordinator()

    coordinator.areDetailsVisible = true

    coordinator.start()

    await run(until: 6, schedules: 6)

    coordinator.powerState.isLowPowerModeEnabled = true

    #expect(coordinator.store[.cpu]?.interval == .seconds(5))
    #expect(coordinator.store[.gpu]?.interval == .seconds(5))
    #expect(coordinator.store[.kern]?.interval == .seconds(5))
    #expect(coordinator.store[.temperature]?.interval == .seconds(20))
    #expect(coordinator.store[.memoryPressure]?.interval == .seconds(10))
    #expect(coordinator.store[.memory]?.interval == .seconds(10))

    await run(until: 41, schedules: 6)

    #expect(logs[.cpu]!.reads == [0, 2, 4, 6, 11, 16, 21, 26, 31, 36, 41])
    #expect(logs[.gpu]!.reads == [0, 2, 4, 6, 11, 16, 21, 26, 31, 36, 41])
    #expect(logs[.kern]!.reads == logs[.cpu]!.reads)
    #expect(logs[.temperature]!.reads == [0, 20, 40])
    #expect(logs[.memoryPressure]!.reads == [0, 5, 15, 25, 35])
    #expect(logs[.memory]!.reads == [0, 5, 15, 25, 35])

    coordinator.powerState.isLowPowerModeEnabled = false

    #expect(coordinator.store[.cpu]?.interval == .seconds(2))
    #expect(coordinator.store[.temperature]?.interval == .seconds(10))
    #expect(coordinator.store[.memoryPressure]?.interval == .seconds(5))
    #expect(coordinator.store[.memory]?.interval == .seconds(5))

    await run(until: 51, schedules: 6)

    #expect(logs[.cpu]!.reads == [0, 2, 4, 6, 11, 16, 21, 26, 31, 36, 41, 43, 45, 47, 49, 51])
    #expect(logs[.gpu]!.reads == logs[.cpu]!.reads)
    #expect(logs[.kern]!.reads == logs[.cpu]!.reads)
    #expect(logs[.temperature]!.reads == [0, 20, 40, 50])
    #expect(logs[.memoryPressure]!.reads == [0, 5, 15, 25, 35, 41, 46, 51])
    #expect(logs[.memory]!.reads == [0, 5, 15, 25, 35, 41, 46, 51])

    for metric in Metric.allCases {
      #expect(logs[metric]!.all.filter { !$0.hasPrefix("read") } == ["open"], "\(metric)")
    }
  }

  @Test func lowPowerModeNeverSamplesAMetricMoreOftenThanItsConfiguredInterval() async {
    let coordinator = coordinator([.cpu, .temperature, .memoryPressure])

    coordinator.setInterval(.seconds(8), for: .cpu)
    coordinator.setInterval(.seconds(30), for: .temperature)
    coordinator.setInterval(.seconds(12), for: .memoryPressure)

    coordinator.powerState.isLowPowerModeEnabled = true

    coordinator.start()

    await run(until: 60, schedules: 3)

    #expect(logs[.cpu]!.reads == Array(stride(from: 0, through: 56, by: 8)))
    #expect(logs[.temperature]!.reads == [0, 30, 60])
    #expect(logs[.memoryPressure]!.reads == Array(stride(from: 0, through: 60, by: 12)))
    #expect(coordinator.store[.cpu]?.interval == .seconds(8))

    coordinator.setInterval(.seconds(1), for: .cpu)

    #expect(coordinator.store[.cpu]?.interval == .seconds(5))

    await run(until: 71, schedules: 3)

    #expect(logs[.cpu]!.reads == Array(stride(from: 0, through: 56, by: 8)) + [61, 66, 71])

    coordinator.powerState.isLowPowerModeEnabled = false

    await run(until: 74, schedules: 3)

    #expect(logs[.cpu]!.reads.suffix(3) == [72, 73, 74])
  }

  @Test func overrideKeepsTheConfiguredIntervalsAndAChangeOfPreferenceAppliesAtOnce() async {
    let coordinator = coordinator([.cpu, .temperature])

    coordinator.lowPowerModeBehavior = .override
    coordinator.powerState.isLowPowerModeEnabled = true

    coordinator.start()

    await run(until: 6, schedules: 2)

    #expect(logs[.cpu]!.reads == [0, 2, 4, 6])
    #expect(coordinator.store[.cpu]?.interval == .seconds(2))
    #expect(coordinator.store[.temperature]?.interval == .seconds(10))

    coordinator.lowPowerModeBehavior = .adaptive

    await run(until: 16, schedules: 2)

    #expect(logs[.cpu]!.reads == [0, 2, 4, 6, 11, 16])
    #expect(coordinator.store[.temperature]?.interval == .seconds(20))

    coordinator.lowPowerModeBehavior = .override

    await run(until: 20, schedules: 2)

    #expect(logs[.cpu]!.reads == [0, 2, 4, 6, 11, 16, 18, 20])
    #expect(logs[.temperature]!.reads == [0, 16])
    #expect(logs[.cpu]!.opens == 1)
  }

  @Test func adaptiveIsTheStandardBehavior() {
    #expect(LowPowerModeBehavior.standard == .adaptive)
    #expect(coordinator([.cpu]).lowPowerModeBehavior == .adaptive)
  }

  @Test func lowPowerModeCutsTenMinutesOfCPUSamplesFromThreeHundredToOneHundredTwenty() async {
    let coordinator = coordinator([.cpu, .gpu, .temperature, .memoryPressure])

    coordinator.start()

    await run(until: 600, schedules: 4)

    let standard = logs.mapValues { $0.reads.count { $0 > 0 } }

    coordinator.powerState.isLowPowerModeEnabled = true

    await run(until: 1_200, schedules: 4)

    let reduced = logs.mapValues { $0.reads.count { $0 > 600 } }

    #expect(standard[.cpu] == 300)
    #expect(standard[.gpu] == 300)
    #expect(standard[.temperature] == 60)
    #expect(standard[.memoryPressure] == 120)
    #expect(reduced[.cpu] == 120)
    #expect(reduced[.gpu] == 120)
    #expect(reduced[.temperature] == 30)
    #expect(reduced[.memoryPressure] == 60)
  }
}
