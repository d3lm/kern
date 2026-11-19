import AppKit
import KernCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  public let preferences: PreferencesStore
  private lazy var loginItem = LoginItemManager()
  private var coordinator: MetricsCoordinator<ContinuousClock>?
  private var statusItem: StatusItemController?
  private var details: DetailPopover?
  private var powerState: PowerStateObserver?
  private var settings: SettingsWindowController?

  public override init() {
    preferences = PreferencesStore()

    super.init()
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    let (chip, providers) = Self.providers()
    let coordinator = MetricsCoordinator(providers: providers)
    let current = preferences.preferences
    let openSettings: @MainActor () -> Void = { [weak self] in self?.showSettings() }

    coordinator.apply(current)

    powerState = PowerStateObserver { coordinator.powerState = $0 }

    let details = DetailPopover(
      coordinator: coordinator, chip: chip, temperatureUnit: current.temperatureUnit, openSettings: openSettings)

    statusItem = StatusItemController(
      store: coordinator.store,
      layout: current.shownMenuBarLayout,
      temperatureUnit: current.temperatureUnit,
      details: details,
      openSettings: openSettings
    )

    preferences.onChange = { [weak self] in self?.apply($0) }

    coordinator.start()

    self.details = details
    self.coordinator = coordinator

    #if DEBUG
      if let delay = Self.debugOptions.settingsDelay {
        Task { [weak self] in
          try? await Task.sleep(for: delay)
          self?.showSettings()
        }
      }
    #endif
  }

  public func applicationWillTerminate(_ notification: Notification) {
    settings?.window.close()
  }

  func showSettings() {
    guard let coordinator else { return }

    let settings =
      settings
      ?? SettingsWindowController(preferences: preferences, loginItem: loginItem, store: coordinator.store) {
        [weak self] in
        self?.settings = nil

        self?.applySampling()
      }

    self.settings = settings

    applySampling()
    settings.show()
  }

  private func applySampling() {
    coordinator?.apply(preferences.preferences, isSettingsOpen: settings != nil)
  }

  private func apply(_ preferences: Preferences) {
    coordinator?.apply(preferences, isSettingsOpen: settings != nil)
    statusItem?.show(layout: preferences.shownMenuBarLayout, temperatureUnit: preferences.temperatureUnit)

    details?.temperatureUnit = preferences.temperatureUnit

    settings?.show(preferences)
  }

  #if DEBUG
    private static let debugOptions: DebugLaunchOptions = {
      do {
        return try DebugLaunchOptions(arguments: CommandLine.arguments)
      } catch {
        fatalError("invalid launch argument: \(error)")
      }
    }()
  #endif

  private static func providers() -> (chip: ChipIdentity, providers: [Metric: MetricProvider]) {
    #if DEBUG
      let launch = ContinuousClock.now
      let options = debugOptions
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
      .storage: StorageSensor(),
      .kern: ProcessUsageSensor(),
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
