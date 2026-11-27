import Foundation

/// Pure temporal behavioral state machine (Milestone 1, spec §5 & §13.2).
///
/// Consumes monotonic timestamps, `WorkContextSnapshot`, and `BehaviorEvidence`, and
/// emits `BehaviorSnapshot` values with interpretable reason codes and optional
/// `InterventionEvent` triggers. Contains no camera, clock, workspace, or notification
/// calls, so every transition and edge case is deterministically unit-tested.
struct BehaviorEngine: Sendable {
    /// Tunable hypotheses from spec §5.1 and §13.2. Configurable in code for Milestone 1.
    struct Rules: Sendable, Equatable {
        /// Number of recent valid samples considered for candidate activation.
        var candidateWindowSamples = 5
        /// Positive samples required within `candidateWindowSamples` to enter `.candidate`.
        var candidatePositiveSamples = 3
        /// Minimum monotonic span of confirming positive samples to activate `.candidate`.
        var candidateMinSpanSeconds = 2.0
        /// Keyboard and pointer idle threshold required alongside away posture (spec §5.1).
        /// Idle alone never activates a candidate or reminder.
        var idleCorroborationSeconds = 6.0
        /// Input within this window counts as active typing/mousing (reliable negative evidence).
        var inputActiveSeconds = 3.0
        /// Sustained corroborated phone-away duration before emitting a reminder (spec §5.1, §13.2).
        /// Absorbs quick replies, MFA checks, and music changes even with headphones.
        var episodeGraceSeconds = 25.0
        /// Brief dropout tolerance; missing or negative frames never add positive duration.
        var dropoutToleranceSeconds = 3.0
        /// Stale/unknown evidence timeout before suppressing and resetting any active candidate.
        var staleEvidenceSeconds = 5.0
        /// Maximum single-step gap credited as continuous positive time (accommodates 1–2 Hz
        /// sampling with jitter while ensuring longer dropouts/stalls add zero invented duration).
        var maxStepSeconds = 1.5
        /// Reliable negative evidence duration needed to close an episode as returned to work.
        var returnToWorkSeconds = 5.0
        /// Global reminder cooldown after a reminder or dismissal (spec §5.1).
        var cooldownSeconds = 120.0
        /// Default intentional break length (spec §5.1).
        var defaultBreakSeconds = 300.0
        /// Minimum positive duration for an unnotified ended episode to count as a short pickup (§13.2).
        var shortPickupMinSeconds = 15.0
        /// Rolling window for fragmented-focus pickup counting (12 min; spec §13.2 recommends 10–15 min).
        var pickupWindowSeconds = 720.0
        /// Total pickups (completed in window + current qualifying pickup) that trigger a reminder.
        /// Set to 0 to disable the repeated-pickup rule.
        var pickupThresholdCount = 4
        /// Idle-at-desk rule (added 27 Nov 2026). A phone held high barely tilts the head, so the
        /// posture episode above flickers and keeps restarting (12.5 s peak in that day's guided
        /// behavior test). This rule instead measures one stretch without keyboard or mouse while the
        /// person is at the desk (starting once input has been idle `idleCorroborationSeconds`), and
        /// the share of it with any sign of looking elsewhere, strong or soft. Input ends the stretch.
        /// Seconds of stretch, and cue share, for the first tier. Zero turns the tier off.
        var idleStretchCueSeconds = 45.0
        var idleStretchCueShare = 0.5
        /// Second tier: a longer stretch with fewer cues. Staring at the screen with no cue at all
        /// (watching a build, an AI agent or a long read) never fires on its own. Zero turns it off.
        var idleStretchLongSeconds = 150.0
        var idleStretchLongCueShare = 0.25
        /// Plain tier: this long at the desk with no keyboard or mouse reminds whatever the head
        /// does. Catches a phone held at eye level, at the cost of also reminding during a long
        /// read. Zero (the default) turns it off; only the Quick test sensitivity uses it.
        var idleStretchPlainSeconds = 0.0
    }

    private struct ValidSample: Sendable, Equatable {
        var time: Double
        var positive: Bool
    }

    var rules: Rules
    private(set) var policy: InterventionPolicy
    private(set) var snapshot: BehaviorSnapshot

