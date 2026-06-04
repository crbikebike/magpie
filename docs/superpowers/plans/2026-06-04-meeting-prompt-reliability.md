# Pre-meeting Record Prompt Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pre-meeting "record this?" prompt fire reliably by reusing the last-good event list when a fetch fails, retrying failed fetches fast, and polling more often — verified by a new Swift unit-test target.

**Architecture:** Extract the scheduler's timing/state decisions into a pure, side-effect-free `SchedulePlanner` enum (testable without subprocesses or wall-clock timers). `MeetingScheduler` keeps a last-good event cache and reconciles alert timers off it when a live fetch fails, arms a one-shot 90s retry on failure, and runs its base poll every 5 minutes instead of 15. The existing `fireAlert` re-confirm guards against stale-cache phantom prompts.

**Tech Stack:** Swift 5.9, Swift Package Manager (`MagpieCore` library target), AppKit/Foundation/Combine.

> **AMENDMENT (2026-06-04, during execution):** This machine has no Xcode and no
> runnable test framework — Command Line Tools ship neither XCTest nor a working
> Swift Testing (the bundled `Testing.framework` is missing `lib_TestingInterop.dylib`).
> Tests therefore run via a **plain executable target** `MagpieCoreTests` with a tiny
> assert harness (`TestHarness` in `Tests/MagpieCore/main.swift`), run with
> `swift run MagpieCoreTests` (exits non-zero on any failure). Each suite is a
> `runXxx()` function in its own file that records results via `TestHarness.check(...)`,
> added to the run list in `main.swift`. The XCTest code in Tasks 2–5 below is
> superseded by the harness-style equivalents the implementer is given; coverage is
> identical. Task 1 is already implemented this way and committed.

---

## File Structure

- `Sources/SchedulePlanner.swift` — **new**. `ReconcilePlan` value type + pure decision functions (`chooseReconcileSource`, `planReconcile`, `shouldArmRetry`). Foundation-only, no side effects.
- `Sources/MeetingScheduler.swift` — **modify**. Add last-good cache + retry state; route `refresh()` through `SchedulePlanner`; change interval 15→5 min; clear retry on sleep.
- `Package.swift` — **modify**. Add `MagpieCoreTests` test target.
- `Tests/MagpieCore/SchedulePlannerTests.swift` — **new**. Unit tests for the pure decision layer, including the #21 regression test.

All pure logic lives in `SchedulePlanner` so `MeetingScheduler` stays a thin shell. `CalendarEvent`/`EventStatus` (in `CalendarPrompt.swift`) are reused unchanged.

---

## Task 1: Add the test target and prove the harness runs

**Files:**
- Modify: `Package.swift`
- Create: `Tests/MagpieCore/HarnessSmokeTests.swift`

- [ ] **Step 1: Confirm the baseline builds**

Run: `swift build`
Expected: `Build complete!` (no errors). If this fails for a pre-existing reason, stop and report — do not proceed.

- [ ] **Step 2: Add the test target to `Package.swift`**

Replace the entire `targets:` array so it reads:

```swift
    targets: [
        .target(
            name: "MagpieCore",
            path: "Sources",
            exclude: [
                "App.swift",
                "RecorderView.swift",
                "OnboardingView.swift",
                "EqualizerView.swift",
                "FloatingPillView.swift",
            ]
        ),
        .testTarget(
            name: "MagpieCoreTests",
            dependencies: ["MagpieCore"],
            path: "Tests/MagpieCore"
        ),
    ]
```

- [ ] **Step 3: Add a smoke test**

Create `Tests/MagpieCore/HarnessSmokeTests.swift`:

```swift
import XCTest
@testable import MagpieCore

final class HarnessSmokeTests: XCTestCase {
    func testHarnessRuns() {
        XCTAssertEqual(2 + 2, 4)
    }
}
```

- [ ] **Step 4: Run the test target**

Run: `swift test`
Expected: PASS — `Executed 1 test, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/MagpieCore/HarnessSmokeTests.swift
git commit -m "test: add MagpieCoreTests target with smoke test"
```

---

## Task 2: `SchedulePlanner.chooseReconcileSource`

Decides which event list `reconcileAlertTimers` should act on: fresh on success, cached on failure (if cache is within the lookahead window), else nil.

**Files:**
- Create: `Sources/SchedulePlanner.swift`
- Test: `Tests/MagpieCore/SchedulePlannerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MagpieCore/SchedulePlannerTests.swift`:

