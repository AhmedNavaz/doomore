import Foundation

/// Where the head is relative to the straight-ahead position learned at Start.
enum Posture: String, Sendable, Equatable {
    /// A face is visible but the straight-ahead position is still being learned.
    case calibrating
    case facing
    /// Head tilted from straight-ahead, or eyes lowered. Raw value kept as "down" for the log.
    case down
    case turned
    /// A person is in view but no face was found: head far down, turned away or covered.
    case hidden
    case nobody

    /// Counts toward the phone guess: the person is there but not looking at the screen.
    var isAway: Bool { self == .down || self == .turned || self == .hidden }
}

/// A guess from simple rules. It is not a measurement of attention and cannot tell
/// a phone from a book, paper or a plate. The thresholds are starting values from one
/// unlabelled live run, two screenshots (25 Nov 2026) and one guided check by one person
/// (26 Nov 2026); they have not been checked for accuracy.
struct ActivityEstimate: Sendable, Equatable {
    var posture: Posture
    /// Keyboard or pointer used within `Rules.inputActiveSeconds`.
    var inputActive: Bool
    var secondsInState: Double
    /// Keyboard and pointer idle for `Rules.idleSeconds`, and away from the screen for at least
    /// `Rules.awayShare` of the last `Rules.windowSeconds`, and away within the last `Rules.returnSeconds`.
    var possiblePhoneUse: Bool
    /// Vision pitch minus straight-ahead, in Vision's own sign. Nil without a face or a baseline.
    var tilt: Double?
    /// Degrees turned from straight-ahead for this sample, unsigned.
    var yawOff: Double?
    /// Eye openness divided by its straight-ahead value; below 1 means eyes more closed or lowered.
    var eyeRatio: Double?
    /// Share of samples in the recent window that were away from the screen, 0 to 1.
    var awayShare = 0.0
    /// A weaker sign of looking at something other than the screen, while the posture still
    /// reads as facing: a slight downward tilt (below `Rules.tiltDegrees`) or the face sitting
    /// lower in the picture than straight-ahead (slumping toward a phone held in the lap).
    /// Too common on its own to drive a guess; the behaviour engine only counts it over a
    /// long stretch without keyboard or mouse.
    var softCue = false
    /// How far the face centre sits below its straight-ahead height, as a share of picture
    /// height. Positive is lower. Nil without a face or a baseline.
    var faceDrop: Double?

    /// Stable name used in the shared text log.
    var key: String { "\(posture.rawValue)-\(inputActive ? "active" : "idle")" }

    var headline: String {
        let input = inputActive ? "using keyboard or mouse" : "no keyboard or mouse"
        switch posture {
        case .calibrating: return "Learning your straight-ahead position — look at the screen"
        case .facing: return "Facing the screen · \(input)"
        case .down: return "Head tilted or eyes lowered · \(input)"
        case .turned: return "Turned away from the screen · \(input)"
        case .hidden: return "Someone is there but the face is hidden · \(input)"
        case .nobody: return inputActive ? "No one in view · keyboard or mouse in use" : "No one in view"
        }
    }
}

