import Testing

@testable import KernCore

extension MetricsCoordinatorTests {
  typealias Coordinator = MetricsCoordinator<TestClock>

  var readFailure: SensorError { SensorError("read failed") }

  @Test(arguments: [0.25, 1, 2, 5, 7, 10, 20, 45, 60, 90])
  func retryDelayDoublesFromOneIntervalAndStopsBeforeItWouldPassTheMaximum(seconds: Double) {
    let interval = Duration.seconds(seconds)
    let delays = (0...40).map { Coordinator.retryDelay(after: $0, every: interval) }

    #expect(delays[0] == interval)
    #expect(delays[1] == interval)
    #expect(zip(delays.dropFirst(), delays.dropFirst(2)).allSatisfy { $1 == $0 || $1 == $0 * 2 })
    #expect(delays.allSatisfy { $0 >= interval })
    #expect(delays.allSatisfy { $0 <= max(Coordinator.maximumRetryDelay, interval) })
    #expect(delays[40] * 2 > Coordinator.maximumRetryDelay)
    #expect(delays[39] == delays[40])
  }

  @Test func maximumRetryDelayIsOneMinute() {
    #expect(Coordinator.maximumRetryDelay == .seconds(60))
    #expect(Coordinator.retryDelay(after: 40, every: .seconds(2)) == .seconds(32))
    #expect(Coordinator.retryDelay(after: 40, every: .seconds(5)) == .seconds(40))
    #expect(Coordinator.retryDelay(after: 40, every: .seconds(10)) == .seconds(40))
    #expect(Coordinator.retryDelay(after: 40, every: .seconds(20)) == .seconds(40))
    #expect(Coordinator.retryDelay(after: 40, every: .seconds(90)) == .seconds(90))
  }

  @Test func failingSensorIsRetriedAfterOneTwoFourIntervalsUntilTheDelayStopsGrowing() async {
    let coordinator = coordinator([.cpu, .temperature, .memoryPressure]) { metric, sensor in
      sensor.failure = metric == .memoryPressure ? nil : readFailure
    }

    coordinator.start()

    await run(until: 200, schedules: 3)

    #expect(logs[.cpu]!.reads == [0, 2, 6, 14, 30, 62, 94, 126, 158, 190])
    #expect(logs[.temperature]!.reads == [0, 10, 30, 70, 110, 150, 190])
    #expect(logs[.memoryPressure]!.reads == Array(stride(from: 0, through: 200, by: 5)))
    #expect(logs[.cpu]!.opens == 1)
    #expect(coordinator.store[.cpu]?.latest?.state == .unavailable(.sensorFailed(readFailure)))
    #expect(coordinator.store[.cpu]?.history?.count == 10)
  }

  @Test func sensorThatWorksAgainGivesReadingsAtTheNextRetryAndThenKeepsItsInterval() async {
    let coordinator = coordinator([.cpu]) { _, sensor in
      sensor.failure = readFailure
      sensor.recoversAt = 20
    }

    coordinator.start()

    await run(until: 29, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 6, 14])
    #expect(coordinator.store[.cpu]?.lastSuccessful == nil)

    await run(until: 36, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 6, 14, 30, 32, 34, 36])
    #expect(coordinator.store[.cpu]?.latest?.value == MetricValue(36, .percent))
    #expect(coordinator.store[.cpu]?.history?.map(\.value?.value) == [nil, nil, nil, nil, 30, 32, 34, 36])
    #expect(logs[.cpu]!.opens == 1)
  }

  @Test func sensorThatCannotOpenIsOpenedAgainAtEachRetryUntilItOpens() async {
    let coordinator = coordinator([.temperature]) { _, sensor in
      sensor.failsToOpen = true
      sensor.recoversAt = 25
    }

    coordinator.start()

    await run(until: 29, schedules: 1)

    #expect(logs[.temperature]!.all == ["open", "open"])
    #expect(coordinator.store[.temperature]?.history?.count == 2)
    #expect(coordinator.store[.temperature]?.latest?.state == .unavailable(.sensorFailed(SensorError("cannot open"))))

    await run(until: 50, schedules: 1)

    #expect(logs[.temperature]!.all == ["open", "open", "open", "read 30", "read 40", "read 50"])
    #expect(coordinator.store[.temperature]?.latest?.value == MetricValue(50, .percent))
  }

  @Test func changeOfIntervalKeepsTheCountOfFailuresAndRetriesAtTheNewInterval() async {
    let coordinator = coordinator([.cpu]) { _, sensor in sensor.failure = readFailure }

    coordinator.start()

    await run(until: 15, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 6, 14])

    coordinator.powerState.isLowPowerModeEnabled = true

    await run(until: 94, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 6, 14, 54, 94])

    coordinator.powerState.isLowPowerModeEnabled = false

    await run(until: 160, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 6, 14, 54, 94, 126, 158])
  }

  @Test func sensorThatCannotOpenIsRetriedAfterAChangeOfIntervalToo() async {
    let coordinator = coordinator([.cpu]) { _, sensor in
      sensor.failsToOpen = true
      sensor.recoversAt = 3
    }

    coordinator.start()

    await run(until: 1, schedules: 1)

    coordinator.setInterval(.seconds(4), for: .cpu)

    await run(until: 8, schedules: 1)

    #expect(logs[.cpu]!.all == ["open", "open", "read 4", "read 8"])
  }

  @Test func wakeStartsTheRetriesOverWithAFreshAttempt() async {
    let coordinator = coordinator([.cpu]) { _, sensor in sensor.failure = readFailure }

    coordinator.start()

    await run(until: 14, schedules: 1)

    coordinator.powerState.isAsleep = true

    await waitUntil { everyProviderIsClosed }
    await run(until: 20, schedules: 0)

    coordinator.powerState.isAsleep = false

    await run(until: 27, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 6, 14, 20, 22, 26])
    #expect(logs[.cpu]!.opens == 2)
  }

  @Test func enablingAFailingMetricAgainStartsTheRetriesOverOneIntervalAfterItsLastAttempt() async {
    let coordinator = coordinator([.cpu]) { _, sensor in sensor.failure = readFailure }

    coordinator.start()

    await run(until: 14, schedules: 1)

    coordinator.disable(.cpu)
    coordinator.enable(.cpu)

    await run(until: 23, schedules: 1)

    #expect(logs[.cpu]!.reads == [0, 2, 6, 14, 16, 18, 22])
  }
}
