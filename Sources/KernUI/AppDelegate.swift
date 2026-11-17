import AppKit
import KernCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  private var coordinator: MetricsCoordinator<ContinuousClock>?
  private var statusItem: StatusItemController?
  private var powerState: PowerStateObserver?

  public func applicationDidFinishLaunching(_ notification: Notification) {
    let (chip, providers) = Self.providers()
    let coordinator = MetricsCoordinator(providers: providers)

    coordinator.lowPowerModeBehavior = .configured(in: .standard)
    powerState = PowerStateObserver { coordinator.powerState = $0 }

    statusItem = StatusItemController(
      store: coordinator.store,
      layout: .configured(in: .standard),
      details: DetailPopover(coordinator: coordinator, chip: chip)
    )

    coordinator.start()

    self.coordinator = coordinator
  }

  private static func providers() -> (chip: ChipIdentity, providers: [Metric: MetricProvider]) {
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
      .memoryPressure: MemoryPressureSensor(),
    ]

    let providers = Dictionary(
      uniqueKeysWithValues: sensors.map { metric, sensor in
        #if DEBUG
          let sensor = options.sensor(sensor, for: metric, launchedAt: launch)
        #endif

        return (metric, MetricProvider(sensor: sensor))
      })

    return (chip, providers)
  }
}
