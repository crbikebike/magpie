import Foundation
@testable import MagpieCore

// Proves the harness runs and `@testable import MagpieCore` reaches internal
// symbols (a real CalendarEvent is constructed below).
func runHarnessSmokeTests() {
    TestHarness.check(2 + 2 == 4, "harness_runs")

    let probe = CalendarEvent(
        id: "probe", title: "Probe",
        start: Date(timeIntervalSince1970: 1_700_000_600),
        end: Date(timeIntervalSince1970: 1_700_002_400),
        status: .accepted, calendar: "Work", allDay: false
    )
    TestHarness.check(probe.id == "probe", "testable_import_works")
}
