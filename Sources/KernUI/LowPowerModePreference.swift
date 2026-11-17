import Foundation
import KernCore
import os

private let logger = Logger(subsystem: "Kern", category: "preferences")

extension LowPowerModeBehavior {
  static let defaultsKey = "lowPowerModeBehavior"

  static func configured(in defaults: UserDefaults) -> LowPowerModeBehavior {
    guard let value = defaults.object(forKey: defaultsKey) else { return .standard }

    guard let name = value as? String, let behavior = LowPowerModeBehavior(rawValue: name) else {
      logger.error(
        "ignoring the invalid \(defaultsKey, privacy: .public): \(String(describing: value), privacy: .public)")

      return .standard
    }

    return behavior
  }
}
