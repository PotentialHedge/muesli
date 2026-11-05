import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String { "\(operation) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

/// Thin typed accessors over `AudioObjectGetPropertyData`.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Reads a plain-old-data property (integers, structs like `AudioStreamBasicDescription`).
    func read<T>(_ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        try check(status, "read property \(selector) of object \(self)")
        return value
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        try check(status, "read string property \(selector) of object \(self)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector, initial: T) throws -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "size of property \(selector)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: initial, count: count)
        let status = values.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "read array property \(selector)")
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// The Core Audio process object for a PID (only exists once the process has touched audio).
    static func process(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            "translate pid \(pid)"
        )
        return object
    }
}
