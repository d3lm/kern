import AppKit
import KernCore

/// Builds Kern at launch: a provider for each metric, the coordinator that samples them, and the menu-bar
/// item that shows the samples.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  private var coordinator: MetricsCoordinator<ContinuousClock>?
  private var statusItem: StatusItemController?

  public func applicationDidFinishLaunching(_ notification: Notification) {
    let coordinator = MetricsCoordinator(providers: Self.providers())

    statusItem = StatusItemController(store: coordinator.store, layout: .configured(in: .standard))
    coordinator.start()

    self.coordinator = coordinator
  }

  private static func providers() -> [Metric: MetricProvider] {
    #if DEBUG
      let launch = ContinuousClock.now
      let options: DebugLaunchOptions

      do {
        options = try DebugLaunchOptions(arguments: CommandLine.arguments)
      } catch {
        fatalError("invalid launch argument: \(error)")
      }

      let chip = options.chip ?? ChipIdentifier.current
    #else
      let chip = ChipIdentifier.current
    #endif

    let sensors: [Metric: any MetricSensor] = [
      .cpu: CPUSensor(),
      .gpu: GPUSensor(),
      .temperature: TemperatureSensor(chip: chip),
      .memory: MemorySensor(),
    ]

    return Dictionary(
      uniqueKeysWithValues: sensors.map { metric, sensor in
        #if DEBUG
          let sensor = options.sensor(sensor, for: metric, launchedAt: launch)
        #endif

        return (metric, MetricProvider(sensor: sensor))
      })
  }
}