```swift
import XCTest
@testable import MagpieCore

final class SchedulePlannerTests: XCTestCase {

    // Shared anchor so tests never touch the real wall clock.
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func makeEvent(
        id: String,
        startOffset: TimeInterval,
        status: EventStatus = .accepted,
        allDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            title: "Test \(id)",
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + 1800),
            status: status,
            calendar: "Work",
            allDay: allDay
        )
    }

    // MARK: chooseReconcileSource

    func testSuccessReturnsFreshList() {
        let fresh = [makeEvent(id: "a", startOffset: 600)]
        let cached = [makeEvent(id: "old", startOffset: 600)]
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: true, fresh: fresh, cached: cached,
            cacheTimestamp: now.addingTimeInterval(-99_999), now: now
        )
        XCTAssertEqual(source, fresh)
    }

    func testFailureWithFreshCacheReturnsCached() {
        let cached = [makeEvent(id: "a", startOffset: 600)]
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: cached,
            cacheTimestamp: now.addingTimeInterval(-60), now: now
        )
        XCTAssertEqual(source, cached)
    }

    func testFailureWithStaleCacheReturnsNil() {
        let cached = [makeEvent(id: "a", startOffset: 600)]
        // Cache stamped >4h ago.
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: cached,
            cacheTimestamp: now.addingTimeInterval(-(4 * 60 * 60) - 1), now: now
        )
        XCTAssertNil(source)
    }

    func testFailureWithEmptyCacheReturnsNil() {
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: [],
            cacheTimestamp: now, now: now
        )
        XCTAssertNil(source)
    }

    func testFailureWithNoTimestampReturnsNil() {
        let cached = [makeEvent(id: "a", startOffset: 600)]
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: cached,
            cacheTimestamp: nil, now: now
        )
        XCTAssertNil(source)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SchedulePlannerTests`
Expected: FAIL — `cannot find 'SchedulePlanner' in scope`.

- [ ] **Step 3: Create `SchedulePlanner` with `chooseReconcileSource`**

Create `Sources/SchedulePlanner.swift`:

```swift
// Sources/SchedulePlanner.swift
// Magpie — Pure scheduling decisions extracted from MeetingScheduler so they
// can be unit-tested without subprocesses, real timers, or wall-clock waits.
// No side effects: every function takes its inputs explicitly and returns data.

import Foundation

enum SchedulePlanner {

    /// Choose which event list `reconcileAlertTimers` should act on.
    ///
    /// - On success: the freshly fetched list.
    /// - On failure: the cached list, but only while the cache is within the
    ///   lookahead window. Older than that and every cached event is necessarily
    ///   past its start, so reconciling off it would schedule nothing.
    /// - Otherwise: nil (skip reconcile this cycle and rely on the retry).
    static func chooseReconcileSource(
        fetchSucceeded: Bool,
        fresh: [CalendarEvent],
        cached: [CalendarEvent],
        cacheTimestamp: Date?,
        now: Date,
        freshnessWindow: TimeInterval = CalendarEvent.lookaheadWindow
    ) -> [CalendarEvent]? {
        if fetchSucceeded { return fresh }
        guard let ts = cacheTimestamp, !cached.isEmpty else { return nil }
        if now.timeIntervalSince(ts) > freshnessWindow { return nil }
        return cached
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SchedulePlannerTests`
Expected: PASS — `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchedulePlanner.swift Tests/MagpieCore/SchedulePlannerTests.swift
git commit -m "feat: add SchedulePlanner.chooseReconcileSource with tests"
```

---

## Task 3: `ReconcilePlan` + `SchedulePlanner.planReconcile`

Turns the timer-scheduling decision into pure data: which timers to cancel, which to create (with their fire intervals).

