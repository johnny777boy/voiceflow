import Foundation

/// A minimal, dependency-free test harness used in place of XCTest (which is not
/// available with the Command Line Tools SDK). Tests register cases via
/// `suite.test(...)` and assert with `expect*`. The process exits non-zero if any
/// assertion fails, so it behaves like `swift test` for CI and scripts.
public final class TestSuite {
    public private(set) var passed = 0
    public private(set) var failed = 0
    private var currentTest: String = "<none>"
    private var currentFailed = false
    private var failureMessages: [String] = []

    public init() {}

    /// Run a single test case. Any assertion failure inside marks the case failed;
    /// a thrown error also fails the case (with the error described).
    public func test(_ name: String, _ body: (TestSuite) throws -> Void) {
        currentTest = name
        currentFailed = false
        do {
            try body(self)
        } catch {
            recordFailure("threw unexpected error: \(error)", file: #file, line: #line)
        }
        if currentFailed {
            failed += 1
            FileHandle.standardError.write(Data("  ✗ \(name)\n".utf8))
        } else {
            passed += 1
        }
    }

    private func recordFailure(_ message: String, file: StaticString, line: UInt) {
        currentFailed = true
        let entry = "[\(currentTest)] \(message)  (\(file):\(line))"
        failureMessages.append(entry)
        FileHandle.standardError.write(Data("    → \(message)  (\(file):\(line))\n".utf8))
    }

    // MARK: - Assertions

    public func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true",
                       file: StaticString = #file, line: UInt = #line) {
        if !condition { recordFailure(message(), file: file, line: line) }
    }

    public func expectFalse(_ condition: Bool, _ message: @autoclosure () -> String = "expected false",
                            file: StaticString = #file, line: UInt = #line) {
        if condition { recordFailure(message(), file: file, line: line) }
    }

    public func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "",
                                          file: StaticString = #file, line: UInt = #line) {
        if a != b {
            let m = message()
            recordFailure(m.isEmpty ? "expected \(a) == \(b)" : "\(m): \(a) != \(b)", file: file, line: line)
        }
    }

    public func expectNil<T>(_ value: T?, _ message: @autoclosure () -> String = "expected nil",
                             file: StaticString = #file, line: UInt = #line) {
        if value != nil { recordFailure(message(), file: file, line: line) }
    }

    public func expectNotNil<T>(_ value: T?, _ message: @autoclosure () -> String = "expected non-nil",
                                file: StaticString = #file, line: UInt = #line) {
        if value == nil { recordFailure(message(), file: file, line: line) }
    }

    public func expectThrows(_ body: () throws -> Void, _ message: @autoclosure () -> String = "expected throw",
                             file: StaticString = #file, line: UInt = #line) {
        do { try body(); recordFailure(message(), file: file, line: line) }
        catch { /* success */ }
    }

    public func expectNoThrow(_ body: () throws -> Void, _ message: @autoclosure () -> String = "unexpected throw",
                              file: StaticString = #file, line: UInt = #line) {
        do { try body() } catch { recordFailure("\(message()): \(error)", file: file, line: line) }
    }

    public func fail(_ message: String, file: StaticString = #file, line: UInt = #line) {
        recordFailure(message, file: file, line: line)
    }

    // MARK: - Reporting

    /// Print a summary and terminate the process with an appropriate exit code.
    public func finish() -> Never {
        let total = passed + failed
        let line = String(repeating: "─", count: 48)
        print(line)
        if failed == 0 {
            print("✓ All \(total) tests passed.")
        } else {
            print("✗ \(failed) of \(total) tests FAILED:")
            for m in failureMessages { print("   • \(m)") }
        }
        print(line)
        exit(failed == 0 ? 0 : 1)
    }
}
