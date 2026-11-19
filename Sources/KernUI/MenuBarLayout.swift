import KernCore

public enum Widget: String, CaseIterable, Sendable {
  case temperature
  case cpu
  case gpu
  case memory
  case cores
  case storage
  case kern

  var metric: Metric {
    switch self {
    case .temperature: .temperature
    case .cpu, .cores: .cpu
    case .gpu: .gpu
    case .memory: .memoryPressure
    case .storage: .storage
    case .kern: .kern
    }
  }

  var label: String? {
    switch self {
    case .temperature, .kern: nil
    case .cpu, .cores: "CPU"
    case .gpu: "GPU"
    case .memory: "RAM"
    case .storage: "SSD"
    }
  }
}

public struct MenuBarLayout: Equatable, Sendable {
  /// Holds every widget once, in the order the menu bar shows them from left to right, hidden ones included.
  public private(set) var order: [Widget]
  public private(set) var hidden: Set<Widget>
  /// Holds the widgets whose label is hidden. Only widgets that have a label are in it.
  public private(set) var unlabeled: Set<Widget>

  public static let standard = MenuBarLayout(widgets: [.temperature, .cpu, .gpu, .memory], unlabeled: [])!

  /// Lists `widgets` first, in their order, then the widgets missing from it, hidden and in their standard order.
  /// Returns nil when `widgets` names a widget twice.
  init?(widgets: [Widget], hidden: Set<Widget> = [], unlabeled: Set<Widget>) {
    guard Set(widgets).count == widgets.count else { return nil }

    let missing = Widget.allCases.filter { !widgets.contains($0) }

    self.order = widgets + missing
    self.hidden = hidden.union(missing)
    self.unlabeled = unlabeled.filter { $0.label != nil }
  }

  init?(widgets: [Widget], hidden: Set<Widget> = [], showsLabels: Bool) {
    self.init(widgets: widgets, hidden: hidden, unlabeled: showsLabels ? [] : Set(Widget.allCases))
  }

  public var widgets: [Widget] {
    order.filter { !hidden.contains($0) }
  }

  public func isShown(_ widget: Widget) -> Bool {
    !hidden.contains(widget)
  }

  public func label(of widget: Widget) -> String? {
    unlabeled.contains(widget) ? nil : widget.label
  }

  public mutating func setShowsLabel(_ showsLabel: Bool, _ widget: Widget) {
    guard widget.label != nil else { return }

    if showsLabel {
      unlabeled.remove(widget)
    } else {
      unlabeled.insert(widget)
    }
  }

  public mutating func setShown(_ isShown: Bool, _ widget: Widget) {
    if isShown {
      hidden.remove(widget)
    } else {
      hidden.insert(widget)
    }
  }

  /// Shows `widget` just before `target`, or after every shown widget when `target` is nil. Placing a widget before
  /// itself shows it where it is.
  public mutating func place(_ widget: Widget, before target: Widget?) {
    hidden.remove(widget)

    guard target != widget, !isShown(widget, before: target) else { return }

    order.removeAll { $0 == widget }

    let index =
      target.flatMap { order.firstIndex(of: $0) }
      ?? order.lastIndex { !hidden.contains($0) }.map { $0 + 1 }
      ?? 0

    order.insert(widget, at: index)
  }
}

extension MenuBarLayout {
  private func isShown(_ widget: Widget, before target: Widget?) -> Bool {
    let shown = widgets

    guard let index = shown.firstIndex(of: widget) else { return false }

    return shown.indices.contains(index + 1) ? shown[index + 1] == target : target == nil
  }

  /// `widgets` lists the widgets in their order, `hidden` those of them that are hidden, and `unlabeled` those whose
  /// label is hidden. A widget missing from `widgets` is hidden, so a value written before `hidden` existed still
  /// shows exactly the widgets it lists. A value written before `unlabeled` existed has `showsLabels`, which shows or
  /// hides every label.
  init?(propertyList: Any) {
    guard let dictionary = propertyList as? [String: Any],
      let widgets = Self.widgets(dictionary["widgets"]),
      let hidden = dictionary["hidden"] == nil ? [] : Self.widgets(dictionary["hidden"])
    else {
      return nil
    }

    if dictionary["unlabeled"] != nil {
      guard let unlabeled = Self.widgets(dictionary["unlabeled"]) else { return nil }

      self.init(widgets: widgets, hidden: Set(hidden), unlabeled: Set(unlabeled))
    } else {
      guard let showsLabels = dictionary["showsLabels"].flatMap(PropertyListValue.boolean) else { return nil }

      self.init(widgets: widgets, hidden: Set(hidden), showsLabels: showsLabels)
    }
  }

  private static func widgets(_ value: Any?) -> [Widget]? {
    guard let names = value as? [String] else { return nil }

    let widgets = names.compactMap(Widget.init(rawValue:))

    return widgets.count == names.count ? widgets : nil
  }

  var propertyList: [String: Any] {
    [
      "widgets": order.map(\.rawValue),
      "hidden": order.filter(hidden.contains).map(\.rawValue),
      "unlabeled": order.filter(unlabeled.contains).map(\.rawValue),
    ]
  }
}
