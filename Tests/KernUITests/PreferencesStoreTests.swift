import Foundation
import KernCore
import Testing

@testable import KernUI

@MainActor
struct PreferencesStoreTests {
  let defaults = TestDefaults()

  func store() -> PreferencesStore {
    PreferencesStore(defaults: defaults.defaults)
  }

  @Test func everySettingStartsAtItsDefault() {
    let preferences = store().preferences

    for monitor in Monitor.allCases {
      #expect(preferences[monitor].isEnabled, "\(monitor)")
    }

    #expect(preferences.cpu.interval == 2)
    #expect(preferences.gpu.interval == 2)
    #expect(preferences.temperature.interval == 10)
    #expect(preferences.memory.interval == 6)
    #expect(preferences.graphSamples == 60)
    #expect(preferences.temperatureUnit == .celsius)
    #expect(preferences.lowPowerModeBehavior == .adaptive)
    #expect(preferences.menuBarLayout == .standard)
    #expect(preferences == .standard)
  }

  @Test func changedSettingsAreReadBackByTheNextLaunch() {
    let first = store()

    first.update { preferences in
      preferences.cpu = MonitorSettings(isEnabled: false, interval: 7)
      preferences.memory.interval = 30
      preferences.graphSamples = 120
      preferences.temperatureUnit = .fahrenheit
      preferences.lowPowerModeBehavior = .override

      preferences.menuBarLayout.setShown(false, .gpu)
      preferences.menuBarLayout.place(.memory, before: .temperature)
      preferences.menuBarLayout.setShowsLabel(false, .gpu)
    }

    #expect(store().preferences == first.preferences)
    #expect(first.preferences != .standard)
  }

  @Test func onlyTheChangedSettingIsWritten() {
    let store = store()

    store.update { $0.gpu.interval = 4 }

    #expect(defaults.keys == ["gpuInterval"])
    #expect(defaults.defaults.object(forKey: "gpuInterval") as? Int == 4)
  }

  @Test func updateThatChangesNothingWritesNothingAndTellsNoOne() {
    let store = store()

    var changes = 0

    store.onChange = { _ in changes += 1 }

    store.update { $0.temperature.interval = 10 }
    store.update { $0.temperature.interval = 0 }
    store.update { $0.temperature.interval = 1 }
    store.update { $0.temperature.interval = -5 }

    #expect(changes == 1)
    #expect(defaults.keys == ["temperatureInterval"])
  }

  @Test func settingBackAtItsDefaultLeavesNoValue() {
    let store = store()

    store.update { $0.temperatureUnit = .fahrenheit }
    store.update { $0.temperatureUnit = .celsius }

    #expect(defaults.keys.isEmpty)
  }

  @Test func restoreDefaultsReturnsEverySettingToItsDefaultAndLeavesNoValue() {
    let store = store()

    store.update { preferences in
      for monitor in Monitor.allCases {
        preferences[monitor] = MonitorSettings(isEnabled: false, interval: monitor.intervals.upperBound)
      }

      preferences.graphSamples = 20
      preferences.temperatureUnit = .fahrenheit
      preferences.lowPowerModeBehavior = .override
      preferences.menuBarLayout = MenuBarLayout(widgets: [.memory], showsLabels: false)!
    }

    #expect(defaults.keys.count == 12)

    store.restoreDefaults()

    #expect(store.preferences == .standard)
    #expect(defaults.keys.isEmpty)
    #expect(self.store().preferences == .standard)
  }

  @Test func restoreDefaultsAlsoRemovesStoredValuesThatWereReadAsTheDefault() throws {
    defaults.defaults.set("1", forKey: "cpuInterval")
    defaults.defaults.set(0, forKey: "gpuInterval")
    defaults.defaults.set("kelvin", forKey: "temperatureUnit")
    defaults.defaults.set(MenuBarLayout.standard.propertyList, forKey: "menuBarLayout")

    let store = store()

    var changes = 0

    store.onChange = { _ in changes += 1 }

    #expect(store.preferences == .standard)

    store.restoreDefaults()

    #expect(defaults.keys.isEmpty)
    #expect(changes == 0)
  }

