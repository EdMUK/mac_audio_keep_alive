import CoreAudio
import Foundation
import Observation

struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    var id: AudioDeviceID
    var uid: String
    var name: String
}

/// Lists CoreAudio output devices and keeps the list current as devices come
/// and go (e.g. a USB optical adapter being unplugged).
@MainActor
@Observable
final class AudioDeviceMonitor {
    private(set) var outputs: [AudioOutputDevice] = []
    /// Called after the device list changes.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        var address = Self.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
    }

    isolated deinit {
        if let listener {
            var address = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    func refresh() {
        let devices = Self.allOutputDevices()
        if devices != outputs {
            outputs = devices
            onChange?()
        }
    }

    func device(uid: String) -> AudioOutputDevice? {
        outputs.first { $0.uid == uid }
    }

    /// The system's default output device, used when no device is chosen.
    var defaultOutput: AudioOutputDevice? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return outputs.first { $0.id == id }
    }

    /// A likely digital output (optical/S/PDIF adapter) to pick on first launch.
    var likelyDigitalOutput: AudioOutputDevice? {
        let hints = ["spdif", "s/pdif", "optical", "toslink", "digital"]
        return outputs.first { device in
            let name = device.name.lowercased()
            return hints.contains { name.contains($0) }
        }
    }

    // MARK: - CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allOutputDevices() -> [AudioOutputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard outputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
