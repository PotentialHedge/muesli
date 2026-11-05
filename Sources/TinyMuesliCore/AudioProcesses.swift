import CoreAudio
import Darwin
import Foundation

/// A process Core Audio knows about, and whether it's currently capturing / playing.
public struct AudioProcess: Sendable, Hashable {
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
}

/// Which processes are using the microphone. This is the meeting-detection signal:
/// no calendar access, no screen recording, just Core Audio's per-process state (macOS 14.2+).
public enum AudioProcesses {
    public static func all() throws -> [AudioProcess] {
        let objects = try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, initial: AudioObjectID.unknown)
        return objects.compactMap { object in
            guard let pid = try? object.read(kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            let input = (try? object.read(kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0
            let output = (try? object.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(
                pid: pid,
                bundleID: (try? object.readString(kAudioProcessPropertyBundleID)) ?? "",
                name: processName(pid),
                isRunningInput: input != 0,
                isRunningOutput: output != 0
            )
        }
    }

    public static func usingMicrophone(excludingPID excluded: pid_t = getpid()) throws -> [AudioProcess] {
        try all().filter { $0.isRunningInput && $0.pid != excluded }
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
