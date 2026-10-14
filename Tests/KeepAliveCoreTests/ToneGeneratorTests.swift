import AudioToolbox
import Foundation
import Testing
@testable import KeepAliveCore

/// Renders `frames` stereo frames and returns (left, right).
private func render(_ generator: ToneGenerator, frames: Int, blockSize: Int = 512) -> ([Float], [Float]) {
    var left: [Float] = []
    var right: [Float] = []
    let buffers = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(buffers.unsafeMutablePointer) }
    let l = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
    let r = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
    defer { l.deallocate(); r.deallocate() }
    let bytes = UInt32(blockSize * MemoryLayout<Float>.size)
    buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: l)
    buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: r)

    var remaining = frames
    while remaining > 0 {
        let n = min(blockSize, remaining)
        generator.render(frameCount: n, buffers: buffers)
        left += UnsafeBufferPointer(start: l, count: n)
        right += UnsafeBufferPointer(start: r, count: n)
        remaining -= n
    }
    return (left, right)
}

private func peak(_ samples: ArraySlice<Float>) -> Float {
    samples.map(abs).max() ?? 0
}

@Suite struct ToneGeneratorTests {
    let rate = 48_000.0
    // -20 dBFS = 0.1 linear; 0.5 s burst with 10 ms fades.
    let tone = ToneSettings(frequencyHz: 1_000, levelDBFS: -20, burstSeconds: 0.5, intervalSeconds: 60, fadeMilliseconds: 10)

    func makeGenerator() -> ToneGenerator {
        let generator = ToneGenerator(sampleRate: rate)
        generator.configure(tone)
        return generator
    }

    @Test func silentUntilBurstRequested() {
        let (left, _) = render(makeGenerator(), frames: 4_800)
        #expect(left.allSatisfy { $0 == 0 })
    }

    @Test func burstHasRequestedLevelLengthAndFades() {
        let generator = makeGenerator()
        generator.requestBurst()
        let (left, right) = render(generator, frames: Int(rate))
        let burstEnd = Int(0.5 * rate)
        let fade = Int(0.01 * rate)

        #expect(left == right)
        // Starts from silence and ramps up rather than clicking in.
        #expect(abs(left[0]) < 0.001)
        #expect(peak(left[0..<(fade / 4)]) < 0.03)
        // Full level in the middle of the burst.
        #expect(abs(peak(left[(burstEnd / 2)..<(burstEnd / 2 + 480)]) - 0.1) < 0.002)
        // Fades out and is silent after the burst.
        #expect(peak(left[(burstEnd - fade / 4)..<burstEnd]) < 0.03)
        #expect(left[burstEnd...].allSatisfy { $0 == 0 })
    }

    @Test func eachRequestPlaysOneBurst() {
        let generator = makeGenerator()
        generator.requestBurst()
        _ = render(generator, frames: Int(rate))
        let (afterFirst, _) = render(generator, frames: 4_800)
        #expect(afterFirst.allSatisfy { $0 == 0 })

        generator.requestBurst()
        let (second, _) = render(generator, frames: 4_800)
        #expect(peak(second[...]) > 0.09)
    }

    @Test func continuousModeKeepsPlaying() {
        let generator = makeGenerator()
        generator.setContinuous(true)
        let (left, _) = render(generator, frames: Int(rate * 2))
        #expect(peak(left[Int(rate * 1.5)...]) > 0.099)

        generator.setContinuous(false)
        let (after, _) = render(generator, frames: 4_800)
        #expect(after[960...].allSatisfy { $0 == 0 })
    }

    @Test func frequencyIsClampedBelowNyquist() {
        let generator = ToneGenerator(sampleRate: 8_000)
        var high = tone
        high.frequencyHz = 20_000
        generator.configure(high)
        generator.setContinuous(true)
        let (left, _) = render(generator, frames: 8_000)
        // Count zero crossings over the last half second: a clamped 3.6 kHz
        // tone crosses ~3,600 times, an aliased one far fewer.
        let tail = left[4_000...]
        let crossings = zip(tail, tail.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(crossings > 3_000)
    }
}
