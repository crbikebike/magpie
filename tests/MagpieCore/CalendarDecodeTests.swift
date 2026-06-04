import Foundation
@testable import MagpieCore

// Issue #19: when the calendar fetch subprocess returns non-JSON, decode()
// must (a) distinguish *empty* output (subprocess exited cleanly but produced
// nothing) from *prose* (claude ignored the strict-JSON instruction), and
// (b) carry the FULL raw stdout for the vault log — not just a 200-char
// preview — while keeping `errorDescription` bounded for the UI chip.
func runCalendarDecodeTests() {
    let valid = #"{"events": [], "fetched_at": "2026-01-01T00:00:00+00:00"}"#

    // Stage 1: a clean strict envelope decodes.
    do {
        let resp = try CalendarService.decode(output: valid)
        TestHarness.check(resp.events.isEmpty, "decode_valid_empty_events")
    } catch {
        TestHarness.check(false, "decode_valid_empty_events", "threw \(error)")
    }

    // Stage 2: a code-fenced envelope still decodes.
    do {
        _ = try CalendarService.decode(output: "```json\n\(valid)\n```")
        TestHarness.check(true, "decode_fenced_json")
    } catch {
        TestHarness.check(false, "decode_fenced_json", "threw \(error)")
    }

    // Empty / whitespace-only stdout => .emptyOutput (distinct from prose).
    for (raw, name) in [("", "decode_empty_string"), ("   \n\t ", "decode_whitespace_only")] {
        do {
            _ = try CalendarService.decode(output: raw)
            TestHarness.check(false, name, "expected emptyOutput, got success")
        } catch CalendarServiceError.emptyOutput {
            TestHarness.check(true, name)
        } catch {
            TestHarness.check(false, name, "expected emptyOutput, got \(error)")
        }
    }

    // Non-JSON prose => .jsonParseFailed carrying the FULL output.
    let prose = String(repeating: "I'm sorry, I can't reach the calendar right now. ", count: 10)
    do {
        _ = try CalendarService.decode(output: prose)
        TestHarness.check(false, "decode_prose_throws", "expected jsonParseFailed")
    } catch let CalendarServiceError.jsonParseFailed(rawOutput) {
        TestHarness.check(rawOutput == prose, "decode_prose_full_raw_output",
                          "raw len \(rawOutput.count) != \(prose.count)")
        let err = CalendarServiceError.jsonParseFailed(rawOutput: rawOutput)
        // Full diagnostic (for the vault log) includes the entire output.
        TestHarness.check(err.diagnosticDetail.contains(prose),
                          "diagnostic_detail_contains_full_output")
        // UI description stays bounded (the chip truncates anyway).
        TestHarness.check((err.errorDescription ?? "").count < prose.count,
                          "error_description_bounded")
    } catch {
        TestHarness.check(false, "decode_prose_throws", "expected jsonParseFailed, got \(error)")
    }
}
