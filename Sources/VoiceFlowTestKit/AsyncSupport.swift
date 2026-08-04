import Foundation

/// A thread-safe box for moving a value out of an async Task into the calling
/// (blocking) test thread without tripping Swift 6 concurrency diagnostics.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Run an async operation to completion from synchronous test code and return
/// its result. Used because the CLT SDK has no XCTest async support.
public func blockingAwait<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task {
        let v = await operation()
        box.set(v)
        sem.signal()
    }
    sem.wait()
    return box.get()!
}
