import AppKit
import CoreAudio
import KeepAliveCore
import Observation

private let events = EventLog.shared

/// Decides when to keep the speakers awake (schedule, overrides, sleep, device
/// presence) and drives the engine accordingly.
@MainActor
@Observable
final class Coordinator {
    enum Status: Equatable {
        case active
        case outsideSchedule
        case off
        case paused
        /// The Mac is asleep (or just waking); the speakers are allowed to sleep too.
        case asleep
        case deviceMissing(String)
        case error(String)

        var logDescription: String {
            switch self {
            case .active: "keeping speakers awake"
            case .outsideSchedule: "outside scheduled hours"
            case .off: "off"
            case .paused: "paused"
            case .asleep: "Mac asleep"
            case .deviceMissing(let name): "waiting for \(name)"
            case .error(let message): "problem: \(message)"
            }
        }
    }

    let devices = AudioDeviceMonitor()
    let profiles = ProfileStore()

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            reevaluate()
        }
    }

    private(set) var override: ActivityOverride?
    private(set) var status: Status = .off {
        didSet {
            if status != oldValue { events.record("Status: \(status.logDescription)") }
        }
    }
    private(set) var nextBurst: Date?
    /// When the schedule or override next changes.
    private(set) var changesAt: Date?
    /// Whether the schedule/override currently calls for keeping awake.
    private(set) var shouldBeActive = false

    @ObservationIgnored private let engine = KeepAliveEngine()
    @ObservationIgnored private var running: RunningConfig?
    @ObservationIgnored private var burstTask: Task<Void, Never>?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var isAsleep = false

    /// Everything that requires restarting the engine when it changes.
    private struct RunningConfig: Equatable {
        var deviceID: AudioDeviceID
        var profile: SpeakerProfile
    }

    init() {
        events.record("Speaker Keep-Alive \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") started")
        // Our tone shouldn't keep the Mac awake: if the Mac idle-sleeps, the
        // speakers can sleep too.
        KeepAliveEngine.allowIdleSleepDuringPlayback()
        settings = AppSettings.load()
        pickInitialDevice()

        profiles.onChange = { [weak self] in self?.reevaluate() }
        devices.onChange = { [weak self] in self?.reevaluate() }
        engine.onConfigurationChange = { [weak self] reason in
            events.record("Audio device changed (\(reason)); restarting the tone")
            self?.restartSoon()
        }
        observeSystem()

        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        reevaluate()
    }

    func showEventLog() {
        NSWorkspace.shared.open(EventLog.shared.fileURL)
    }

    // MARK: - Derived state

    var activeProfile: SpeakerProfile {
        profiles.profile(id: settings.profileID) ?? profiles.fallback
    }

    var targetDevice: AudioOutputDevice? {
        if let uid = settings.deviceUID {
            return devices.device(uid: uid)
        }
        return devices.defaultOutput
    }

    var targetDeviceName: String {
        targetDevice?.name ?? settings.deviceName ?? "System default output"
    }

    var menuBarSymbol: String {
        switch status {
        // Bookshelf speakers, so it isn't mistaken for the system volume icon.
        case .active: "hifispeaker.2.fill"
        case .outsideSchedule, .paused, .off, .asleep: "hifispeaker.2"
        case .deviceMissing, .error: "hifispeaker.badge.exclamationmark"
        }
    }

    // MARK: - Actions

    func selectDevice(_ device: AudioOutputDevice?) {
        settings.deviceUID = device?.uid
        settings.deviceName = device?.name
        settings.hasChosenDevice = true
    }

    func keepAwake(for duration: TimeInterval) {
        setOverride(.keepAwake(until: .now.addingTimeInterval(duration)))
    }

    func keepAwakeUntilMidnight() {
        let midnight = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        setOverride(.keepAwake(until: midnight ?? .now.addingTimeInterval(3600)))
    }

    func pause(for duration: TimeInterval) {
        setOverride(.pause(until: .now.addingTimeInterval(duration)))
    }

    func clearOverride() {
        setOverride(nil)
    }

    /// Plays one burst now, using `tone` if given (e.g. an unsaved draft in the
    /// profile editor) or the active profile.
    func playTestBurst(tone: ToneSettings? = nil) {
        guard let device = targetDevice else { return }
        let tone = tone ?? activeProfile.tone
        if let running, running.profile.keepStreamOpen, engine.isRunning {
            engine.update(tone: tone)
            engine.playBurst()
            restoreToneAfter(tone)
            return
        }
        testTask?.cancel()
        testTask = Task { [weak self] in
            await self?.playStandaloneBurst(deviceID: device.id, tone: tone)
        }
    }

    // MARK: - Decision

    func reevaluate() {
        let decision = ActivityPolicy.decide(schedule: settings.schedule, override: override, now: .now)
        override = decision.override
        changesAt = decision.changesAt
        shouldBeActive = decision.isActive

        guard decision.isActive, !isAsleep else {
            stopKeepAlive()
            if isAsleep {
                status = .asleep
            } else if override != nil {
                status = .paused
            } else {
                status = settings.schedule.mode == .off ? .off : .outsideSchedule
            }
            return
        }
        guard let device = targetDevice else {
            stopKeepAlive()
            status = .deviceMissing(targetDeviceName)
            return
        }

        let config = RunningConfig(deviceID: device.id, profile: activeProfile)
        if config != running {
            startKeepAlive(config)
        } else if config.profile.keepStreamOpen, !engine.isPlaying(on: device.id) {
            // Belt and braces: the stream should never move or stop on its own,
            // but if it does the speakers silently stop getting the tone.
            events.record("Tone was no longer playing to \(device.name) (id \(device.id)); restarting it")
            startKeepAlive(config)
        }
    }

    private func setOverride(_ newValue: ActivityOverride?) {
        override = newValue
        reevaluate()
    }

    private func startKeepAlive(_ config: RunningConfig) {
        stopKeepAlive()
        let profile = config.profile
        if profile.keepStreamOpen {
            do {
                try engine.start(deviceID: config.deviceID, tone: profile.tone)
            } catch {
                // Leave `running` nil so the next tick retries.
                events.record("Couldn't start the tone on device \(config.deviceID): \(error.localizedDescription)")
                status = .error(error.localizedDescription)
                return
            }
        }
        running = config
        status = .active
        events.record("Tone started: profile \(profile.id), device \(config.deviceID), \(profile.tone.frequencyHz.formatted()) Hz at \(profile.tone.levelDBFS.formatted()) dBFS, \(profile.tone.burstSeconds.formatted()) s every \(profile.tone.intervalSeconds.formatted()) s, stream open \(profile.keepStreamOpen)")

        let interval = profile.tone.intervalSeconds
        burstTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.nextBurst = .now.addingTimeInterval(interval)
                if profile.keepStreamOpen {
                    self.engine.playBurst()
                } else {
                    await self.playStandaloneBurst(deviceID: config.deviceID, tone: profile.tone)
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func stopKeepAlive() {
        burstTask?.cancel()
        burstTask = nil
        running = nil
        nextBurst = nil
        engine.stop()
    }

    /// Opens the device just long enough for one burst.
    private func playStandaloneBurst(deviceID: AudioDeviceID, tone: ToneSettings) async {
        do {
            try engine.start(deviceID: deviceID, tone: tone)
        } catch {
            status = .error(error.localizedDescription)
            return
        }
        engine.playBurst()
        if running != nil, case .error = status {
            status = .active
        }
        try? await Task.sleep(for: .seconds(tone.burstSeconds + 0.3))
        // Don't stop a stream that a profile with keepStreamOpen now owns.
        if running?.profile.keepStreamOpen != true {
            engine.stop()
        }
    }

    private func restoreToneAfter(_ tone: ToneSettings) {
        testTask?.cancel()
        testTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(tone.burstSeconds + 0.3))
            guard !Task.isCancelled, let self, let running = self.running else { return }
            self.engine.update(tone: running.profile.tone)
        }
    }

    /// The audio hardware changed under us; rebuild once things settle.
    private func restartSoon() {
        stopKeepAlive()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.devices.refresh()
            self?.reevaluate()
        }
    }

    // MARK: - System events

    private func pickInitialDevice() {
        guard !settings.hasChosenDevice else { return }
        if let digital = devices.likelyDigitalOutput {
            selectDevice(digital)
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                events.record("Mac going to sleep")
                self?.isAsleep = true
                self?.reevaluate()
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                events.record("Mac woke up")
                // Give USB audio devices a moment to come back after wake.
                _ = Task {
                    try? await Task.sleep(for: .seconds(3))
                    self?.isAsleep = false
                    self?.devices.refresh()
                    self?.reevaluate()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
    }
}