/// Turns samples into an estimate. Pure value logic: no camera, clock or system calls,
/// so every rule is unit-tested with synthetic samples. Those tests check the rules as
/// written; they say nothing about how well the rules match real behaviour.
struct ActivityEstimator {
    /// Starting values. Tune them from labelled guided-check runs.
    struct Rules: Equatable {
        /// Face samples used to learn straight-ahead (about 3 s at two samples per second).
        var calibrationSamples = 6
        /// Pitch change downward only (Vision's pitch rises when the head goes down). In the guided
        /// check (26 Nov 2026) looking down at the phone measured +8.8…+15.2°. Upward tilt of -6…-9°
        /// appeared while facing the screen again and kept the guess on for about 4 s, so it no longer counts.
        var tiltDegrees = 8.0
        /// Yaw change in either direction. The same user held the phone off to one side and
        /// turned 33–44° while looking at it (25 Nov 2026).
        var turnedDegrees = 20.0
        /// Eye openness at or below this share of straight-ahead counts as eyes lowered.
        /// Two screenshots measured about 0.68 looking at a phone (25 Nov 2026).
        var eyesLoweredRatio = 0.75
        var inputActiveSeconds = 3.0
        /// A new state must persist this long before it replaces the current one,
        /// so one odd sample neither flips the state nor restarts its timer.
        var settleSeconds = 0.4
        /// Keyboard and pointer must both be idle at least this long for the phone guess.
        var idleSeconds = 5.0
        /// The phone guess looks at this many recent seconds, so a head that bobs
        /// between phone and screen is still counted.
        var windowSeconds = 8.0
        /// Share of the window that must be away from the screen.
        var awayShare = 0.5
        /// The guess clears once the head has faced the screen this long, without waiting for
        /// the window to empty. In the first guided check it lingered about 4 s after the
        /// head came back up (26 Nov 2026).
        var returnSeconds = 1.5
        /// While the keyboard or mouse is in use the person is taken to be facing the screen, and
        /// straight-ahead is relearned from the face samples of this many recent seconds of input.
        /// In the third guided check (26 Nov 2026) the person shifted in the chair: the picture share
        /// fell from 0.22 to 0.12 and facing the screen afterwards read 12–17° turned against the
        /// position learned at Start. Zero turns relearning off.
        var relearnSeconds = 10.0
        /// Only face samples within this many degrees (yaw and upward/reclined pitch) of the current
        /// straight-ahead are used for relearning, so a head held toward a phone while a key is touched
        /// cannot drag the reference along. In the fourth guided check (26 Nov 2026) it learned +8.6°
        /// while the head was near +20°, and facing the screen then read as turned away (75% flagged).
        var relearnMaxShift = 10.0
        /// Downward pitch cap above the calibrated anchor pitch so looking down at the keyboard while
        /// typing (+4…+10° in the 26–27 Nov 2026 checks) cannot step-by-step ratchet straight-ahead
        /// pitch downward (which reached +7.4° during the guided behavior run).
        var relearnMaxDownwardPitch = 2.5
        /// Minimum eye-openness ratio (against current straight-ahead) for relearning so lowered eyes
        /// while typing at the keyboard cannot drag straight-ahead eye openness downward (dropped from
        /// ~0.30 to 0.158 in the 26 Nov 2026 negative check).
        var relearnMinEyeRatio = 0.80
        /// Without a face, at least this share of the picture must be a person to count as "face hidden".
        var personCoverage = 0.05
        /// Soft cue: downward tilt from this many degrees (up to `tiltDegrees`). In the guided behavior
        /// test of 27 Nov 2026 the person held the phone high: sustained use read +1.8/+3.7/+5.6° (p25/p50/p75)
        /// while idle facing the screen never exceeded +3.4°.
        var softTiltDegrees = 4.0
        /// Soft cue: face centre this much lower in the picture than straight-ahead (share of picture
        /// height). The same test measured 0.36 at the screen and 0.22–0.25 on the phone (88% of samples
        /// at least 0.06 lower), but also 43% of samples after the phone went down, because the person
        /// stayed slumped; so it is a soft cue only.
        var faceDropShare = 0.06
    }

    struct Baseline: Equatable {
        var pitch: Double?
        var yaw: Double?
        var eyeOpenness: Double?
        /// Normalized vertical centre of the face box (0 bottom, 1 top).
        var faceCenterY: Double? = nil
    }

    private struct State: Equatable {
        var posture: Posture
        var inputActive: Bool
    }

    var rules = Rules()
    private(set) var baseline: Baseline?
    /// Initial calibrated pitch used as the ceiling anchor for downward pitch relearning so
    /// repeated keyboard glances cannot ratchet `baseline.pitch` downward while still allowing
    /// reclining backward and returning upright while typing.
    private var anchorPitch: Double?
    private var calibration: [(head: HeadPose, eyes: Double?, faceY: Double?)] = []
    private var current: (state: State, since: Double)?
    private var pending: (state: State, since: Double)?
    private var recent: [(time: Double, away: Bool)] = []
    private var lastAway: Double?
    private var activeFaces: [(time: Double, head: HeadPose, eyes: Double?, faceY: Double?)] = []

    init(rules: Rules = Rules()) { self.rules = rules }

    /// Forgets everything, including the straight-ahead position.
    mutating func reset() {
        recalibrate()
        current = nil
        pending = nil
    }

    /// Learns straight-ahead again from the next face samples, and forgets the recent window.
    mutating func recalibrate() {
        baseline = nil
        anchorPitch = nil
        calibration.removeAll()
        recent.removeAll()
        lastAway = nil
        activeFaces.removeAll()
    }

    private static func isEligibleForRelearn(_ head: HeadPose, eyes: Double?, baseline: Baseline,
                                             anchorPitch: Double?, rules: Rules) -> Bool {
        if let yaw = head.yaw, let neutral = baseline.yaw, abs(yaw - neutral) > rules.relearnMaxShift { return false }
        if let pitch = head.pitch, let neutral = baseline.pitch {
            let delta = pitch - neutral
            if abs(delta) > rules.relearnMaxShift { return false }
            let downwardCeiling = (anchorPitch ?? neutral) + rules.relearnMaxDownwardPitch
            if pitch > downwardCeiling { return false }
        }
        if let eyes, let neutral = baseline.eyeOpenness, neutral > 0, eyes / neutral < rules.relearnMinEyeRatio {
            return false
        }
        return true
    }