    private var stateSince: Double = 0
    private var lastSampleTime: Double?
    private var lastValidEvidenceTime: Double?
    private var unknownSince: Double?
    private var recentValidSamples: [ValidSample] = []

    // Active candidate / sustained episode tracking
    private var episodeID: UUID?
    private var episodeNotified = false
    private var evidenceDuration: Double = 0
    private var lastPositiveTime: Double?
    private var previousSampleWasPositive = false
    private var negativeSince: Double?
    private var sustainedTriggered = false
    private var triggeredKind: InterventionKind?

    // Idle-at-desk stretch tracking (see `Rules.idleStretchCueSeconds`)
    private var stretchID: UUID?
    private var stretchSeconds = 0.0
    private var stretchCueSeconds = 0.0
    private var stretchLastTime: Double?
    private var stretchNotified = false

    // Rolling timestamps of completed short pickups (spec §13.2)
    private var completedPickups: [Double] = []

    init(rules: Rules = Rules(), policy: InterventionPolicy = InterventionPolicy(), startTime: Double = 0) {
        self.rules = rules
        self.policy = policy
        self.stateSince = startTime
        self.snapshot = .initial(at: startTime)
    }

    /// Processes a new perception sample at monotonic timestamp `evidence.time`.
    @discardableResult
    mutating func step(context: WorkContextSnapshot, evidence: BehaviorEvidence) -> BehaviorSnapshot {
        let now = evidence.time
        guard now.isFinite else {
            return publish(
                state: snapshot.state,
                at: snapshot.lastUpdate,
                reasons: [.lowQualityOrUnknown],
                intervention: nil,
                context: context
            )
        }

        policy.clearExpiredTimers(at: now)
        prunePickups(at: now)

        if let gated = evaluateHardGates(at: now, context: context) {
            resetStretch()
            lastSampleTime = now
            return gated
        }

        // Reject out-of-order timestamps without inventing duration or rewinding state.
        if let prev = lastSampleTime, now < prev {
            return publish(
                state: snapshot.state,
                at: prev,
                reasons: [.lowQualityOrUnknown],
                intervention: nil,
                context: context
            )
        }

        // Long gap between samples: evidence went stale; never credit gap time.
        if let prev = lastSampleTime, now - prev > rules.staleEvidenceSeconds {
            clearEpisode(clearSamples: true)
            resetStretch()
            unknownSince = nil
            policy.noteReturnedToWork()
        }
        lastSampleTime = now

        // Handle non-valid perception quality explicitly (spec §5.1, §6.2, §7.1).
        switch evidence.quality {
        case .multiplePeople:
            clearEpisode(clearSamples: true)
            resetStretch()
            unknownSince = nil
            return publishIdleOrCooldown(at: now, extraReason: .multiplePeopleInView, context: context)
        case .noPerson:
            clearEpisode(clearSamples: true)
            resetStretch()
            unknownSince = nil
            return publishIdleOrCooldown(at: now, extraReason: .noPersonInView, context: context)
        case .calibrating:
            clearEpisode(clearSamples: true)
            resetStretch()
            unknownSince = nil
            return publishIdleOrCooldown(at: now, extraReason: .calibrating, context: context)
        case .unknown:
            previousSampleWasPositive = false
            if unknownSince == nil { unknownSince = now }
            if let since = unknownSince, now - since >= rules.staleEvidenceSeconds {
                clearEpisode(clearSamples: true)
                resetStretch()
                return publishIdleOrCooldown(at: now, extraReason: .lowQualityOrUnknown, context: context)
            }
            // Suspended during brief unknown/occlusion: never add positive duration or alert.
            return publishCurrentWith(reason: .lowQualityOrUnknown, at: now, context: context)
        case .valid:
            unknownSince = nil
            lastValidEvidenceTime = now
        }

        let isInputActive = evidence.inputIdleSeconds.isFinite && evidence.inputIdleSeconds < rules.inputActiveSeconds
        let isIdleCorroborated = evidence.inputIdleSeconds.isFinite && evidence.inputIdleSeconds >= rules.idleCorroborationSeconds
        // Positive requires BOTH away posture AND idle corroboration. Idle alone is never positive.
        let isPositive = evidence.awayFromScreen && isIdleCorroborated
        let isReliableNegative = !evidence.awayFromScreen || isInputActive

        // If user dismissed/acknowledged an episode while still away, stay suppressed until
        // they show reliable return-to-work evidence (spec §5.3).
        if policy.suppressedUntilReturn {
            previousSampleWasPositive = false
            if isReliableNegative {
                if negativeSince == nil { negativeSince = now }
                if let since = negativeSince, now - since >= rules.returnToWorkSeconds {
                    policy.noteReturnedToWork()
                    negativeSince = nil
                }
            } else {
                negativeSince = nil
            }
            if policy.suppressedUntilReturn {
                return publishIdleOrCooldown(at: now, extraReason: .episodeAcknowledged, context: context)
            }
        }

        recordValidSample(ValidSample(time: now, positive: isPositive))

        if episodeID == nil {
            negativeSince = nil
            if isPositive, let initialDuration = candidateActivationDuration() {
                episodeID = UUID()
                episodeNotified = false
                sustainedTriggered = false
                triggeredKind = nil
                evidenceDuration = initialDuration
                lastPositiveTime = now
                previousSampleWasPositive = true
            } else {
                previousSampleWasPositive = isPositive
            }
        } else {
            if isPositive {
                negativeSince = nil
                if previousSampleWasPositive, let prevPos = lastPositiveTime {
                    let dt = now - prevPos
                    // Credit only bounded consecutive positive intervals; dropout gaps add zero time.
                    if dt > 0 && dt <= rules.maxStepSeconds {
                        evidenceDuration += dt
                    }
                }
                lastPositiveTime = now
                previousSampleWasPositive = true
            } else if isReliableNegative {
                previousSampleWasPositive = false
                if negativeSince == nil { negativeSince = now }
                if let since = negativeSince, now - since >= rules.returnToWorkSeconds {
                    // User reliably returned to work; record short pickup if eligible (spec §13.2).
                    if !episodeNotified && evidenceDuration >= rules.shortPickupMinSeconds {
                        completedPickups.append(now)
                    }
                    clearEpisode(clearSamples: true)
                }
            } else {
                // Ambiguous transitional sample (e.g. away posture before idle corroboration):
                // adds zero positive time, does not count as reliable return-to-work.
                previousSampleWasPositive = false
                if let prevPos = lastPositiveTime, now - prevPos >= rules.staleEvidenceSeconds {
                    clearEpisode(clearSamples: true)
                }
            }
        }

        updateStretch(evidence: evidence, at: now, isInputActive: isInputActive, isIdleCorroborated: isIdleCorroborated)

        // Evaluate sustained / fragmented-focus intervention only with fresh positive evidence.
        var emitted: InterventionEvent?
        if let currentEpisodeID = episodeID {
            let sustainedReached = evidenceDuration >= rules.episodeGraceSeconds
            let currentQualifiesAsPickup = evidenceDuration >= rules.shortPickupMinSeconds
            let effectivePickupCount = completedPickups.count + (currentQualifiesAsPickup ? 1 : 0)
            let fragmentedReached = rules.pickupThresholdCount > 0
                && currentQualifiesAsPickup
                && effectivePickupCount >= rules.pickupThresholdCount

            if isPositive && (sustainedReached || fragmentedReached) {
                let kind: InterventionKind = sustainedReached ? .sustainedEpisode : .repeatedShortPickups
                sustainedTriggered = true
                triggeredKind = kind
                if policy.canNotify(episodeID: currentEpisodeID, at: now) {
                    episodeNotified = true
                    policy.recordNotification(episodeID: currentEpisodeID, at: now, cooldownSeconds: rules.cooldownSeconds)
                    var eventReasons: [BehaviorReason] = [.awayFromScreen, .idleCorroborated]
                    eventReasons.append(kind == .sustainedEpisode ? .sustainedGraceElapsed : .repeatedShortPickups)
                    emitted = InterventionEvent(
                        episodeID: currentEpisodeID,
                        kind: kind,
                        timestamp: now,
                        evidenceDuration: evidenceDuration,
                        recentPickupCount: effectivePickupCount,
                        reasons: eventReasons
                    )
                    if kind == .repeatedShortPickups {
                        // Start a fresh pickup count after notifying for fragmented focus.
                        completedPickups.removeAll()
                    }
                    // One reminder per idle stretch, whichever rule reaches it first.
                    stretchNotified = true
                }
            }
        }
        if emitted == nil {
            emitted = emitIdleAtDeskIfDue(evidence: evidence, at: now)
        }

        if episodeID != nil {
            let state: BehaviorState = sustainedTriggered || stretchNotified ? .sustainedPhoneUse : .candidate
            var reasons: [BehaviorReason] = [.awayFromScreen, .idleCorroborated]
            if sustainedTriggered {
                reasons.append(triggeredKind == .repeatedShortPickups ? .repeatedShortPickups : .sustainedGraceElapsed)
            }
            if stretchNotified { reasons.append(.idleAtDeskWithCues) }
            if policy.isCooldownActive(at: now) && emitted == nil {
                reasons.append(.cooldownActive)
            }
            return publish(state: state, at: now, reasons: reasons, intervention: emitted, context: context)
        }

        // The idle-at-desk rule fired for this stretch and the person has not touched the Mac since.
        if stretchID != nil && stretchNotified {
            var reasons: [BehaviorReason] = [.idleAtDeskWithCues]
            if policy.isCooldownActive(at: now) && emitted == nil { reasons.append(.cooldownActive) }
            return publish(state: .sustainedPhoneUse, at: now, reasons: reasons, intervention: emitted, context: context)
        }

        // No active episode: report `.cooldown` or `.observing`.
        var extraReason: BehaviorReason?
        if isInputActive {
            extraReason = .inputActive
        } else if isIdleCorroborated && evidence.macVideoPlaying {
            extraReason = .macPlayingVideo
        } else if stretchID != nil && stretchCueShare >= rules.idleStretchCueShare && stretchSeconds >= rules.idleCorroborationSeconds {
            extraReason = .idleAtDeskWithCues
        } else if isIdleCorroborated && !evidence.awayFromScreen {
            extraReason = .idleOnlyWithoutAwayPosture
        }
        return publishIdleOrCooldown(at: now, extraReason: extraReason, context: context)
    }

