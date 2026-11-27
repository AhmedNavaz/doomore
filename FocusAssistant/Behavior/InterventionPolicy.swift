import Foundation

/// Pure suppression, break, acknowledgement, and cooldown policy (spec §4.1, §5.2, §5.3).
/// Kept separate from temporal evidence accumulation so reminder throttling never hides
/// underlying posture or lifecycle transitions.
struct InterventionPolicy: Sendable, Equatable {
    private(set) var cooldownUntil: Double?
    private(set) var breakUntil: Double?
    private(set) var notifiedEpisodeIDs: Set<UUID> = []
    private(set) var acknowledgedEpisodeID: UUID?
    /// Set after `backToWork` or `notADistraction` so an episode does not instantly
    /// retrigger while the phone remains visible/away before the user returns to work.
    private(set) var suppressedUntilReturn = false

    func isBreakActive(at now: Double) -> Bool {
        guard let breakUntil, breakUntil.isFinite, now.isFinite else { return false }
        return now < breakUntil
    }

    func breakRemaining(at now: Double) -> Double {
        guard let breakUntil, breakUntil.isFinite, now.isFinite else { return 0 }
        return max(0, breakUntil - now)
    }

    func isCooldownActive(at now: Double) -> Bool {
        guard let cooldownUntil, cooldownUntil.isFinite, now.isFinite else { return false }
        return now < cooldownUntil
    }

    func cooldownRemaining(at now: Double) -> Double {
        guard let cooldownUntil, cooldownUntil.isFinite, now.isFinite else { return 0 }
        return max(0, cooldownUntil - now)
    }

    /// True iff this episode has not already notified or been acknowledged, no break is
    /// active, and the global cooldown has expired.
    func canNotify(episodeID: UUID, at now: Double) -> Bool {
        guard now.isFinite else { return false }
        guard !isBreakActive(at: now) else { return false }
        guard !isCooldownActive(at: now) else { return false }
        guard !suppressedUntilReturn else { return false }
        guard acknowledgedEpisodeID != episodeID else { return false }
        guard !notifiedEpisodeIDs.contains(episodeID) else { return false }
        return true
    }

    mutating func recordNotification(episodeID: UUID, at now: Double, cooldownSeconds: Double) {
        guard now.isFinite else { return }
        notifiedEpisodeIDs.insert(episodeID)
        // Bound stored IDs to prevent unbounded growth in long sessions.
        if notifiedEpisodeIDs.count > 64 {
            notifiedEpisodeIDs = [episodeID]
        }
        if cooldownSeconds > 0 {
            cooldownUntil = max(cooldownUntil ?? now, now + cooldownSeconds)
        }
    }

    mutating func apply(_ action: InterventionAction, episodeID: UUID?, at now: Double, cooldownSeconds: Double) {
        guard now.isFinite else { return }
        switch action {
        case .backToWork, .notADistraction:
            if let episodeID {
                acknowledgedEpisodeID = episodeID
                notifiedEpisodeIDs.insert(episodeID)
            }
            suppressedUntilReturn = true
            if cooldownSeconds > 0 {
                cooldownUntil = max(cooldownUntil ?? now, now + cooldownSeconds)
            }
        case let .takingABreak(duration):
            if let episodeID {
                acknowledgedEpisodeID = episodeID
                notifiedEpisodeIDs.insert(episodeID)
            }
            suppressedUntilReturn = false
            breakUntil = duration > 0 ? now + duration : nil
        }
    }

    /// Clears `suppressedUntilReturn` once the user shows reliable return-to-work evidence.
    mutating func noteReturnedToWork() {
        suppressedUntilReturn = false
    }

    mutating func clearExpiredTimers(at now: Double) {
        guard now.isFinite else { return }
        if let breakUntil, now >= breakUntil {
            self.breakUntil = nil
        }
        if let cooldownUntil, now >= cooldownUntil {
            self.cooldownUntil = nil
        }
    }

    mutating func endBreak() {
        breakUntil = nil
    }

    /// Called on hard lifecycle stops (disable / lock / sleep) so stale suppression
    /// never carries over after recovery, while preserving an explicit break if still set externally.
    mutating func resetEpisodeSuppression() {
        suppressedUntilReturn = false
        acknowledgedEpisodeID = nil
    }
}
