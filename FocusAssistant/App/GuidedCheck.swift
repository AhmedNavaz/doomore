import Foundation

/// A short labelled test. The app speaks each instruction, so the person does not need to
/// watch the screen while holding the phone, and every logged reading carries the phase it
/// belongs to. That turns a run into labelled data: what the signals look like while the
/// person faces the screen without typing, types on the keyboard, uses the phone briefly,
/// or uses the phone past the grace period.
enum GuidedCheck {
    enum Suite: String, Equatable, CaseIterable {
        /// Milestone 0 signal check (62 s): screen, shift chair, phone, screen again.
        case phoneSignals
        /// Milestone 1 behavioral engine check (198 s): idle facing screen, keyboard typing,
        /// quick reply under grace (short pickup), return to screen, sustained phone reminder, recover.
        case behaviorEngine

        var title: String {
            switch self {
            case .phoneSignals: return "Guided phone check"
            case .behaviorEngine: return "Guided behavior test"
            }
        }
    }

    enum Kind: Equatable {
        /// Facing the screen or typing without phone use: any phone guess/candidate here is a false alarm.
        case screen
        /// Using the phone: a phone guess/candidate here is expected.
        case phone
        /// Preparation or recovery step; logged but not scored.
        case setup
    }

    struct Phase: Equatable {
        /// Stable name used in the shared log.
        let name: String
        let kind: Kind
        let seconds: Double
        /// Spoken aloud when the phase begins.
        let cue: String
        /// Shown in the window during the phase.
        let instruction: String
    }

    /// The screen phases keep the hands off the keyboard on purpose: reading the screen
    /// without typing is the case most likely to be mistaken for phone use. The move phase
    /// changes the seating position while the mouse is in use, so the estimator has to relearn
    /// straight-ahead before the phone; in the third check (26 Nov 2026) a shift in the chair
    /// left facing the screen reading 12–17° turned.
    static let phases = [
        Phase(name: "screen", kind: .screen, seconds: 12,
              cue: "Look at the screen, and keep your hands off the keyboard and mouse.",
              instruction: "Look at the screen. Hands off the keyboard and mouse."),
        Phase(name: "move", kind: .setup, seconds: 15,
              cue: "Now lean or shift to a different position. Keep looking at the screen, and keep moving the mouse.",
              instruction: "Shift to a new position. Look at the screen and keep moving the mouse."),
        Phase(name: "phone", kind: .phone, seconds: 20,
              cue: "Now pick up your phone and use it the way you normally do.",
              instruction: "Use your phone the way you normally do."),
        Phase(name: "screen-again", kind: .screen, seconds: 15,
              cue: "Put the phone down and look at the screen again. Stay where you are, hands off the keyboard.",
              instruction: "Phone down. Look at the screen, hands off the keyboard and mouse.")
    ]

    /// Spoken end-to-end Milestone 1 behavioral test (~3.3 minutes):
    /// 1. Idle facing screen (16 s) -> stays Observing (no idle-only false trigger).
    /// 2. Looking down at keyboard & typing (14 s) -> stays Observing (no baseline drift).
    /// 3. Quick reply (34 s) -> may enter Candidate grace, no reminder emitted.
    /// 4. Return to screen with a touch of the mouse (12 s) -> closes the quick reply and its idle stretch.
    /// 5. Sustained phone use (110 s) -> a reminder from the 45 s posture grace or the 90 s idle-at-desk rule.
    ///    Lengthened from 65 s on 27 Nov 2026 so the idle-at-desk rule, which needs 10 s idle plus 90 s,
    ///    can be reached when the phone is held high and the head barely tilts.
    /// 6. Recover (12 s) -> return to screen / optional acknowledgement.
    static let behaviorPhases = [
        Phase(name: "screen-idle", kind: .screen, seconds: 16,
              cue: "Step 1. Look straight at the screen, and keep your hands off the keyboard and mouse.",
              instruction: "Step 1 of 6 · Look at the screen. Hands off keyboard and mouse."),
        Phase(name: "keyboard", kind: .screen, seconds: 14,
              cue: "Step 2. Look down at your keyboard and type or move the mouse.",
              instruction: "Step 2 of 6 · Look at your keyboard and keep typing or moving the mouse."),
        Phase(name: "quick-reply", kind: .phone, seconds: 34,
              cue: "Step 3. Quick reply. Hands off the keyboard, pick up your phone and use it.",
              instruction: "Step 3 of 6 · Quick reply: hands off keyboard and mouse, use your phone."),
        Phase(name: "return-screen", kind: .screen, seconds: 12,
              cue: "Step 4. Put the phone down, look straight at the screen, and move the mouse a little, the way you would when getting back to work.",
              instruction: "Step 4 of 6 · Phone down. Look at the screen and move the mouse a little."),
        Phase(name: "sustained-phone", kind: .phone, seconds: 110,
              cue: "Step 5. Sustained phone use. Hands off the keyboard, pick up your phone and keep using it until the next cue.",
              instruction: "Step 5 of 6 · Sustained use: keep using your phone (hands off keyboard and mouse)."),
        Phase(name: "recover", kind: .setup, seconds: 12,
              cue: "Step 6. Put the phone down, look at the screen, and click Back to work if a reminder is shown.",
              instruction: "Step 6 of 6 · Phone down. Look at the screen (click Back to work if shown).")
    ]

