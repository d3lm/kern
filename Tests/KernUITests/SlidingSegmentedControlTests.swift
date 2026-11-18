import AppKit
import Testing

@testable import KernUI

@MainActor
struct SlidingSegmentedControlTests {
  let control = SlidingSegmentedControl(labels: ["Adaptive", "Keep intervals"])
  let target = Target()
  let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)

  init() {
    control.target = target
    control.action = #selector(Target.fire)

    window.setContentSize(control.frame.size)
    window.contentView?.addSubview(control)
  }

  func mouse(_ type: NSEvent.EventType, on segment: Int) throws -> NSEvent {
    let frame = control.segmentFrame(segment)

    return try #require(
      NSEvent.mouseEvent(
        with: type, location: control.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  func click(_ segment: Int) throws {
    control.mouseDown(with: try mouse(.leftMouseDown, on: segment))
    control.mouseUp(with: try mouse(.leftMouseUp, on: segment))
  }

  @Test func mouseLetGoOnAnotherOptionChoosesNothingAndAClickLeavesNoFocus() throws {
    control.mouseDown(with: try mouse(.leftMouseDown, on: 0))

    #expect(control.selectedSegment == 0)

    control.mouseUp(with: try mouse(.leftMouseUp, on: 1))

    #expect(control.selectedSegment == 0 && target.fired == 0)
    #expect(control.acceptsFirstResponder == NSApp.isFullKeyboardAccessEnabled)
    #expect(control.acceptsFirstMouse(for: nil))
  }

  @Test func clickOnAnotherOptionMovesTheThumbAndSendsTheAction() throws {
    #expect(control.thumbFrame == control.segmentFrame(0))

    try click(1)

    #expect(control.selectedSegment == 1)
    #expect(control.thumbFrame == control.segmentFrame(1))
    #expect(target.fired == 1)

    try click(1)

    #expect(target.fired == 1)
  }

  @Test func eachOptionIsAsWideAsItsLabel() {
    #expect(control.segmentFrame(0).width < control.segmentFrame(1).width)
    #expect(control.segmentFrame(0).maxX == control.segmentFrame(1).minX)
    #expect(control.frame.width == control.segmentFrame(1).maxX + 2)
  }

  @Test func showingASettingMovesTheThumbWithoutSendingTheAction() {
    control.selectedSegment = 1
    control.selectedSegment = 5

    #expect(control.selectedSegment == 1)
    #expect(control.thumbFrame == control.segmentFrame(1))
    #expect(target.fired == 0)
  }

  @Test func arrowKeysChooseTheNeighboringOption() throws {
    func press(_ key: NSEvent.SpecialKey) throws {
      control.keyDown(
        with: try #require(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: String(Character(UnicodeScalar(key.rawValue)!)),
            charactersIgnoringModifiers: String(Character(UnicodeScalar(key.rawValue)!)), isARepeat: false,
            keyCode: 0)))
    }

    try press(.rightArrow)
    try press(.rightArrow)

    #expect(control.selectedSegment == 1 && target.fired == 1)

    try press(.leftArrow)

    #expect(control.selectedSegment == 0 && target.fired == 2)
  }

  @Test func voiceOverReadsTheOptionsAsRadioButtonsAndPressesThem() throws {
    control.setAccessibilityLabel("When Low Power Mode is on")

    let segments = try #require(control.accessibilityChildren() as? [NSAccessibilityElement])

    #expect(control.accessibilityRole() == .radioGroup)
    #expect(segments.map { $0.accessibilityLabel() } == ["Adaptive", "Keep intervals"])
    #expect(segments.map { $0.accessibilityValue() as? Int } == [1, 0])
    #expect(segments[1].accessibilityPerformPress())
    #expect(control.selectedSegment == 1 && target.fired == 1)

    let again = try #require(control.accessibilityChildren() as? [NSAccessibilityElement])

    #expect(zip(segments, again).allSatisfy { $0 === $1 })
    #expect(segments.map { $0.accessibilityValue() as? Int } == [0, 1])
  }
}
