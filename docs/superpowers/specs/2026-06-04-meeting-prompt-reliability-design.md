# Pre-meeting record prompt reliability — design

**Issue:** #21 — Pre-meeting record prompt fires ~1/40 meetings — scheduling window too fragile
**Date:** 2026-06-04
**Status:** Approved (pending spec review)

## Problem

The calendar prompt to record fires roughly once per 40+ meetings. The code path
works (it has been seen firing), but the practical success rate is near zero.

Root cause is structural, not a single bug. `MeetingScheduler` polls the calendar
every **15 minutes** and schedules a per-event `Timer` that fires 30s before each
event start. The fragility:

- **`refresh()` bails entirely on a failed fetch** (`MeetingScheduler.swift:114-118`)
  — it logs and returns without reconciling. One failed poll = no scheduling work
  that cycle.
- **The 15-minute cadence is the only retry.** A meeting that first enters the
  4-hour window between two polls gets exactly one (or zero) chances; if that poll
  fails, the next runs 15 min later, by which time `start.timeIntervalSinceNow < 0`
  and `reconcileAlertTimers` skips it (`MeetingScheduler.swift:147`) — silently and
  permanently.
- **Fetch failures are common.** A cold `claude -p` spawn that starts a model
  session and round-trips to Google can time out (60s) or return non-JSON
  (`jsonParseFailed`, tracked in #19). A single failure is invisible until three
  pile up (amber dot at `consecutiveFailures >= 3`).

### Key structural insight

Per-event `Timer`s **already persist across failed polls** — a failed `refresh()`
never touches existing timers. So once *any* poll succeeds with an event in the
4-hour window, that meeting's alert is locked in. The real defect is the **first
usable read**: if every poll while a meeting is in-window fails — or there simply
was no poll (fresh launch or wake <15 min before start) — the meeting is missed
with no recovery. The fix therefore aims to **guarantee at least one good read per
meeting and never discard a read we already have.**

## Scope

In scope (chosen tier: *Core reliability + optimistic cache*):

- Reuse the last successful event list when a fetch fails, so reconciliation still
  runs through transient failures.
- Fast retry after a failed fetch.
- Shorter base poll interval.
- A Swift unit-test target covering the scheduling decision logic.

Explicitly **out of scope** (deferred):

- UI visibility changes (amber dot at first failure, "last check" tooltip/line).
- Lead time (stays 30s) and lookahead window (stays 4h).
- Subprocess/timeout internals of `CalendarService`.
- `#19` JSON-parse hardening (related but separate).

## Design

### 1. Last-good event cache (`MeetingScheduler`)

Add main-actor-only state:

```swift
private var cachedEvents: [CalendarEvent] = []
private var cacheTimestamp: Date? = nil
```

- **Successful fetch** → replace `cachedEvents`, stamp `cacheTimestamp`, reconcile
  off the fresh list.
- **Failed fetch** → if `cacheTimestamp` is within the 4-hour lookahead, reconcile
  off `cachedEvents` instead of bailing. If the cache is stale or empty, skip
  reconcile (nothing trustworthy) and rely on retry.

Staleness is self-correcting: `fireAlert` (`MeetingScheduler.swift:164-180`) already
re-fetches and re-checks `passesAlertFilters` before prompting, so a timer scheduled
off slightly-stale cache cannot produce a phantom prompt for a cancelled meeting —
it is caught at fire time. No additional staleness logic is required beyond the
freshness bound on the cache itself.

### 2. Fast retry on failure

```swift
private static let baseInterval: TimeInterval = 5 * 60   // was 15 * 60
private static let retryDelay: TimeInterval = 90
private var retryScheduled = false
```

- `refresh()` becomes `@discardableResult func refresh() async -> Bool`, returning
  whether the fetch succeeded.
- On failure, arm a **one-shot retry** in `retryDelay` (the base repeating
  `DispatchSourceTimer` keeps running underneath — the retry is additive).
- `retryScheduled` de-duplicates: a failing base poll does not stack a second retry
  if one is already pending. The flag clears when the retry fires (before it runs).
- A **successful** fetch cancels any pending retry and clears the flag.

### 3. Threading & lifecycle

- All new state (`cachedEvents`, `cacheTimestamp`, `retryScheduled`) is mutated
  **only on `@MainActor`**, inside the existing `MainActor.run` reconcile block — no
  new locks.
- `willSleep` additionally clears `retryScheduled` so a retry armed before sleep
  does not linger across wake.
- `didWake` / `didBecomeActive` paths are unchanged and now strictly better: a
  failed post-wake fetch reconciles off cache instead of leaving zero timers.
- `start()`'s immediate kickoff fetch benefits directly: a failed first fetch arms
  the 90s retry instead of waiting 5 minutes — fixing the "launched right before a
  meeting" miss.

### 4. Logging

Keep the existing failure `log(...)`. Add one-line logs when (a) reconciling off
cache and (b) arming a retry, so transcripts show the recovery path working. No UI
changes.

### Net behavior

A meeting is missed only if **every** fetch — base polls every 5 min **plus** the
90s retry after each failure — fails for the entire time the meeting sits in the
4-hour window. This replaces "one specific poll must succeed."

## Test seam

Extract the decisions from the side effects so they can be unit-tested without a
subprocess, real timers, or wall-clock waits. The scheduler becomes a thin shell
that calls pure functions and applies their results.

1. `chooseReconcileSource(fetchSucceeded:fresh:cached:cacheTimestamp:now:) -> [CalendarEvent]?`
   Fresh events on success; cached events on failure within the 4h freshness bound;
   `nil` otherwise.

2. `planReconcile(events:now:alertedIDs:activeTimerIDs:leadTime:) -> ReconcilePlan`
   Returns `{ cancel: [eventID], schedule: [(eventID, fireInterval)] }`, encoding the
   existing `reconcileAlertTimers` logic (skip alerted, skip past-start, fire
   interval `max(0.5, fireDate - now)`, drop out-of-window) as data. The scheduler
   iterates the plan to create/invalidate real `Timer`s.

3. `shouldArmRetry(fetchSucceeded:retryAlreadyScheduled:) -> Bool`

These live in `MagpieCore` (internal visibility), tested via `@testable import`.
`spawnClaude` and actual `Timer` creation remain untested by unit tests — verified
manually.

### Test target

Add to `Package.swift`:

```swift
.testTarget(name: "MagpieCoreTests", dependencies: ["MagpieCore"], path: "Tests/MagpieCore")
```

Framework: **XCTest** (built into the Swift toolchain, no new dependencies). Run
with `swift test`.

### Test cases (TDD — written first, red before green)

- **Cache source:** success → fresh list; failure + fresh cache → cached list;
  failure + stale cache (>4h) → nil; failure + empty cache → nil.
- **Plan:** in-window unalerted no-timer → scheduled with interval ≈ `start−lead−now`;
  past lead but not started → interval `0.5`; past start → not scheduled; already
  alerted → not scheduled; already has timer → not scheduled; event left window →
  cancelled.
- **Retry:** failure → arm; failure while already armed → do not double-arm; success
  → do not arm.
- **#21 regression:** the issue's exact mechanism — a meeting enters the window, the
  catching poll fails, yet cache reuse + retry still yields a `schedule` entry before
  `start`. This is the test that would have caught the bug.

### Manual verification (post-implementation)

Run the app against a real calendar with a meeting ~6 min out, force a fetch failure
(e.g. temporarily break the resolved binary path), confirm the 90s retry recovers and
the pill prompts at `start − 30s`. Capture in transcripts per
`verification-before-completion`.

## Files touched

- `Sources/MeetingScheduler.swift` — cache state, retry, `refresh()` returns Bool,
  reconcile via extracted plan, sleep clears retry, logging.
- `Sources/CalendarPrompt.swift` *or* a new small file — `ReconcilePlan` value type and
  the pure decision functions (placement decided in the plan).
- `Package.swift` — add `MagpieCoreTests` test target.
- `Tests/MagpieCore/…` — new XCTest cases.

## Risks / open questions

- **Spawn frequency.** 15 → 5 min triples baseline `claude -p` spawns plus retries.
  Expected acceptable (warm fetches <5s); revisit if battery/cost is noticeable.
- **Pure-function placement.** Whether the decision functions live in
  `CalendarPrompt.swift`, `MeetingScheduler.swift`, or a new `SchedulePlanner.swift`
  is an implementation-plan detail.
```
