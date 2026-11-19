import AppKit
import KernUI

let usage = """
  Usage: kern-popover-bench [<openings>] [--idle | --accessibility | --menu] [--pause]

  Runs Kern as the app does, then opens and closes its detail panel <openings> times (default 50) by posting clicks
  to its menu-bar item, checks each opening, and prints how much memory Kern used. Odd openings are closed by a click
  elsewhere in the app, even ones by a click on the item. Build it with -c release to measure a Release build. Kern
  logs how long each opening took as "opened popover in"; read it with log stream. Real clicks while it runs close
  the panel or open the menu, and spoil the run.

  --idle           Wait as long as the openings would take without opening the panel, for comparison.
  --accessibility  Print what VoiceOver can read in the panel, once it has been open for 6 seconds.
  --menu           Right-click the item, check that its menu is only as wide as its items and opens where a status
                   item opens its own, and choose Quit Kern in it, which must end the process. Pass
                   -menuBarLayout with many widgets to check it against an item wider than the menu.
  --pause          Stop at each memory report, and once with the third opening on screen, until the process gets
                   SIGCONT, so that heap, vmmap, footprint, or leaks can examine it.

  A Debug build also accepts Kern's own launch arguments, such as --fail gpu.
  """

let arguments = CommandLine.arguments.dropFirst()
let idle = arguments.contains("--idle")
let printsAccessibility = arguments.contains("--accessibility")
let usesMenu = arguments.contains("--menu")
let pauses = arguments.contains("--pause")
let openings = arguments.first.flatMap { Int($0) } ?? 50

guard openings >= 20 else {
  print(usage)
  exit(EX_USAGE)
}

@MainActor
final class Bench {
  private let item: NSStatusBarButton
  private let elsewhere: NSWindow
  private var failures = 0