    mutating func update(_ snapshot: SignalSnapshot) -> ActivityEstimate {
        let head = snapshot.vision.head
        let eyes = snapshot.vision.eyeOpenness
        let faceY = snapshot.vision.faceCenterY
        if baseline == nil, let head {
            calibration.append((head, eyes, faceY))
            if calibration.count >= max(1, rules.calibrationSamples) {
                let calibratedPitch = Self.median(calibration.compactMap(\.head.pitch))
                baseline = Baseline(pitch: calibratedPitch,
                                    yaw: Self.median(calibration.compactMap(\.head.yaw)),
                                    eyeOpenness: Self.median(calibration.compactMap(\.eyes)),
                                    faceCenterY: Self.median(calibration.compactMap(\.faceY)))
                anchorPitch = calibratedPitch
                calibration.removeAll()
            }
        }

        let typing = snapshot.input.any < rules.inputActiveSeconds
        if baseline != nil, rules.relearnSeconds > 0 {
            // A sample counts only once more input has followed it, so the seconds after the
            // last key press (when the head may already be down at a phone) never teach straight-ahead.
            let lastInput = snapshot.time - snapshot.input.any
            if let last = activeFaces.last, snapshot.time < last.time { activeFaces.removeAll() }
            if typing, let head, let baseline,
               Self.isEligibleForRelearn(head, eyes: eyes, baseline: baseline, anchorPitch: anchorPitch, rules: rules) {
                activeFaces.append((snapshot.time, head, eyes, faceY))
            }
            activeFaces.removeAll { $0.time < snapshot.time - rules.relearnSeconds - rules.inputActiveSeconds }
            let confirmed = activeFaces.filter { $0.time <= lastInput && $0.time >= lastInput - rules.relearnSeconds }
            if typing, confirmed.count >= max(1, rules.calibrationSamples) {
                baseline = Baseline(pitch: Self.median(confirmed.compactMap(\.head.pitch)),
                                    yaw: Self.median(confirmed.compactMap(\.head.yaw)),
                                    eyeOpenness: Self.median(confirmed.compactMap(\.eyes)),
                                    faceCenterY: Self.median(confirmed.compactMap(\.faceY)))
            }
        }

        var tilt: Double?
        var yawOff: Double?
        var eyeRatio: Double?
        var faceDrop: Double?
        if let head, let baseline {
            if let faceY, let neutral = baseline.faceCenterY { faceDrop = neutral - faceY }
            if let pitch = head.pitch, let neutral = baseline.pitch { tilt = pitch - neutral }
            if let yaw = head.yaw, let neutral = baseline.yaw { yawOff = abs(yaw - neutral) }
            if let eyes, let neutral = baseline.eyeOpenness, neutral > 0 { eyeRatio = eyes / neutral }
        }

        let posture: Posture
        if head != nil {
            if baseline == nil {
                posture = .calibrating
            } else if let yawOff, yawOff >= rules.turnedDegrees {
                posture = .turned
            } else if let tilt, tilt >= rules.tiltDegrees {
                posture = .down
            } else if let eyeRatio, eyeRatio <= rules.eyesLoweredRatio {
                posture = .down
            } else {
                posture = .facing
            }
        } else {
            posture = snapshot.vision.personCoverage >= rules.personCoverage ? .hidden : .nobody
        }

        let now = snapshot.time
        let observed = State(posture: posture, inputActive: typing)
        if let held = current, now >= held.since {
            if observed == held.state {
                pending = nil
            } else if let waiting = pending, waiting.state == observed, now >= waiting.since {
                if now - waiting.since >= rules.settleSeconds {
                    current = waiting
                    pending = nil
                }
            } else {
                pending = (observed, now)
            }
        } else {
            // First sample, or a clock that went backwards: start again from this sample.
            current = (observed, now)
            pending = nil
        }

        if let last = recent.last, now < last.time { recent.removeAll(); lastAway = nil }
        recent.append((now, posture.isAway))
        if posture.isAway { lastAway = now }
        let recentlyAway = lastAway.map { now - $0 < rules.returnSeconds } ?? false
        recent.removeAll { $0.time < now - rules.windowSeconds }
        let share = Double(recent.filter(\.away).count) / Double(recent.count)
        let span = now - (recent.first?.time ?? now)

        let held = current ?? (observed, now)
        return ActivityEstimate(
            posture: held.state.posture,
            inputActive: held.state.inputActive,
            secondsInState: max(0, now - held.since),
            possiblePhoneUse: posture != .nobody
                && recentlyAway
                && snapshot.input.any >= rules.idleSeconds
                && span >= rules.windowSeconds / 2
                && share >= rules.awayShare,
            tilt: tilt,
            yawOff: yawOff,
            eyeRatio: eyeRatio,
            awayShare: share,
            softCue: posture == .facing
                && ((tilt ?? -.infinity) >= rules.softTiltDegrees || (faceDrop ?? -.infinity) >= rules.faceDropShare),
            faceDrop: faceDrop)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
