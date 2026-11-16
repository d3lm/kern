import AppKit
import Testing

@testable import KernUI

extension AppEvents {
  @MainActor
  final class MouseDownMonitorTests: NSObject {
    let button = NSButton(title: "", target: nil, action: nil)

    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 22),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )

    var actions = 0

    override init() {
      _ = NSApplication.shared

      super.init()

      button.cell = ItemButtonCell()
      button.frame = NSRect(x: 0, y: 0, width: 100, height: 22)
      button.target = self
      button.action = #selector(act)
      window.contentView = NSView()
      window.contentView?.addSubview(button)
      window.orderFrontRegardless()
    }

    @objc func act() {
      actions += 1
      button.highlight(true)
    }

    func click(at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
      let event = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: point,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      )!

      NSApp.sendEvent(event)
    }

    @Test func mouseDownOnTheButtonGoesToTheHandlerAndTheHighlightStays() {
      var handled: [NSEvent] = []

      let monitor = MouseDownMonitor(on: button) { event in
        handled.append(event)
        self.button.highlight(true)
      }

      click(at: NSPoint(x: 50, y: 11))

      #expect(handled.count == 1)
      #expect(actions == 0)
      #expect(button.isHighlighted)

      withExtendedLifetime(monitor) {}
    }

    @Test func commandClickStillReachesTheButtonSoTheItemCanBeMoved() {
      var handled = 0
      let monitor = MouseDownMonitor(on: button) { _ in handled += 1 }

      click(at: NSPoint(x: 50, y: 11), modifiers: .command)

      #expect(handled == 0)
      #expect(actions == 1)

      withExtendedLifetime(monitor) {}
    }

    @Test func mouseDownBesideTheButtonIsLeftAlone() {
      var handled = 0
      let monitor = MouseDownMonitor(on: button) { _ in handled += 1 }

      click(at: NSPoint(x: 150, y: 11))

      #expect(handled == 0)
      #expect(actions == 0)

      withExtendedLifetime(monitor) {}
    }

    @Test func releasedMonitorTakesNothing() {
      var handled = 0
      var monitor: MouseDownMonitor? = MouseDownMonitor(on: button) { _ in handled += 1 }

      monitor = nil
      click(at: NSPoint(x: 50, y: 11))

      #expect(monitor == nil && handled == 0)
      #expect(actions == 1)
    }
  }
}

/// Stands in for `NSStatusBarButtonCell`, which sends the action on the mouse-down and stops tracking there.
private final class ItemButtonCell: NSButtonCell {
  override func trackMouse(
    with event: NSEvent,
    in cellFrame: NSRect,
    of controlView: NSView,
    untilMouseUp: Bool
  ) -> Bool {
    (controlView as? NSControl)?.sendAction(action, to: target)

    return true
  }
}