    static let finishedCue = "Done. Thank you."

    /// The start of each phase is left out of the score because people take time to move.
    /// In the first check (26 Nov 2026) the head went down about 4 s after the phone cue and
    /// came back up about 5 s after the screen cue. Those samples are still logged.
    static let settleSeconds = 5.0

    static func phases(for suite: Suite) -> [Phase] {
        switch suite {
        case .phoneSignals: return phases
        case .behaviorEngine: return behaviorPhases
        }
    }

    static var totalSeconds: Double { totalSeconds(for: .phoneSignals) }

    static func totalSeconds(for suite: Suite) -> Double {
        phases(for: suite).reduce(0) { $0 + $1.seconds }
    }

    /// The phase at `elapsed` seconds since the check began; nil before the start or once finished.
    static func phaseIndex(at elapsed: Double, suite: Suite = .phoneSignals) -> Int? {
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        var end = 0.0
        for (index, phase) in phases(for: suite).enumerated() {
            end += phase.seconds
            if elapsed < end { return index }
        }
        return nil
    }

    /// Whether a sample at `elapsed` counts toward the score: inside a phase and past its settle time.
    static func isScored(at elapsed: Double, suite: Suite = .phoneSignals) -> Bool {
        let suitePhases = phases(for: suite)
        guard let index = phaseIndex(at: elapsed, suite: suite) else { return false }
        let phaseStart = suitePhases[..<index].reduce(0) { $0 + $1.seconds }
        return elapsed - phaseStart >= settleSeconds
    }
}

/// Human-readable pass/fail breakdown shown in `DiagnosticsView` after a guided test completes.
struct GuidedReport: Equatable {
    struct CheckItem: Equatable, Identifiable {
        enum Status: Equatable {
            case pass
            case fail
            case info
        }

        let id: String
        let title: String
        let status: Status
        let detail: String
    }

    let suite: GuidedCheck.Suite
    let items: [CheckItem]

    var allPassed: Bool {
        !items.isEmpty && !items.contains { $0.status == .fail }
    }
}

/// Per-phase totals of one guided check, logged when it finishes. Constant memory.
struct GuidedSummary {
    struct PhaseTotals {
        var samples = 0
        var faces = 0
        var away = 0
        var phoneGuess = 0
        var idle = 0
        /// Samples past the settle time, and how many of those were away or flagged.
        var scored = 0
        var scoredAway = 0
        var scoredPhoneGuess = 0
        var tilt = RunSummary.Spread()
        var turn = RunSummary.Spread()
        var eyes = RunSummary.Spread()
    }

    let suite: GuidedCheck.Suite
    private(set) var phases: [String: PhaseTotals] = [:]

    init(suite: GuidedCheck.Suite = .phoneSignals) {
        self.suite = suite
    }

    mutating func add(phase: String, scored: Bool, snapshot: SignalSnapshot, estimate: ActivityEstimate) {
        var totals = phases[phase, default: PhaseTotals()]
        totals.samples += 1
        if snapshot.vision.faceCount > 0 { totals.faces += 1 }
        if estimate.posture.isAway { totals.away += 1 }
        if estimate.possiblePhoneUse { totals.phoneGuess += 1 }
        if !estimate.inputActive { totals.idle += 1 }
        if scored {
            totals.scored += 1
            if estimate.posture.isAway { totals.scoredAway += 1 }
            if estimate.possiblePhoneUse { totals.scoredPhoneGuess += 1 }
        }
        totals.tilt.add(estimate.tilt)
        totals.turn.add(estimate.yawOff)
        totals.eyes.add(estimate.eyeRatio)
        phases[phase] = totals
    }

