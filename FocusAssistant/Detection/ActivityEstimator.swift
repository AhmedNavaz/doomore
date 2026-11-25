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
        /// Only face samples within this many degrees (yaw and pitch) of the current straight-ahead
        /// are used for relearning, so a head held toward a phone while a key is touched cannot drag
        /// the reference along. In the fourth guided check (26 Nov 2026) it learned +8.6° while the head
        /// was near +20°, and facing the screen then read as turned away (75% flagged).
        var relearnMaxShift = 10.0
        /// Without a face, at least this share of the picture must be a person to count as "face hidden".
        var personCoverage = 0.05
    }

    struct Baseline: Equatable {
        var pitch: Double?
        var yaw: Double?
        var eyeOpenness: Double?
    }

    private struct State: Equatable {
        var posture: Posture
        var inputActive: Bool
    }

    var rules = Rules()
    private(set) var baseline: Baseline?
    private var calibration: [(head: HeadPose, eyes: Double?)] = []
    private var current: (state: State, since: Double)?
    private var pending: (state: State, since: Double)?
    private var recent: [(time: Double, away: Bool)] = []
    private var lastAway: Double?
    private var activeFaces: [(time: Double, head: HeadPose, eyes: Double?)] = []

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
        calibration.removeAll()
        recent.removeAll()
        lastAway = nil
        activeFaces.removeAll()
    }

    private static func isNear(_ head: HeadPose, _ baseline: Baseline, within limit: Double) -> Bool {
        if let yaw = head.yaw, let neutral = baseline.yaw, abs(yaw - neutral) > limit { return false }
        if let pitch = head.pitch, let neutral = baseline.pitch, abs(pitch - neutral) > limit { return false }
        return true
    }

    mutating func update(_ snapshot: SignalSnapshot) -> ActivityEstimate {
        let head = snapshot.vision.head
        let eyes = snapshot.vision.eyeOpenness
        if baseline == nil, let head {
            calibration.append((head, eyes))
            if calibration.count >= max(1, rules.calibrationSamples) {
                baseline = Baseline(pitch: Self.median(calibration.compactMap(\.head.pitch)),
                                    yaw: Self.median(calibration.compactMap(\.head.yaw)),
                                    eyeOpenness: Self.median(calibration.compactMap(\.eyes)))
                calibration.removeAll()
            }
        }

        let typing = snapshot.input.any < rules.inputActiveSeconds
        if baseline != nil, rules.relearnSeconds > 0 {
            // A sample counts only once more input has followed it, so the seconds after the
            // last key press (when the head may already be down at a phone) never teach straight-ahead.
            let lastInput = snapshot.time - snapshot.input.any
            if let last = activeFaces.last, snapshot.time < last.time { activeFaces.removeAll() }
            if typing, let head, let baseline, Self.isNear(head, baseline, within: rules.relearnMaxShift) {
                activeFaces.append((snapshot.time, head, eyes))
            }
            activeFaces.removeAll { $0.time < snapshot.time - rules.relearnSeconds - rules.inputActiveSeconds }
            let confirmed = activeFaces.filter { $0.time <= lastInput && $0.time >= lastInput - rules.relearnSeconds }
            if typing, confirmed.count >= max(1, rules.calibrationSamples) {
                baseline = Baseline(pitch: Self.median(confirmed.compactMap(\.head.pitch)),
                                    yaw: Self.median(confirmed.compactMap(\.head.yaw)),
                                    eyeOpenness: Self.median(confirmed.compactMap(\.eyes)))
            }
        }

        var tilt: Double?
        var yawOff: Double?
        var eyeRatio: Double?
        if let head, let baseline {
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
            awayShare: share)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
