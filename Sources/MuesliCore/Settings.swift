import Foundation

/// User preferences shared by the app and the CLI. Stored under the app's bundle id, so the CLI
/// sees the same values even when run outside the app bundle.
public enum Settings {
    static let bundleID = "dev.muesli.Muesli"
    /// Inside the bundle that domain is `.standard` (a suite named after your own bundle id doesn't work).
    nonisolated(unsafe) static let defaults = Bundle.main.bundleIdentifier == bundleID
        ? .standard
        : UserDefaults(suiteName: bundleID) ?? .standard

    /// Transcription language. nil = the system language (or the closest supported one).
    public static var language: Locale? {
        get { defaults.string(forKey: "language").map(Locale.init(identifier:)) }
        set { defaults.set(newValue?.identifier(.bcp47), forKey: "language") }
    }

    /// Keep `audio/` after a successful transcription. Off by default: transcript only.
    public static var keepAudio: Bool {
        get { defaults.bool(forKey: "keepAudio") }
        set { defaults.set(newValue, forKey: "keepAudio") }
    }
}
