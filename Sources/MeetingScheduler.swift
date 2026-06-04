// Sources/MeetingScheduler.swift
// Magpie — Polls the calendar every 5 minutes, schedules per-event alert
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
    static let alertsEnabled = "calendarAlertsEnabled"   // Bool, default false

    /// Fixed at 30s — the design's chosen lead time.
    static let leadTime: Int = 30
}

// MARK: - Scheduler

final class MeetingScheduler: @unchecked Sendable {

    private let service: CalendarService
    private weak var model: RecorderModel?

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
        // 5-min cadence rolls around.
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
            self?.cancelPendingRetry()
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
        timer.schedule(deadline: .now() + Self.baseInterval, repeating: Self.baseInterval)
        timer.setEventHandler { [weak self] in
            Task { await self?.refresh() }
        }
        timer.resume()
        pollTimer = timer
    }

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
            // Log the full diagnostic for CalendarServiceError (e.g. the
            // entire non-JSON stdout), not the bounded UI description (#19).
            let detail = (error as? CalendarServiceError)?.diagnosticDetail
                ?? error.localizedDescription
            log("CalendarService fetch failed: \(detail)",
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

    // MARK: - Alert scheduling

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
        guard event.passesAlertFilters(now: Date()) else { return }

        // If the user is already past the start, no prompt — they're late.
        guard event.start.timeIntervalSinceNow > -1 else { return }

        alertedEventIDs.insert(event.id)
        model?.pendingPrompt = CalendarPrompt(event: event)
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
            Task { @MainActor in self?.cancelPendingRetry() }
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
