import Dispatch
import Testing

@testable import KernCore

extension MetricsCoordinatorTests {
  var everyProviderIsClosed: Bool {
    Metric.allCases.allSatisfy { !logs[$0]!.isOpen }
  }

  @Test func sleepEndsSamplingAndWakeReopensEveryProviderBeforeItsFirstSample() async {
    let coordinator = coordinator()

    coordinator.start()

    await run(until: 4, schedules: 6)

    coordinator.powerState.isAsleep = true

    #expect(clock.sleeperCount == 0)

    await waitUntil { everyProviderIsClosed }
    await run(until: 64, schedules: 0)

    #expect(logs[.cpu]!.all == ["open", "read 0", "read 2", "read 4", "close"])
    #expect(logs[.temperature]!.all == ["open", "read 0", "close"])

    coordinator.powerState.isAsleep = false

    await run(until: 70, schedules: 6)

    #expect(
      logs[.cpu]!.all
        == ["open", "read 0", "read 2", "read 4", "close", "open", "read 64", "read 66", "read 68", "read 70"])

    #expect(logs[.gpu]!.all == logs[.cpu]!.all)
    #expect(logs[.kern]!.all == logs[.cpu]!.all)
    #expect(logs[.temperature]!.all == ["open", "read 0", "close", "open", "read 64"])
    #expect(logs[.storage]!.all == logs[.temperature]!.all)
    #expect(logs[.memoryPressure]!.all == ["open", "read 0", "close", "open", "read 64", "read 69"])
    #expect(logs[.memory]!.all.isEmpty)
    #expect(coordinator.store[.temperature]?.latest?.value == MetricValue(64, .percent))
  }

  @Test func wakeSamplesEveryMetricAtOnceEvenAfterASleepShorterThanItsInterval() async {
    let coordinator = coordinator()

    coordinator.start()

    await run(until: 1, schedules: 6)

    coordinator.powerState.isAsleep = true

    await waitUntil { everyProviderIsClosed }
    await run(until: 3, schedules: 0)

    coordinator.powerState.isAsleep = false

    await run(until: 13, schedules: 6)

    #expect(logs[.cpu]!.reads == [0, 3, 5, 7, 9, 11, 13])
    #expect(logs[.gpu]!.reads == [0, 3, 5, 7, 9, 11, 13])
    #expect(logs[.kern]!.reads == [0, 3, 5, 7, 9, 11, 13])
    #expect(logs[.temperature]!.reads == [0, 3, 13])
    #expect(logs[.storage]!.reads == [0, 3, 13])
    #expect(logs[.memoryPressure]!.reads == [0, 3, 8, 13])
  }

  @Test func rateReadsItsBaselineAndItsValueAfterWakeAsAtLaunchThenKeepsItsInterval() async {
    let coordinator = coordinator([.cpu]) { _, sensor in sensor.baselineReads = 1 }

    coordinator.start()

    await waitUntil { clock.sleeperCount == 1 }

    clock.advance(by: MetricsCoordinator<TestClock>.baselineSpan)

    await waitUntil { logs[.cpu]!.reads == [0, 0] }
    await run(until: 4, schedules: 1)

    coordinator.powerState.isAsleep = true

    await waitUntil { everyProviderIsClosed }
    await run(until: 304, schedules: 0)

    coordinator.powerState.isAsleep = false

    await waitUntil { clock.sleeperCount == 1 }

    #expect(logs[.cpu]!.reads == [0, 0, 2, 4, 304])
    #expect(coordinator.store[.cpu]?.latest?.state == .unavailable(.noValue(.awaitingBaseline)))

    clock.advance(by: MetricsCoordinator<TestClock>.baselineSpan)

    // the schedule sleeps again only once the sample is in the store, which the sensor's own log cannot tell
    await waitUntil { logs[.cpu]!.reads == [0, 0, 2, 4, 304, 304] && clock.sleeperCount == 1 }

    #expect(coordinator.store[.cpu]?.latest?.value == MetricValue(304, .percent))

    await run(until: 310, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 0, 2, 4, 304, 304, 306, 308, 310])
  }

  @Test func tenSleepWakeCyclesLeaveExactlyOneScheduleForEachEnabledMetric() async {
    let coordinator = coordinator()

    coordinator.disable(.gpu)
    coordinator.start()

    await run(until: 3, schedules: 5)

    for cycle in 1...10 {
      coordinator.powerState.isAsleep = true

      // even cycles wake before the providers have closed, as a sleep that is called off does
      if cycle.isMultiple(of: 2) {
        coordinator.powerState.isAsleep = false
      } else {
        await waitUntil { everyProviderIsClosed }
        await run(until: clock.seconds + cycle, schedules: 0)

        coordinator.powerState.isAsleep = false
      }

      await run(until: clock.seconds + 3, schedules: 5)
    }

    let readsBefore = logs.mapValues(\.reads.count)
    let from = clock.seconds

    await run(until: from + 60, schedules: 5)

    for metric in [Metric.cpu, .temperature, .memoryPressure, .storage, .kern] {
      let reads = logs[metric]!.reads.dropFirst(readsBefore[metric]!)
      let interval = Int(metric.defaultInterval.components.seconds)

      #expect(reads.count == 60 / interval, "\(metric)")
      #expect(zip(reads, reads.dropFirst()).allSatisfy { $1 - $0 == interval }, "\(metric)")
      #expect(logs[metric]!.opens == 11, "\(metric)")
      #expect(logs[metric]!.closes == 10, "\(metric)")
    }

    #expect(logs[.gpu]!.all.isEmpty)
    #expect(logs[.memory]!.all.isEmpty)
    #expect(clock.sleeperCount == 5)
  }

  @Test func changesMadeDuringSleepTouchNoSensorAndTakeEffectAtWake() async {
    let coordinator = coordinator()

    coordinator.start()

    await run(until: 2, schedules: 6)

    coordinator.powerState.isAsleep = true

    await waitUntil { everyProviderIsClosed }

    let eventsAsleep = logs.mapValues(\.all)

    coordinator.disable(.gpu)
    coordinator.setInterval(.seconds(1), for: .cpu)

    coordinator.areDetailsVisible = true

    coordinator.disable(.temperature)
    coordinator.enable(.temperature)
    coordinator.stop()
    coordinator.start()

    await run(until: 20, schedules: 0)

    #expect(logs.mapValues(\.all) == eventsAsleep)

    coordinator.powerState.isAsleep = false

    await run(until: 23, schedules: 6)

    #expect(logs[.cpu]!.reads == [0, 2, 20, 21, 22, 23])
    #expect(logs[.gpu]!.all == eventsAsleep[.gpu])
    #expect(logs[.temperature]!.reads == [0, 20])
    #expect(logs[.memory]!.all == ["open", "read 20"])
  }

  @Test func sleepAndWakeDuringASampleLeaveOneSchedule() async {
    let gate = DispatchSemaphore(value: 0)

    let coordinator = coordinator([.cpu]) { _, sensor in
      sensor.whileReading = [{ gate.wait() }]
    }

    coordinator.start()

    await waitUntil { logs[.cpu]!.reads == [0] }

    coordinator.powerState.isAsleep = true
    coordinator.powerState.isAsleep = false

    gate.signal()

    await waitUntil { clock.sleeperCount == 1 }

    #expect(logs[.cpu]!.all == ["open", "read 0", "close", "open", "read 0"])

    await run(until: 4, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 0, 2, 4])
  }

  @Test func sleepOrWakeAnnouncedTwiceChangesNothingTheSecondTime() async {
    let coordinator = coordinator([.cpu])

    coordinator.start()

    await run(until: 2, schedules: 1)

    coordinator.powerState.isAsleep = true
    coordinator.powerState.isAsleep = true

    await waitUntil { everyProviderIsClosed }
    await run(until: 10, schedules: 0)

    coordinator.powerState.isAsleep = false
    coordinator.powerState.isAsleep = false

    await run(until: 14, schedules: 1)

    #expect(logs[.cpu]!.all == ["open", "read 0", "read 2", "close", "open", "read 10", "read 12", "read 14"])
  }

  @Test func coordinatorStartedWhileTheSystemSleepsSamplesOnlyAfterWake() async {
    let coordinator = coordinator()

    coordinator.powerState.isAsleep = true

    coordinator.start()

    await run(until: 5, schedules: 0)

    #expect(logs.values.allSatisfy { $0.all.isEmpty })

    coordinator.powerState.isAsleep = false

    await run(until: 7, schedules: 6)

    #expect(logs[.cpu]!.reads == [5, 7])
    #expect(logs[.temperature]!.reads == [5])
    #expect(logs[.storage]!.reads == [5])
  }
}