    // MARK: Idle-at-desk stretch

    private var stretchCueShare: Double {
        stretchSeconds > 0 ? stretchCueSeconds / stretchSeconds : 0
    }

    private mutating func resetStretch() {
        stretchID = nil
        stretchSeconds = 0
        stretchCueSeconds = 0
        stretchLastTime = nil
        stretchNotified = false
    }

    /// Input ends the stretch. While input is idle past `idleCorroborationSeconds` and this Mac is
    /// not playing video, valid samples add their (bounded) time, and cue time when any away cue shows.
    private mutating func updateStretch(evidence: BehaviorEvidence, at now: Double,
                                        isInputActive: Bool, isIdleCorroborated: Bool) {
        if isInputActive {
            resetStretch()
            return
        }
        defer { if stretchID != nil { stretchLastTime = now } }
        guard isIdleCorroborated, !evidence.macVideoPlaying else { return }
        guard stretchID != nil, let last = stretchLastTime else {
            stretchID = UUID()
            stretchSeconds = 0
            stretchCueSeconds = 0
            stretchNotified = false
            return
        }
        let dt = now - last
        guard dt > 0, dt <= rules.maxStepSeconds else { return }
        stretchSeconds += dt
        if evidence.anyAwayCue { stretchCueSeconds += dt }
    }