    /// One line per phase in the check's order, then the share of scored samples (past each
    /// phase's settle time) flagged as possible phone use while on the phone and while facing the screen.
    func lines() -> [String] {
        let suitePhases = GuidedCheck.phases(for: suite)
        let n = ReadingText.number, s = ReadingText.signed
        func share(_ count: Int, _ of: Int) -> String { of > 0 ? n(Double(count) / Double(of), 2) : "n/a" }
        var result: [String] = []
        for phase in suitePhases {
            guard let t = phases[phase.name] else {
                result.append("GUIDED phase=\(phase.name) samples=0")
                continue
            }
            result.append("GUIDED phase=\(phase.name) samples=\(t.samples) face=\(t.faces)"
                + " away=\(share(t.away, t.samples)) phone_guess=\(share(t.phoneGuess, t.samples))"
                + " idle=\(share(t.idle, t.samples))"
                + " scored=\(t.scored) away_scored=\(share(t.scoredAway, t.scored))"
                + " phone_guess_scored=\(share(t.scoredPhoneGuess, t.scored))"
                + " tilt_min_mean_max=\(s(t.tilt.low, 1))/\(s(t.tilt.mean, 1))/\(s(t.tilt.high, 1))"
                + " turn_mean_max=\(n(t.turn.mean, 1))/\(n(t.turn.high, 1))"
                + " eyes_min_mean_max=\(n(t.eyes.low, 2))/\(n(t.eyes.mean, 2))/\(n(t.eyes.high, 2))")
        }
        let phoneTotals = suitePhases.filter { $0.kind == .phone }.compactMap { phases[$0.name] }
        var phone = PhaseTotals()
        phone.scored = phoneTotals.reduce(0) { $0 + $1.scored }
        phone.scoredPhoneGuess = phoneTotals.reduce(0) { $0 + $1.scoredPhoneGuess }
        let screens = suitePhases.filter { $0.kind == .screen }.compactMap { phases[$0.name] }
        let screenSamples = screens.reduce(0) { $0 + $1.scored }
        let screenGuesses = screens.reduce(0) { $0 + $1.scoredPhoneGuess }
        result.append("GUIDED result settle_seconds=\(n(GuidedCheck.settleSeconds, 0))"
            + " phone_guess_while_on_phone=\(share(phone.scoredPhoneGuess, phone.scored))"
            + " phone_guess_while_facing_screen=\(share(screenGuesses, screenSamples))")
        return result
    }

    func report() -> GuidedReport {
        let suitePhases = GuidedCheck.phases(for: suite)
        let phoneTotals = suitePhases.filter { $0.kind == .phone }.compactMap { phases[$0.name] }
        let phoneScored = phoneTotals.reduce(0) { $0 + $1.scored }
        let phoneFlagged = phoneTotals.reduce(0) { $0 + $1.scoredPhoneGuess }
        let screenTotals = suitePhases.filter { $0.kind == .screen }.compactMap { phases[$0.name] }
        let screenScored = screenTotals.reduce(0) { $0 + $1.scored }
        let screenFlagged = screenTotals.reduce(0) { $0 + $1.scoredPhoneGuess }

        func pct(_ count: Int, _ total: Int) -> String {
            guard total > 0 else { return "no settled samples" }
            return "\(Int((Double(count) / Double(total) * 100).rounded()))% (\(count)/\(total))"
        }

        return GuidedReport(
            suite: suite,
            items: [
                GuidedReport.CheckItem(
                    id: "phone",
                    title: "Phone phase",
                    status: phoneScored > 0 && phoneFlagged * 2 >= phoneScored ? .pass : (phoneScored == 0 ? .fail : .info),
                    detail: "Flagged on phone: \(pct(phoneFlagged, phoneScored))"
                ),
                GuidedReport.CheckItem(
                    id: "screen",
                    title: "Screen phases",
                    status: screenScored > 0 && screenFlagged == 0 ? .pass : (screenScored == 0 ? .fail : .info),
                    detail: "False flags facing screen: \(pct(screenFlagged, screenScored))"
                )
            ]
        )
    }
}

/// Per-phase behavioral engine outcomes for `GuidedCheck.Suite.behaviorEngine`. Constant memory.
struct BehaviorGuidedSummary {
    struct PhaseTotals: Equatable {
        var samples = 0
        var observingSamples = 0
        var candidateSamples = 0
        var sustainedSamples = 0
        var pausedSamples = 0
        var maxEvidenceSeconds = 0.0
        /// Longest stretch without keyboard or mouse seen in the phase, and its cue share then.
        var maxIdleStretchSeconds = 0.0
        var idleStretchCueShareAtMax = 0.0
        var remindersEmitted = 0
        var firstReminderKind: InterventionKind?
        var firstCandidateAtSeconds: Double?
        var firstReminderAtSeconds: Double?
        var endPickupCount = 0
        /// Keyboard or mouse was used at some point in this phase.
        var inputSeen = false
        /// Candidate or sustained samples from the first input in this phase onward. A phase can
        /// open while the person is still idle from the step before; in the 27 Nov 2026 run a
        /// glance at the keyboard before the first key press read as eyes lowered for about 5 s.
        var awayAfterInputSamples = 0
    }

