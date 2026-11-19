import AppKit
import KernCore

/// Shows the Settings window, with a toolbar tab for each group of settings. It exists only while it is open, so a
/// closed window holds no views and observes nothing.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  let window: NSWindow
  let tabs: NSTabViewController
  let panes: [SettingsPane]
  private let onClose: @MainActor () -> Void

  init(
    preferences: PreferencesStore,
    loginItem: LoginItemManager,
    store: MetricsStore,
    onClose: @escaping @MainActor () -> Void
  ) {
    self.onClose = onClose

    panes = [
      GeneralSettings(preferences: preferences, loginItem: loginItem),
      MetricsSettings(preferences: preferences, store: store),
      MenuBarSettings(preferences: preferences, store: store, isActive: false),
    ]

    tabs = SettingsTabs()
    tabs.tabStyle = .toolbar
    tabs.transitionOptions = []

    for (pane, symbol) in zip(panes, ["gearshape", "chart.bar", "menubar.rectangle"]) {
      let item = NSTabViewItem(viewController: pane)

      item.label = pane.title ?? ""
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)

      tabs.addTabViewItem(item)
    }

    window = SettingsWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none

    window.setContentSize(panes[0].preferredContentSize)

    super.init()

    window.delegate = self

    window.center()
  }

  func show(_ preferences: Preferences) {
    for pane in panes {
      pane.show(preferences)
    }
  }

  /// An agent app is never active on its own, and `activate()` only asks macOS, which can refuse it,
  /// so the window would open behind the app the user is in. `activate(ignoringOtherApps:)` makes Kern
  /// active regardless, so typing reaches the window, and `orderFrontRegardless()` keeps the window in
  /// front even when macOS still refuses activation.
  func show() {
    (panes.first as? GeneralSettings)?.refreshLoginItem()
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  /// malloc keeps freed pages, which count as Kern's memory, until memory pressure, so the pages the window
  /// leaves empty are returned once it has been released.
  func windowWillClose(_ notification: Notification) {
    window.delegate = nil

    for pane in panes {
      pane.stop()
    }

    onClose()

    DispatchQueue.main.async {
      malloc_zone_pressure_relief(nil, 0)
    }
  }
}

/// Takes ⌘W and ⌘Q itself. Kern has no main menu to take them, because a main menu with an Edit menu makes macOS add
/// AutoFill and Writing Tools to it, which loads about 540 more frameworks into Kern at launch.
final class SettingsWindow: NSWindow {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    switch event.shortcut {
    case (.command, "w"):
      performClose(nil)
      return true
    case (.command, "q"):
      NSApp.terminate(nil)
      return true
    default:
      return super.performKeyEquivalent(with: event)
    }
  }
}

extension NSEvent {
  /// Returns the modifiers and the key of a shortcut, as a menu reads them. The key is what the key gives with ⌘
  /// held, which differs from what it types on a layout such as Dvorak – QWERTY ⌘ or one without Latin letters.
  /// It is in lowercase, so Caps Lock changes nothing.
  var shortcut: (modifiers: NSEvent.ModifierFlags, key: String?) {
    let characters = characters.flatMap { $0.isEmpty ? nil : $0 } ?? charactersIgnoringModifiers

    return (modifierFlags.intersection([.command, .shift, .option, .control]), characters?.lowercased())
  }
}
