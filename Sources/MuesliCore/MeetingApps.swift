import Foundation

/// An app that, when it uses the microphone, probably means a meeting is happening.
public struct MeetingApp: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable {
        /// Dedicated meeting app: mic use is a strong signal.
        case native
        /// Browser: could be Google Meet, could be anything. Weaker signal.
        case browser
    }

    /// Stable identifier (the main bundle ID); used for settings like "always record".
    public let id: String
    public let name: String
    public let kind: Kind
    /// Bundle IDs that count as this app. Helpers match too: `com.google.Chrome` matches
    /// `com.google.Chrome.helper`, since browsers and Electron apps capture audio in helper processes.
    let bundleIDs: [String]

    public init(id: String, name: String, kind: Kind, bundleIDs: [String]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bundleIDs = bundleIDs ?? [id]
    }

    public func matches(bundleID: String) -> Bool {
        bundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    public static func == (lhs: MeetingApp, rhs: MeetingApp) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum MeetingApps {
    /// Verify new entries with `Muesli mic-users` while the app is in a call.
    public static let known: [MeetingApp] = [
        MeetingApp(id: "us.zoom.xos", name: "Zoom", kind: .native, bundleIDs: ["us.zoom"]),
        MeetingApp(id: "com.microsoft.teams2", name: "Teams", kind: .native,
                   bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        MeetingApp(id: "com.tinyspeck.slackmacgap", name: "Slack", kind: .native),
        MeetingApp(id: "com.apple.FaceTime", name: "FaceTime", kind: .native),
        MeetingApp(id: "Cisco-Systems.Spark", name: "Webex", kind: .native,
                   bundleIDs: ["Cisco-Systems.Spark", "com.webex.meetingmanager"]),
        MeetingApp(id: "com.hnc.Discord", name: "Discord", kind: .native),

        MeetingApp(id: "com.google.Chrome", name: "Chrome", kind: .browser),
        // Safari captures the mic in WebKit's GPU process.
        MeetingApp(id: "com.apple.Safari", name: "Safari", kind: .browser,
                   bundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"]),
        MeetingApp(id: "company.thebrowser.Browser", name: "Arc", kind: .browser),
        MeetingApp(id: "company.thebrowser.dia", name: "Dia", kind: .browser),
        MeetingApp(id: "com.microsoft.edgemac", name: "Edge", kind: .browser),
        MeetingApp(id: "com.brave.Browser", name: "Brave", kind: .browser),
        MeetingApp(id: "org.mozilla.firefox", name: "Firefox", kind: .browser),
    ]

    public static func match(bundleID: String) -> MeetingApp? {
        known.first { $0.matches(bundleID: bundleID) }
    }

    /// Meeting apps currently using the mic, deduplicated, native apps first.
    public static func active(in processes: [AudioProcess]) -> [MeetingApp] {
        var seen = Set<MeetingApp>()
        let apps = processes.compactMap { match(bundleID: $0.bundleID) }.filter { seen.insert($0).inserted }
        return apps.filter { $0.kind == .native } + apps.filter { $0.kind == .browser }
    }
}
