import AppKit
import KernCore

/// Dragging a widget along the bar moves it, and the others make room as it passes. Dragging it out of the bar shows
/// the system's disappearing-item cursor, and letting go there removes it. Dragging it in from the shelf of available
/// widgets below shows it again. A right-click on a widget, and VoiceOver's actions, do the same without dragging.
///
/// The bar and the shelf are one view, because AppKit sends the rest of a drag to the view that took the mouse-down.
@MainActor
final class MenuBarEditor: NSView, SettingsContent {
  enum Place: Equatable {
    case bar
    case shelf
  }

  private struct Press {
    let widget: Widget
    let place: Place
    let point: NSPoint
  }

  private struct Drag {
    let widget: Widget
    let place: Place
    let ghost: NSImageView
    /// Holds the distance from the ghost's origin to the pointer.
    let grip: NSSize
    var layout: MenuBarLayout
    var isRemoving = false
  }

  private struct Look: Equatable {
    let layout: MenuBarLayout
    let temperatureUnit: TemperatureUnit
  }

  static let barHeight: CGFloat = 30
  static let shelfHeight: CGFloat = 64
  private static let clockSpacing: CGFloat = 14
  private static let shelfSpacing: CGFloat = 28
  private static let dragThreshold: CGFloat = 3
  private static let disabledAlpha: CGFloat = 0.35
  private static let removingAlpha: CGFloat = 0.5
  static let placeholderAlpha: CGFloat = 0.3
  private static let slideDuration: TimeInterval = 0.2
  private static let dropMargin = NSSize(width: 24, height: 14)

  var onLayoutChange: (MenuBarLayout) -> Void = { _ in }
  /// Asks the owner to arrange the editor again, which a reading or a change of widgets can make it need when the
  /// shelf's items take another number of rows.
  var onHeightChange: () -> Void = {}

  let bar: SettingsPlate
  let clock = NSTextField(labelWithString: "")
  let shelfHeader: NSTextField
  let shelf: SettingsPlate
  let emptyShelf: NSTextField
  private(set) var barView: MenuBarView?
  private(set) var shelfItems: [ShelfItem] = []
  private(set) var preferences = Preferences.standard
  private let store: MetricsStore
  private let style: SettingsStyle
  private var look: Look?
  private var press: Press?
  private var drag: Drag?
  private var observer: MetricsStore.ObserverID?
  private var ticking: Task<Void, Never>?