    /// Emits the idle-at-desk reminder once per stretch, only on a sample that itself shows a cue.
    private mutating func emitIdleAtDeskIfDue(evidence: BehaviorEvidence, at now: Double) -> InterventionEvent? {
        guard let id = stretchID, !stretchNotified, !evidence.macVideoPlaying else { return nil }
        let plainTier = rules.idleStretchPlainSeconds > 0 && stretchSeconds >= rules.idleStretchPlainSeconds
        guard evidence.anyAwayCue || plainTier else { return nil }
        let share = stretchCueShare
        let firstTier = rules.idleStretchCueSeconds > 0
            && stretchSeconds >= rules.idleStretchCueSeconds && share >= rules.idleStretchCueShare
        let longTier = rules.idleStretchLongSeconds > 0
            && stretchSeconds >= rules.idleStretchLongSeconds && share >= rules.idleStretchLongCueShare
        guard firstTier || longTier || plainTier, policy.canNotify(episodeID: id, at: now) else { return nil }
        stretchNotified = true
        policy.recordNotification(episodeID: id, at: now, cooldownSeconds: rules.cooldownSeconds)
        return InterventionEvent(
            episodeID: id,
            kind: .idleAtDesk,
            timestamp: now,
            evidenceDuration: stretchSeconds,
            recentPickupCount: completedPickups.count,
            reasons: [.idleAtDeskWithCues]
        )
    }

