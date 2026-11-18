import Foundation
import Testing

@testable import KernUI

struct MenuBarLayoutTests {
  @Test func standardLayoutShowsTemperatureCPUGPUAndMemoryWithLabels() {
    #expect(MenuBarLayout.standard.widgets == [.temperature, .cpu, .gpu, .memory])
    #expect(MenuBarLayout.standard.order == [.temperature, .cpu, .gpu, .memory])
    #expect(MenuBarLayout.standard.hidden.isEmpty)
    #expect(MenuBarLayout.standard.unlabeled.isEmpty)
    #expect(Widget.allCases.map(MenuBarLayout.standard.label) == [nil, "CPU", "GPU", "RAM"])
  }

  @Test func widgetsLeftOutAreHiddenAfterTheListedOnes() throws {
    let layout = try #require(MenuBarLayout(widgets: [.gpu, .cpu], showsLabels: false))

    #expect(layout.widgets == [.gpu, .cpu])
    #expect(layout.order == [.gpu, .cpu, .temperature, .memory])
    #expect(layout.hidden == [.temperature, .memory])
  }

  @Test func layoutWithAWidgetTwiceIsInvalidAndOneWithoutWidgetsShowsNone() {
    #expect(MenuBarLayout(widgets: [.cpu, .gpu, .cpu], showsLabels: true) == nil)
    #expect(MenuBarLayout(widgets: [], showsLabels: true)?.widgets == [])
  }

  @Test func hidingAWidgetKeepsItsPlaceForWhenItIsShownAgain() {
    var layout = MenuBarLayout.standard

    layout.setShown(false, .cpu)

    #expect(layout.widgets == [.temperature, .gpu, .memory])

    layout.setShown(true, .cpu)

    #expect(layout == .standard)
  }

  @Test(arguments: [
    (Widget.temperature, Widget?.some(.memory), [Widget.cpu, .gpu, .temperature, .memory]),
    (.memory, .temperature, [.memory, .temperature, .cpu, .gpu]),
    (.cpu, .memory, [.temperature, .gpu, .cpu, .memory]),
    (.gpu, .cpu, [.temperature, .gpu, .cpu, .memory]),
    (.cpu, .cpu, [.temperature, .cpu, .gpu, .memory]),
    (.cpu, nil, [.temperature, .gpu, .memory, .cpu]),
  ])
  func widgetPlacedBeforeAnotherGoesJustBeforeIt(widget: Widget, target: Widget?, order: [Widget]) {
    var layout = MenuBarLayout.standard

    layout.place(widget, before: target)

    #expect(layout.order == order)
    #expect(layout.widgets == order)
  }

  @Test(arguments: [(Widget.memory, Widget?.none), (.cpu, .memory), (.temperature, .cpu)])
  func widgetPlacedWhereItIsKeepsTheHiddenWidgetsInTheirPlaces(widget: Widget, target: Widget?) {
    var layout = MenuBarLayout.standard

    layout.setShown(false, .gpu)

    let before = layout

    layout.place(widget, before: target)

    #expect(layout == before)
  }

  @Test func hiddenWidgetPlacedInTheMenuBarIsShown() {
    var layout = MenuBarLayout.standard

    layout.setShown(false, .gpu)
    layout.place(.gpu, before: .temperature)

    #expect(layout.widgets == [.gpu, .temperature, .cpu, .memory])
  }

  @Test func widgetPlacedAtTheEndGoesAfterTheShownWidgetsAndBeforeHiddenOnes() {
    var layout = MenuBarLayout.standard

    layout.setShown(false, .memory)
    layout.setShown(false, .gpu)
    layout.place(.gpu, before: nil)

    #expect(layout.order == [.temperature, .cpu, .gpu, .memory])
    #expect(layout.widgets == [.temperature, .cpu, .gpu])
  }

  @Test func widgetPlacedWhenEveryWidgetIsHiddenKeepsItsPlace() {
    var layout = MenuBarLayout(widgets: [], showsLabels: true)!

    layout.place(.memory, before: nil)

    #expect(layout.order == MenuBarLayout.standard.order)
    #expect(layout.widgets == [.memory])
  }

  @Test func propertyListKeepsTheOrderOfHiddenWidgets() throws {
    var layout = MenuBarLayout.standard

    layout.place(.gpu, before: .temperature)
    layout.setShown(false, .temperature)
    layout.setShowsLabel(false, .memory)

    #expect(MenuBarLayout(propertyList: layout.propertyList) == layout)
  }

  @Test func eachWidgetShowsOrHidesItsOwnLabel() {
    var layout = MenuBarLayout.standard

    layout.setShowsLabel(false, .gpu)
    layout.setShowsLabel(false, .temperature)

    #expect(layout.unlabeled == [.gpu])
    #expect(Widget.allCases.map(layout.label) == [nil, "CPU", nil, "RAM"])

    layout.setShowsLabel(true, .gpu)

    #expect(layout == .standard)
  }

  @Test func propertyListListsTheWidgetsWithoutLabels() throws {
    var layout = MenuBarLayout.standard

    layout.setShowsLabel(false, .memory)
    layout.setShowsLabel(false, .cpu)

    #expect(layout.propertyList["unlabeled"] as? [String] == ["cpu", "memory"])
    #expect(layout.propertyList["showsLabels"] == nil)

    let text = "{ widgets = (gpu, cpu); unlabeled = (gpu); showsLabels = NO; }"
    let read = try #require(MenuBarLayout(propertyList: try propertyList(text)))

    #expect(read.unlabeled == [.gpu])
  }

  @Test(arguments: [
    ("{ widgets = (gpu, cpu); showsLabels = 0; }", false),
    ("{ widgets = (gpu, cpu); showsLabels = NO; }", false),
    ("{ widgets = (gpu, cpu); showsLabels = 1; }", true),
    ("{ widgets = (gpu, cpu); showsLabels = YES; }", true),
  ])
  func valueWrittenAsTextBeforeHiddenWidgetsExistedShowsExactlyItsWidgets(text: String, showsLabels: Bool) throws {
    let layout = MenuBarLayout(propertyList: try propertyList(text))

    #expect(layout == MenuBarLayout(widgets: [.gpu, .cpu], showsLabels: showsLabels))
    #expect(layout?.widgets == [.gpu, .cpu])
  }

  @Test func valueWrittenAsTextWithHiddenWidgetsIsRead() throws {
    let text = "{ widgets = (memory, gpu, temperature, cpu); hidden = (gpu); showsLabels = YES; }"
    let layout = try #require(MenuBarLayout(propertyList: try propertyList(text)))

    #expect(layout.order == [.memory, .gpu, .temperature, .cpu])
    #expect(layout.widgets == [.memory, .temperature, .cpu])
  }

  @Test(arguments: [
    "\"temperature, cpu, gpu\"",
    "{ widgets = (gpu, disk); showsLabels = YES; }",
    "{ widgets = (gpu, gpu); showsLabels = YES; }",
    "{ widgets = (gpu); }",
    "{ widgets = (gpu); showsLabels = maybe; }",
    "{ widgets = gpu; showsLabels = YES; }",
    "{ widgets = (gpu); hidden = gpu; showsLabels = YES; }",
    "{ widgets = (gpu); hidden = (disk); showsLabels = YES; }",
    "{ widgets = (gpu); unlabeled = gpu; }",
    "{ widgets = (gpu); unlabeled = (disk); }",
  ])
  func invalidValueIsRefused(text: String) throws {
    #expect(MenuBarLayout(propertyList: try propertyList(text)) == nil)
  }
}