  init(store: MetricsStore, style: SettingsStyle) {
    self.store = store
    self.style = style
    bar = SettingsPlate(style: style)
    shelf = SettingsPlate(style: style)
    shelfHeader = style.header("Available")
    emptyShelf = NSTextField(labelWithString: "Every widget is in the menu bar.")

    super.init(frame: .zero)

    clock.font = NSFont.menuBarFont(ofSize: 0)
    emptyShelf.font = style.footerFont
    emptyShelf.textColor = .tertiaryLabelColor

    emptyShelf.sizeToFit()
    bar.addSubview(clock)
    shelf.addSubview(emptyShelf)

    for view in [bar, shelfHeader, shelf] {
      addSubview(view)
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Menu bar widgets")

    observer = store.observe { [weak self] metric in self?.showReadings(of: metric) }

    tick()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("MenuBarEditor is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  /// Takes every click, so that the widgets, which pass clicks on as they do in the menu bar, can be dragged.
  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  /// Waits with a rebuild during a drag, which shows the result of the drop itself.
  func show(_ preferences: Preferences) {
    self.preferences = preferences

    guard drag == nil else { return }

    showBar(preferences.menuBarLayout)
    showShelf()
  }

  func stop() {
    cancelDrag()

    if let observer { store.removeObserver(observer) }

    observer = nil

    ticking?.cancel()
  }

  func arrange() {
    let width = style.boxWidth

    bar.frame = NSRect(x: 0, y: 0, width: width, height: Self.barHeight)

    clock.sizeToFit()

    clock.setAlignmentOrigin(
      NSPoint(
        x: width - style.inset - clock.alignmentSize.width,
        y: ((Self.barHeight - clock.alignmentSize.height) / 2).rounded()))

    let shelfTop = bar.frame.maxY + style.sectionSpacing

    shelfHeader.setAlignmentOrigin(NSPoint(x: style.inset, y: shelfTop))
    shelf.setFrameOrigin(NSPoint(x: 0, y: shelfTop + shelfHeader.alignmentSize.height + style.headerGap))

    arrangeShelf()
  }

  /// Starts a new row of items wherever the next item would pass the box's inset, and makes the shelf one row taller
  /// for each. Returns whether that changed the editor's height.
  @discardableResult
  private func arrangeShelf() -> Bool {
    let available = style.boxWidth - 2 * style.inset

    var rows: [[ShelfItem]] = []
    var rowWidth: CGFloat = 0

    for item in shelfItems {
      let widened = rowWidth + Self.shelfSpacing + item.frame.width

      if !rows.isEmpty, widened <= available {
        rows[rows.count - 1].append(item)

        rowWidth = widened
      } else {
        rows.append([item])

        rowWidth = item.frame.width
      }
    }

    let rowHeight = shelfItems.map(\.frame.height).max() ?? 0
    let rowStep = rowHeight + ((Self.shelfHeight - rowHeight) / 2).rounded()

    for (index, row) in rows.enumerated() {
      var left = style.inset

      for item in row {
        let top = ((Self.shelfHeight - item.frame.height) / 2).rounded() + CGFloat(index) * rowStep

        item.setFrameOrigin(NSPoint(x: left, y: top))

        left = item.frame.maxX + Self.shelfSpacing
      }
    }

    emptyShelf.isHidden = !shelfItems.isEmpty

    emptyShelf.setFrameOrigin(
      NSPoint(
        x: ((style.boxWidth - emptyShelf.frame.width) / 2).rounded(),
        y: ((Self.shelfHeight - emptyShelf.frame.height) / 2).rounded()))

    shelf.setFrameSize(
      NSSize(width: style.boxWidth, height: Self.shelfHeight + CGFloat(max(rows.count - 1, 0)) * rowStep))

    let size = NSSize(width: style.boxWidth, height: shelf.frame.maxY)

    guard size != frame.size else { return false }

    setFrameSize(size)

    return true
  }

  private func showBar(_ layout: MenuBarLayout, dragged: Widget? = nil) {
    let look = Look(layout: layout, temperatureUnit: preferences.temperatureUnit)

    if look != self.look {
      let before = Dictionary(uniqueKeysWithValues: (barView?.widgetViews ?? []).map { ($0.widget, frame(of: $0)) })

      self.look = look

      barView?.removeFromSuperview()

      let view = MenuBarView(layout: layout, temperatureUnit: preferences.temperatureUnit)

      view.onStaleDeadline = { [weak self] metric in self?.showReadings(of: metric) }
      view.translatesAutoresizingMaskIntoConstraints = false

      bar.addSubview(view)

      // a widget that shows text widens with its value, as in the menu bar, so the widgets keep their trailing
      // edge by a constraint rather than a frame set once
      NSLayoutConstraint.activate([
        view.trailingAnchor.constraint(equalTo: clock.leadingAnchor, constant: -Self.clockSpacing),
        view.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      ])

      barView = view

      showReadings(on: view)
      bar.layoutSubtreeIfNeeded()

      if drag != nil {
        slide(view.widgetViews, from: before)
      }
    }

    let shown = layout.widgets

    for widgetView in barView?.widgetViews ?? [] {
      let widget = widgetView.widget
      let position = (shown.firstIndex(of: widget) ?? 0) + 1

      showAvailability(of: widget, on: widgetView)

      if widget == dragged {
        widgetView.alphaValue = Self.placeholderAlpha
      }

      offerCommands(
        for: widget, on: widgetView, label: "\(widget.title), in the menu bar, \(position) of \(shown.count)")
    }

    bar.layoutSubtreeIfNeeded()
    window?.invalidateCursorRects(for: self)
  }

  private var animates: Bool {
    window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func slide(_ views: [WidgetView], from before: [Widget: NSRect]) {
    guard animates else { return }

    let targets = views.map(\.frame)

    for view in views {
      if let old = before[view.widget], let superview = view.superview {
        view.frame = superview.convert(old, from: self)
      }
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.slideDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

      for (view, target) in zip(views, targets) {
        view.animator().frame = target
      }
    }
  }

  private func showShelf() {
    let hidden = preferences.menuBarLayout.order.filter { !preferences.menuBarLayout.isShown($0) }

    if hidden != shelfItems.map(\.widget) || shelfItems.contains(where: { !$0.matches(preferences) }) {
      for item in shelfItems { item.removeFromSuperview() }

      shelfItems = hidden.map { widget in
        let item = ShelfItem(widget, preferences: preferences, style: style)

        shelf.addSubview(item)
        showReadings(on: item.menuBarView)
        item.arrange()

        return item
      }
    }

    for item in shelfItems {
      showAvailability(of: item.widget, on: item.menuBarView)
      offerCommands(for: item.widget, on: item, label: "\(item.widget.title), available")
    }

    if arrangeShelf() {
      onHeightChange()
    }

    window?.invalidateCursorRects(for: self)
  }

  private func showAvailability(of widget: Widget, on view: NSView) {
    let monitor = Monitor(widget.metric)
    let isOn = monitor.map { preferences[$0].isEnabled } ?? true

    view.alphaValue = isOn ? 1 : Self.disabledAlpha
    view.toolTip = monitor.flatMap { isOn ? nil : "Hidden from the menu bar while \($0.title) is off" }
  }

  private func offerCommands(for widget: Widget, on view: NSView, label: String) {
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.button)
    view.setAccessibilityLabel(label)

    view.setAccessibilityCustomActions(
      commands(for: widget).filter { layout(after: $0, on: widget) != nil }.map { command in
        NSAccessibilityCustomAction(name: command.title) { [weak self] in
          self?.run(command, on: widget)
          return true
        }
      })
  }

  private func showReadings(of metric: Metric) {
    guard let readings = store[metric] else { return }

    barView?.show(readings, for: metric)

    for item in shelfItems {
      item.menuBarView.show(readings, for: metric)
    }

    if shelfItems.map({ $0.arrange() }).contains(true), arrangeShelf() {
      onHeightChange()
    }

    window?.invalidateCursorRects(for: self)
  }

  private func showReadings(on view: MenuBarView) {
    for metric in Metric.allCases {
      if let readings = store[metric] { view.show(readings, for: metric) }
    }
  }

  private func tick() {
    var seconds = showTime()

    ticking = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60 - seconds), tolerance: .seconds(1))

        guard let next = self?.showTime() else { return }

        seconds = next
      }
    }
  }

  /// Returns the second of the minute it shows.
  private func showTime() -> Int {
    let now = Date.now

    clock.stringValue = now.formatted(date: .omitted, time: .shortened)

    arrange()

    return Calendar.current.component(.second, from: now)
  }

  func widget(at point: NSPoint) -> (widget: Widget, place: Place)? {
    if let view = barView?.widgetViews.first(where: { frame(of: $0).contains(point) }) {
      return (view.widget, .bar)
    }

    if let item = shelfItems.first(where: { frame(of: $0).contains(point) }) {
      return (item.widget, .shelf)
    }

    return nil
  }

  func frame(of view: NSView) -> NSRect {
    view.convert(view.bounds, to: self)
  }

  override func resetCursorRects() {
    let views: [NSView] = (barView?.widgetViews ?? []) + shelfItems

    for view in views {
      addCursorRect(frame(of: view), cursor: .openHand)
    }
  }

  private func isOverBar(_ point: NSPoint) -> Bool {
    bar.frame.insetBy(dx: -Self.dropMargin.width, dy: -Self.dropMargin.height).contains(point)
  }

  private func layout(dropping widget: Widget, at point: NSPoint) -> MenuBarLayout {
    let others = (barView?.widgetViews ?? []).filter { $0.widget != widget }

    var layout = preferences.menuBarLayout

    layout.place(widget, before: others.first { frame(of: $0).midX > point.x }?.widget)

    return layout
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)

    // a drag outlives a mouse-up the editor never got
    cancelDrag()

    press = widget(at: point).map { Press(widget: $0.widget, place: $0.place, point: point) }

    if press != nil {
      window?.makeFirstResponder(self)
    }
  }

  /// Takes the keyboard while a widget is pressed, so that Escape can cancel its drag, but is never reached by Tab.
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { false }

  override func cancelOperation(_ sender: Any?) {
    guard press != nil || drag != nil else {
      nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
      return
    }

    press = nil

    cancelDrag()
  }

  private func cancelDrag() {
    guard let drag else { return }

    self.drag = nil

    drag.ghost.removeFromSuperview()
    window?.enableCursorRects()
    NSCursor.arrow.set()

    for item in shelfItems {
      item.alphaValue = 1
    }

    show(preferences)
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)

    if drag == nil, let press, hypot(point.x - press.point.x, point.y - press.point.y) >= Self.dragThreshold {
      beginDrag(press)
    }

    if drag != nil {
      moveDrag(to: point)
    }
  }

  override func mouseUp(with event: NSEvent) {
    press = nil

    if drag != nil {
      endDrag(at: convert(event.locationInWindow, from: nil))
    }
  }

  private func beginDrag(_ press: Press) {
    let source: NSView? =
      switch press.place {
      case .bar: barView?.widgetViews.first { $0.widget == press.widget }
      case .shelf: shelfItems.first { $0.widget == press.widget }?.menuBarView
      }

    guard let source else { return }

    let sourceFrame = frame(of: source)
    let ghost = NSImageView(image: Self.snapshot(of: source))

    ghost.frame = sourceFrame
    ghost.imageScaling = .scaleNone

    addSubview(ghost)

    drag = Drag(
      widget: press.widget, place: press.place, ghost: ghost,
      grip: NSSize(width: press.point.x - sourceFrame.minX, height: press.point.y - sourceFrame.minY),
      layout: preferences.menuBarLayout)

    shelfItems.first { $0.widget == press.widget }?.alphaValue = Self.placeholderAlpha

    window?.disableCursorRects()
    NSCursor.closedHand.set()
  }

  private func moveDrag(to point: NSPoint) {
    guard var drag else { return }

    let wasRemoving = drag.isRemoving

    drag.ghost.setFrameOrigin(ghostOrigin(at: point, grip: drag.grip, size: drag.ghost.frame.size))

    if isOverBar(point) {
      drag.layout = layout(dropping: drag.widget, at: point)
      drag.isRemoving = false
    } else {
      drag.layout = preferences.menuBarLayout

      drag.layout.setShown(false, drag.widget)

      drag.isRemoving = drag.place == .bar
    }

    drag.ghost.alphaValue = drag.isRemoving ? Self.removingAlpha : 1

    if drag.isRemoving != wasRemoving {
      (drag.isRemoving ? NSCursor.disappearingItem : NSCursor.closedHand).set()
    }

    self.drag = drag

    showBar(drag.layout, dragged: drag.widget)
  }

  /// Keeps the ghost inside the window's content, because views do not clip their subviews and it would otherwise
  /// slide under the toolbar.
  private func ghostOrigin(at point: NSPoint, grip: NSSize, size: NSSize) -> NSPoint {
    let origin = NSPoint(x: point.x - grip.width, y: point.y - grip.height)

    guard let window else { return origin }

    let content = convert(window.contentLayoutRect, from: nil)

    return NSPoint(
      x: min(max(origin.x, content.minX), content.maxX - size.width),
      y: min(max(origin.y, content.minY), content.maxY - size.height))
  }

  private func endDrag(at point: NSPoint) {
    moveDrag(to: point)

    guard let drag else { return }

    self.drag = nil

    window?.enableCursorRects()
    NSCursor.arrow.set()

    for item in shelfItems {
      item.alphaValue = 1
    }

    if drag.layout != preferences.menuBarLayout {
      onLayoutChange(drag.layout)
    }

    show(preferences)
    settle(drag)
  }

  /// Keeps the widget the ghost lands on hidden until the ghost arrives, so the widget is never shown twice.
  private func settle(_ drag: Drag) {
    let ghost = drag.ghost

    let target: NSView? =
      if drag.layout.isShown(drag.widget) {
        barView?.widgetViews.first { $0.widget == drag.widget }
      } else if drag.isRemoving {
        nil
      } else {
        shelfItems.first { $0.widget == drag.widget }?.menuBarView
      }

    guard animates else {
      ghost.removeFromSuperview()
      return
    }

    let alpha = target?.alphaValue ?? 1

    if let target {
      land(ghost, as: target)
    }

    target?.alphaValue = 0

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.slideDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)

      if let target {
        ghost.animator().frame = frame(of: target)
      } else {
        ghost.animator().alphaValue = 0
      }
    } completionHandler: {
      ghost.removeFromSuperview()

      target?.alphaValue = alpha
    }
  }

  /// Shows the widget in the ghost as it looks where it lands, with the ghost's trailing edge kept in place.
  /// A widget that shows text is only as wide as its reading, which can gain a digit during the drag, and the
  /// widgets draw it right-aligned, so a ghost of the old width stretched to the new one would slide its reading
  /// past its place and jump back when the widget appears.
  ///
  /// A widget dropped just after the others moved is still sliding to its place, so it is put there at once first,
  /// which nobody sees because it stays hidden until the ghost arrives.
  private func land(_ ghost: NSImageView, as target: NSView) {
    if let barView, let index = barView.widgetViews.firstIndex(where: { $0 === target }) {
      let final = barView.layoutFrames[index]

      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        target.animator().frame = final
      }

      target.frame = final
    }

    let size = target.bounds.size

    ghost.image = Self.snapshot(of: target)
    ghost.frame = NSRect(x: ghost.frame.maxX - size.width, y: ghost.frame.minY, width: size.width, height: size.height)
  }

  private static func snapshot(of view: NSView) -> NSImage {
    let image = NSImage(size: view.bounds.size)

    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      image.addRepresentation(bitmap)
    }

    return image
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let (widget, _) = widget(at: convert(event.locationInWindow, from: nil)) else { return nil }

    let menu = NSMenu()

    menu.autoenablesItems = false

    for command in commands(for: widget) {
      if command == .remove {
        menu.addItem(.separator())
      }

      menu.addItem(
        CommandMenuItem(title: command.title, isEnabled: layout(after: command, on: widget) != nil) { [weak self] in
          self?.run(command, on: widget)
        })
    }

    return menu
  }

  enum Command {
    case moveLeft
    case moveRight
    case remove
    case add

    var title: String {
      switch self {
      case .moveLeft: "Move Left"
      case .moveRight: "Move Right"
      case .remove: "Remove from Menu Bar"
      case .add: "Add to Menu Bar"
      }
    }
  }

  func commands(for widget: Widget) -> [Command] {
    preferences.menuBarLayout.isShown(widget) ? [.moveLeft, .moveRight, .remove] : [.add]
  }

  /// Returns nil when `command` cannot be done, such as moving the leftmost widget left.
  func layout(after command: Command, on widget: Widget) -> MenuBarLayout? {
    var layout = preferences.menuBarLayout

    let shown = layout.widgets
    let index = shown.firstIndex(of: widget)

    switch (command, index) {
    case (.moveLeft, let index?) where index > 0:
      layout.place(widget, before: shown[index - 1])
    case (.moveRight, let index?) where index < shown.count - 1:
      layout.place(widget, before: index + 2 < shown.count ? shown[index + 2] : nil)
    case (.remove, _?):
      layout.setShown(false, widget)
    case (.add, nil):
      layout.setShown(true, widget)
    default:
      return nil
    }

    return layout
  }

  /// Works on the layout as it is when the command runs, because VoiceOver can keep an element and its actions
  /// across changes.
  private func run(_ command: Command, on widget: Widget) {
    if let layout = layout(after: command, on: widget) { onLayoutChange(layout) }
  }

  private final class CommandMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, isEnabled: Bool, run: @escaping () -> Void) {
      self.run = run

      super.init(title: title, action: #selector(runCommand), keyEquivalent: "")

      target = self
      self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
      fatalError("CommandMenuItem is not loaded from a nib")
    }

    @objc private func runCommand() {
      run()
    }
  }
}

