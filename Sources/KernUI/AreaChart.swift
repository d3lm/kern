import AppKit
import KernCore

enum AreaChart {
  static func path(_ levels: [Double?], smoothing radius: Int, in plot: CGRect, pixel: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()

    for area in areas(smoothed(levels, radius: radius), in: plot, pixel: pixel) {
      path.move(to: area[0])

      for point in area.dropFirst() {
        path.line(to: point)
      }

      path.close()
    }

    return path
  }

  static func smoothed(_ levels: [Double?], radius: Int) -> [Double?] {
    levels.indices.map { slot in
      guard levels[slot] != nil else { return nil }

      var neighbors: [Double] = []
      var before = slot

      while before > slot - radius, before > levels.startIndex, let level = levels[before - 1] {
        neighbors.append(level)
        before -= 1
      }

      var after = slot

      while after < slot + radius, after < levels.endIndex - 1, let level = levels[after + 1] {
        neighbors.append(level)
        after += 1
      }

      let all = neighbors + [levels[slot]!]

      return all.reduce(0, +) / Double(all.count)
    }
  }

  static func areas(_ levels: [Double?], in plot: CGRect, pixel: CGFloat) -> [[CGPoint]] {
    let slotWidth = plot.width / CGFloat(levels.count)
    var areas: [[CGPoint]] = []
    var run: [(slot: Int, top: CGFloat)] = []

    func closeRun() {
      guard let first = run.first, let last = run.last else { return }

      let start = plot.minX + CGFloat(first.slot) * slotWidth
      let end = plot.minX + CGFloat(last.slot + 1) * slotWidth
      let line = run.map { CGPoint(x: plot.minX + (CGFloat($0.slot) + 0.5) * slotWidth, y: $0.top) }

      areas.append(
        [CGPoint(x: start, y: plot.minY), CGPoint(x: start, y: first.top)]
          + line
          + [CGPoint(x: end, y: last.top), CGPoint(x: end, y: plot.minY)]
      )

      run = []
    }

    for (slot, level) in levels.enumerated() {
      guard let level else {
        closeRun()
        continue
      }

      run.append((slot, plot.minY + max(pixel, plot.height * level / 100)))
    }

    closeRun()

    return areas
  }
}

extension SampleHistory {
  var levels: [Double?] {
    [Double?](repeating: nil, count: capacity - count) + map { $0.value?.value }
  }
}
