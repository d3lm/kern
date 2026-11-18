import AppKit
import KernUI

let usage = """
  Usage: kern-settings-bench [<changes>] [<seed>]

  Runs Kern as the app does, opens its detail panel by posting a click to its menu-bar item, and presses ⌘, in the
  panel, which must close the panel and open the Settings window. Then it makes <changes> random settings changes
  (default 100) through Kern's preferences, 100 ms apart, with the Settings window open, restores the defaults,
  closes the window, and keeps Kern running for 30 seconds more. It prints Kern's memory before the first change,
  after the last, and after the window has closed. <seed> (default 1) picks the changes, so a run can be repeated.
  Build it with -c release to measure a Release build.

  Kern's debug log says what the changes did to the sampling. Pipe it to Scripts/schedule-report.swift, which
  checks that every metric has exactly one schedule after the last change:

    log stream --style ndjson --level debug --predicate 'subsystem == "Kern" && process == "kern-settings-bench"' \\
      | swift Scripts/schedule-report.swift

  The settings are kept in the bench's own defaults domain, kern-settings-bench, never in Kern's. Real clicks or
  keys while it runs can close the panel or the window and spoil the run.
  """

let numbers = CommandLine.arguments.dropFirst().map { Int($0) }

guard numbers.count <= 2, numbers.allSatisfy({ ($0 ?? 0) >= 1 }) else {
  print(usage)
  exit(EX_USAGE)
}

let changes = numbers.first.flatMap { $0 } ?? 100
let seed = UInt64(numbers.dropFirst().first.flatMap { $0 } ?? 1)

struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15

    var z = state

    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB

    return z ^ (z >> 31)
  }
}

@MainActor
final class Bench {
  private let delegate: AppDelegate
  private let item: NSStatusBarButton
  private var random: SplitMix64
  private var failures = 0

  init(delegate: AppDelegate, seed: UInt64) {
    guard
      let item = NSApp.windows.lazy.compactMap({ $0.contentView?.descendant(of: NSStatusBarButton.self) }).first
    else {
      fatalError("Kern made no menu-bar item")
    }

    self.delegate = delegate
    self.item = item
    self.random = SplitMix64(state: seed)
  }

