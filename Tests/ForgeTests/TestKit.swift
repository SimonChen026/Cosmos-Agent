import Foundation

// Minimal test harness — the Command Line Tools ship neither XCTest nor
// Swift Testing, so forge-tests is a plain executable. Tests run
// sequentially on the main task.

final class TestHarness: @unchecked Sendable {
    static let shared = TestHarness()
    var passed = 0
    var failed = 0
    private var currentFailures = 0
    private var currentName = ""

    func begin(_ name: String) {
        currentName = name
        currentFailures = 0
    }

    func assertFailed(_ message: String, file: StaticString, line: UInt) {
        currentFailures += 1
        print("      ✗ \(file):\(line) \(message)")
    }

    func end(threw error: Error?) {
        if let error {
            currentFailures += 1
            print("      ✗ threw: \(error)")
        }
        if currentFailures == 0 {
            passed += 1
            print("   ✓ \(currentName)")
        } else {
            failed += 1
            print("   ✗ \(currentName) (\(currentFailures) failure\(currentFailures == 1 ? "" : "s"))")
        }
    }
}

func suite(_ name: String) {
    print("\n▸ \(name)")
}

func test(_ name: String, _ body: () async throws -> Void) async {
    TestHarness.shared.begin(name)
    do {
        try await body()
        TestHarness.shared.end(threw: nil)
    } catch {
        TestHarness.shared.end(threw: error)
    }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true",
            file: StaticString = #fileID, line: UInt = #line) {
    if !condition {
        TestHarness.shared.assertFailed(message(), file: file, line: line)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                               _ message: @autoclosure () -> String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected {
        TestHarness.shared.assertFailed(
            "got: \(actual)\n         want: \(expected) \(message())",
            file: file, line: line
        )
    }
}

func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    TestHarness.shared.assertFailed(message, file: file, line: line)
}

func finishTests() -> Never {
    let h = TestHarness.shared
    print("\n\(h.passed + h.failed) tests: \(h.passed) passed, \(h.failed) failed")
    exit(h.failed == 0 ? 0 : 1)
}