    /// Advances time-based expiries (stale evidence, break expiry, cooldown expiry)
    /// when no new camera sample has arrived.
    @discardableResult
    mutating func tick(at now: Double, context: WorkContextSnapshot) -> BehaviorSnapshot {
        guard now.isFinite else { return snapshot }
        if let prev = lastSampleTime, now < prev { return snapshot }

        policy.clearExpiredTimers(at: now)
        prunePickups(at: now)

        if let gated = evaluateHardGates(at: now, context: context) {
            resetStretch()
            return gated
        }

        if let lastValid = lastValidEvidenceTime, now - lastValid > rules.staleEvidenceSeconds {
            clearEpisode(clearSamples: true)
            resetStretch()
            return publishIdleOrCooldown(at: now, extraReason: .evidenceStale, context: context)
        }

        if episodeID == nil && !(stretchID != nil && stretchNotified) {
            return publishIdleOrCooldown(at: now, extraReason: nil, context: context)
        }

        return publish(
            state: snapshot.state,
            at: now,
            reasons: snapshot.reasons,
            intervention: nil,
            context: context
        )
    }

    /// Applies user feedback to the active or most recent episode (spec §5.3).
    @discardableResult
    mutating func apply(_ action: InterventionAction, at now: Double, context: WorkContextSnapshot) -> BehaviorSnapshot {
        guard now.isFinite else { return snapshot }
        policy.apply(action, episodeID: episodeID ?? stretchID, at: now, cooldownSeconds: rules.cooldownSeconds)
        clearEpisode(clearSamples: true)
        resetStretch()

        switch action {
        case .backToWork, .notADistraction:
            if let gated = evaluateHardGates(at: now, context: context) {
                return gated
            }
            return publishIdleOrCooldown(at: now, extraReason: .episodeAcknowledged, context: context)
        case .takingABreak:
            return evaluateHardGates(at: now, context: context)
                ?? publishIdleOrCooldown(at: now, extraReason: nil, context: context)
        }
    }

    /// Ends an active intentional break early.
    @discardableResult
    mutating func endBreak(at now: Double, context: WorkContextSnapshot) -> BehaviorSnapshot {
        policy.endBreak()
        return tick(at: now, context: context)
    }

    // MARK: Internals

    private mutating func evaluateHardGates(at now: Double, context: WorkContextSnapshot) -> BehaviorSnapshot? {
        if !context.monitoringEnabled {
            clearEpisode(clearSamples: true)
            lastValidEvidenceTime = nil
            unknownSince = nil
            policy.resetEpisodeSuppression()
            return publish(state: .disabled, at: now, reasons: [.monitoringDisabled], intervention: nil, context: context)
        }
        if !context.sessionActive {
            clearEpisode(clearSamples: true)
            lastValidEvidenceTime = nil
            unknownSince = nil
            policy.resetEpisodeSuppression()
            return publish(state: .unavailable, at: now, reasons: [.sessionInactive], intervention: nil, context: context)
        }
        if !context.cameraAvailable {
            clearEpisode(clearSamples: true)
            lastValidEvidenceTime = nil
            unknownSince = nil
            policy.resetEpisodeSuppression()
            return publish(state: .unavailable, at: now, reasons: [.cameraUnavailable], intervention: nil, context: context)
        }
        if context.userPaused {
            clearEpisode(clearSamples: true)
            unknownSince = nil
            return publish(state: .paused, at: now, reasons: [.userPaused], intervention: nil, context: context)
        }
        if context.isBreakActive(at: now) || policy.isBreakActive(at: now) {
            clearEpisode(clearSamples: true)
            unknownSince = nil
            return publish(state: .paused, at: now, reasons: [.breakActive], intervention: nil, context: context)
        }
        if context.isMeetingActive {
            clearEpisode(clearSamples: true)
            unknownSince = nil
            return publish(state: .paused, at: now, reasons: [.meetingAppActive], intervention: nil, context: context)
        }
        if !context.isWorkAppActive {
            clearEpisode(clearSamples: true)
            unknownSince = nil
            return publish(state: .paused, at: now, reasons: [.outsideWorkContext], intervention: nil, context: context)
        }
        return nil
    }

