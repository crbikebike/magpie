// Sources/SchedulePlanner.swift
// Magpie — Pure scheduling decisions extracted from MeetingScheduler so they
// can be unit-tested without subprocesses, real timers, or wall-clock waits.
// No side effects: every function takes its inputs explicitly and returns data.

import Foundation

/// Result of deciding which alert timers to cancel and which to create.
/// Pure data — `MeetingScheduler` applies it to real `Timer`s.
struct ReconcilePlan: Equatable {
    /// Event IDs whose existing timers should be invalidated (sorted, for
    /// deterministic ordering).
    let cancel: [String]
    /// Timers to create, in event order.
    let schedule: [ScheduledAlert]

    struct ScheduledAlert: Equatable {
        let eventID: String
        /// Seconds from now at which the alert should fire.
        let fireInterval: TimeInterval
    }
}

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

    /// Decide which timers to cancel and which to create, given the current
    /// event set and scheduler state. `passesAlertFilters` already excludes
    /// declined, all-day, out-of-window, and past-start events.
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

    /// Whether a one-shot retry should be armed after a fetch attempt. Arm only
    /// on failure, and only if one isn't already pending.
    static func shouldArmRetry(fetchSucceeded: Bool, retryAlreadyScheduled: Bool) -> Bool {
        !fetchSucceeded && !retryAlreadyScheduled
    }
}