    private(set) var phases: [String: PhaseTotals] = [:]

    mutating func add(
        phase: String,
        phaseElapsed: Double,
        snapshot: SignalSnapshot,
        estimate: ActivityEstimate,
        behavior: BehaviorSnapshot
    ) {
        var totals = phases[phase, default: PhaseTotals()]
        totals.samples += 1
        if snapshot.input.any < ActivityEstimator.Rules().inputActiveSeconds { totals.inputSeen = true }
        if totals.inputSeen, behavior.state == .candidate || behavior.state == .sustainedPhoneUse {
            totals.awayAfterInputSamples += 1
        }
        switch behavior.state {
        case .observing:
            totals.observingSamples += 1
        case .candidate:
            totals.candidateSamples += 1
            if totals.firstCandidateAtSeconds == nil {
                totals.firstCandidateAtSeconds = phaseElapsed
            }
        case .sustainedPhoneUse:
            totals.sustainedSamples += 1
            if totals.firstCandidateAtSeconds == nil {
                totals.firstCandidateAtSeconds = phaseElapsed
            }
        case .paused, .disabled, .unavailable, .cooldown:
            totals.pausedSamples += 1
        }
        totals.maxEvidenceSeconds = max(totals.maxEvidenceSeconds, behavior.evidenceDuration)
        if behavior.idleStretchSeconds >= totals.maxIdleStretchSeconds {
            totals.maxIdleStretchSeconds = behavior.idleStretchSeconds
            totals.idleStretchCueShareAtMax = behavior.idleStretchCueShare
        }
        if let reminder = behavior.pendingIntervention {
            totals.remindersEmitted += 1
            if totals.firstReminderAtSeconds == nil {
                totals.firstReminderAtSeconds = phaseElapsed
                totals.firstReminderKind = reminder.kind
            }
        }
        totals.endPickupCount = behavior.recentPickupCount
        phases[phase] = totals
    }

    func lines() -> [String] {
        let n = ReadingText.number
        var result: [String] = []
        for phase in GuidedCheck.behaviorPhases {
            guard let t = phases[phase.name] else {
                result.append("GUIDED_BEHAVIOR phase=\(phase.name) samples=0")
                continue
            }
            result.append(
                "GUIDED_BEHAVIOR phase=\(phase.name) samples=\(t.samples)"
                + " observing=\(t.observingSamples) candidate=\(t.candidateSamples) sustained=\(t.sustainedSamples)"
                + " away_after_input=\(t.awayAfterInputSamples)"
                + " max_evidence=\(n(t.maxEvidenceSeconds, 1))s"
                + " max_idle_stretch=\(n(t.maxIdleStretchSeconds, 1))s cue_share=\(n(t.idleStretchCueShareAtMax, 2))"
                + " reminders=\(t.remindersEmitted)"
                + " first_candidate=\(ReadingText.unit(t.firstCandidateAtSeconds, 1, "s"))"
                + " first_reminder=\(ReadingText.unit(t.firstReminderAtSeconds, 1, "s"))"
                + " first_reminder_kind=\(t.firstReminderKind?.rawValue ?? "n/a")"
                + " pickups_end=\(t.endPickupCount)"
            )
        }
        let report = self.report()
        let overall = report.allPassed ? "pass" : "fail"
        let itemSummary = report.items.map { item in
            let flag: String
            switch item.status {
            case .pass: flag = "pass"
            case .fail: flag = "fail"
            case .info: flag = "info"
            }
            return "\(item.id)=\(flag)"
        }.joined(separator: " ")
        result.append("GUIDED_BEHAVIOR result=\(overall) \(itemSummary)")
        return result
    }

