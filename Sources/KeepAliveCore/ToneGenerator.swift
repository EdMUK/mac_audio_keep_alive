import AudioToolbox
import Foundation
import Synchronization

/// Generates the keep-alive sine wave on the real-time audio thread. The main
/// thread changes parameters and requests bursts through atomics; the render
/// thread owns everything else, so there are no locks.
public final class ToneGenerator: @unchecked Sendable {
    public let sampleRate: Double

    private let frequencyBits = Atomic<UInt64>(0)
    private let amplitudeBits = Atomic<UInt64>(0)
    private let burstSamples = Atomic<Int>(0)
    private let fadeSamples = Atomic<Int>(1)
    private let continuous = Atomic<Bool>(false)
    private let burstRequests = Atomic<Int>(0)

    // Render-thread state.
    private var phase = 0.0
    private var gain = 0.0
    private var burstRemaining = 0
    private var handledRequests = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public func configure(_ tone: ToneSettings) {
        // Stay well under Nyquist whatever the device rate is.
        let frequency = min(tone.frequencyHz, sampleRate * 0.45)
        frequencyBits.store(frequency.bitPattern, ordering: .relaxed)
        amplitudeBits.store(tone.amplitude.bitPattern, ordering: .relaxed)
        burstSamples.store(Int(tone.burstSeconds * sampleRate), ordering: .relaxed)
        fadeSamples.store(max(1, Int(tone.fadeMilliseconds / 1000 * sampleRate)), ordering: .relaxed)
    }

    public func setContinuous(_ on: Bool) {
        continuous.store(on, ordering: .relaxed)
    }

    public func requestBurst() {
        burstRequests.wrappingAdd(1, ordering: .relaxed)
    }

    public func render(frameCount: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        let requests = burstRequests.load(ordering: .relaxed)
        if requests != handledRequests {
            handledRequests = requests
            burstRemaining = burstSamples.load(ordering: .relaxed)
        }
        let frequency = Double(bitPattern: frequencyBits.load(ordering: .relaxed))
        let amplitude = Double(bitPattern: amplitudeBits.load(ordering: .relaxed))
        let fade = fadeSamples.load(ordering: .relaxed)
        let step = 1 / Double(fade)
        let isContinuous = continuous.load(ordering: .relaxed)
        let increment = 2 * Double.pi * frequency / sampleRate

        for frame in 0..<frameCount {
            // Ramp gain towards the target so bursts fade in and out without clicks.
            let target: Double = (isContinuous || burstRemaining > fade) ? 1 : 0
            if gain < target {
                gain = min(target, gain + step)
            } else if gain > target {
                gain = max(target, gain - step)
            }
            if burstRemaining > 0 { burstRemaining -= 1 }

            let sample = gain > 0 ? Float(amplitude * gain * sin(phase)) : 0
            phase += increment
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }

            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
    }
}
