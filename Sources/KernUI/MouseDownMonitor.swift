import AppKit

/// A button clears its highlight when click tracking ends, so it must not track the mouse-downs that open a panel.
/// Command-clicks must still reach it, because the menu bar uses them to move the item.
///
/// A status item's window is wider and taller than its button, and hands the button the mouse-downs outside its
/// bounds too, so every mouse-down in the button's window is taken, not only those on the button.
@MainActor
final class MouseDownMonitor {
  nonisolated(unsafe) private var monitor: Any?

  init(on button: NSButton, handler: @escaping @MainActor (NSEvent) -> Void) {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak button] event in
      let isOnItem = MainActor.assumeIsolated {
        guard let window = button?.window else { return false }

        return event.window === window && !event.modifierFlags.contains(.command)
      }

      guard isOnItem else { return event }

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
