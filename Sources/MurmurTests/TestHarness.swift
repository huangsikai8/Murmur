import Foundation

/// Minimal assertion harness.
///
/// Exists because XCTest and Swift Testing are both Xcode-only, and this
/// project deliberately carries no package dependencies.
final class TestRunner: @unchecked Sendable {

    private var passedCount = 0
    private var failedCount = 0
    private var failures: [String] = []
    private var currentTest = ""
    private var currentFailures = 0

    private let green = "\u{001B}[32m"
    private let red = "\u{001B}[31m"
    private let dim = "\u{001B}[2m"
    private let bold = "\u{001B}[1m"
    private let reset = "\u{001B}[0m"

    func suite(_ name: String) {
        print("\n\(bold)\(name)\(reset)")
    }

    /// Runs one test case, reporting a single pass/fail line.
    func test(_ name: String, _ body: () async throws -> Void) async {
        currentTest = name
        currentFailures = 0
        do {
            try await body()
        } catch {
            record("threw \(error)")
        }
        if currentFailures == 0 {
            passedCount += 1
            print("  \(green)✓\(reset) \(name)")
        } else {
            failedCount += 1
            print("  \(red)✗\(reset) \(name)")
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard !condition else { return }
        record(message())
    }

    func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: @autoclosure () -> String = ""
    ) {
        guard actual != expected else { return }
        let suffix = message().isEmpty ? "" : " — \(message())"
        record("expected \(inspect(expected)) but got \(inspect(actual))\(suffix)")
    }

    private func inspect<T>(_ value: T) -> String {
        if let string = value as? String { return "\"\(string)\"" }
        return String(describing: value)
    }

    private func record(_ detail: String) {
        currentFailures += 1
        let entry = "\(currentTest): \(detail)"
        failures.append(entry)
        print("      \(red)\(detail)\(reset)")
    }

    /// Prints the summary and returns the process exit code.
    func finish() -> Int32 {
        let total = passedCount + failedCount
        print("\n\(dim)────────────────────────────────────────\(reset)")
        if failedCount == 0 {
            print("\(green)\(bold)All \(total) tests passed.\(reset)\n")
            return 0
        }
        print("\(red)\(bold)\(failedCount) of \(total) tests failed:\(reset)")
        for failure in failures { print("  \(red)•\(reset) \(failure)") }
        print("")
        return 1
    }
}
