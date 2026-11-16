import AppKit

/// A button clears its highlight when click tracking ends, so it must not track the mouse-downs that open a panel.
/// Command-clicks must still reach it, because the menu bar uses them to move the item.
@MainActor
final class MouseDownMonitor {
  nonisolated(unsafe) private var monitor: Any?

  init(on button: NSButton, handler: @escaping @MainActor (NSEvent) -> Void) {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak button] event in
      let isOnButton = MainActor.assumeIsolated {
        guard let button, event.window === button.window, !event.modifierFlags.contains(.command) else { return false }

        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
      }

      guard isOnButton else { return event }

      MainActor.assumeIsolated { handler(event) }

      return nil
    }
  }

  deinit {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}
