import Foundation
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "preferences")

/// Keeps the preferences in the user defaults. A setting at its default has no value there, so Restore Defaults
/// leaves nothing behind and a later version's new default applies.
@MainActor
public final class PreferencesStore {
  public private(set) var preferences: Preferences
  var onChange: @MainActor (Preferences) -> Void = { _ in }
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.preferences = Self.load(from: defaults)
  }

  /// Moves intervals and the graph sample count that are out of range to the nearest value in range, writes only
  /// the settings that changed, and does nothing when nothing changed.
  public func update(_ change: (inout Preferences) -> Void) {
    var updated = preferences

    change(&updated)

    updated = updated.normalized()

    guard updated != preferences else { return }

    save(updated, replacing: preferences)

    preferences = updated

    onChange(updated)
  }

  /// Removes every key, also those whose stored value was read as the default because it was invalid or out of range.
  public func restoreDefaults() {
    for key in Key.all {
      defaults.removeObject(forKey: key)
    }

    logger.debug("restored the defaults")

    guard preferences != .standard else { return }

    preferences = .standard

    onChange(preferences)
  }

  private func save(_ new: Preferences, replacing old: Preferences) {
    for monitor in Monitor.allCases {
      save(\.[monitor].isEnabled, of: new, replacing: old, as: Key.enabled(monitor)) { $0 }
      save(\.[monitor].interval, of: new, replacing: old, as: Key.interval(monitor)) { $0 }
    }

    save(\.graphSamples, of: new, replacing: old, as: Key.graphSamples) { $0 }
    save(\.temperatureUnit, of: new, replacing: old, as: Key.temperatureUnit, \.rawValue)
    save(\.lowPowerModeBehavior, of: new, replacing: old, as: Key.lowPowerModeBehavior, \.rawValue)
    save(\.menuBarLayout, of: new, replacing: old, as: Key.menuBarLayout, \.propertyList)
  }

  private func save<Value: Equatable>(
    _ setting: KeyPath<Preferences, Value>,
    of new: Preferences,
    replacing old: Preferences,
    as key: String,
    _ propertyList: (Value) -> Any
  ) {
    let value = new[keyPath: setting]

    guard value != old[keyPath: setting] else { return }

    if value == Preferences.standard[keyPath: setting] {
      defaults.removeObject(forKey: key)
      logger.debug("\(key, privacy: .public) back to its default")
    } else {
      defaults.set(propertyList(value), forKey: key)
      logger.debug("\(key, privacy: .public) set to \(String(describing: value), privacy: .public)")
    }
  }

  private static func load(from defaults: UserDefaults) -> Preferences {
    var preferences = Preferences.standard

    func read<Value>(_ key: String, _ parse: (Any) -> Value?) -> Value? {
      guard let value = defaults.object(forKey: key) else { return nil }

      guard let parsed = parse(value) else {
        logger.error("ignoring the invalid \(key, privacy: .public): \(String(describing: value), privacy: .public)")

        return nil
      }

      return parsed
    }

    for monitor in Monitor.allCases {
      if let isEnabled = read(Key.enabled(monitor), PropertyListValue.boolean) {
        preferences[monitor].isEnabled = isEnabled
      }

      if let interval = read(Key.interval(monitor), { PropertyListValue.number($0).flatMap(monitor.intervals.nearest) })
      {
        preferences[monitor].interval = interval
      }
    }

    if let count = read(
      Key.graphSamples, { PropertyListValue.number($0).flatMap(Preferences.graphSampleCounts.nearest) })
    {
      preferences.graphSamples = count
    }

    if let unit = read(Key.temperatureUnit, { ($0 as? String).flatMap(TemperatureUnit.init) }) {
      preferences.temperatureUnit = unit
    }

    if let behavior = read(Key.lowPowerModeBehavior, { ($0 as? String).flatMap(LowPowerModeBehavior.init) }) {
      preferences.lowPowerModeBehavior = behavior
    }

    if let layout = read(Key.menuBarLayout, MenuBarLayout.init(propertyList:)) {
      preferences.menuBarLayout = layout
    }

    return preferences
  }
}

/// Names the defaults keys, which `defaults write dev.kern.Kern <key> <value>` also sets.
enum Key {
  static let graphSamples = "graphSamples"
  static let temperatureUnit = "temperatureUnit"
  static let lowPowerModeBehavior = "lowPowerModeBehavior"
  static let menuBarLayout = "menuBarLayout"

  static func enabled(_ monitor: Monitor) -> String {
    "\(monitor.rawValue)Enabled"
  }

  static func interval(_ monitor: Monitor) -> String {
    "\(monitor.rawValue)Interval"
  }

  static let all =
    Monitor.allCases.flatMap { [enabled($0), interval($0)] }
    + [graphSamples, temperatureUnit, lowPowerModeBehavior, menuBarLayout]
}

/// A property list written as text, as by `defaults write` without a type or by a launch argument, holds strings
/// where a typed one holds Booleans and numbers.
enum PropertyListValue {
  static func boolean(_ value: Any) -> Bool? {
    switch value {
    case let value as Bool: value
    case let text as String where ["YES", "TRUE", "1"].contains(text.uppercased()): true
    case let text as String where ["NO", "FALSE", "0"].contains(text.uppercased()): false
    default: nil
    }
  }

  static func number(_ value: Any) -> Double? {
    switch value {
    case let number as NSNumber where CFGetTypeID(number) == CFNumberGetTypeID(): number.doubleValue
    case let text as String: Double(text.trimmingCharacters(in: .whitespaces))
    default: nil
    }
  }
}