    func report() -> GuidedReport {
        let idle = phases["screen-idle"]
        let keyboard = phases["keyboard"]
        let quick = phases["quick-reply"]
        let returned = phases["return-screen"]
        let sustained = phases["sustained-phone"]

        let idleItem: GuidedReport.CheckItem = {
            guard let idle, idle.samples > 0 else {
                return .init(id: "idle_screen", title: "1. Idle facing screen", status: .fail, detail: "No samples recorded")
            }
            let falseTriggers = idle.candidateSamples + idle.sustainedSamples + idle.remindersEmitted
            if falseTriggers == 0 {
                return .init(id: "idle_screen", title: "1. Idle facing screen", status: .pass,
                             detail: "Stayed Observing across \(idle.samples) samples (no idle-only alert)")
            }
            return .init(id: "idle_screen", title: "1. Idle facing screen", status: .fail,
                         detail: "Entered candidate/sustained on \(idle.candidateSamples + idle.sustainedSamples) samples")
        }()

        let keyboardItem: GuidedReport.CheckItem = {
            guard let keyboard, keyboard.samples > 0 else {
                return .init(id: "keyboard", title: "2. Typing at keyboard", status: .fail, detail: "No samples recorded")
            }
            let falseTriggers = keyboard.candidateSamples + keyboard.sustainedSamples + keyboard.remindersEmitted
            if falseTriggers == 0 {
                return .init(id: "keyboard", title: "2. Typing at keyboard", status: .pass,
                             detail: "Stayed Observing across \(keyboard.samples) samples")
            }
            if keyboard.remindersEmitted > 0 || keyboard.sustainedSamples > 0 || keyboard.awayAfterInputSamples > 0 {
                return .init(id: "keyboard", title: "2. Typing at keyboard", status: .fail,
                             detail: "Entered candidate/sustained on \(keyboard.candidateSamples + keyboard.sustainedSamples) samples"
                                 + " (\(keyboard.awayAfterInputSamples) after input began)")
            }
            return .init(id: "keyboard", title: "2. Typing at keyboard", status: .info,
                         detail: "Brief candidate on \(keyboard.candidateSamples) samples before the first key or mouse use; cleared by input, no reminder")
        }()

        let quickItem: GuidedReport.CheckItem = {
            guard let quick, quick.samples > 0 else {
                return .init(id: "quick_reply", title: "3. Quick reply grace", status: .fail, detail: "No samples recorded")
            }
            let enteredGrace = quick.candidateSamples > 0 || quick.sustainedSamples > 0
            let pickups = returned?.endPickupCount ?? quick.endPickupCount
            let peak = ReadingText.number(quick.maxEvidenceSeconds, 1)
            if quick.remindersEmitted > 0 || quick.sustainedSamples > 0 {
                return .init(id: "quick_reply", title: "3. Quick reply grace", status: .fail,
                             detail: "Triggered reminder too early (peak \(peak) s)")
            }
            if !enteredGrace {
                return .init(id: "quick_reply", title: "3. Quick reply grace", status: .fail,
                             detail: "Phone posture not detected in quick-reply phase (peak \(peak) s)")
            }
            if pickups >= 1 {
                return .init(id: "quick_reply", title: "3. Quick reply grace", status: .pass,
                             detail: "Entered grace (peak \(peak) s), no reminder, short pickup counted (\(pickups) / 4)")
            }
            return .init(id: "quick_reply", title: "3. Quick reply grace", status: .info,
                         detail: "Entered grace (peak \(peak) s), no reminder (pickup needs ≥ 15 s away)")
        }()

        let sustainedItem: GuidedReport.CheckItem = {
            guard let sustained, sustained.samples > 0 else {
                return .init(id: "sustained", title: "4. Sustained phone reminder", status: .fail, detail: "No samples recorded")
            }
            let peak = ReadingText.number(sustained.maxEvidenceSeconds, 1)
            let stretch = ReadingText.number(sustained.maxIdleStretchSeconds, 0)
            let share = Int((sustained.idleStretchCueShareAtMax * 100).rounded())
            if sustained.remindersEmitted >= 1 {
                let at = ReadingText.unit(sustained.firstReminderAtSeconds, 1, "s")
                let rule = sustained.firstReminderKind == .idleAtDesk ? "idle-at-desk rule" : "posture grace"
                return .init(id: "sustained", title: "4. Sustained phone reminder", status: .pass,
                             detail: "Reminder from the \(rule) \(at) into phase (posture peak \(peak) s, idle stretch \(stretch) s, \(share)% with cues)")
            }
            return .init(id: "sustained", title: "4. Sustained phone reminder", status: .fail,
                         detail: "No reminder (posture peak \(peak) s / 45 s; idle stretch \(stretch) s / 90 s with \(share)% cues / 50%)")
        }()

        return GuidedReport(suite: .behaviorEngine, items: [idleItem, keyboardItem, quickItem, sustainedItem])
    }
}