  init() {
    guard
      let item = NSApp.windows.lazy.compactMap(
        { $0.contentView?.descendant(of: NSStatusBarButton.self) }
      ).first
    else {
      fatalError("Kern made no menu-bar item")
    }

    self.item = item

    self.elsewhere = NSWindow(
      contentRect: NSRect(x: 200, y: 200, width: 100, height: 100),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )

    elsewhere.orderFrontRegardless()

    guard usesMenu else { return }

    NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification,
      object: nil,
      queue: nil
    ) {
      [weak self] notification in
      // menus post it on the main thread, where they are tracked
      nonisolated(unsafe) let menu = notification.object as? NSMenu

      MainActor.assumeIsolated { self?.chooseQuit(in: menu) }
    }
  }

  /// Matched by class name, because a tooltip is also a visible panel.
  private var panel: NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.className.contains("DetailPanel") }
  }

  func run(openings: Int, idle: Bool) async {
    report("before the first opening")

    if idle {
      try? await Task.sleep(for: .seconds(Double(openings) * 0.65))
      report("after idling")
      return
    }

    if usesMenu {
      click(item, down: .rightMouseDown, up: .rightMouseUp)
      try? await Task.sleep(for: .seconds(2))
      print("FAILED: still running 2 seconds after the right-click")
      exit(EXIT_FAILURE)
    }

    for opening in 1...openings {
      if panel != nil {
        click(elsewhere.contentView!)
        try? await Task.sleep(for: .milliseconds(300))
      }

      // read on every opening, because other apps' items can move Kern's between openings
      let itemFrame = item.window!.frame

      click(item)

      let clicked = ContinuousClock.now

      while panel == nil && ContinuousClock.now < clicked + .seconds(2) {
        try? await Task.sleep(for: .milliseconds(1))
      }

      guard panel != nil else {
        check(false, "opening \(opening) shows the panel")

        continue
      }

      // weak, so the bench does not keep the closed panel alive
      weak var shown = panel

      if let shown {
        check(shown.frame.maxY <= itemFrame.minY, "the panel opens below the item")
      }

      check(item.window!.frame == itemFrame, "the item keeps its place and size")

      if printsAccessibility, opening == 1, let content = shown?.contentView {
        try? await Task.sleep(for: .seconds(6))
        printAccessibility(of: content)
      }

      try? await Task.sleep(for: .milliseconds(300))
      check(item.isHighlighted, "the item stays highlighted while the panel is open")

      if pauses, opening == 3 {
        report("with the third opening on screen")
      }

      click(opening.isMultiple(of: 2) ? item : elsewhere.contentView!)
      try? await Task.sleep(for: .milliseconds(300))
      check(shown?.isVisible != true, "opening \(opening) is closed by the click and stays closed")
      check(!item.isHighlighted, "the item is not highlighted once the panel has closed")

      if [1, 20, openings].contains(opening) {
        try? await Task.sleep(for: .seconds(1))
        report("after \(opening) \(opening == 1 ? "opening" : "openings")")
      }
    }

    print("openings: \(openings), \(failures) failed checks")
  }

  private func chooseQuit(in menu: NSMenu?) {
    guard let menu else { return }

    guard let quit = menu.items.firstIndex(where: { $0.title == "Quit Kern" }) else {
      print("FAILED: the menu has no Quit Kern")
      exit(EXIT_FAILURE)
    }

    // the menu's window appears a moment after tracking begins, which runs the common modes only, and the timer runs
    // on the main run loop so the menu stays on the main actor
    nonisolated(unsafe) let openMenu = menu

    let timer = Timer(timeInterval: 0.3, repeats: false) { [self] _ in
      MainActor.assumeIsolated {
        checkPlacement(of: openMenu)

        openMenu.cancelTracking()
        openMenu.performActionForItem(at: quit)
      }
    }

    RunLoop.main.add(timer, forMode: .common)
  }

  /// Expects the menu where the status item opens its own menu, 4 points left of the item and against the bottom
  /// of the menu bar, but only as wide as its items, where the status item's own is as wide as the item.
  private func checkPlacement(of menu: NSMenu) {
    let itemFrame = item.window!.convertToScreen(item.convert(item.bounds, to: nil))

    guard let frame = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Menu") })?.frame else {
      print("FAILED: the menu has no visible window")
      return
    }

    // a menu the status item shows reports the item's width as its own size, and a copy that is not shown does not
    let itemsWidth = (menu.copy() as? NSMenu)?.size.width ?? 0

    print(
      "menu: \(menu.items.map(\.title)) at \(frame), \(itemsWidth) wide by its items, item at \(itemFrame), "
        + "item highlighted: \(item.isHighlighted)")

    check(item.isHighlighted, "the item stays highlighted while the menu is open")
    check(frame.width == itemsWidth, "the menu is as wide as its items")
    check(frame.minX == itemFrame.minX - 4, "the menu starts 4 points left of the item")
    check(frame.maxY == itemFrame.minY - 2, "the menu opens against the bottom of the menu bar")

    fflush(stdout)
  }

  private func click(
    _ view: NSView,
    down: NSEvent.EventType = .leftMouseDown,
    up: NSEvent.EventType = .leftMouseUp
  ) {
    let window = view.window!
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)

    for type in [down, up] {
      let event = NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: type == down ? 1 : 0
      )!

      NSApp.postEvent(event, atStart: false)
    }
  }

  private func printAccessibility(of view: NSView) {
    if view.isAccessibilityElement() {
      let role = view.accessibilityRole()?.rawValue ?? "?"
      let text = [view.accessibilityLabel(), view.accessibilityValue() as? String].compactMap { $0 }

      print("accessibility \(role): \(text.joined(separator: " | "))")
    }

    for subview in view.subviews {
      printAccessibility(of: subview)
    }
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
        format: "memory %@: footprint %.1f MiB, resident %.1f MiB",
        moment,
        Double(info.phys_footprint) / 1_048_576,
        Double(info.resident_size) / 1_048_576
      )
    )

    if pauses {
      print("paused \(moment), until: kill -CONT \(getpid())")
      fflush(stdout)
      raise(SIGSTOP)
    }
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
  await Bench().run(openings: openings, idle: idle)
  exit(0)
}

withExtendedLifetime(delegate) {
  application.run()
}
