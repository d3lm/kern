import Foundation
import Testing

@testable import KernUI

struct MenuBarLayoutTests {
  /// A defaults domain of its own, so the test neither reads nor changes Kern's real settings.
  final class Defaults {
    let suiteName = "KernUITests.\(UUID())"
    let defaults: UserDefaults

    init() {
      defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
      defaults.removePersistentDomain(forName: suiteName)
    }
  }

  /// Parses `text` the way `defaults write` and launch arguments do, so every value in it is a string.
  func propertyList(_ text: String) throws -> Any {
    try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
  }

  @Test func standardLayoutIsTemperatureCPUGPUAndMemoryWithLabels() {
    #expect(MenuBarLayout.standard.widgets == [.temperature, .cpu, .gpu, .memory])
    #expect(MenuBarLayout.standard.showsLabels)
  }

  @Test func layoutWithoutWidgetsOrWithAWidgetTwiceIsInvalid() {
    #expect(MenuBarLayout(widgets: [], showsLabels: true) == nil)
    #expect(MenuBarLayout(widgets: [.cpu, .gpu, .cpu], showsLabels: true) == nil)
    #expect(MenuBarLayout(widgets: [.gpu], showsLabels: false)?.widgets == [.gpu])
  }

  @Test func configuredValueSetsOrderVisibilityAndLabels() {
    let defaults = Defaults()

    defaults.defaults.set(["widgets": ["memory", "gpu", "cpu"], "showsLabels": false], forKey: "menuBarLayout")

    #expect(
      MenuBarLayout.configured(in: defaults.defaults)
        == MenuBarLayout(widgets: [.memory, .gpu, .cpu], showsLabels: false))
  }

  @Test(arguments: [
    ("{ widgets = (gpu, cpu); showsLabels = 0; }", false),
    ("{ widgets = (gpu, cpu); showsLabels = NO; }", false),
    ("{ widgets = (gpu, cpu); showsLabels = 1; }", true),
    ("{ widgets = (gpu, cpu); showsLabels = YES; }", true),
  ])
  func valueWrittenAsTextIsRead(text: String, showsLabels: Bool) throws {
    let defaults = Defaults()

    defaults.defaults.set(try propertyList(text), forKey: "menuBarLayout")

    #expect(
      MenuBarLayout.configured(in: defaults.defaults) == MenuBarLayout(widgets: [.gpu, .cpu], showsLabels: showsLabels))
  }

  @Test func missingValueGivesTheStandardLayout() {
    #expect(MenuBarLayout.configured(in: Defaults().defaults) == .standard)
  }

  @Test(arguments: [
    "\"temperature, cpu, gpu\"",
    "{ widgets = (gpu, disk); showsLabels = YES; }",
    "{ widgets = (); showsLabels = YES; }",
    "{ widgets = (gpu, gpu); showsLabels = YES; }",
    "{ widgets = (gpu); }",
    "{ widgets = (gpu); showsLabels = maybe; }",
    "{ widgets = gpu; showsLabels = YES; }",
  ])
  func invalidValueGivesTheStandardLayout(text: String) throws {
    let defaults = Defaults()

    defaults.defaults.set(try propertyList(text), forKey: "menuBarLayout")

    #expect(MenuBarLayout.configured(in: defaults.defaults) == .standard)
  }
}
