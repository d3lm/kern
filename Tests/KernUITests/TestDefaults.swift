import Foundation

final class TestDefaults {
  let suiteName = "KernUITests.\(UUID())"
  let defaults: UserDefaults

  init() {
    defaults = UserDefaults(suiteName: suiteName)!
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }

  /// Returns the keys that hold a value in this domain alone, without those of the global domain.
  var keys: Set<String> {
    Set(defaults.persistentDomain(forName: suiteName)?.keys ?? [:].keys)
  }
}

/// Parses `text` as `defaults write` and launch arguments do, so every value in it is a string.
func propertyList(_ text: String) throws -> Any {
  try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
}