    private mutating func clearEpisode(clearSamples: Bool) {
        episodeID = nil
        episodeNotified = false
        evidenceDuration = 0
        lastPositiveTime = nil
        previousSampleWasPositive = false
        negativeSince = nil
        sustainedTriggered = false
        triggeredKind = nil
        if clearSamples {
            recentValidSamples.removeAll()
        }
    }

    private mutating func recordValidSample(_ sample: ValidSample) {
        recentValidSamples.append(sample)
        let limit = max(1, rules.candidateWindowSamples)
        if recentValidSamples.count > limit {
            recentValidSamples.removeFirst(recentValidSamples.count - limit)
        }
    }

    /// Checks whether recent valid samples meet candidate activation:
    /// at least `candidatePositiveSamples` positives within the last `candidateWindowSamples`
    /// spanning at least `candidateMinSpanSeconds`. Returns the accumulated positive duration
    /// across adjacent positive pairs (bounded by `maxStepSeconds` so gaps never invent time).
    private func candidateActivationDuration() -> Double? {
        let positives = recentValidSamples.filter(\.positive)
        guard positives.count >= max(1, rules.candidatePositiveSamples) else { return nil }
        guard let first = positives.first, let last = positives.last else { return nil }
        guard last.time - first.time >= rules.candidateMinSpanSeconds else { return nil }

        var duration = 0.0
        for index in 1..<recentValidSamples.count {
            let prev = recentValidSamples[index - 1]
            let curr = recentValidSamples[index]
            if prev.positive && curr.positive {
                let dt = curr.time - prev.time
                if dt > 0 && dt <= rules.maxStepSeconds {
                    duration += dt
                }
            }
        }
        return duration
    }

    private mutating func prunePickups(at now: Double) {
        guard rules.pickupWindowSeconds > 0 else {
            completedPickups.removeAll()
            return
        }
        let cutoff = now - rules.pickupWindowSeconds
        completedPickups.removeAll { $0 < cutoff }
    }

    private mutating func publishIdleOrCooldown(
        at now: Double,
        extraReason: BehaviorReason?,
        context: WorkContextSnapshot
    ) -> BehaviorSnapshot {
        var reasons: [BehaviorReason] = []
        if let extraReason { reasons.append(extraReason) }
        if policy.isCooldownActive(at: now) {
            reasons.append(.cooldownActive)
            return publish(state: .cooldown, at: now, reasons: reasons, intervention: nil, context: context)
        }
        return publish(state: .observing, at: now, reasons: reasons, intervention: nil, context: context)
    }

    private mutating func publishCurrentWith(
        reason: BehaviorReason,
        at now: Double,
        context: WorkContextSnapshot
    ) -> BehaviorSnapshot {
        var reasons = snapshot.reasons
        if !reasons.contains(reason) { reasons.append(reason) }
        return publish(state: snapshot.state, at: now, reasons: reasons, intervention: nil, context: context)
    }

    private mutating func publish(
        state: BehaviorState,
        at now: Double,
        reasons: [BehaviorReason],
        intervention: InterventionEvent?,
        context: WorkContextSnapshot
    ) -> BehaviorSnapshot {
        if state != snapshot.state {
            stateSince = now
        }
        let grace = rules.episodeGraceSeconds > 0
            ? min(1.0, max(0.0, evidenceDuration / rules.episodeGraceSeconds))
            : (episodeID != nil ? 1.0 : 0.0)
        let contextBreak = context.breakUntil.map { max(0, $0 - now) } ?? 0
        let breakRem = max(contextBreak, policy.breakRemaining(at: now))
        let result = BehaviorSnapshot(
            state: state,
            stateSince: stateSince,
            evidenceDuration: evidenceDuration,
            graceProgress: grace,
            recentPickupCount: completedPickups.count,
            episodeID: episodeID,
            reasons: reasons,
            lastUpdate: now,
            pendingIntervention: intervention,
            cooldownRemaining: policy.cooldownRemaining(at: now),
            breakRemaining: breakRem,
            idleStretchSeconds: stretchSeconds,
            idleStretchCueShare: stretchCueShare
        )
        snapshot = result
        return result
    }
}
