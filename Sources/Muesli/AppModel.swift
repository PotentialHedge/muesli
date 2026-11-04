import AppKit
import Foundation
import MuesliCore
import Observation

@MainActor
@Observable
final class AppModel {
    enum Status {
        case idle
        /// A meeting app is on the mic and we've asked whether to record.
        case detected(MeetingApp)
        case recording(RecordingSession)
    }

    private(set) var status: Status = .idle
    private(set) var lastError: String?
    private(set) var recentMeetings: [URL] = []
    /// Bundle IDs of apps the user wants recorded without asking.
    private(set) var alwaysRecord: Set<String>

    let store = MeetingStore()
    @ObservationIgnored private var detector = MeetingDetector(gracePeriod: 20)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let notifications = NotificationController()

    private static let alwaysRecordKey = "alwaysRecord"

    init() {
        alwaysRecord = Set(UserDefaults.standard.stringArray(forKey: Self.alwaysRecordKey) ?? [])
        notifications.onAction = { [weak self] action in self?.handle(action) }
        notifications.setUp()
        refreshRecentMeetings()
        startPolling()
    }

    // MARK: - Detection

    /// Polling every 2s is cheap (a handful of property reads) and simpler than
    /// juggling Core Audio listeners on every process object.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func poll() {
        let processes = (try? AudioProcesses.usingMicrophone()) ?? []
        let apps = MeetingApps.active(in: processes)
        for event in detector.update(activeApps: apps, now: .now) {
            handle(event)
        }
    }

    private func handle(_ event: MeetingDetector.Event) {
        switch event {
        case .started(let app):
            if case .recording = status { return }
            if alwaysRecord.contains(app.id) {
                startRecording(app: app)
            } else {
                status = .detected(app)
                notifications.promptToRecord(app)
            }

        case .ended(let app):
            notifications.removePrompt()
            switch status {
            case .recording(let session) where session.appID == app.id:
                stopRecording()
            case .detected:
                status = .idle
            default:
                break
            }
        }
    }

    private func handle(_ action: NotificationController.Action) {
        switch action {
        case .record(let appID):
            guard case .detected(let app) = status, app.id == appID else { return }
            startRecording(app: app)
        case .alwaysRecord(let appID):
            setAlwaysRecord(appID, true)
            if case .detected(let app) = status, app.id == appID { startRecording(app: app) }
        }
    }

    // MARK: - Recording

    var currentApp: MeetingApp? {
        switch status {
        case .idle: nil
        case .detected(let app): app
        case .recording(let session): session.appID.flatMap { id in MeetingApps.known.first { $0.id == id } }
        }
    }

    func startRecording(app: MeetingApp?) {
        if case .recording = status { return }
        notifications.removePrompt()
        Task {
            guard await MicRecorder.requestPermission() else {
                lastError = "Muesli needs microphone access. Enable it in System Settings → Privacy & Security → Microphone."
                return
            }
            do {
                let session = try RecordingSession(store: store, app: app)
                try session.start()
                lastError = session.warnings.first
                status = .recording(session)
                refreshRecentMeetings()
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func stopRecording() {
        guard case .recording(let session) = status else { return }
        session.stop()
        status = .idle
        refreshRecentMeetings()
    }

    // MARK: - Settings & files

    func setAlwaysRecord(_ appID: String, _ enabled: Bool) {
        if enabled { alwaysRecord.insert(appID) } else { alwaysRecord.remove(appID) }
        UserDefaults.standard.set(alwaysRecord.sorted(), forKey: Self.alwaysRecordKey)
    }

    func refreshRecentMeetings() {
        recentMeetings = store.recentMeetings(limit: 5)
    }

    func openMeetingsFolder() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.root)
    }

    // MARK: - Menu bar presentation

    var statusSymbol: String {
        switch status {
        case .idle: "waveform"
        case .detected: "mic.circle"
        case .recording: "record.circle.fill"
        }
    }

    var statusText: String {
        switch status {
        case .idle:
            return "No meeting detected"
        case .detected(let app):
            return "\(app.name) is using the microphone"
        case .recording(let session):
            let since = session.startedAt.formatted(date: .omitted, time: .shortened)
            return "Recording \(session.appName ?? "meeting") since \(since)"
        }
    }
}
