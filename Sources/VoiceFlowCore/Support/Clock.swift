import Foundation

/// An injectable time source so latency measurement and history timestamps are
/// deterministic in tests.
public protocol TimeSource: Sendable {
    /// Monotonic-ish seconds for measuring durations.
    func now() -> TimeInterval
    /// Wall-clock date for timestamps.
    func date() -> Date
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }
    public func date() -> Date { Date() }
}

/// A controllable time source for tests.
public final class MockTimeSource: TimeSource, @unchecked Sendable {
    private var current: TimeInterval
    private let fixedDate: Date
    public init(start: TimeInterval = 0, date: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.current = start
        self.fixedDate = date
    }
    public func advance(by seconds: TimeInterval) { current += seconds }
    public func now() -> TimeInterval { current }
    public func date() -> Date { fixedDate }
}
