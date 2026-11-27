import Foundation

/// Injectable monotonic clock for elapsed durations (never wall-clock time).
protocol MonotonicClock: Sendable {
    func now() -> Double
}

struct SystemMonotonicClock: MonotonicClock {
    func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}
