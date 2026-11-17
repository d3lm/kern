public struct PowerState: Equatable, Sendable {
  /// Holds from the system's announcement that it will sleep until its announcement that it woke.
  public var isAsleep: Bool
  public var isLowPowerModeEnabled: Bool

  public init(isAsleep: Bool = false, isLowPowerModeEnabled: Bool = false) {
    self.isAsleep = isAsleep
    self.isLowPowerModeEnabled = isLowPowerModeEnabled
  }
}

public enum LowPowerModeBehavior: String, Sendable {
  /// Samples at each metric's `lowPowerInterval` while Low Power Mode is on.
  case adaptive
  /// Keeps the configured intervals while Low Power Mode is on.
  case override

  public static let standard = LowPowerModeBehavior.adaptive
}
