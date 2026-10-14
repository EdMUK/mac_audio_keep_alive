import AVFoundation
import AudioToolbox
import KeepAliveCore

/// Plays the keep-alive tone to one specific output device, independent of the
/// system default output.
@MainActor
final class KeepAliveEngine {
    enum EngineError: LocalizedError {
        case noOutputUnit
        case couldNotSelectDevice(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutputUnit: "The audio output isn't available."
            case .couldNotSelectDevice(let status): "Couldn't use the selected output device (error \(status))."
            }
        }
    }

    /// Called when the audio hardware changes under a running engine, e.g. the
    /// device is unplugged or its sample rate changes.
    var onConfigurationChange: (() -> Void)?

    private var engine: AVAudioEngine?
    private var generator: ToneGenerator?
    private var configurationObserver: (any NSObjectProtocol)?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start(deviceID: AudioDeviceID, tone: ToneSettings) throws {
        stop()
        let engine = AVAudioEngine()
        let output = engine.outputNode
        guard let unit = output.audioUnit else { throw EngineError.noOutputUnit }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw EngineError.couldNotSelectDevice(status) }

        let deviceRate = output.outputFormat(forBus: 0).sampleRate
        let sampleRate = deviceRate > 0 ? deviceRate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let generator = ToneGenerator(sampleRate: sampleRate)
        generator.configure(tone)

        let source = Self.makeSourceNode(format: format, generator: generator)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        try engine.start()

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }
        self.engine = engine
        self.generator = generator
    }

    func update(tone: ToneSettings) {
        generator?.configure(tone)
    }

    func playBurst() {
        generator?.requestBurst()
    }

    func setContinuous(_ on: Bool) {
        generator?.setContinuous(on)
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.stop()
        engine = nil
        generator = nil
    }

    /// Built outside the main actor: the render block runs on the real-time
    /// audio thread and must not inherit main-actor isolation.
    private nonisolated static func makeSourceNode(format: AVAudioFormat, generator: ToneGenerator) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            generator.render(frameCount: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(audioBufferList))
            return noErr
        }
    }
}