**Files:**
- Modify: `Sources/SchedulePlanner.swift`
- Test: `Tests/MagpieCore/SchedulePlannerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these methods inside `SchedulePlannerTests` (before the closing `}`):

```swift
    // MARK: planReconcile

    func plan(
        events: [CalendarEvent],
        alerted: Set<String> = [],
        activeTimers: Set<String> = []
    ) -> ReconcilePlan {
        SchedulePlanner.planReconcile(
            events: events, now: now,
            alertedIDs: alerted, activeTimerIDs: activeTimers, leadTime: 30
        )
    }

    func testSchedulesInWindowEvent() {
        let e = makeEvent(id: "a", startOffset: 360) // 6 min out
        let p = plan(events: [e])
        XCTAssertEqual(p.cancel, [])
        XCTAssertEqual(p.schedule.count, 1)
        XCTAssertEqual(p.schedule[0].eventID, "a")
        // fireDate = start - 30s = now + 330s.
        XCTAssertEqual(p.schedule[0].fireInterval, 330, accuracy: 0.001)
    }

    func testPastLeadButNotStartedFiresImmediately() {
        let e = makeEvent(id: "a", startOffset: 10) // inside lead window
        let p = plan(events: [e])
        XCTAssertEqual(p.schedule.count, 1)
        XCTAssertEqual(p.schedule[0].fireInterval, 0.5, accuracy: 0.001)
    }

    func testPastStartIsNotScheduled() {
        let e = makeEvent(id: "a", startOffset: -60)
        let p = plan(events: [e])
        XCTAssertTrue(p.schedule.isEmpty)
        XCTAssertTrue(p.cancel.isEmpty)
    }

    func testAlreadyAlertedIsNotScheduled() {
        let e = makeEvent(id: "a", startOffset: 360)
        let p = plan(events: [e], alerted: ["a"])
        XCTAssertTrue(p.schedule.isEmpty)
    }

    func testAlreadyTimedIsNotRescheduled() {
        let e = makeEvent(id: "a", startOffset: 360)
        let p = plan(events: [e], activeTimers: ["a"])
        XCTAssertTrue(p.schedule.isEmpty)
        XCTAssertTrue(p.cancel.isEmpty) // still live → keep it
    }

    func testEventLeftWindowIsCancelled() {
        let e = makeEvent(id: "a", startOffset: 360)
        // "b" had a timer but is no longer in the event set.
        let p = plan(events: [e], activeTimers: ["a", "b"])
        XCTAssertEqual(p.cancel, ["b"])
        XCTAssertTrue(p.schedule.isEmpty) // "a" already timed
    }

    func testDeclinedAndAllDayAreNotScheduled() {
        let declined = makeEvent(id: "d", startOffset: 360, status: .declined)
        let allDay = makeEvent(id: "x", startOffset: 360, allDay: true)
        let p = plan(events: [declined, allDay])
        XCTAssertTrue(p.schedule.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SchedulePlannerTests`
Expected: FAIL — `cannot find 'ReconcilePlan' in scope` / `planReconcile`.

- [ ] **Step 3: Add `ReconcilePlan` and `planReconcile`**

In `Sources/SchedulePlanner.swift`, add above the `enum SchedulePlanner` line:

```swift
/// Result of deciding which alert timers to cancel and which to create.
/// Pure data — `MeetingScheduler` applies it to real `Timer`s.
struct ReconcilePlan: Equatable {
    /// Event IDs whose existing timers should be invalidated (sorted, for
    /// deterministic ordering in tests).
    let cancel: [String]
    /// Timers to create, in event order.
    let schedule: [ScheduledAlert]

    struct ScheduledAlert: Equatable {
        let eventID: String
        /// Seconds from now at which the alert should fire.
        let fireInterval: TimeInterval
    }
}
```

Then add this method inside `enum SchedulePlanner` (after `chooseReconcileSource`):

```swift
    /// Decide which timers to cancel and which to create, given the current
    /// event set and scheduler state. `passesAlertFilters` already excludes
    /// declined, all-day, out-of-window, and past-start events, so no extra
    /// past-start guard is needed here.
    static func planReconcile(
        events: [CalendarEvent],
        now: Date,
        alertedIDs: Set<String>,
        activeTimerIDs: Set<String>,
        leadTime: Int
    ) -> ReconcilePlan {
        let filtered = events.filter { $0.passesAlertFilters(now: now) }
        let liveIDs = Set(filtered.map(\.id))

        let cancel = activeTimerIDs.filter { !liveIDs.contains($0) }.sorted()

        var schedule: [ReconcilePlan.ScheduledAlert] = []
        for event in filtered {
            if alertedIDs.contains(event.id) { continue }
            if activeTimerIDs.contains(event.id) { continue }
            let fireDate = event.alertFireDate(leadTimeSeconds: leadTime)
            let interval = max(0.5, fireDate.timeIntervalSince(now))
            schedule.append(.init(eventID: event.id, fireInterval: interval))
        }
        return ReconcilePlan(cancel: cancel, schedule: schedule)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SchedulePlannerTests`
Expected: PASS — all `SchedulePlannerTests` green (12 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/SchedulePlanner.swift Tests/MagpieCore/SchedulePlannerTests.swift
git commit -m "feat: add ReconcilePlan and SchedulePlanner.planReconcile with tests"
```

---

## Task 4: `SchedulePlanner.shouldArmRetry`

One-line decision, pinned by tests so the retry de-dup behavior can't silently regress.

**Files:**
- Modify: `Sources/SchedulePlanner.swift`
- Test: `Tests/MagpieCore/SchedulePlannerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `SchedulePlannerTests` (before the closing `}`):

```swift
    // MARK: shouldArmRetry

    func testFailureArmsRetry() {
        XCTAssertTrue(SchedulePlanner.shouldArmRetry(
            fetchSucceeded: false, retryAlreadyScheduled: false))
    }

    func testFailureWhileAlreadyArmedDoesNotDoubleArm() {
        XCTAssertFalse(SchedulePlanner.shouldArmRetry(
            fetchSucceeded: false, retryAlreadyScheduled: true))
    }

    func testSuccessNeverArmsRetry() {
        XCTAssertFalse(SchedulePlanner.shouldArmRetry(
            fetchSucceeded: true, retryAlreadyScheduled: false))
        XCTAssertFalse(SchedulePlanner.shouldArmRetry(
            fetchSucceeded: true, retryAlreadyScheduled: true))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SchedulePlannerTests`
Expected: FAIL — `cannot find operator / member 'shouldArmRetry'`.

- [ ] **Step 3: Add `shouldArmRetry`**

In `Sources/SchedulePlanner.swift`, add inside `enum SchedulePlanner` (after `planReconcile`):

```swift
    /// Whether a one-shot retry should be armed after a fetch attempt. Arm only
    /// on failure, and only if one isn't already pending.
    static func shouldArmRetry(fetchSucceeded: Bool, retryAlreadyScheduled: Bool) -> Bool {
        !fetchSucceeded && !retryAlreadyScheduled
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SchedulePlannerTests`
Expected: PASS — `Executed 16 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchedulePlanner.swift Tests/MagpieCore/SchedulePlannerTests.swift
git commit -m "feat: add SchedulePlanner.shouldArmRetry with tests"
```

---

## Task 5: #21 regression test

The test that would have caught the original bug: a meeting enters the window, the catching poll fails, and there's no existing timer — yet cache reuse + the plan still schedule it before start.

**Files:**
- Test: `Tests/MagpieCore/SchedulePlannerTests.swift`

- [ ] **Step 1: Write the regression test**

Append inside `SchedulePlannerTests` (before the closing `}`):

```swift
    // MARK: #21 regression — failed poll must not drop an in-window meeting

    func testFailedPollStillSchedulesViaCache() {
        // A meeting sits 200s out (inside the window, past nothing yet). The
        // poll that should have scheduled it just FAILED, and no timer exists.
        let meeting = makeEvent(id: "standup", startOffset: 200)

        // Cache holds the meeting from an earlier successful poll, stamped 3 min
        // ago — well within the freshness window.
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false,
            fresh: [],
            cached: [meeting],
            cacheTimestamp: now.addingTimeInterval(-180),
            now: now
        )
        // Old behavior bailed here (returned nil) → meeting silently dropped.
        XCTAssertEqual(source, [meeting])

        let plan = SchedulePlanner.planReconcile(
            events: source ?? [], now: now,
            alertedIDs: [], activeTimerIDs: [], leadTime: 30
        )
        XCTAssertEqual(plan.schedule.count, 1)
        XCTAssertEqual(plan.schedule[0].eventID, "standup")
        XCTAssertEqual(plan.schedule[0].fireInterval, 170, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter testFailedPollStillSchedulesViaCache`
Expected: PASS (it exercises functions built in Tasks 2–3).

- [ ] **Step 3: Commit**

```bash
git add Tests/MagpieCore/SchedulePlannerTests.swift
git commit -m "test: add #21 regression — failed poll schedules via cache"
```

---

## Task 6: Wire `MeetingScheduler` to the planner, cache, and retry

Integration task. The subprocess and real `Timer` creation can't be unit-tested (per the spec); correctness of the *decisions* is already covered by Tasks 2–5. This task is verified by `swift build` + `swift test` (no regressions) and the manual check in Task 7.

**Files:**
- Modify: `Sources/MeetingScheduler.swift`

- [ ] **Step 1: Change the poll interval and add retry constants + state**

Replace lines 36-42 (the `pollInterval` doc + declaration through `isRunning`):

```swift
    /// Base polling cadence — fetch upcoming events every 5 minutes. The cache
    /// and fast retry (below) do the heavy lifting, so this needn't be tight.
    private static let baseInterval: TimeInterval = 5 * 60
    /// One-shot retry delay after a failed fetch.
    private static let retryDelay: TimeInterval = 90

    private var pollTimer: DispatchSourceTimer?
    private var alertTimers: [String: Timer] = [:]
    private var alertedEventIDs: Set<String> = []
    private var isRunning = false

    // Last-good event cache — reused for reconciliation when a live fetch
    // fails so a transient error doesn't blind the scheduler. Mutated on the
    // main actor only.
    private var cachedEvents: [CalendarEvent] = []
    private var cacheTimestamp: Date? = nil

    // One-shot retry bookkeeping (main actor only).
    private var retryScheduled = false
    private var retryWorkItem: DispatchWorkItem?
```

- [ ] **Step 2: Update `scheduleNextPoll` to use `baseInterval`**

In `scheduleNextPoll` (around line 100), replace both `Self.pollInterval` occurrences:

```swift
        timer.schedule(deadline: .now() + Self.baseInterval, repeating: Self.baseInterval)
```

- [ ] **Step 3: Rewrite `refresh()` to return success and route through the planner**

Replace the entire `refresh()` method (lines 108-120) with:

```swift
    /// Fetch events, then reconcile timers off the freshest available data
    /// (live result on success, cache on failure) and manage the retry.
    /// Returns whether the live fetch succeeded.
    @discardableResult
    private func refresh() async -> Bool {
        guard isRunning else { return false }
        let fetched: [CalendarEvent]?
        do {
            fetched = try await service.fetchUpcomingEvents()
        } catch {
            log("CalendarService fetch failed: \(error.localizedDescription)",
                vaultPath: await MainActor.run { model?.vaultPath })
            fetched = nil
        }
        let succeeded = fetched != nil
        await MainActor.run {
            self.applyFetchResult(succeeded: succeeded, fresh: fetched ?? [])
        }
        return succeeded
    }

    /// Main-actor sink for a fetch attempt: refresh the cache on success,
    /// reconcile off the chosen source, and arm/cancel the retry.
    @MainActor
    private func applyFetchResult(succeeded: Bool, fresh: [CalendarEvent]) {
        let now = Date()
        if succeeded {
            cachedEvents = fresh
            cacheTimestamp = now
            cancelPendingRetry()
        }
        if let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: succeeded,
            fresh: fresh,
            cached: cachedEvents,
            cacheTimestamp: cacheTimestamp,
            now: now
        ) {
            if !succeeded {
                log("CalendarService fetch failed — reconciling off cached events",
                    vaultPath: model?.vaultPath)
            }
            reconcileAlertTimers(with: source, now: now)
        }
        if SchedulePlanner.shouldArmRetry(
            fetchSucceeded: succeeded, retryAlreadyScheduled: retryScheduled
        ) {
            armRetry()
        }
    }

    // MARK: - Retry

    @MainActor
    private func armRetry() {
        retryScheduled = true
        let work = DispatchWorkItem { [weak self] in
            Task { await self?.runRetry() }
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay, execute: work)
        log("CalendarService fetch failed — retry armed in \(Int(Self.retryDelay))s",
            vaultPath: model?.vaultPath)
    }

    private func runRetry() async {
        await MainActor.run {
            self.retryScheduled = false
            self.retryWorkItem = nil
        }
        await refresh()
    }

    @MainActor
    private func cancelPendingRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        retryScheduled = false
    }
```

- [ ] **Step 4: Rewrite `reconcileAlertTimers` to apply a `ReconcilePlan`**

Replace the entire `reconcileAlertTimers(with:)` method (lines 124-157) with:

```swift
    @MainActor
    private func reconcileAlertTimers(with events: [CalendarEvent], now: Date) {
        let plan = SchedulePlanner.planReconcile(
            events: events,
            now: now,
            alertedIDs: alertedEventIDs,
            activeTimerIDs: Set(alertTimers.keys),
            leadTime: CalendarPrefs.leadTime
        )

        for id in plan.cancel {
            alertTimers[id]?.invalidate()
            alertTimers.removeValue(forKey: id)
        }

        for item in plan.schedule {
            guard let event = events.first(where: { $0.id == item.eventID }) else { continue }
            let timer = Timer.scheduledTimer(withTimeInterval: item.fireInterval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    await self?.fireAlert(for: event)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            alertTimers[event.id] = timer
        }
    }
```

- [ ] **Step 5: Clear the retry on sleep**

In `installSystemObservers`, inside the `willSleepNotification` handler (the block that currently invalidates timers, around lines 193-198), add a line after `self?.alertTimers.removeAll()`:

```swift
            self?.cancelPendingRetry()
```

Note: the surrounding closure runs on `queue: .main` and already mutates `alertTimers` directly, so calling `cancelPendingRetry()` here matches the existing pattern. If the compiler flags main-actor isolation, wrap just this call as `Task { @MainActor in self?.cancelPendingRetry() }`.

- [ ] **Step 6: Build and run the full suite**

Run: `swift build`
Expected: `Build complete!`

Run: `swift test`
Expected: PASS — all tests green, no regressions (`HarnessSmokeTests` + 17 `SchedulePlannerTests`).

- [ ] **Step 7: Commit**

```bash
git add Sources/MeetingScheduler.swift
git commit -m "feat: cache-anchored alert scheduling + fast retry (#21)

Reconcile off the last-good event cache when a fetch fails, arm a 90s
one-shot retry, and shorten the base poll interval to 5 minutes. Routes
all decisions through the tested SchedulePlanner."
```

---

## Task 7: Manual verification

Unit tests cover the decision logic; this confirms the live wiring (subprocess + real timers) end to end. Follows `superpowers:verification-before-completion` — evidence before claiming done.

**Files:** none (verification only).

- [ ] **Step 1: Build the app bundle and enable calendar alerts**

Build/run Magpie the normal way for this repo (the app target, not `swift build`). In Preferences, enable calendar alerts and authorize Google Calendar. Confirm an upcoming meeting (within 4h) appears in the menubar Upcoming list.

- [ ] **Step 2: Confirm the happy path**

Create or pick a real calendar event ~6 minutes out. Wait for a poll (or toggle calendar alerts off/on to force `start()` → immediate fetch). Confirm the floating pill prompts at roughly `start − 30s`.

- [ ] **Step 3: Confirm failure recovery (the actual #21 fix)**

Force a fetch failure: temporarily move the resolved `claude` binary aside (or point `PATH` at a non-existent dir) so the next fetch throws. With a meeting ~3 minutes out:
- Observe in the transcript log: `fetch failed … retry armed in 90s` and, if a prior good fetch exists, `reconciling off cached events`.
- Restore the binary. Confirm the 90s retry recovers and the pill still prompts before the meeting start.

- [ ] **Step 4: Record the result**

Note what was observed (timestamps, log lines, whether the pill fired) in the PR description or a transcript file. If any step failed, return to Task 6 — do not mark the work complete.

- [ ] **Step 5: Final commit (if any verification notes/fixes)**

```bash
git add -A
git commit -m "docs: record #21 manual verification results"
```

---

## Self-Review

**Spec coverage:**
- Last-good cache (spec §1) → Task 2 (`chooseReconcileSource`) + Task 6 (state + `applyFetchResult`). ✓
- Fast retry + 5-min interval (spec §2) → Task 4 (`shouldArmRetry`) + Task 6 (constants, `armRetry`/`runRetry`/`cancelPendingRetry`, `scheduleNextPoll`). ✓
- Threading/lifecycle, sleep clears retry, start() benefits (spec §3) → Task 6 steps 1, 3, 5. ✓
- Logging on cache-reconcile and retry-arm (spec §4) → Task 6 step 3. ✓
- `fireAlert` staleness safety net → unchanged by design; no task needed (verified untouched in Task 6, which does not modify `fireAlert`). ✓
- Test seam: three pure functions + `ReconcilePlan` (spec "Test seam") → Tasks 2, 3, 4. ✓
- Test target via XCTest + `swift test` (spec "Test target") → Task 1. ✓
- All test cases (spec "Test cases") → Tasks 2–4; #21 regression → Task 5. ✓
- Manual verification (spec) → Task 7. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every code step shows complete code. The one conditional ("if the compiler flags main-actor isolation") gives the exact fallback code. ✓

**Type consistency:** `ReconcilePlan { cancel: [String], schedule: [ScheduledAlert] }` and `ScheduledAlert { eventID, fireInterval }` are used identically in Tasks 3 and 6. `chooseReconcileSource`/`planReconcile`/`shouldArmRetry` signatures match between their defining tasks and their call sites in Task 6. `reconcileAlertTimers(with:now:)` is defined and called with the same arity. `CalendarEvent` memberwise init matches its definition in `CalendarPrompt.swift`. ✓
```
