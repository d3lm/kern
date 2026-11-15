import AppKit
import KernUI

@main
@MainActor
enum KernApp {
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()

    application.delegate = delegate

    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}
