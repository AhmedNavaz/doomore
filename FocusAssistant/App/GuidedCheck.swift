import Foundation

/// A short labelled test. The app speaks each instruction, so the person does not need to
/// watch the screen while holding the phone, and every logged reading carries the phase it
/// belongs to. That turns a run into labelled data: what the signals look like while the
/// person faces the screen without typing, and while they use the phone.
enum GuidedCheck {
    enum Kind: Equatable {
        /// Facing the screen without input: any phone guess here is a false alarm.
        case screen
        /// Using the phone: a phone guess here is a hit.
        case phone
        /// Preparation with keyboard or mouse in use; logged but not scored.
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

    static let finishedCue = "Done. Thank you."

    /// The start of each phase is left out of the score because people take time to move.
    /// In the first check (26 Nov 2026) the head went down about 4 s after the phone cue and
    /// came back up about 5 s after the screen cue. Those samples are still logged.
    static let settleSeconds = 5.0

    static var totalSeconds: Double { phases.reduce(0) { $0 + $1.seconds } }

    /// The phase at `elapsed` seconds since the check began; nil before the start or once finished.
    static func phaseIndex(at elapsed: Double) -> Int? {
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        var end = 0.0
        for (index, phase) in phases.enumerated() {
            end += phase.seconds
            if elapsed < end { return index }
        }
        return nil
    }

    /// Whether a sample at `elapsed` counts toward the score: inside a phase and past its settle time.
    static func isScored(at elapsed: Double) -> Bool {
        guard let index = phaseIndex(at: elapsed) else { return false }
        let phaseStart = phases[..<index].reduce(0) { $0 + $1.seconds }
        return elapsed - phaseStart >= settleSeconds
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

    private(set) var phases: [String: PhaseTotals] = [:]

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
        let n = ReadingText.number, s = ReadingText.signed
        func share(_ count: Int, _ of: Int) -> String { of > 0 ? n(Double(count) / Double(of), 2) : "n/a" }
        var result: [String] = []
        for phase in GuidedCheck.phases {
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
        let phoneTotals = GuidedCheck.phases.filter { $0.kind == .phone }.compactMap { phases[$0.name] }
        var phone = PhaseTotals()
        phone.scored = phoneTotals.reduce(0) { $0 + $1.scored }
        phone.scoredPhoneGuess = phoneTotals.reduce(0) { $0 + $1.scoredPhoneGuess }
        let screens = GuidedCheck.phases.filter { $0.kind == .screen }.compactMap { phases[$0.name] }
        let screenSamples = screens.reduce(0) { $0 + $1.scored }
        let screenGuesses = screens.reduce(0) { $0 + $1.scoredPhoneGuess }
        result.append("GUIDED result settle_seconds=\(n(GuidedCheck.settleSeconds, 0))"
            + " phone_guess_while_on_phone=\(share(phone.scoredPhoneGuess, phone.scored))"
            + " phone_guess_while_facing_screen=\(share(screenGuesses, screenSamples))")
        return result
    }
}
