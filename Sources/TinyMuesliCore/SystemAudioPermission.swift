import Foundation

/// The "System Audio Recording" permission that process taps need. macOS has no public API to check
/// or request it (the prompt otherwise only appears when a tap first starts), so this goes through
/// TCC's own preflight/request calls, looked up at runtime. If they ever go away, the status is
/// `.unknown` and requesting does nothing; recording still triggers the system prompt.
public enum SystemAudioPermission {
    public enum Status: Sendable, Equatable {
        case granted, denied, notDetermined, unknown
    }

    nonisolated(unsafe) private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let tcc, let pointer = dlsym(tcc, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    public static var status: Status {
        guard let preflight = symbol("TCCAccessPreflight", as: Preflight.self) else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't been asked yet. Returns whether access is granted.
    public static func request() async -> Bool {
        guard let request = symbol("TCCAccessRequest", as: Request.self) else { return false }
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}