  @Test(arguments: [
    (Monitor.cpu, 0, 2), (.cpu, 1, 2), (.cpu, -1, 2), (.cpu, 61, 60), (.cpu, Int.max, 60), (.cpu, Int.min, 2),
    (.gpu, 1, 2), (.temperature, 1, 5), (.temperature, 301, 300), (.memory, 1, 2), (.memory, 100_000, 300),
  ])
  func intervalOutsideItsRangeMovesToTheNearestEnd(monitor: Monitor, interval: Int, expected: Int) {
    let store = store()

    store.update { $0[monitor].interval = interval }

    #expect(store.preferences[monitor].interval == expected)
  }

  @Test(arguments: [(0, 20), (19, 20), (241, 240), (-60, 20)])
  func graphSampleCountOutsideItsRangeMovesToTheNearestEnd(count: Int, expected: Int) {
    let store = store()

    store.update { $0.graphSamples = count }

    #expect(store.preferences.graphSamples == expected)
  }

  @Test func valuesWrittenAsTextAreRead() throws {
    for (key, text) in [
      ("cpuEnabled", "NO"), ("cpuInterval", "3"), ("temperatureInterval", "12.4"), ("graphSamples", " 90 "),
      ("temperatureUnit", "fahrenheit"), ("lowPowerModeBehavior", "override"),
      ("menuBarLayout", "{ widgets = (gpu, cpu); showsLabels = NO; }"),
    ] {
      defaults.defaults.set(key == "menuBarLayout" ? try propertyList(text) : text, forKey: key)
    }

    let preferences = store().preferences

    #expect(preferences.cpu == MonitorSettings(isEnabled: false, interval: 3))
    #expect(preferences.temperature.interval == 12)
    #expect(preferences.graphSamples == 90)
    #expect(preferences.temperatureUnit == .fahrenheit)
    #expect(preferences.lowPowerModeBehavior == .override)
    #expect(preferences.menuBarLayout.widgets == [.gpu, .cpu])
  }

  @Test(arguments: [
    ("cpuInterval", "0", 2), ("cpuInterval", "1", 2), ("cpuInterval", "-1", 2), ("cpuInterval", "1e300", 60),
    ("cpuInterval", "999999", 60),
    ("temperatureInterval", "2", 5), ("memoryInterval", "1e400", 300),
  ])
  func storedIntervalOutsideItsRangeMovesToTheNearestEnd(key: String, text: String, expected: Int) {
    defaults.defaults.set(text, forKey: key)

    let preferences = store().preferences
    let monitor = Monitor.allCases.first { key.hasPrefix($0.rawValue) }!

    #expect(preferences[monitor].interval == expected)
  }

  @Test(arguments: [
    ("cpuInterval", "two"), ("cpuInterval", "nan"), ("cpuInterval", ""), ("cpuEnabled", "maybe"),
    ("temperatureUnit", "kelvin"), ("lowPowerModeBehavior", "Override"), ("menuBarLayout", "temperature, cpu"),
  ])
  func invalidTextIsIgnoredForTheDefault(key: String, text: String) {
    defaults.defaults.set(text, forKey: key)

    #expect(store().preferences == .standard)
  }

  @Test func valueOfTheWrongTypeIsIgnoredForTheDefault() {
    let values: [(String, Any)] = [
      ("cpuInterval", true), ("cpuEnabled", 2), ("graphSamples", ["60"]), ("lowPowerModeBehavior", 1),
      ("menuBarLayout", ["widgets": "cpu", "showsLabels": true]),
    ]

    for (key, value) in values {
      let defaults = TestDefaults()

      defaults.defaults.set(value, forKey: key)

      #expect(PreferencesStore(defaults: defaults.defaults).preferences == .standard, "\(key)")
    }
  }

  @Test func storedLayoutWithoutWidgetsShowsNone() throws {
    defaults.defaults.set(try propertyList("{ widgets = (); showsLabels = YES; }"), forKey: "menuBarLayout")

    #expect(store().preferences.menuBarLayout.widgets == [])
  }

  @Test func changeIsReportedWithTheNewPreferences() {
    let store = store()

    var reported: [Preferences] = []

    store.onChange = { reported.append($0) }

    store.update { $0.gpu.isEnabled = false }

    #expect(reported == [store.preferences])
    #expect(reported.first?.gpu.isEnabled == false)
  }

  @Test func turnedOffMetricHidesItsWidgetWithoutChangingTheLayout() {
    var preferences = Preferences.standard

    preferences.gpu.isEnabled = false
    preferences.memory.isEnabled = false

    #expect(preferences.shownMenuBarLayout.widgets == [.temperature, .cpu])
    #expect(preferences.menuBarLayout == .standard)
  }
}
