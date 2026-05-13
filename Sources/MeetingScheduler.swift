// Sources/MeetingScheduler.swift
// Magpie — Polls the calendar every 15 minutes, schedules per-event alert
// timers that fire `leadTimeSeconds` before each event start, and publishes
// CalendarPrompt to RecorderModel for the floating pill to render.
//
// Threading:
//   - Polling timer runs on a background dispatch queue (DispatchSourceTimer).
//   - Per-event alert timers run on the main RunLoop (Foundation.Timer).
//   - All mutations of @Published state happen on the main actor.
//
// Dedup:
//   - alertedEventIDs holds event ids that have already fired this lifetime
//     of the app — keeps re-scheduled refreshes from re-prompting the same
//     meeting after the user clicked Skip. Cleared on calendar-alerts off→on.

import AppKit
import Combine
import Foundation

// MARK: - UserDefaults keys

enum CalendarPrefs {
    static let alertsEnabled        = "calendarAlertsEnabled"        // Bool, default false
    static let leadTimeSeconds      = "calendarLeadTimeSeconds"      // Int, default 30
    static let watchedCalendars     = "calendarWatchedCalendars"     // [String]
    static let workStartHour        = "calendarWorkStartHour"        // Int, default 8
    static let workEndHour          = "calendarWorkEndHour"          // Int, default 18
    static let blockList            = "calendarBlockList"            // [String]

    static var leadTime: Int {
        // 0 is a valid user choice ("the moment a meeting starts"), so treat
        // an absent key as default 30 rather than treating 0 as unset.
        guard UserDefaults.standard.object(forKey: leadTimeSeconds) != nil else { return 30 }
        return UserDefaults.standard.integer(forKey: leadTimeSeconds)
    }
    static var workStart: Int {
        let v = UserDefaults.standard.object(forKey: workStartHour) as? Int
        return v ?? 8
    }
    static var workEnd: Int {
        let v = UserDefaults.standard.object(forKey: workEndHour) as? Int
        return v ?? 18
    }
    static var watched: Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: watchedCalendars) ?? []
        return Set(arr)
    }
    static var blocked: [String] {
        UserDefaults.standard.stringArray(forKey: blockList) ?? []
    }
}

// MARK: - Scheduler

final class MeetingScheduler: @unchecked Sendable {

    private let service: CalendarService
    private weak var model: RecorderModel?

    /// Polling cadence — fetch upcoming events every 15 minutes.
    private static let pollInterval: TimeInterval = 15 * 60

    /// 4-hour lookahead window — must match the CalendarService prompt.
    private static let lookaheadWindow: TimeInterval = 4 * 60 * 60

    private var pollTimer: DispatchSourceTimer?
    private var alertTimers: [String: Timer] = [:]
    private var alertedEventIDs: Set<String> = []
    private var isRunning = false

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    init(service: CalendarService, model: RecorderModel) {
        self.service = service
        self.model = model
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        alertedEventIDs.removeAll()
        installSystemObservers()
        scheduleNextPoll()
        // Kick off an immediate fetch so the first alert can fire before the
        // 15-min cadence rolls around.
        Task { await self.refresh() }
    }

    func stop() {
        isRunning = false
        pollTimer?.cancel()
        pollTimer = nil
        for (_, t) in alertTimers { t.invalidate() }
        alertTimers.removeAll()
        removeSystemObservers()
        DispatchQueue.main.async { [weak self] in
            self?.model?.pendingPrompt = nil
        }
    }

    /// Force a refetch now — used by RecorderView's preferences when the user
    /// changes the watched-calendars selection.
    func forceRefresh() {
        Task { await self.refresh() }
    }

    /// Dismiss the current prompt and remember the event ID so a later
    /// refresh doesn't re-prompt for the same meeting.
    @MainActor
    func dismissCurrentPrompt(rememberEventID id: String?) {
        if let id { alertedEventIDs.insert(id) }
        model?.pendingPrompt = nil
    }

    // MARK: - Poll loop

