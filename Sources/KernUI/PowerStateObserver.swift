import AppKit
import KernCore

/// Reports the system's power state once when it is created, and again after each change.
@MainActor
final class PowerStateObserver {
  private let isLowPowerModeEnabled: @MainActor () -> Bool
  private let report: @MainActor (PowerState) -> Void
  nonisolated(unsafe) private var observations: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

  private var state: PowerState {
    didSet {
      if state != oldValue { report(state) }
    }
  }

  init(
    workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
    process: NotificationCenter = .default,
    isLowPowerModeEnabled: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
    report: @escaping @MainActor (PowerState) -> Void
  ) {
    self.isLowPowerModeEnabled = isLowPowerModeEnabled
    self.report = report
    self.state = PowerState(isAsleep: false, isLowPowerModeEnabled: isLowPowerModeEnabled())

    observe(NSWorkspace.willSleepNotification, in: workspace) { $0.state.isAsleep = true }
    observe(NSWorkspace.didWakeNotification, in: workspace) { $0.state.isAsleep = false }

    observe(.NSProcessInfoPowerStateDidChange, in: process) {
      $0.state.isLowPowerModeEnabled = $0.isLowPowerModeEnabled()
    }

    report(state)
  }

  deinit {
    for observation in observations {
      observation.center.removeObserver(observation.token)
    }
  }

  /// With the main queue, the handler runs on the main thread before the post returns, whichever thread posts.
  /// The sleep announcement must be handled before its post returns, because the system sleeps once its observers
  /// have returned, and Low Power Mode changes are posted off the main thread.
  private func observe(
    _ name: Notification.Name,
    in center: NotificationCenter,
    update: @escaping @MainActor (PowerStateObserver) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        if let self { update(self) }
      }
    }

    observations.append((center, token))
  }
}
