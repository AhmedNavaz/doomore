import XCTest
@testable import FocusAssistant

/// Deterministic fake monotonic clock for Milestone 1 behavioral engine tests.
final class FakeClock: MonotonicClock, @unchecked Sendable {
    private var current: Double

    init(_ start: Double = 100.0) {
        self.current = start
    }

    func now() -> Double { current }

    @discardableResult
    func advance(by seconds: Double) -> Double {
        current += seconds
        return current
    }

    func set(_ value: Double) {
        current = value
    }
}

/// Deterministic unit tests for `WorkContextSnapshot`, `InterventionPolicy`, and `BehaviorEngine`
/// (spec §5, §7.1, §13.2). No camera, real clock, or notifications are touched.
final class BehaviorEngineTests: XCTestCase {

    // MARK: Helpers

    private func workContext(
        enabled: Bool = true,
        cameraAvailable: Bool = true,
        sessionActive: Bool = true,
        userPaused: Bool = false,
        breakUntil: Double? = nil,
        bundleID: String? = "com.apple.dt.Xcode",
        mode: WorkContextMode = .selectedApps
    ) -> WorkContextSnapshot {
        WorkContextSnapshot(
            monitoringEnabled: enabled,
            cameraAvailable: cameraAvailable,
            sessionActive: sessionActive,
            userPaused: userPaused,
            breakUntil: breakUntil,
            frontmostBundleID: bundleID,
            config: WorkContextConfig(mode: mode)
        )
    }

    private func positiveEvidence(at time: Double, idle: Double = 20.0) -> BehaviorEvidence {
        BehaviorEvidence(
            time: time,
            quality: .valid,
            posture: .down,
            awayFromScreen: true,
            inputIdleSeconds: idle,
            possiblePhoneUse: true,
            handCount: 0,
            faceCount: 1
        )
    }

    private func facingEvidence(at time: Double, idle: Double = 0.5) -> BehaviorEvidence {
        BehaviorEvidence(
            time: time,
            quality: .valid,
            posture: .facing,
            awayFromScreen: false,
            inputIdleSeconds: idle,
            possiblePhoneUse: false,
            handCount: 0,
            faceCount: 1
        )
    }

    /// Feeds samples every `step` seconds while advancing `clock`. Returns every snapshot produced.
    private func run(
        engine: inout BehaviorEngine,
        clock: FakeClock,
        context: WorkContextSnapshot,
        forDuration duration: Double,
        step: Double = 0.5,
        evidence: (Double) -> BehaviorEvidence
    ) -> [BehaviorSnapshot] {
        var results: [BehaviorSnapshot] = []
        let count = Int((duration / step).rounded())
        for _ in 0...count {
            results.append(engine.step(context: context, evidence: evidence(clock.now())))
            clock.advance(by: step)
        }
        return results
    }

    // MARK: WorkContext

    func testWorkContextSelectedAppsAllowsConfiguredEditorsAndExcludesBrowsers() {
        let xcode = workContext(bundleID: "com.apple.dt.Xcode", mode: .selectedApps)
        XCTAssertTrue(xcode.isWorkAppActive)
        XCTAssertFalse(xcode.isMeetingActive)

        let safari = workContext(bundleID: "com.apple.Safari", mode: .selectedApps)
        XCTAssertFalse(safari.isWorkAppActive, "arbitrary browsers are never assumed to be work")

        let terminal = workContext(bundleID: "com.apple.Terminal", mode: .selectedApps)
        XCTAssertFalse(terminal.isWorkAppActive, "arbitrary terminals are never assumed to be work")
    }

    func testMeetingAppSuppressesEvenInManualWorkMode() {
        let zoom = workContext(bundleID: "us.zoom.xos", mode: .manualWork)
        XCTAssertTrue(zoom.isMeetingActive)
        XCTAssertFalse(zoom.isWorkAppActive)

        let facetime = workContext(bundleID: "com.apple.FaceTime", mode: .selectedApps)
        XCTAssertTrue(facetime.isMeetingActive)
        XCTAssertFalse(facetime.isWorkAppActive)
    }

