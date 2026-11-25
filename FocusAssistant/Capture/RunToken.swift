import Foundation

/// Owned by the monitoring coordinator. A stopped or superseded run cannot publish
/// a delayed permission response, frame result, or status update into a new run.
struct RunToken {
    private(set) var current: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        current = id
        return id
    }

    mutating func cancel() {
        current = nil
    }

    func accepts(_ id: UUID) -> Bool {
        current == id
    }
}

/// A queue-confined sampling decision, not a timer or an inference work queue.
/// Gaps never create catch-up work. Invalid timestamps leave the schedule unchanged.
struct InferenceSchedule {
    let minimumInterval: Double
    private var latestSeenTime: Double?
    private var lastProcessedTime: Double?

    init(minimumInterval: Double = 1) {
        precondition(minimumInterval.isFinite && minimumInterval > 0,
                     "Inference interval must be finite and positive")
        self.minimumInterval = minimumInterval
    }

    mutating func shouldProcess(at monotonicTime: Double) -> Bool {
        guard monotonicTime.isFinite, monotonicTime >= 0 else { return false }
        if let latestSeenTime, monotonicTime <= latestSeenTime { return false }
        latestSeenTime = monotonicTime

        if let lastProcessedTime, monotonicTime - lastProcessedTime < minimumInterval {
            return false
        }
        lastProcessedTime = monotonicTime
        return true
    }

    mutating func reset() {
        latestSeenTime = nil
        lastProcessedTime = nil
    }
}
