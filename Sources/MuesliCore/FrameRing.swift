import Synchronization

/// A lock-free, single-producer single-consumer queue of mono audio, so the audio thread can hand
/// samples over without locking or allocating.
///
/// Memory is split into fixed slots rather than one run of samples, because each stretch of audio
/// carries the host time it was captured at. A buffer larger than a slot spans several; only the
/// first has a host time. When the ring is full new audio is dropped and counted: the audio thread
/// must never wait. The default size holds 11 to 22 s of 48 kHz audio, depending on buffer size.
final class FrameRing: @unchecked Sendable {
    private struct Slot {
        var frames = 0
        var hostTime: UInt64?
    }

    let slotFrames: Int
    private let slotCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let slots: UnsafeMutablePointer<Slot>
    /// Slots ever written and read. They only grow; `% slotCount` gives the position.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    init(slotFrames: Int = 256, slotCount: Int = 4096) {
        self.slotFrames = slotFrames
        self.slotCount = slotCount
        samples = .allocate(capacity: slotFrames * slotCount)
        samples.initialize(repeating: 0, count: slotFrames * slotCount)
        slots = .allocate(capacity: slotCount)
        slots.initialize(repeating: Slot(), count: slotCount)
    }

    deinit {
        samples.deallocate()
        slots.deallocate()
    }

    /// Frames lost so far because the ring was full.
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Producer only. `fill` is given a destination, the offset into the buffer being written, and
    /// the number of frames to copy from there.
    func write(frames: Int, hostTime: UInt64?, fill: (UnsafeMutablePointer<Float>, Int, Int) -> Void) {
        var next = written.load(ordering: .relaxed)
        var offset = 0
        while offset < frames {
            guard next - read.load(ordering: .acquiring) < slotCount else {
                dropped.add(frames - offset, ordering: .relaxed)
                return
            }
            let slot = next % slotCount
            let count = min(frames - offset, slotFrames)
            fill(samples + slot * slotFrames, offset, count)
            slots[slot] = Slot(frames: count, hostTime: offset == 0 ? hostTime : nil)
            next += 1
            written.store(next, ordering: .releasing)
            offset += count
        }
    }

    /// Consumer only. Passes everything queued so far to `body`, oldest first.
    func drain(_ body: (UnsafeBufferPointer<Float>, UInt64?) -> Void) {
        var next = read.load(ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        while next < end {
            let slot = next % slotCount
            let info = slots[slot]
            body(UnsafeBufferPointer(start: samples + slot * slotFrames, count: info.frames), info.hostTime)
            next += 1
            read.store(next, ordering: .releasing)
        }
    }
}
