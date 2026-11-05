import Foundation

/// Turns periodic snapshots of "which meeting apps are using the mic" into start/end events.
///
/// Pure state machine, no I/O: feed it snapshots, get events back.
/// A meeting ends only after its app has been off the mic for `gracePeriod`, so brief
/// device switches or reconnects don't split one meeting into several.
public struct MeetingDetector: Sendable {
    public enum Event: Sendable, Equatable {
        case started(MeetingApp)
        case ended(MeetingApp)
    }

    public let gracePeriod: TimeInterval
    public private(set) var current: MeetingApp?
    private var lastSeen: Date?

    public init(gracePeriod: TimeInterval = 5) {
        self.gracePeriod = gracePeriod
    }

    /// - Parameter activeApps: meeting apps using the mic right now, in priority order.
    public mutating func update(activeApps: [MeetingApp], now: Date) -> [Event] {
        var events: [Event] = []

        if let current {
            if activeApps.contains(current) {
                lastSeen = now
                return []
            }
            guard let lastSeen, now.timeIntervalSince(lastSeen) >= gracePeriod else { return [] }
            self.current = nil
            self.lastSeen = nil
            events.append(.ended(current))
        }

        if let next = activeApps.first {
            current = next
            lastSeen = now
            events.append(.started(next))
        }
        return events
    }
}
