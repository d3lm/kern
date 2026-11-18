import AppKit
import Testing

@testable import KernCore
@testable import KernUI

@MainActor
struct PowerStateObserverTests {
  final class Reports {
    var all: [PowerState] = []
    var offTheMainThread = 0
  }

  final class LowPowerMode {
    var isEnabled = false
  }

  /// A notification center has no list of its observers to read, so this one counts the removals.
  final class CountingCenter: NotificationCenter, @unchecked Sendable {
    nonisolated(unsafe) var removals = 0

    override func removeObserver(_ observer: Any) {
      removals += 1

      super.removeObserver(observer)
    }
  }

  let workspace = NotificationCenter()
  let process = NotificationCenter()
  let reports = Reports()
  let lowPowerMode = LowPowerMode()

  func observer(workspace: NotificationCenter? = nil, process: NotificationCenter? = nil) -> PowerStateObserver {
    PowerStateObserver(
      workspace: workspace ?? self.workspace,
      process: process ?? self.process,
      isLowPowerModeEnabled: { [lowPowerMode] in lowPowerMode.isEnabled },
      report: { [reports] state in
        reports.all.append(state)

        if pthread_main_np() == 0 { reports.offTheMainThread += 1 }
      }
    )
  }

  let awake = PowerState(isAsleep: false, isLowPowerModeEnabled: false)
  let asleep = PowerState(isAsleep: true, isLowPowerModeEnabled: false)
  let lowPower = PowerState(isAsleep: false, isLowPowerModeEnabled: true)

  @Test func reportsTheStateOnceWhenCreated() {
    lowPowerMode.isEnabled = true

    let observer = observer()

    #expect(reports.all == [lowPower])

    withExtendedLifetime(observer) {}
  }

  @Test func sleepAndWakeAreReportedBeforeTheirAnnouncementsReturn() {
    let observer = observer()

    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)

    #expect(reports.all == [awake, asleep])

    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

    #expect(reports.all == [awake, asleep, awake])

    withExtendedLifetime(observer) {}
  }

  @Test func announcementThatChangesNothingIsNotReported() {
    let observer = observer()

    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    process.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

    #expect(reports.all == [awake, asleep, awake])

    withExtendedLifetime(observer) {}
  }

  @Test func lowPowerModeIsReadWhenItsChangeIsAnnounced() {
    let observer = observer()

    lowPowerMode.isEnabled = true

    #expect(reports.all == [awake])

    process.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

    #expect(reports.all == [awake, lowPower])

    lowPowerMode.isEnabled = false

    process.post(name: .NSProcessInfoPowerStateDidChange, object: nil)

    #expect(reports.all == [awake, lowPower, awake])

    withExtendedLifetime(observer) {}
  }

  @Test func lowPowerModeKeepsItsStateThroughSleepAndWake() {
    let observer = observer()

    lowPowerMode.isEnabled = true

    process.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
    workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

    #expect(reports.all == [awake, lowPower, PowerState(isAsleep: true, isLowPowerModeEnabled: true), lowPower])

    withExtendedLifetime(observer) {}
  }

  @Test func changeAnnouncedOffTheMainThreadIsReportedOnIt() async {
    let observer = observer()

    lowPowerMode.isEnabled = true

    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { [process] in
        process.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        continuation.resume()
      }
    }

    #expect(reports.all == [awake, lowPower])
    #expect(reports.offTheMainThread == 0)

    withExtendedLifetime(observer) {}
  }

  @Test func releasedObserverIsRemovedFromItsCentersAndReportsNothingMore() {
    let workspace = CountingCenter()
    let process = CountingCenter()

    var observer: PowerStateObserver? = observer(workspace: workspace, process: process)

    #expect(workspace.removals == 0)

    weak var released = observer

    observer = nil

    #expect(released == nil)
    #expect(workspace.removals == 2)
    #expect(process.removals == 1)

    workspace.post(name: NSWorkspace.willSleepNotification, object: nil)

    #expect(reports.all == [awake])
  }
}

extension AppEvents {
  /// Posts to the app's real workspace center, so it runs with the tests that send events to the whole app.
  @MainActor
  struct PowerAnnouncementTests {
    @Test func observerMadeWithoutCentersHearsTheWorkspacesAnnouncements() {
      let reports = PowerStateObserverTests.Reports()
      let observer = PowerStateObserver { reports.all.append($0) }
      let workspace = NSWorkspace.shared.notificationCenter
      let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

      workspace.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
      workspace.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

      #expect(
        reports.all == [
          PowerState(isAsleep: false, isLowPowerModeEnabled: lowPower),
          PowerState(isAsleep: true, isLowPowerModeEnabled: lowPower),
          PowerState(isAsleep: false, isLowPowerModeEnabled: lowPower),
        ])

      withExtendedLifetime(observer) {}
    }

    @Test func announcedSleepsAndWakesReachTheCoordinatorAndReopenEverySensor() async {
      let workspace = NotificationCenter()
      let sampled = [Metric.cpu, .gpu, .temperature, .memoryPressure]
      let calls = Dictionary(uniqueKeysWithValues: sampled.map { ($0, SensorCalls()) })

      let coordinator = MetricsCoordinator(
        providers: Dictionary(
          uniqueKeysWithValues: sampled.map { ($0, MetricProvider(sensor: RecordingSensor(calls: calls[$0]!))) }))

      let observer = PowerStateObserver(workspace: workspace, process: NotificationCenter()) {
        coordinator.powerState = $0
      }

      func events(_ event: String) -> [Int] {
        sampled.map { metric in calls[metric]!.all.count { $0 == event } }
      }

      coordinator.start()

      await waitUntil { events("read").allSatisfy { $0 > 0 } }

      for cycle in 1...10 {
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)

        await waitUntil { events("close") == Array(repeating: cycle, count: 4) }

        let readsBeforeTheWake = events("read")

        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

        await waitUntil { zip(events("read"), readsBeforeTheWake).allSatisfy { $0 > $1 } }

        #expect(events("open") == Array(repeating: cycle + 1, count: 4))
      }

      for metric in sampled {
        let openings = calls[metric]!.all.split(separator: "close", omittingEmptySubsequences: false)

        #expect(openings.count == 11, "\(metric)")

        for opening in openings {
          #expect(opening.first == "open" && opening.count > 1, "\(metric)")
          #expect(opening.dropFirst().allSatisfy { $0 == "read" }, "\(metric)")
        }
      }

      withExtendedLifetime(observer) {}
    }
  }
}
