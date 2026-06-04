import Foundation
@testable import MagpieCore

// Pure scheduling-decision tests for issue #21. Run via the executable harness
// (swift run MagpieCoreTests).
func runSchedulePlannerTests() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func makeEvent(id: String, startOffset: TimeInterval,
                   status: EventStatus = .accepted, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: "Test \(id)",
                      start: now.addingTimeInterval(startOffset),
                      end: now.addingTimeInterval(startOffset + 1800),
                      status: status, calendar: "Work", allDay: allDay)
    }

    func plan(events: [CalendarEvent], alerted: Set<String> = [],
              activeTimers: Set<String> = []) -> ReconcilePlan {
        SchedulePlanner.planReconcile(events: events, now: now,
                                      alertedIDs: alerted, activeTimerIDs: activeTimers,
                                      leadTime: 30)
    }

    // MARK: chooseReconcileSource
    do {
        let fresh = [makeEvent(id: "a", startOffset: 600)]
        let cached = [makeEvent(id: "old", startOffset: 600)]
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: true, fresh: fresh, cached: cached,
            cacheTimestamp: now.addingTimeInterval(-99_999), now: now)
        TestHarness.check(source == fresh, "success_returns_fresh")
    }
    do {
        let cached = [makeEvent(id: "a", startOffset: 600)]
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: cached,
            cacheTimestamp: now.addingTimeInterval(-60), now: now)
        TestHarness.check(source == cached, "failure_fresh_cache_returns_cached")
    }
    do {
        let cached = [makeEvent(id: "a", startOffset: 600)]
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: cached,
            cacheTimestamp: now.addingTimeInterval(-(4 * 60 * 60) - 1), now: now)
        TestHarness.check(source == nil, "failure_stale_cache_returns_nil")
    }
    do {
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: [],
            cacheTimestamp: now, now: now)
        TestHarness.check(source == nil, "failure_empty_cache_returns_nil")
    }
    do {
        let cached = [makeEvent(id: "a", startOffset: 600)]
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: cached,
            cacheTimestamp: nil, now: now)
        TestHarness.check(source == nil, "failure_no_timestamp_returns_nil")
    }

    // MARK: planReconcile
    do {
        let p = plan(events: [makeEvent(id: "a", startOffset: 360)])
        TestHarness.check(p.cancel == [], "plan_inwindow_no_cancel")
        TestHarness.check(p.schedule.count == 1, "plan_inwindow_one_scheduled")
        TestHarness.check(p.schedule.first?.eventID == "a", "plan_inwindow_id")
        TestHarness.check(TestHarness.approxEqual(p.schedule.first?.fireInterval ?? -1, 330),
                          "plan_inwindow_interval", "got \(p.schedule.first?.fireInterval ?? -1)")
    }
    do {
        let p = plan(events: [makeEvent(id: "a", startOffset: 10)])
        TestHarness.check(p.schedule.count == 1, "plan_pastlead_scheduled")
        TestHarness.check(TestHarness.approxEqual(p.schedule.first?.fireInterval ?? -1, 0.5),
                          "plan_pastlead_immediate", "got \(p.schedule.first?.fireInterval ?? -1)")
    }
    do {
        let p = plan(events: [makeEvent(id: "a", startOffset: -60)])
        TestHarness.check(p.schedule.isEmpty, "plan_paststart_not_scheduled")
        TestHarness.check(p.cancel.isEmpty, "plan_paststart_no_cancel")
    }
    do {
        let p = plan(events: [makeEvent(id: "a", startOffset: 360)], alerted: ["a"])
        TestHarness.check(p.schedule.isEmpty, "plan_alerted_not_scheduled")
    }
    do {
        let p = plan(events: [makeEvent(id: "a", startOffset: 360)], activeTimers: ["a"])
        TestHarness.check(p.schedule.isEmpty, "plan_timed_not_rescheduled")
        TestHarness.check(p.cancel.isEmpty, "plan_timed_not_cancelled")
    }
    do {
        let p = plan(events: [makeEvent(id: "a", startOffset: 360)], activeTimers: ["a", "b"])
        TestHarness.check(p.cancel == ["b"], "plan_leftwindow_cancelled")
        TestHarness.check(p.schedule.isEmpty, "plan_leftwindow_no_schedule")
    }
    do {
        let declined = makeEvent(id: "d", startOffset: 360, status: .declined)
        let allDay = makeEvent(id: "x", startOffset: 360, allDay: true)
        let p = plan(events: [declined, allDay])
        TestHarness.check(p.schedule.isEmpty, "plan_declined_allday_not_scheduled")
    }

    // MARK: shouldArmRetry
    TestHarness.check(SchedulePlanner.shouldArmRetry(fetchSucceeded: false, retryAlreadyScheduled: false),
                      "retry_failure_arms")
    TestHarness.check(!SchedulePlanner.shouldArmRetry(fetchSucceeded: false, retryAlreadyScheduled: true),
                      "retry_no_double_arm")
    TestHarness.check(!SchedulePlanner.shouldArmRetry(fetchSucceeded: true, retryAlreadyScheduled: false),
                      "retry_success_no_arm_1")
    TestHarness.check(!SchedulePlanner.shouldArmRetry(fetchSucceeded: true, retryAlreadyScheduled: true),
                      "retry_success_no_arm_2")

    // MARK: #21 regression — failed poll must still schedule via cache
    do {
        let meeting = makeEvent(id: "standup", startOffset: 200)
        let source = SchedulePlanner.chooseReconcileSource(
            fetchSucceeded: false, fresh: [], cached: [meeting],
            cacheTimestamp: now.addingTimeInterval(-180), now: now)
        TestHarness.check(source == [meeting], "regression_cache_source")
        let p = SchedulePlanner.planReconcile(events: source ?? [], now: now,
                                              alertedIDs: [], activeTimerIDs: [], leadTime: 30)
        TestHarness.check(p.schedule.count == 1, "regression_scheduled")
        TestHarness.check(p.schedule.first?.eventID == "standup", "regression_id")
        TestHarness.check(TestHarness.approxEqual(p.schedule.first?.fireInterval ?? -1, 170),
                          "regression_interval", "got \(p.schedule.first?.fireInterval ?? -1)")
    }
}
