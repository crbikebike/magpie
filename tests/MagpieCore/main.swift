import Foundation
@testable import MagpieCore

// Minimal assertion harness. There is no XCTest and no runnable Swift Testing
// on this Command Line Tools install (no Xcode; the bundled Testing.framework
// is missing its runtime interop dylib). Tests therefore run as a plain
// executable that exits non-zero on any failure.
//
//   Run all tests:  swift run MagpieCoreTests
//
// Each test suite lives in its own file as a `runXxx()` function that records
// results via TestHarness.check(...). Add new suites to the run list below.
enum TestHarness {
    static var passed = 0
    static var failed = 0

    /// Record a single assertion. `detail` is only evaluated on failure.
    static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            failed += 1
            FileHandle.standardError.write("FAIL: \(name) \(detail())\n".data(using: .utf8)!)
        }
    }

    /// True when two Doubles are within `tol` — for fire-interval assertions.
    static func approxEqual(_ a: Double, _ b: Double, tol: Double = 0.001) -> Bool {
        abs(a - b) < tol
    }

    static func finish() -> Never {
        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

// MARK: - Run list (each task appends its suite here)

runHarnessSmokeTests()
runSchedulePlannerTests()
runCalendarDecodeTests()

TestHarness.finish()
