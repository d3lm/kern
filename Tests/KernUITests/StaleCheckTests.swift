import Synchronization
import Testing

@testable import KernUI

final class HeldSleeps: Sendable {
  private let sleeping = Mutex<[CheckedContinuation<Void, any Error>]>([])

  var count: Int { sleeping.withLock { $0.count } }

  func sleep(until _: ContinuousClock.Instant) async throws {
    try await withCheckedThrowingContinuation { continuation in
      sleeping.withLock { $0.append(continuation) }
    }
  }

  func wakeAll() {
    let woken = sleeping.withLock { sleeping in
      defer { sleeping = [] }

      return sleeping
    }

    for continuation in woken {
      continuation.resume()
    }
  }
}

@MainActor
struct StaleCheckTests {
  let sleeps = HeldSleeps()

  @Test func checkMarksTheValueStaleOnceWhenItWakes() async {
    var marked = 0

    let check = StaleCheck(sleep: sleeps.sleep) { marked += 1 }

    check.schedule(at: .now)

    await waitUntil { sleeps.count == 1 }

    sleeps.wakeAll()

    await waitUntil { marked == 1 }
  }

  @Test func checkThatWokeBeforeANewDeadlineLeavesTheNewValueCurrent() async {
    var marked = 0

    let check = StaleCheck(sleep: sleeps.sleep) { marked += 1 }
    let first = ContinuousClock.now

    check.schedule(at: first)

    await waitUntil { sleeps.count == 1 }

    // the woken check runs only when this test next awaits, so scheduling with no await in between
    // makes the new deadline arrive after the wake but before the check runs
    sleeps.wakeAll()
    check.schedule(at: first + .seconds(1))

    await waitUntil { sleeps.count == 1 }

    #expect(marked == 0)

    sleeps.wakeAll()

    await waitUntil { marked == 1 }
  }

  @Test func noDeadlineCancelsTheCheck() async throws {
    var marked = 0

    let check = StaleCheck { marked += 1 }

    check.schedule(at: .now + .milliseconds(10))
    check.schedule(at: nil)

    try await Task.sleep(for: .milliseconds(600))

    #expect(marked == 0)
  }
}
