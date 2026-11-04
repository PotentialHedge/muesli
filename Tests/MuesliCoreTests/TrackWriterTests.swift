import AVFAudio
import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import MuesliCore

@Suite struct FrameRingTests {
    func fill(_ value: Float) -> (UnsafeMutablePointer<Float>, Int, Int) -> Void {
        { out, _, count in out.update(repeating: value, count: count) }
    }

    func contents(of ring: FrameRing) -> (samples: [Float], hostTimes: [UInt64?]) {
        var samples: [Float] = []
        var hostTimes: [UInt64?] = []
        ring.drain { samples += $0; hostTimes.append($1) }
        return (samples, hostTimes)
    }

    @Test func splitsLargeBuffersAndTimesOnlyTheFirstSlot() {
        let ring = FrameRing(slotFrames: 4, slotCount: 8)
        ring.write(frames: 10, hostTime: 7) { out, offset, count in
            for i in 0..<count { out[i] = Float(offset + i) }
        }
        let result = contents(of: ring)
        #expect(result.samples == (0..<10).map(Float.init))
        #expect(result.hostTimes == [7, nil, nil])
    }

    @Test func dropsAndCountsWhatDoesNotFit() {
        let ring = FrameRing(slotFrames: 4, slotCount: 2)
        ring.write(frames: 4, hostTime: nil, fill: fill(1))
        ring.write(frames: 8, hostTime: nil, fill: fill(2))
        #expect(ring.droppedFrames == 4)
        #expect(contents(of: ring).samples == [1, 1, 1, 1, 2, 2, 2, 2])
    }

    @Test func reusesSlotsOnceDrained() {
        let ring = FrameRing(slotFrames: 4, slotCount: 2)
        for value in 1...5 {
            ring.write(frames: 4, hostTime: nil, fill: fill(Float(value)))
            #expect(contents(of: ring).samples == [Float](repeating: Float(value), count: 4))
        }
        #expect(ring.droppedFrames == 0)
    }
}

@Suite struct TrackWriterTests {
    func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("muesli-writer-\(UUID().uuidString).caf")
    }

    func stereo(frames: Int, left: Float, right: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            samples[frame * 2] = left
            samples[frame * 2 + 1] = right
        }
        return buffer
    }

    @Test func closingWritesEverythingToAReadableFile() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = stereo(frames: 512, left: 0.1, right: 0.3)
        let writer = try TrackWriter(url: url, inputFormat: source.format)
        for _ in 0..<94 { writer.write(source) }  // about a second
        writer.close()

        #expect(writer.framesWritten == 94 * 512)
        #expect(writer.lastError == nil)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - writer.secondsWritten) < 0.1)
    }

    @Test func teeGetsMonoAudioInOrderAndInBatches() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let received = Mutex<[[Float]]>([])
        let source = stereo(frames: 128, left: 0, right: 0)
        let writer = try TrackWriter(url: url, inputFormat: source.format) { buffer in
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            received.withLock { $0.append(samples) }
        }
        for value in 0..<100 {
            writer.write(stereo(frames: 128, left: Float(value), right: Float(value)))
        }
        writer.close()

        let batches = received.withLock { $0 }
        let expected = (0..<100).flatMap { [Float](repeating: Float($0), count: 128) }
        #expect(batches.flatMap { $0 } == expected)
        #expect(batches.count < 100)
    }

    @Test func fillsGapsWithSilenceSoTracksStayAligned() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let start: UInt64 = 1_000
        let source = stereo(frames: 480, left: 1, right: 1)
        let writer = try TrackWriter(url: url, inputFormat: source.format, clockStart: start)
        writer.write(source, hostTime: start)
        writer.write(source, hostTime: start + AudioConvertNanosToHostTime(2_000_000_000))
        writer.close()

        #expect(abs(writer.secondsWritten - 2.01) < 0.001)
    }

    @Test func ignoresWritesAfterClose() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = stereo(frames: 480, left: 1, right: 1)
        let writer = try TrackWriter(url: url, inputFormat: source.format)
        writer.write(source)
        writer.close()
        writer.write(source)
        writer.close()
        #expect(writer.framesWritten == 480)
    }

    @Test func readsRawBufferListsFromALaterBuffer() throws {
        // Two leading device buffers, then a stereo tap that's interleaved in one buffer.
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let received = Mutex<[Float]>([])
        let tap = stereo(frames: 4, left: 0.5, right: 0.5)
        let writer = try TrackWriter(url: url, inputFormat: tap.format) { buffer in
            received.withLock { $0 += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)) }
        }
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { list.unsafeMutablePointer.deallocate() }
        var device = [Float](repeating: -9, count: 8)
        device.withUnsafeMutableBytes { bytes in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            list[1] = tap.audioBufferList.pointee.mBuffers
            writer.write(bufferList: list.unsafePointer, firstBuffer: 1)
            writer.close()
        }
        #expect(received.withLock { $0 } == [0.5, 0.5, 0.5, 0.5])
    }
}
