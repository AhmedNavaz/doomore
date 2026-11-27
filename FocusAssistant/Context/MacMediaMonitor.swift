import CoreAudio
import Foundation
import IOKit.pwr_mgt

/// Whether this Mac itself is playing video or sound. Reads only yes/no system flags: no
/// app names, titles, URLs or audio. Nil means the flag could not be read.
struct MacMediaState: Sendable, Equatable {
    /// Another process holds a "prevent display sleep" assertion. Browsers and video players
    /// take one while a video plays, so sitting still without input is expected then.
    var videoPlaying: Bool?
    /// The default output device is running for some process. Coarse: it is also on while
    /// this app speaks a guided-check cue, and with a headset whose microphone this app is
    /// using. Logged for tuning only; nothing decides on it yet.
    var audioPlaying: Bool?

    static let unknown = MacMediaState(videoPlaying: nil, audioPlaying: nil)

    /// Short form for the shared text log.
    static func key(_ value: Bool?) -> String {
        guard let value else { return "n/a" }
        return value ? "on" : "off"
    }
}

/// Reads `MacMediaState` at most once per `interval`, so the 2 Hz sample loop does not ask
/// the power manager and the audio server on every sample.
@MainActor
final class MacMediaMonitor {
    private let interval: Double
    private var cached = MacMediaState.unknown
    private var readAt = -Double.infinity

    init(interval: Double = 2.0) {
        self.interval = interval
    }

    func current(at now: Double = ProcessInfo.processInfo.systemUptime) -> MacMediaState {
        if now - readAt >= interval || now < readAt {
            cached = MacMediaState(videoPlaying: Self.readVideoPlaying(), audioPlaying: Self.readAudioPlaying())
            readAt = now
        }
        return cached
    }

    /// A media-playback display-sleep assertion held by any process other than this one.
    nonisolated static func readVideoPlaying() -> Bool? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for (pid, assertions) in byProcess where pid.int32Value != ownPID {
            for assertion in assertions where isVideoAssertion(type: assertion["AssertType"] as? String,
                                                                name: assertion["AssertName"] as? String) {
                return true
            }
        }
        return false
    }

    /// kIOPMAssertionTypePreventUserIdleDisplaySleep and the older kIOPMAssertionTypeNoDisplaySleep.
    nonisolated static let displaySleepTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Words that media players and browsers put in the assertion name while a video plays
    /// ("Playing video", "Video Wake Lock", "… is playing", "media playback").
    nonisolated static let mediaNameWords = ["video", "media", "play", "movie", "wake lock"]

    /// Whether one assertion looks like video playback. A display-sleep type alone is not
    /// enough: Electron apps (this coding app, Slack, VS Code) hold one named "Electron" for
    /// as long as they run, which read as "video on" all the time. The name is only matched
    /// here, never stored or logged.
    nonisolated static func isVideoAssertion(type: String?, name: String?) -> Bool {
        guard let type, displaySleepTypes.contains(type), let name else { return false }
        let lowered = name.lowercased()
        return mediaNameWords.contains { lowered.contains($0) }
    }

    /// Whether the default output device is running for any process.
    nonisolated static func readAudioPlaying() -> Bool? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }
}