  /// Finds the panel by its class name, because a tooltip is also a visible panel.
  private var panel: NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.className.contains("DetailPanel") }
  }

  private var settings: NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.contentViewController is NSTabViewController }
  }

  func run(changes: Int) async {
    delegate.preferences.restoreDefaults()

    await openSettingsFromThePanel()

    report("before the first change")

    for change in 1...changes {
      makeRandomChange()
      print("change \(change): \(describe(delegate.preferences.preferences))")
      fflush(stdout)

      try? await Task.sleep(for: .milliseconds(100))
    }

    try? await Task.sleep(for: .seconds(1))
    report("after \(changes) changes")

    delegate.preferences.restoreDefaults()
    print("restored the defaults")

    weak var window = settings

    window?.performClose(nil)
    try? await Task.sleep(for: .seconds(1))
    check(window == nil, "the closed Settings window is released")
    report("after closing the Settings window")

    print("keeping Kern running for 30 seconds with the default settings")
    fflush(stdout)
    try? await Task.sleep(for: .seconds(30))

    print("\(changes) changes, \(failures) failed checks")
  }

  private func openSettingsFromThePanel() async {
    let frontmost = NSWorkspace.shared.frontmostApplication

    click(item)

    await wait { self.panel != nil }

    guard let panel else {
      check(false, "a click on the item opens the panel")
      return
    }

    try? await Task.sleep(for: .milliseconds(300))

    print(
      """
      panel open: key window \(panel.isKeyWindow), Kern active \(NSApp.isActive), frontmost app before \
      \(frontmost?.localizedName ?? "none"), now \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
      """)

    check(panel.isKeyWindow, "the open panel is the key window")
    check(NSWorkspace.shared.frontmostApplication == frontmost, "the app the user was in stays the frontmost app")

    press(",", .command, in: panel)

    await wait { self.settings != nil }

    check(self.panel == nil, "⌘, in the panel closes the panel")
    check(settings != nil, "⌘, in the panel opens the Settings window")
    check(NSApp.activationPolicy() == .accessory, "opening Settings adds no Dock icon")
    check(NSApp.windows.filter { $0.contentViewController is NSTabViewController }.count == 1, "one Settings window")
  }

  private func makeRandomChange() {
    let monitor = Monitor.allCases.randomElement(using: &random)!
    let widget = Widget.allCases.randomElement(using: &random)!
    let kind = Int.random(in: 0..<7, using: &random)
    let interval = Int.random(in: monitor.intervals, using: &random)
    let samples = Int.random(in: Preferences.graphSampleCounts, using: &random)
    let target = Widget.allCases.randomElement(using: &random)!

    delegate.preferences.update { preferences in
      switch kind {
      case 0: preferences[monitor].isEnabled.toggle()
      case 1: preferences[monitor].interval = interval
      case 2: preferences.graphSamples = samples
      case 3: preferences.temperatureUnit = preferences.temperatureUnit == .celsius ? .fahrenheit : .celsius
      case 4: preferences.lowPowerModeBehavior = preferences.lowPowerModeBehavior == .adaptive ? .override : .adaptive
      case 5: preferences.menuBarLayout.setShown(!preferences.menuBarLayout.isShown(widget), widget)
      default: preferences.menuBarLayout.place(widget, before: target == widget ? nil : target)
      }
    }
  }

  private func describe(_ preferences: Preferences) -> String {
    let monitors = Monitor.allCases.map { monitor in
      let settings = preferences[monitor]

      return "\(monitor.rawValue) \(settings.isEnabled ? "\(settings.interval) s" : "off")"
    }

    let layout = preferences.menuBarLayout
    let widgets = layout.order.map { layout.isShown($0) ? $0.rawValue : "(\($0.rawValue))" }

    return
      (monitors + [
        "\(preferences.graphSamples) samples", preferences.temperatureUnit.rawValue,
        preferences.lowPowerModeBehavior.rawValue, widgets.joined(separator: " "),
        "unlabeled \(layout.order.filter(layout.unlabeled.contains).map(\.rawValue))",
      ]).joined(separator: ", ")
  }

  private func wait(_ condition: @escaping @MainActor () -> Bool) async {
    let start = ContinuousClock.now

    while !condition() && ContinuousClock.now < start + .seconds(2) {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func click(_ view: NSView) {
    let window = view.window!
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)

    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == .leftMouseDown ? 1 : 0
      )!

      NSApp.postEvent(event, atStart: false)
    }
  }

  private func press(_ key: String, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      characters: key,
      charactersIgnoringModifiers: key,
      isARepeat: false,
      keyCode: 43
    )!

    NSApp.postEvent(event, atStart: false)
  }

  private func check(_ condition: Bool, _ message: String) {
    if !condition {
      failures += 1

      print("FAILED: \(message)")
    }
  }

  private func report(_ moment: String) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

    _ = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }

    print(
      String(
        format: "memory %@: footprint %.1f MiB, resident %.1f MiB", moment, Double(info.phys_footprint) / 1_048_576,
        Double(info.resident_size) / 1_048_576))

    fflush(stdout)
  }
}

extension NSView {
  func descendant<View: NSView>(of type: View.Type) -> View? {
    (self as? View) ?? subviews.lazy.compactMap { $0.descendant(of: type) }.first
  }
}

let application = NSApplication.shared
let delegate = AppDelegate()

application.delegate = delegate

application.setActivationPolicy(.accessory)

Task { @MainActor in
  try? await Task.sleep(for: .seconds(5))
  await Bench(delegate: delegate, seed: seed).run(changes: changes)
  exit(0)
}

withExtendedLifetime(delegate) {
  application.run()
}
