import AudioToolbox
import CoreAudio
import KeepAliveCore

/// Plays the keep-alive tone to one specific output device, independent of the
/// system default output.
///
/// This uses a HAL output unit bound to the device rather than AVAudioEngine:
/// AVAudioEngine's output node follows the system default, so when AirPods
/// connected and became the default output, the tone went to them instead.
@MainActor
final class KeepAliveEngine {
    enum EngineError: LocalizedError {
        case noOutputUnit
        case couldNotSelectDevice(OSStatus)
        case couldNotStart(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutputUnit: "The audio output isn't available."
            case .couldNotSelectDevice(let status): "Couldn't use the selected output device (error \(status))."
            case .couldNotStart(let status): "Couldn't start audio output (error \(status))."
            }
        }
    }

    /// Called when the device changes under a running engine, e.g. its sample
    /// rate changes or it stops working.
    var onConfigurationChange: (() -> Void)?

    private var unit: AudioUnit?
    private var deviceID: AudioDeviceID?
    private var generator: Unmanaged<ToneGenerator>?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    var isRunning: Bool {
        guard let unit else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        return running != 0
    }

    /// Whether the tone is actually being sent to `deviceID` right now.
    func isPlaying(on deviceID: AudioDeviceID) -> Bool {
        guard isRunning, let unit else { return false }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr else { return false }
        return current == deviceID
    }

    /// By default, any running audio output stops macOS idle-sleeping (coreaudiod
    /// takes a PreventUserIdleSystemSleep assertion). This opts this process
    /// out, so the keep-alive tone never keeps the Mac awake on its own.
    static func allowIdleSleepDuringPlayback() {
        var allowed: UInt32 = 1
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertySleepingIsAllowed,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allowed)
    }

    func start(deviceID: AudioDeviceID, tone: ToneSettings) throws {
        stop()
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw EngineError.noOutputUnit }
        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &newUnit) == noErr, let unit = newUnit else { throw EngineError.noOutputUnit }

        var device = deviceID
        var status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw EngineError.couldNotSelectDevice(status)
        }

        // Render at the device's own rate so the unit doesn't resample.
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &deviceFormat, &size)
        let sampleRate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : 48_000

        // Stereo, non-interleaved Float32: one buffer per channel, as ToneGenerator expects.
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size)

        let generator = ToneGenerator(sampleRate: sampleRate)
        generator.configure(tone)
        // Retained until stop(), after the unit has been disposed of.
        let retained = Unmanaged.passRetained(generator)
        var callback = AURenderCallbackStruct(inputProc: renderTone, inputProcRefCon: retained.toOpaque())
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        status = AudioUnitInitialize(unit)
        if status == noErr { status = AudioOutputUnitStart(unit) }
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            retained.release()
            throw EngineError.couldNotStart(status)
        }

        self.unit = unit
        self.deviceID = deviceID
        self.generator = retained
        listenForDeviceChanges(deviceID)
    }

    func update(tone: ToneSettings) {
        generator?.takeUnretainedValue().configure(tone)
    }

    func playBurst() {
        generator?.takeUnretainedValue().requestBurst()
    }

    func setContinuous(_ on: Bool) {
        generator?.takeUnretainedValue().setContinuous(on)
    }

    func stop() {
        stopListening()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        deviceID = nil
        generator?.release()
        generator = nil
    }

    // MARK: - Device changes

    private static let watchedProperties: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyDeviceIsAlive,
    ]

    private func listenForDeviceChanges(_ deviceID: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }
        for selector in Self.watchedProperties {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        }
        deviceListener = block
    }

    private func stopListening() {
        guard let deviceListener, let deviceID else { return }
        for selector in Self.watchedProperties {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, deviceListener)
        }
        self.deviceListener = nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Runs on the real-time audio thread, so it lives outside the main actor.
private let renderTone: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    guard let ioData else { return noErr }
    let generator = Unmanaged<ToneGenerator>.fromOpaque(refCon).takeUnretainedValue()
    generator.render(frameCount: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(ioData))
    return noErr
}
