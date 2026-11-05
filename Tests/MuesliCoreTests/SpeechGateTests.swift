import AVFAudio
import Foundation
import Testing
@testable import MuesliCore

/// "Speech" is anything louder than 0.25.
final class LoudnessDetector: SpeechDetector {
    var blocksSeen = 0
    func speechProbability(_ block: AVAudioPCMBuffer) -> Float {
        blocksSeen += 1
        let samples = UnsafeBufferPointer(start: block.floatChannelData![0], count: Int(block.frameLength))
        return samples.contains { abs($0) > 0.25 } ? 1 : 0
    }
}

@Suite struct SpeechGateTests {
    /// 1 kHz, so a block is 256 frames.
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 1000, channels: 1, interleaved: false)!
    let block = 256

    /// One buffer per level, each a block long, fed in pieces that don't line up with blocks.
    func run(_ levels: [Float], piece: Int = 100) -> [Float] {
        var input: [Float] = levels.flatMap { Array(repeating: $0, count: block) }
        let gate = SpeechGate(detector: LoudnessDetector(), format: format)
        var output: [Float] = []
        func take(_ buffers: [AVAudioPCMBuffer]) {
            for b in buffers { output += UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)) }
        }
        while !input.isEmpty {
            let n = min(piece, input.count)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            buffer.floatChannelData![0].update(from: input, count: n)
            input.removeFirst(n)
            take(gate.process(buffer))
            #expect(Int(gate.heldFrames) + output.count == levels.count * block - input.count)
        }
        take(gate.flush())
        return output
    }

    /// Whether each block came out (1) or was silenced (0).
    func kept(_ output: [Float]) -> [Int] {
        stride(from: 0, to: output.count, by: block).map { output[$0] != 0 ? 1 : 0 }
    }

    @Test func silencesAudioWithoutSpeech() {
        let output = run(Array(repeating: 0.1, count: 20))
        #expect(output.count == 20 * block)
        #expect(output.allSatisfy { $0 == 0 })
    }

    @Test func keepsSpeechWithALeadInAndATail() {
        let noise: Float = 0.1, speech: Float = 0.5
        let levels = Array(repeating: noise, count: 10) + [speech, speech] + Array(repeating: noise, count: 10)
        let output = run(levels)
        #expect(output.count == levels.count * block)
        // 2 blocks before the speech (pre-roll) and 6 after (hangover) are kept.
        #expect(kept(output) == Array(repeating: 0, count: 8) + Array(repeating: 1, count: 2 + 2 + 6) + [0, 0, 0, 0])
        // Kept audio is untouched.
        #expect(output[10 * block] == speech)
        #expect(output[9 * block] == noise)
    }

    @Test func shortPausesInSpeechAreKept() {
        let levels: [Float] = [0.5] + Array(repeating: 0.1, count: 6) + [0.5]
        #expect(kept(run(levels)) == Array(repeating: 1, count: 8))
    }

    @Test func speechRightAtTheStartIsKept() {
        #expect(kept(run([0.5, 0.1])) == [1, 1])
    }

    @Test func aPartialLastBlockFollowsTheOneBeforeIt() {
        // Speech, then a fraction of a block: still in the tail, so kept.
        var output = run([0.5], piece: 256)
        #expect(output.count == block)
        let gate = SpeechGate(detector: LoudnessDetector(), format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100
        buffer.floatChannelData![0].update(repeating: 0.1, count: 100)
        #expect(gate.process(buffer).isEmpty)
        output = gate.flush().flatMap { UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength)) }
        #expect(output == Array(repeating: 0, count: 100))  // nothing before it was speech
    }

    @Test func writerKeepsTrackLengthAndAlignmentWithAGate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-gate-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        buffer.floatChannelData![0].update(repeating: 0.1, count: 4800)
        let writer = try TrackWriter(url: url, inputFormat: format, clockStart: 1_000, speechDetector: LoudnessDetector())

        // 1 s of noise from the start, then a gap of 1 s, then 1 s more: 3 s in all.
        let ticksPerSecond = AudioConvertNanosToHostTime(1_000_000_000)
        for i in 0..<10 { writer.write(buffer, hostTime: 1_000 + UInt64(i) * ticksPerSecond / 10) }
        Thread.sleep(forTimeInterval: 0.2)  // let it drain while audio is held in the gate
        for i in 20..<30 { writer.write(buffer, hostTime: 1_000 + UInt64(i) * ticksPerSecond / 10) }
        writer.close()

        #expect(writer.lastError == nil)
        #expect(abs(writer.secondsWritten - 3) < 0.01)
        let file = try AVAudioFile(forReading: url)
        #expect(abs(Double(file.length) / 48_000 - 3) < 0.05)
    }
}
