import SwiftUI
import AppKit

/// How loudly a reminder is delivered.
enum AlertStyle: String, CaseIterable, Identifiable, Sendable {
    /// Full-screen warning on every display plus a repeating sound, until answered.
    case screenAndSound
    /// Only the macOS notification (with its sound).
    case notificationOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .screenAndSound: return "Full-screen warning + sound"
        case .notificationOnly: return "Notification only"
        }
    }
}

/// What the person must do before the full-screen warning lets go. Nothing here touches their
/// files or windows; it only adds friction so the phone habit gets interrupted.
enum AlertChallenge: String, CaseIterable, Identifiable, Sendable {
    case none, wait, math, typePhrase, stretch

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None, answer right away"
        case .wait: return "Wait 15 seconds"
        case .math: return "Solve a math problem"
        case .typePhrase: return "Type a commitment sentence"
        case .stretch: return "Stand up and stretch (30 seconds)"
        }
    }
    var detail: String {
        switch self {
        case .none: return "The buttons work immediately."
        case .wait: return "The buttons unlock after a 15 second countdown. Puts the phone down, at least."
        case .math: return "Answer a two-step arithmetic problem to unlock. Wakes the thinking part up."
        case .typePhrase: return "Type the sentence shown, exactly, to unlock. Makes you say it on purpose."
        case .stretch: return "A 30 second countdown that asks you to stand up and move, then unlocks."
        }
    }
}

/// Shared by the warning on every display, so solving it on one screen unlocks them all.
@MainActor
final class WarningState: ObservableObject {
    static let quotes = [
        "You can scroll later. Right now you are building something.",
        "Every minute on the phone is a minute your goal waits.",
        "Discipline is choosing what you want most over what you want now.",
        "The work you avoid gets heavier. Start it now.",
        "Future you is counting on the next 25 minutes.",
        "Motivation follows action. Begin, and the rest comes.",
    ]
    static let phrases = [
        "I choose my work over my phone",
        "I am in control of my attention",
        "Deep work first, phone later",
    ]

    let challenge: AlertChallenge
    let quote: String?
    @Published var secondsLeft = 0
    @Published var input = ""
    @Published var unlocked: Bool
    let question: String
    let answer: String
    private var timer: Timer?

