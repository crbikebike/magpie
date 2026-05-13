// Sources/CalendarPrompt.swift
// Magpie — Calendar event data models.
//
// Events come from the Claude.ai Google Calendar connector via a subprocess
// `claude -p` call (see CalendarService). The connector returns events as a
// strict JSON contract that maps directly onto these structs.

import Foundation

// MARK: - Event status

/// Mirrors Google Calendar's `attendee.responseStatus` semantics. Declined
/// events are filtered out before alerting; tentative/needsAction still alert.
enum EventStatus: String, Codable {
    case accepted
    case declined
    case tentative
    case needsAction
}

// MARK: - Calendar event

/// One calendar event in the lookahead window.
///
/// Identifier convention: the connector should return the iCal-style stable
/// event ID (a single instance of a recurring event has a unique ID).
struct CalendarEvent: Codable, Equatable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let status: EventStatus
    let calendar: String
    let allDay: Bool

    /// Convenience — `start - leadTimeSeconds`. The scheduler uses this as the
    /// fire time for the per-event alert timer.
    func alertFireDate(leadTimeSeconds: Int) -> Date {
        start.addingTimeInterval(-TimeInterval(leadTimeSeconds))
    }

    /// True when `start` falls within `[work_start, work_end)` on its own day.
    func isInsideWorkHours(startHour: Int, endHour: Int) -> Bool {
        let cal = Calendar.current
        let h = cal.component(.hour, from: start)
        return h >= startHour && h < endHour
    }
}

// MARK: - Prompt

/// A prompt about to be shown (or showing) for a single event.
/// Stored on RecorderModel as the `pendingPrompt` published property.
struct CalendarPrompt: Equatable {
    let event: CalendarEvent
    let promptedAt: Date

    init(event: CalendarEvent, promptedAt: Date = Date()) {
        self.event = event
        self.promptedAt = promptedAt
    }

    /// Friendly start-time label — "10:00", "9:45 AM" depending on locale.
    var startTimeLabel: String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = nil
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: event.start)
    }
}

// MARK: - Wire format

/// Top-level JSON envelope returned by the Calendar connector subprocess.
struct CalendarFetchResponse: Codable {
    let events: [CalendarEvent]
    let fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case events
        case fetchedAt = "fetched_at"
    }
}
