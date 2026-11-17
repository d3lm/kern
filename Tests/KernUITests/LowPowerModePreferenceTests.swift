import Foundation
import KernCore
import Testing

@testable import KernUI

struct LowPowerModePreferenceTests {
  let defaults = MenuBarLayoutTests.Defaults()

  @Test func missingValueGivesAdaptive() {
    #expect(LowPowerModeBehavior.configured(in: defaults.defaults) == .adaptive)
  }

  @Test(arguments: [("adaptive", LowPowerModeBehavior.adaptive), ("override", .override)])
  func configuredValueIsRead(value: String, behavior: LowPowerModeBehavior) {
    defaults.defaults.set(value, forKey: "lowPowerModeBehavior")

    #expect(LowPowerModeBehavior.configured(in: defaults.defaults) == behavior)
  }

  @Test func invalidValueGivesAdaptive() {
    for value in ["Override", "off", "", 1, true, ["override"]] as [Any] {
      defaults.defaults.set(value, forKey: "lowPowerModeBehavior")

      #expect(LowPowerModeBehavior.configured(in: defaults.defaults) == .adaptive, "\(value)")
    }
  }
}
