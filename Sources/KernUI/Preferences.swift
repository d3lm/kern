import KernCore

/// Is a metric as Settings turns it on and off and sets its interval. Memory covers used memory and memory pressure.
public enum Monitor: String, CaseIterable, Sendable {
  case cpu
  case gpu
  case temperature
  case memory

  /// Returns nil for storage and Kern's own usage, which Settings does not turn on and off.
  init?(_ metric: Metric) {
    switch metric {
    case .cpu: self = .cpu
    case .gpu: self = .gpu
    case .temperature: self = .temperature
    case .memory, .memoryPressure: self = .memory
    case .storage, .kern: return nil
    }
  }

  var metrics: [Metric] {
    switch self {
    case .cpu: [.cpu]
    case .gpu: [.gpu]
    case .temperature: [.temperature]
    case .memory: [.memory, .memoryPressure]
    }
  }

  public var intervals: ClosedRange<Int> {
    switch self {
    case .cpu, .gpu: 2...60
    case .temperature: 5...300
    case .memory: 2...300
    }
  }

  var defaultInterval: Int {
    Int(metrics[0].defaultInterval.components.seconds)
  }
}

public struct MonitorSettings: Equatable, Sendable {
  public var isEnabled: Bool
  /// Holds the sampling interval in whole seconds.
  public var interval: Int
}

public enum TemperatureUnit: String, CaseIterable, Sendable {
  case celsius
  case fahrenheit

  func value(ofCelsius celsius: Double) -> Double {
    switch self {
    case .celsius: celsius
    case .fahrenheit: celsius * 9 / 5 + 32
    }
  }

  var spokenName: String {
    switch self {
    case .celsius: "degrees Celsius"
    case .fahrenheit: "degrees Fahrenheit"
    }
  }
}

/// Holds every setting of the Settings window except launch at login, which macOS keeps.
public struct Preferences: Equatable, Sendable {
  public var cpu: MonitorSettings
  public var gpu: MonitorSettings
  public var temperature: MonitorSettings
  public var memory: MonitorSettings
  public var graphSamples: Int
  public var temperatureUnit: TemperatureUnit
  public var lowPowerModeBehavior: LowPowerModeBehavior
  public var menuBarLayout: MenuBarLayout

  public static let standard = Preferences(
    cpu: MonitorSettings(isEnabled: true, interval: Monitor.cpu.defaultInterval),
    gpu: MonitorSettings(isEnabled: true, interval: Monitor.gpu.defaultInterval),
    temperature: MonitorSettings(isEnabled: true, interval: Monitor.temperature.defaultInterval),
    memory: MonitorSettings(isEnabled: true, interval: Monitor.memory.defaultInterval),
    graphSamples: MetricsStore.defaultHistoryCapacity,
    temperatureUnit: .celsius,
    lowPowerModeBehavior: .standard,
    menuBarLayout: .standard
  )

  public static let graphSampleCounts = 20...240

  public subscript(monitor: Monitor) -> MonitorSettings {
    get {
      switch monitor {
      case .cpu: cpu
      case .gpu: gpu
      case .temperature: temperature
      case .memory: memory
      }
    }
    set {
      switch monitor {
      case .cpu: cpu = newValue
      case .gpu: gpu = newValue
      case .temperature: temperature = newValue
      case .memory: memory = newValue
      }
    }
  }

  var shownMenuBarLayout: MenuBarLayout {
    var layout = menuBarLayout

    for widget in Widget.allCases {
      if let monitor = Monitor(widget.metric), !self[monitor].isEnabled {
        layout.setShown(false, widget)
      }
    }

    return layout
  }

  func normalized() -> Preferences {
    var preferences = self

    for monitor in Monitor.allCases {
      preferences[monitor].interval = monitor.intervals.clamp(preferences[monitor].interval)
    }

    preferences.graphSamples = Self.graphSampleCounts.clamp(graphSamples)

    return preferences
  }
}

extension ClosedRange<Int> {
  func clamp(_ value: Int) -> Int {
    Swift.min(Swift.max(value, lowerBound), upperBound)
  }

  func nearest(to value: Double) -> Int? {
    guard !value.isNaN else { return nil }

    return Int(Swift.min(Swift.max(value.rounded(), Double(lowerBound)), Double(upperBound)))
  }
}

extension MetricsCoordinator {
  /// Samples a metric that Settings does not turn on and off while its widget is in the menu bar, and also while
  /// Settings is open, because its Menu Bar tab shows every widget with its reading.
  func apply(_ preferences: Preferences, isSettingsOpen: Bool = false) {
    for monitor in Monitor.allCases {
      let settings = preferences[monitor]

      for metric in monitor.metrics {
        setInterval(.seconds(settings.interval), for: metric)

        if settings.isEnabled {
          enable(metric)
        } else {
          disable(metric)
        }
      }
    }

    for widget in Widget.allCases where Monitor(widget.metric) == nil {
      if isSettingsOpen || preferences.menuBarLayout.isShown(widget) {
        enable(widget.metric)
      } else {
        disable(widget.metric)
      }
    }

    setHistoryCapacity(preferences.graphSamples)

    lowPowerModeBehavior = preferences.lowPowerModeBehavior
  }
}
