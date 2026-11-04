@preconcurrency import AVFAudio
import CoreAudio
import Foundation

/// Records everything the Mac plays (the other meeting participants) using a Core Audio
/// process tap. This needs only the "System Audio Recording" permission, not Screen Recording.
///
/// Setup: a global tap → a private aggregate device that contains the tap → an IOProc that
/// receives the tapped audio.
public final class SystemAudioRecorder {
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: TrackWriter?
    private let queue = DispatchQueue(label: "muesli.system-audio", qos: .userInitiated)

    public init() {}

    public var secondsWritten: Double { writer?.secondsWritten ?? 0 }
    public var writeError: Error? { writer?.lastError }

    public func start(url: URL, clockStart: UInt64? = nil, tee: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) throws {
        do {
            try startTap(url: url, clockStart: clockStart, tee: tee)
        } catch {
            stop()
            throw error
        }
    }

    private func startTap(url: URL, clockStart: UInt64?, tee: (@Sendable (AVAudioPCMBuffer) -> Void)?) throws {
        // Leave our own process out of the tap (it might play sounds later).
        let ownProcess = try? AudioObjectID.process(for: getpid())
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        tap.uuid = UUID()
        tap.name = "Muesli"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create system audio tap")

        var streamDescription = try tapID.read(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError(status: -1, operation: "read tap format")
        }

        // Tap only, no hardware sub-devices. Adding the output device as a sub-device would also
        // open its input stream if it has one (AirPods, headsets), which can drop Bluetooth
        // headphones into low-quality call mode and puts extra buffers in front of the tap's.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Muesli System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")

        let writer = try TrackWriter(url: url, inputFormat: format, clockStart: clockStart, tee: tee)
        self.writer = writer
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue, Self.ioBlock(writing: writer, format: format)),
            "create IOProc"
        )
        try check(AudioDeviceStart(aggregateID, ioProcID), "start system audio capture")
    }

    /// Built in a nonisolated static context so the block never inherits an actor.
    ///
    /// The tap's buffers are the last ones in the aggregate's input buffer list. Normally they're
    /// the only ones, but taking them from the end keeps this correct if a device ever adds its own.
    private static func ioBlock(writing writer: TrackWriter, format: AVAudioFormat) -> AudioDeviceIOBlock {
        let tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        return { @Sendable _, inputData, inputTime, _, _ in
            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count >= tapBufferCount else { return }
            writer.write(bufferList: inputData, firstBuffer: buffers.count - tapBufferCount, hostTime: hostTime)
        }
    }

    public func stop() {
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        queue.sync {}  // drain any in-flight callback before closing the file
        writer?.close()

        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }
}

