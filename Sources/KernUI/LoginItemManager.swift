import ServiceManagement
import os

private let logger = Logger(subsystem: "Kern", category: "preferences")

protocol LoginItemService {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Reads the status from macOS rather than keeping it, because the user can change launch at login in System
/// Settings too.
@MainActor
final class LoginItemManager {
  private(set) var status: SMAppService.Status
  private(set) var failure: String?
  private let service: any LoginItemService

  init(service: any LoginItemService) {
    self.service = service
    self.status = service.status
  }

  convenience init() {
    self.init(service: SMAppService.mainApp)
  }

  /// Is true while Kern is registered, also while macOS waits for the user to allow it in System Settings.
  var isEnabled: Bool {
    status == .enabled || status == .requiresApproval
  }

  func setEnabled(_ isEnabled: Bool) {
    refresh()

    guard isEnabled != self.isEnabled else { return }

    do {
      if isEnabled {
        try service.register()
      } else {
        try service.unregister()
      }

      failure = nil

      logger.debug("launch at login turned \(isEnabled ? "on" : "off", privacy: .public)")
    } catch {
      failure = error.localizedDescription

      logger.error(
        "cannot turn launch at login \(isEnabled ? "on" : "off", privacy: .public): \(error, privacy: .public)")
    }

    refresh()
  }

  func refresh() {
    status = service.status
  }
}