final class ShelfItem: NSView {
  private static let nameGap: CGFloat = 5

  let widget: Widget
  let menuBarView: MenuBarView
  let name: NSTextField
  private let temperatureUnit: TemperatureUnit
  private let label: String?

  init(_ widget: Widget, preferences: Preferences, style: SettingsStyle) {
    self.widget = widget
    temperatureUnit = preferences.temperatureUnit
    label = preferences.menuBarLayout.label(of: widget)

    menuBarView = MenuBarView(
      layout: MenuBarLayout(widgets: [widget], showsLabels: label != nil) ?? .standard,
      temperatureUnit: temperatureUnit)

    name = NSTextField(labelWithString: widget.title)

    super.init(frame: .zero)

    name.setAccessibilityElement(false)

    name.font = style.subtitleFont
    name.textColor = .secondaryLabelColor

    name.sizeToFit()

    addSubview(menuBarView)
    addSubview(name)
    arrange()
  }

  /// Centers the widget and its name under each other on the display's pixels, because on whole points two widths
  /// that differ by an odd number cannot be centered. Returns whether the item changed size, which a reading that
  /// changes the widget's width can make it do.
  @discardableResult
  func arrange() -> Bool {
    let width = max(menuBarView.frame.width, name.alignmentSize.width)

    func centered(_ size: NSSize, top: CGFloat) -> NSPoint {
      let frame = NSRect(origin: NSPoint(x: (width - size.width) / 2, y: top), size: size)

      return backingAlignedRect(frame, options: .alignAllEdgesNearest).origin
    }

    menuBarView.setFrameOrigin(centered(menuBarView.frame.size, top: 0))
    name.setAlignmentOrigin(centered(name.alignmentSize, top: menuBarView.frame.maxY + Self.nameGap))

    let size = NSSize(width: width, height: name.frame.maxY)

    guard size != frame.size else { return false }

    setFrameSize(size)

    return true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("ShelfItem is not loaded from a nib")
  }

  override var isFlipped: Bool { true }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()

    arrange()
  }

  func matches(_ preferences: Preferences) -> Bool {
    preferences.temperatureUnit == temperatureUnit && preferences.menuBarLayout.label(of: widget) == label
  }
}

/// Draws a box's fill and outline behind other views, as the bar and the shelf have it.
final class SettingsPlate: NSView {
  private let style: SettingsStyle

  init(style: SettingsStyle) {
    self.style = style

    super.init(frame: .zero)

    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("SettingsPlate is not loaded from a nib")
  }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    style.drawBox(on: layer)
  }
}
