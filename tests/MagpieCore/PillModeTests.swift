import Foundation
@testable import MagpieCore

// Covers `PillMode.resolve` — the single source of truth for the floating
// pill's visibility/mode, shared by RecorderModel.pillMode and App's Combine
// pipeline. Regression guard for issue #22: a transcription still processing
// after recording stops must NOT keep the recording pill on-screen.
func runPillModeTests() {
    TestHarness.check(
        PillMode.resolve(isRecording: false, hasPrompt: false) == .hidden,
        "pill_hidden_when_idle")
    TestHarness.check(
        PillMode.resolve(isRecording: true, hasPrompt: false) == .recording,
        "pill_recording_when_active")
    TestHarness.check(
        PillMode.resolve(isRecording: false, hasPrompt: true) == .idlePrompt,
        "pill_idle_prompt_when_pending")
    TestHarness.check(
        PillMode.resolve(isRecording: true, hasPrompt: true) == .recordingWithDrawer,
        "pill_drawer_when_recording_with_prompt")

    // Issue #22: not recording + transcript still processing => hidden.
    // `hasPrompt` is false because transcription state no longer feeds the
    // pill at all; the pill follows isRecording only.
    TestHarness.check(
        PillMode.resolve(isRecording: false, hasPrompt: false) == .hidden,
        "pill_hidden_while_transcribing_after_stop")
}