    private func scheduleNextPoll() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            Task { await self?.refresh() }
        }
        timer.resume()
        pollTimer = timer
    }

    /// Fetch events, prune stale alert timers, schedule new ones.
    private func refresh() async {
        guard isRunning else { return }
        let events: [CalendarEvent]
        do {
            events = try await service.fetchUpcomingEvents()
        } catch {
            log("CalendarService fetch failed: \(error.localizedDescription)",
                vaultPath: await MainActor.run { model?.vaultPath })
            return
        }
        await MainActor.run { self.reconcileAlertTimers(with: events) }
    }

    // MARK: - Alert scheduling

    @MainActor
    private func reconcileAlertTimers(with events: [CalendarEvent]) {
        let leadTime = CalendarPrefs.leadTime
        let now = Date()
        let filtered = events.filter { passesFilters($0, now: now) }

        let liveIDs = Set(filtered.map(\.id))

        // Drop timers for events no longer in the window.
        for id in alertTimers.keys where !liveIDs.contains(id) {
            alertTimers[id]?.invalidate()
            alertTimers.removeValue(forKey: id)
        }

        // Schedule timers for new events (skip already-alerted or in-the-past).
        for event in filtered {
            guard !alertedEventIDs.contains(event.id) else { continue }
            guard alertTimers[event.id] == nil else { continue }

            let fireDate = event.alertFireDate(leadTimeSeconds: leadTime)
            // If we're already past the lead-time window but the event hasn't
            // started yet, fire immediately. Past-start events are skipped.
            let interval = max(0.5, fireDate.timeIntervalSinceNow)
            if event.start.timeIntervalSinceNow < 0 { continue }

            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    await self?.fireAlert(for: event)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            alertTimers[event.id] = timer
        }
    }

    @MainActor
    private func fireAlert(for event: CalendarEvent) async {
        alertTimers[event.id]?.invalidate()
        alertTimers.removeValue(forKey: event.id)

        // Re-fetch once to confirm the event still exists — covers cancelled
        // or rescheduled meetings between poll and fire.
        let stillExists: Bool
        do {
            let latest = try await service.fetchUpcomingEvents()
            stillExists = latest.contains(where: { $0.id == event.id })
        } catch {
            // If the confirm fetch fails, trust the cached event and prompt.
            stillExists = true
        }
        guard stillExists else { return }

        // Filters could have flipped (work hours rolled over, blocklist edit).
        guard passesFilters(event, now: Date()) else { return }

        // If the user is already past the start, no prompt — they're late.
        guard event.start.timeIntervalSinceNow > -1 else { return }

        alertedEventIDs.insert(event.id)
        model?.pendingPrompt = CalendarPrompt(event: event)
    }

    // MARK: - Filters

    private func passesFilters(_ event: CalendarEvent, now: Date) -> Bool {
        // Declined → silent.
        if event.status == .declined { return false }
        // All-day → silent (doesn't represent a recordable meeting).
        if event.allDay { return false }
        // Outside lookahead window.
        if event.start.timeIntervalSince(now) > Self.lookaheadWindow { return false }
        // Past-start: only allowed by fireAlert's late-join handling.
        if event.start.timeIntervalSinceNow < 0 { return false }
        // Watched-calendar filter (empty = match all).
        let watched = CalendarPrefs.watched
        if !watched.isEmpty && !watched.contains(event.calendar) {
            return false
        }
        // Work-hours filter — uses the event's start hour in the local zone.
        if !event.isInsideWorkHours(
            startHour: CalendarPrefs.workStart,
            endHour: CalendarPrefs.workEnd
        ) {
            return false
        }
        // Block-list — case-insensitive substring match against title.
        let title = event.title.lowercased()
        for keyword in CalendarPrefs.blocked
            where !keyword.isEmpty && title.contains(keyword.lowercased()) {
            return false
        }
        return true
    }

    // MARK: - System observers (sleep, wake, app foreground)

    private func installSystemObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Invalidate timers — they'll re-fire on the wrong wall clock
            // after wake. We'll re-schedule on the next refresh.
            for (_, t) in self?.alertTimers ?? [:] { t.invalidate() }
            self?.alertTimers.removeAll()
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    private func removeSystemObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        if let s = sleepObserver { nc.removeObserver(s); sleepObserver = nil }
        if let w = wakeObserver  { nc.removeObserver(w); wakeObserver = nil }
        if let f = foregroundObserver {
            NotificationCenter.default.removeObserver(f)
            foregroundObserver = nil
        }
    }
}