    // MARK: Negative & non-triggering scenes (spec §7.1)

    func testIdleAloneWhileFacingScreenNeverTriggersCandidateOrReminder() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        // 120 s watching an AI agent or video render while facing the screen with zero keyboard/mouse.
        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 120) {
            self.facingEvidence(at: $0, idle: 600)
        }

        XCTAssertTrue(snapshots.allSatisfy { $0.state == .observing })
        XCTAssertTrue(snapshots.allSatisfy { $0.pendingIntervention == nil })
        XCTAssertTrue(snapshots.last?.reasons.contains(.idleOnlyWithoutAwayPosture) == true)
    }

    func testTypingWhileLookingDownAtKeyboardNeverTriggers() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 90) {
            BehaviorEvidence(time: $0, quality: .valid, posture: .down, awayFromScreen: true, inputIdleSeconds: 0.3)
        }

        XCTAssertTrue(snapshots.allSatisfy { $0.state == .observing })
        XCTAssertTrue(snapshots.allSatisfy { $0.pendingIntervention == nil })
    }

    func testNoPersonAndMultiplePeopleSuppressAndClearCandidate() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        // Enter candidate for 15 s.
        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 15) { self.positiveEvidence(at: $0) }
        XCTAssertEqual(engine.snapshot.state, .candidate)

        // Second person enters frame → immediately suppressed and cleared.
        let multi = engine.step(
            context: ctx,
            evidence: BehaviorEvidence(time: clock.now(), quality: .multiplePeople, posture: .down, awayFromScreen: true, inputIdleSeconds: 30, faceCount: 2)
        )
        XCTAssertEqual(multi.state, .observing)
        XCTAssertEqual(multi.evidenceDuration, 0)
        XCTAssertEqual(multi.reasons, [.multiplePeopleInView])
        XCTAssertNil(multi.pendingIntervention)

        // Re-enter candidate then walk away (no person in view) → cleared.
        clock.advance(by: 0.5)
        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 10) { self.positiveEvidence(at: $0) }
        XCTAssertEqual(engine.snapshot.state, .candidate)

        let nobody = engine.step(
            context: ctx,
            evidence: BehaviorEvidence(time: clock.now(), quality: .noPerson, posture: .nobody, awayFromScreen: false, inputIdleSeconds: 40, faceCount: 0)
        )
        XCTAssertEqual(nobody.state, .observing)
        XCTAssertEqual(nobody.evidenceDuration, 0)
        XCTAssertEqual(nobody.reasons, [.noPersonInView])
    }

    func testSinglePositiveSampleNeverActivatesCandidateOrAlerts() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        let single = engine.step(context: ctx, evidence: positiveEvidence(at: clock.now()))
        XCTAssertEqual(single.state, .observing)
        XCTAssertNil(single.pendingIntervention)
    }

    func testShortPhoneCheckUnderGracePeriodDoesNotRemind() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        // 10 s phone check (quick MFA / reply), then return to screen for 6 s.
        let away = run(engine: &engine, clock: clock, context: ctx, forDuration: 10) { self.positiveEvidence(at: $0) }
        XCTAssertEqual(away.last?.state, .candidate)
        XCTAssertTrue(away.allSatisfy { $0.pendingIntervention == nil })

        let back = run(engine: &engine, clock: clock, context: ctx, forDuration: 6) { self.facingEvidence(at: $0) }
        XCTAssertEqual(back.last?.state, .observing)
        XCTAssertEqual(back.last?.recentPickupCount, 0, "10 s check is shorter than the 15 s short-pickup floor")
        XCTAssertTrue(back.allSatisfy { $0.pendingIntervention == nil })
    }

    // MARK: Sustained episode & cooldown (spec §5.1, §5.2)

    func testSustainedEpisodeEmitsExactlyOneReminderAfterGraceThenRespectsCooldown() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        // 60 s continuous corroborated phone use.
        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 60) {
            self.positiveEvidence(at: $0, idle: 20)
        }

        let emitted = snapshots.compactMap(\.pendingIntervention)
        XCTAssertEqual(emitted.count, 1, "exactly one reminder per episode")
        XCTAssertEqual(emitted.first?.kind, .sustainedEpisode)
        XCTAssertEqual(emitted.first?.evidenceDuration ?? 0, 45.0, accuracy: 0.6)
        XCTAssertEqual(snapshots.last?.state, .sustainedPhoneUse)

        // Return to work for 5.5 s → transitions to `.cooldown`.
        let back = run(engine: &engine, clock: clock, context: ctx, forDuration: 5.5) { self.facingEvidence(at: $0) }
        XCTAssertEqual(back.last?.state, .cooldown)
        XCTAssertGreaterThan(back.last?.cooldownRemaining ?? 0, 200)

        // Start a second 60 s episode while still inside 5-minute cooldown → no second reminder.
        let second = run(engine: &engine, clock: clock, context: ctx, forDuration: 60) {
            self.positiveEvidence(at: $0, idle: 20)
        }
        XCTAssertTrue(second.allSatisfy { $0.pendingIntervention == nil }, "cooldown suppresses repeat reminders")
        XCTAssertEqual(second.last?.state, .sustainedPhoneUse, "real state changes are still tracked during cooldown")

        // Return to work, advance past cooldown expiry, then verify a fresh episode notifies again.
        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 6) { self.facingEvidence(at: $0) }
        clock.advance(by: 310)
        let expired = engine.tick(at: clock.now(), context: ctx)
        XCTAssertEqual(expired.state, .observing)
        XCTAssertEqual(expired.cooldownRemaining, 0)

        clock.advance(by: 0.5)
        let third = run(engine: &engine, clock: clock, context: ctx, forDuration: 50) {
            self.positiveEvidence(at: $0, idle: 20)
        }
        XCTAssertEqual(third.compactMap(\.pendingIntervention).count, 1)
    }

    // MARK: Section 13.2 — Fragmented focus / repeated short pickups

    func testFourShortPickupsWithinRollingWindowTriggersFragmentedFocusReminder() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        // Three separate 20 s pickups (well below 45 s grace) separated by 30 s of work.
        for expectedCount in 1...3 {
            let away = run(engine: &engine, clock: clock, context: ctx, forDuration: 20) {
                self.positiveEvidence(at: $0, idle: 20)
            }
            XCTAssertTrue(away.allSatisfy { $0.pendingIntervention == nil }, "pickup \(expectedCount) must not alert yet")

            let back = run(engine: &engine, clock: clock, context: ctx, forDuration: 6) { self.facingEvidence(at: $0) }
            XCTAssertEqual(back.last?.state, .observing)
            XCTAssertEqual(back.last?.recentPickupCount, expectedCount)
            clock.advance(by: 24)
        }

        // Fourth pickup reaches 15 s → triggers `.repeatedShortPickups` without waiting for 45 s.
        let fourth = run(engine: &engine, clock: clock, context: ctx, forDuration: 20) {
            self.positiveEvidence(at: $0, idle: 20)
        }
        let alerts = fourth.compactMap(\.pendingIntervention)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.kind, .repeatedShortPickups)
        XCTAssertEqual(alerts.first?.recentPickupCount, 4)
        XCTAssertLessThan(alerts.first?.evidenceDuration ?? 99, 20.0)
    }

    func testOldShortPickupsExpireOutsideRollingWindow() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        // Three pickups happen early.
        for _ in 0..<3 {
            _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 20) { self.positiveEvidence(at: $0) }
            _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 6) { self.facingEvidence(at: $0) }
        }
        XCTAssertEqual(engine.snapshot.recentPickupCount, 3)

        // Advance past the 12-minute (720 s) rolling window.
        clock.advance(by: 800)
        let afterWindow = engine.tick(at: clock.now(), context: ctx)
        XCTAssertEqual(afterWindow.recentPickupCount, 0)

        // A single 20 s pickup now must NOT trigger fragmented focus.
        clock.advance(by: 0.5)
        let pickup = run(engine: &engine, clock: clock, context: ctx, forDuration: 20) { self.positiveEvidence(at: $0) }
        XCTAssertTrue(pickup.allSatisfy { $0.pendingIntervention == nil })
    }

    // MARK: User feedback actions (spec §5.3)

    func testBackToWorkDoesNotInstantlyRetriggerIfPhoneStaysAway() {
        let clock = FakeClock(100)
        var rules = BehaviorEngine.Rules()
        rules.cooldownSeconds = 0 // Isolate return-to-work suppression from cooldown.
        var engine = BehaviorEngine(rules: rules, startTime: clock.now())
        let ctx = workContext()

        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 50) { self.positiveEvidence(at: $0) }
        XCTAssertEqual(engine.snapshot.state, .sustainedPhoneUse)

        let ack = engine.apply(.backToWork, at: clock.now(), context: ctx)
        XCTAssertEqual(ack.state, .observing)
        XCTAssertTrue(ack.reasons.contains(.episodeAcknowledged))

        // Phone stays away for another 60 s right after clicking Back to work → still suppressed.
        clock.advance(by: 0.5)
        let stillAway = run(engine: &engine, clock: clock, context: ctx, forDuration: 60) { self.positiveEvidence(at: $0) }
        XCTAssertTrue(stillAway.allSatisfy { $0.pendingIntervention == nil })
        XCTAssertTrue(stillAway.allSatisfy { $0.state == .observing })

        // Once user returns to screen for 5 s, suppression clears and a new episode can trigger.
        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 6) { self.facingEvidence(at: $0) }
        let nextEpisode = run(engine: &engine, clock: clock, context: ctx, forDuration: 50) { self.positiveEvidence(at: $0) }
        XCTAssertEqual(nextEpisode.compactMap(\.pendingIntervention).count, 1)
    }

    func testTakingABreakPausesSuppressesAndResumesOnExpiry() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 50) { self.positiveEvidence(at: $0) }
        let onBreak = engine.apply(.takingABreak(duration: 300), at: clock.now(), context: ctx)
        XCTAssertEqual(onBreak.state, .paused)
        XCTAssertEqual(onBreak.reasons, [.breakActive])
        XCTAssertEqual(onBreak.breakRemaining, 300, accuracy: 0.01)

        // During break, positive samples do nothing.
        clock.advance(by: 60)
        let during = engine.step(context: ctx, evidence: positiveEvidence(at: clock.now()))
        XCTAssertEqual(during.state, .paused)
        XCTAssertNil(during.pendingIntervention)

        // After 5 min break expires, engine cleanly resumes observing.
        clock.advance(by: 245)
        let resumed = engine.tick(at: clock.now(), context: ctx)
        XCTAssertEqual(resumed.state, .observing)
        XCTAssertEqual(resumed.breakRemaining, 0)
    }

    // MARK: Lifecycle, work-app changes, dropouts & stale evidence (spec §7.1)

    func testWorkAppSwitchAndLockClearCandidateWithoutStaleAlertOnRecovery() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let work = workContext(bundleID: "com.apple.dt.Xcode", mode: .selectedApps)
        let nonWork = workContext(bundleID: "com.apple.Safari", mode: .selectedApps)
        let locked = workContext(sessionActive: false)

        // Build 40 s of candidate evidence (just shy of 45 s grace).
        _ = run(engine: &engine, clock: clock, context: work, forDuration: 40) { self.positiveEvidence(at: $0) }
        XCTAssertEqual(engine.snapshot.state, .candidate)
        XCTAssertGreaterThanOrEqual(engine.snapshot.evidenceDuration, 39)

        // Switch away to non-work app → paused & candidate reset.
        let paused = engine.step(context: nonWork, evidence: positiveEvidence(at: clock.now()))
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.reasons, [.outsideWorkContext])
        XCTAssertEqual(paused.evidenceDuration, 0)

        // Return to work app: must NOT fire a stale alert after 10 s.
        clock.advance(by: 0.5)
        let resumed = run(engine: &engine, clock: clock, context: work, forDuration: 10) { self.positiveEvidence(at: $0) }
        XCTAssertTrue(resumed.allSatisfy { $0.pendingIntervention == nil })

        // Lock screen during candidate → unavailable & cleared; no stale alert after unlock.
        let unavailable = engine.tick(at: clock.now(), context: locked)
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.reasons, [.sessionInactive])
        XCTAssertEqual(unavailable.evidenceDuration, 0)

        clock.advance(by: 120)
        let unlocked = engine.tick(at: clock.now(), context: work)
        XCTAssertEqual(unlocked.state, .observing)
        XCTAssertNil(unlocked.pendingIntervention)
    }

    func testDropoutsOutOfOrderAndStaleGapsNeverInventPositiveTime() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        // 10 s of positive evidence at 2 Hz.
        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 10, step: 0.5) { self.positiveEvidence(at: $0) }
        let beforeDropout = engine.snapshot.evidenceDuration
        XCTAssertEqual(beforeDropout, 10.0, accuracy: 0.1)

        // Out-of-order sample in the past is ignored and adds zero time.
        let ooo = engine.step(context: ctx, evidence: positiveEvidence(at: clock.now() - 5.0))
        XCTAssertEqual(ooo.evidenceDuration, beforeDropout, accuracy: 0.001)

        // 2.5 s missing-frame dropout (within stale window, > maxStepSeconds): candidate survives
        // without inventing 2.5 s of positive time.
        clock.advance(by: 2.5)
        let afterDropout = engine.step(context: ctx, evidence: positiveEvidence(at: clock.now()))
        XCTAssertEqual(afterDropout.state, .candidate)
        XCTAssertEqual(afterDropout.evidenceDuration, beforeDropout, accuracy: 0.001, "missing frames must not add positive duration")

        // Switch frame rate to 1 Hz for 5 s → adds exactly 5.0 s.
        clock.advance(by: 1.0)
        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 4.0, step: 1.0) { self.positiveEvidence(at: $0) }
        XCTAssertEqual(engine.snapshot.evidenceDuration, beforeDropout + 5.0, accuracy: 0.1)

        // Stale gap > 5 s via `tick` → resets candidate and never alerts.
        clock.advance(by: 6.0)
        let stale = engine.tick(at: clock.now(), context: ctx)
        XCTAssertEqual(stale.state, .observing)
        XCTAssertEqual(stale.evidenceDuration, 0)
        XCTAssertTrue(stale.reasons.contains(.evidenceStale))
        XCTAssertNil(stale.pendingIntervention)
    }

    func testUnknownQualitySuspendsThenResetsAfterStaleTimeout() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        _ = run(engine: &engine, clock: clock, context: ctx, forDuration: 10) { self.positiveEvidence(at: $0) }
        let durBefore = engine.snapshot.evidenceDuration

        // 2 s of unknown/occluded observations: does not add duration, does not alert.
        let briefUnknown = run(engine: &engine, clock: clock, context: ctx, forDuration: 2.0) {
            BehaviorEvidence(time: $0, quality: .unknown)
        }
        XCTAssertEqual(briefUnknown.last?.state, .candidate)
        XCTAssertEqual(briefUnknown.last?.evidenceDuration ?? -1, durBefore, accuracy: 0.001)
        XCTAssertTrue(briefUnknown.allSatisfy { $0.pendingIntervention == nil })

        // Continuing unknown past 5 s resets candidate.
        let longUnknown = run(engine: &engine, clock: clock, context: ctx, forDuration: 4.0) {
            BehaviorEvidence(time: $0, quality: .unknown)
        }
        XCTAssertEqual(longUnknown.last?.state, .observing)
        XCTAssertEqual(longUnknown.last?.evidenceDuration, 0)
    }

    // MARK: End-to-end signal adapter (ActivityEstimator -> BehaviorEngine)

    func testActivityEstimatorFeedsBehaviorEngineForSustainedPhoneEpisode() {
        var estimator = ActivityEstimator()
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: 0)
        let ctx = workContext(mode: .manualWork)

        func snapshot(_ t: Double, pitch: Double, idle: Double, faces: Int = 1) -> SignalSnapshot {
            var vision = VisionSignals()
            vision.faceCount = faces
            vision.head = HeadPose(pitch: pitch, yaw: 0, roll: 0)
            vision.eyeOpenness = 0.30
            vision.personCoverage = 0.30
            return SignalSnapshot(time: t, vision: vision, input: InputIdle(keyboard: idle, pointer: idle))
        }

        // Calibrate straight-ahead for 3 s.
        for step in 0..<6 {
            let t = Double(step) * 0.5
            let s = snapshot(t, pitch: 2, idle: 0.2)
            let est = estimator.update(s)
            _ = engine.step(context: ctx, evidence: BehaviorEvidence(snapshot: s, estimate: est))
        }
        XCTAssertNotNil(estimator.baseline)

        // Look down at phone with idle input for 60 s.
        var alerts: [InterventionEvent] = []
        for step in 6...126 {
            let t = Double(step) * 0.5
            let s = snapshot(t, pitch: 18, idle: max(0, t - 3.0))
            let est = estimator.update(s)
            let result = engine.step(context: ctx, evidence: BehaviorEvidence(snapshot: s, estimate: est))
            if let event = result.pendingIntervention { alerts.append(event) }
        }

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.kind, .sustainedEpisode)
        // 10 s idle corroboration + 45 s grace = ~55 s after t = 3.0 -> ~58 s.
        XCTAssertEqual(alerts.first?.timestamp ?? 0, 58.0, accuracy: 1.5)
    }

    // MARK: Idle-at-desk stretch (27 Nov 2026)

    private func softEvidence(at time: Double, idle: Double = 600, soft: Bool = true,
                              away: Bool = false, video: Bool = false) -> BehaviorEvidence {
        BehaviorEvidence(time: time, quality: .valid, posture: away ? .down : .facing, awayFromScreen: away,
                         inputIdleSeconds: idle, possiblePhoneUse: false, handCount: 0, faceCount: 1,
                         softCue: soft, macVideoPlaying: video)
    }

    func testPhoneHeldHighWithOnlySoftCuesRemindsAfterTheIdleStretch() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 120) {
            self.softEvidence(at: $0)
        }
        let reminders = snapshots.compactMap(\.pendingIntervention)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.kind, .idleAtDesk)
        XCTAssertEqual(reminders.first?.timestamp ?? 0, 190, accuracy: 1.0, "stretch starts at the first sample and needs 90 s")
        XCTAssertTrue(snapshots.allSatisfy { $0.state != .candidate }, "soft cues never open a posture episode")
        XCTAssertEqual(snapshots.last?.state, .sustainedPhoneUse)
        XCTAssertTrue(snapshots.last?.reasons.contains(.idleAtDeskWithCues) == true)
    }

    func testFlickeringPostureLikeTheHighPhoneRunStillReminds() {
        // 27 Nov 2026 run: strong posture came and went every few seconds, soft cues in between,
        // and about 1 s in 6 looked cleanly at the screen. The posture episode kept restarting.
        let clock = FakeClock(0)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 110) { t in
            let phase = t.truncatingRemainder(dividingBy: 12)
            if phase < 4 { return self.softEvidence(at: t, soft: false, away: true) }
            if phase < 10 { return self.softEvidence(at: t) }
            return self.softEvidence(at: t, soft: false)
        }
        let reminders = snapshots.compactMap(\.pendingIntervention)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.kind, .idleAtDesk)
        XCTAssertLessThan(snapshots.map(\.evidenceDuration).max() ?? 0, 45, "the posture rule alone would not have fired")
    }

    func testSensitiveRemindsAfterAPlainIdleStretchEvenWhileFacing() {
        // 27 Nov 2026 live run: phone at eye level, face straight on, no input for 58 s.
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: Sensitivity.sensitive.rules, startTime: clock.now())
        let ctx = workContext()

        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 90, step: 1.0) {
            self.softEvidence(at: $0, soft: false)
        }
        let reminders = snapshots.compactMap(\.pendingIntervention)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.kind, .idleAtDesk)
        XCTAssertEqual(reminders.first?.timestamp ?? 0, 165, accuracy: 10.0)
    }

    func testPlainIdleTierIsOffOutsideQuickTest() {
        for sensitivity in [Sensitivity.relaxed, .balanced] {
            XCTAssertEqual(sensitivity.rules.idleStretchPlainSeconds, 0)
        }
    }

    func testStaringAtTheScreenWithoutCuesNeverFiresEvenAfterTenMinutes() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 600, step: 1.0) {
            self.softEvidence(at: $0, soft: false)
        }
        XCTAssertTrue(snapshots.allSatisfy { $0.pendingIntervention == nil })
        XCTAssertEqual(snapshots.last?.state, .observing)
        XCTAssertGreaterThan(snapshots.last?.idleStretchSeconds ?? 0, 590)
    }

    func testLongTierFiresWithFewerCuesAfterFiveMinutes() {
        let clock = FakeClock(0)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        // Cues 30% of the time (3 s in every 10 s): below the 50% first tier, above the 25% long tier.
        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 330) { t in
            self.softEvidence(at: t, soft: t.truncatingRemainder(dividingBy: 10) < 3)
        }
        let reminders = snapshots.compactMap(\.pendingIntervention)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.kind, .idleAtDesk)
        XCTAssertGreaterThanOrEqual(reminders.first?.timestamp ?? 0, 300)
    }

    func testTouchingTheMouseEndsTheStretch() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        let first = run(engine: &engine, clock: clock, context: ctx, forDuration: 80) { self.softEvidence(at: $0) }
        XCTAssertGreaterThan(first.last?.idleStretchSeconds ?? 0, 75)
        let touch = engine.step(context: ctx, evidence: softEvidence(at: clock.now(), idle: 0.2))
        XCTAssertEqual(touch.idleStretchSeconds, 0)
        clock.advance(by: 0.5)
        // Input idle again from zero: the stretch restarts only after 10 s idle, so 80 s more stays short of 90.
        var idle = 0.5
        let second = run(engine: &engine, clock: clock, context: ctx, forDuration: 80) { t in
            defer { idle += 0.5 }
            return self.softEvidence(at: t, idle: idle)
        }
        XCTAssertTrue((first + second).allSatisfy { $0.pendingIntervention == nil })
    }

    func testVideoPlayingOnTheMacHoldsTheStretch() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        let snapshots = run(engine: &engine, clock: clock, context: ctx, forDuration: 200) {
            self.softEvidence(at: $0, video: true)
        }
        XCTAssertTrue(snapshots.allSatisfy { $0.pendingIntervention == nil })
        XCTAssertTrue(snapshots.last?.reasons.contains(.macPlayingVideo) == true)
    }

    func testBackToWorkAfterIdleAtDeskReminderDoesNotRepeatWhileStillIdle() {
        let clock = FakeClock(100)
        var engine = BehaviorEngine(rules: .legacyTimings, startTime: clock.now())
        let ctx = workContext()

        let before = run(engine: &engine, clock: clock, context: ctx, forDuration: 95) { self.softEvidence(at: $0) }
        XCTAssertEqual(before.compactMap(\.pendingIntervention).count, 1)
        _ = engine.apply(.backToWork, at: clock.now(), context: ctx)
        let after = run(engine: &engine, clock: clock, context: ctx, forDuration: 200) { self.softEvidence(at: $0) }
        XCTAssertTrue(after.allSatisfy { $0.pendingIntervention == nil })
    }
}

extension BehaviorEngine.Rules {
    /// The timings before the 27 Nov 2026 speed-up; keeps the older scenario tests readable.
    static var legacyTimings: BehaviorEngine.Rules {
        var r = BehaviorEngine.Rules()
        r.idleCorroborationSeconds = 10
        r.episodeGraceSeconds = 45
        r.cooldownSeconds = 300
        r.idleStretchCueSeconds = 90
        r.idleStretchLongSeconds = 300
        return r
    }
}
