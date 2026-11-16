import Foundation
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "menu bar")

enum Widget: String, CaseIterable, Sendable {
  case temperature
  case cpu
  case gpu
  case memory

  var metric: Metric {
    switch self {
    case .temperature: .temperature
    case .cpu: .cpu
    case .gpu: .gpu
    case .memory: .memoryPressure
    }
  }

  var label: String? {
    switch self {
    case .temperature: nil
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .memory: "RAM"
    }
  }
}

struct MenuBarLayout: Equatable, Sendable {
  let widgets: [Widget]
  let showsLabels: Bool

  static let standard = MenuBarLayout(widgets: [.temperature, .cpu, .gpu, .memory], showsLabels: true)!

  init?(widgets: [Widget], showsLabels: Bool) {
    guard !widgets.isEmpty, Set(widgets).count == widgets.count else { return nil }

    self.widgets = widgets
    self.showsLabels = showsLabels
  }
}

extension MenuBarLayout {
  static let defaultsKey = "menuBarLayout"

  static func configured(in defaults: UserDefaults) -> MenuBarLayout {
    guard let value = defaults.object(forKey: defaultsKey) else { return .standard }

    guard let layout = MenuBarLayout(propertyList: value) else {
      logger.error(
        "ignoring the invalid \(defaultsKey, privacy: .public): \(String(describing: value), privacy: .public)")

      return .standard
    }

    return layout
  }

  init?(propertyList: Any) {
    guard let dictionary = propertyList as? [String: Any],
      let names = dictionary["widgets"] as? [String],
      let showsLabels = dictionary["showsLabels"].flatMap(Self.boolean)
    else {
      return nil
    }

    let widgets = names.compactMap(Widget.init(rawValue:))

    guard widgets.count == names.count else { return nil }

    self.init(widgets: widgets, showsLabels: showsLabels)
  }

  /// A property list written as text, as by `defaults write`, has no Booleans, only strings.
  private static func boolean(_ value: Any) -> Bool? {
    switch value {
    case let value as Bool: value
    case let text as String where ["YES", "TRUE", "1"].contains(text.uppercased()): true
    case let text as String where ["NO", "FALSE", "0"].contains(text.uppercased()): false
    default: nil
    }
  }
}