    init(challenge: AlertChallenge, showQuote: Bool) {
        self.challenge = challenge
        quote = showQuote ? Self.quotes.randomElement() : nil
        let a = Int.random(in: 12...39), b = Int.random(in: 3...9), c = Int.random(in: 2...9)
        switch challenge {
        case .math:
            question = "\(a) × \(b) − \(c) = ?"; answer = String(a * b - c)
        case .typePhrase:
            let p = Self.phrases.randomElement() ?? Self.phrases[0]
            question = p; answer = p
        default:
            question = ""; answer = ""
        }
        unlocked = challenge == .none
        switch challenge {
        case .wait: secondsLeft = 15
        case .stretch: secondsLeft = 30
        default: break
        }
        if secondsLeft > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    private func tick() {
        secondsLeft = max(0, secondsLeft - 1)
        if secondsLeft == 0 { unlocked = true; timer?.invalidate(); timer = nil }
    }

    func submit() {
        let a = input.trimmingCharacters(in: .whitespaces)
        if challenge == .math ? a == answer : a.lowercased() == answer.lowercased() { unlocked = true }
        else { input = "" }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

/// Shows a full-screen warning on every display and loops an alert sound until the person
/// answers. Holds no camera data; it only knows the reminder text.
@MainActor
final class AlertPresenter {
    var onAction: ((InterventionAction) -> Void)?
    private var windows: [NSWindow] = []
    private var sound: NSSound?
    private var state: WarningState?
    private let breakSeconds: Double

    init(breakSeconds: Double) { self.breakSeconds = breakSeconds }

    var isShowing: Bool { !windows.isEmpty }

    /// `onAction` overrides the shared handler, for a preview whose buttons only close it.
    func show(_ event: InterventionEvent, challenge: AlertChallenge = .none, showQuote: Bool = false,
              hideOtherApps: Bool = false, onAction override: ((InterventionAction) -> Void)? = nil) {
        dismiss()
        if hideOtherApps {
            // Hides, never quits: every window and unsaved document stays exactly as it was.
            let me = ProcessInfo.processInfo.processIdentifier
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.processIdentifier != me { app.hide() }
        }
        let state = WarningState(challenge: challenge, showQuote: showQuote)
        self.state = state
        let view = PhoneWarningView(message: event.kind.headline, breakSeconds: breakSeconds, state: state) { [weak self] action in
            if let override { override(action) } else { self?.onAction?(action) }
        }
        for screen in NSScreen.screens {
            let window = WarningWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = NSHostingView(rootView: view)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        let alert = NSSound(named: "Sosumi")
        alert?.loops = true
        alert?.play()
        sound = alert
    }

    func dismiss() {
        sound?.stop()
        sound = nil
        state?.stop()
        state = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

/// Borderless windows refuse key status by default, which would make the buttons need two clicks.
private final class WarningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct PhoneWarningView: View {
    let message: String
    let breakSeconds: Double
    @ObservedObject var state: WarningState
    let respond: (InterventionAction) -> Void
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.55, green: 0.05, blue: 0.12), Color(red: 0.95, green: 0.25, blue: 0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.94)
            VStack(spacing: 26) {
                ZStack {
                    Circle().fill(.white.opacity(0.18)).frame(width: 150, height: 150)
                        .scaleEffect(pulse ? 1.12 : 0.95)
                    Image(systemName: "iphone.gen3.slash").font(.system(size: 64, weight: .semibold))
                }
                VStack(spacing: 8) {
                    Text("Phone down.")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                    Text(message)
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .opacity(0.85).multilineTextAlignment(.center)
                }
                if let quote = state.quote {
                    Text("“\(quote)”")
                        .font(.system(size: 22, weight: .regular, design: .serif).italic())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 28).padding(.vertical, 16)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                }
                challengeView
                HStack(spacing: 12) {
                    pill("Back to work", prominent: true) { respond(.backToWork) }
                        .keyboardShortcut(.defaultAction)
                    pill(ReminderNotification.breakTitle(seconds: breakSeconds), prominent: false) {
                        respond(.takingABreak(duration: breakSeconds))
                    }
                    pill("Not a distraction", prominent: false) { respond(.notADistraction) }
                }
                .disabled(!state.unlocked)
                .opacity(state.unlocked ? 1 : 0.45)
            }
            .foregroundStyle(.white)
            .padding(48)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } }
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .padding(.horizontal, 22).padding(.vertical, 12)
                .foregroundStyle(prominent ? Color(red: 0.7, green: 0.08, blue: 0.12) : .white)
                .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.2)), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var challengeView: some View {
        if state.unlocked {
            if state.challenge != .none {
                Label("Unlocked. Go get it.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
            }
        } else {
            switch state.challenge {
            case .wait:
                countdown(title: "Put the phone down", seconds: state.secondsLeft, total: 15)
            case .stretch:
                countdown(title: "Stand up, roll your shoulders, breathe", seconds: state.secondsLeft, total: 30)
            case .math:
                challengeField(prompt: "Solve to unlock", text: state.question)
            case .typePhrase:
                challengeField(prompt: "Type this to unlock", text: state.question)
            case .none:
                EmptyView()
            }
        }
    }

    private func countdown(title: String, seconds: Int, total: Int) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 8)
                Circle().trim(from: 0, to: CGFloat(total - seconds) / CGFloat(total))
                    .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: seconds)
                Text("\(seconds)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 92, height: 92)
        }
    }

    private func challengeField(prompt: String, text: String) -> some View {
        VStack(spacing: 12) {
            Text(prompt).font(.system(size: 16, weight: .medium, design: .rounded)).opacity(0.8)
            Text(text).font(.system(size: 36, weight: .bold, design: .rounded))
            TextField("", text: $state.input)
                .textFieldStyle(.plain)
                .font(.system(size: 22, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(12)
                .frame(width: 420)
                .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit { state.submit() }
        }
    }
}
