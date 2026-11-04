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
    /// Meeting folders whose final pass (transcription, speaker ID) is running.
    private(set) var processing: Set<URL> = []
    /// Transcription languages this Mac supports (loaded at launch).
    private(set) var languages: [Locale] = []
    /// BCP-47 tag, nil = system default.
    var language: String? = Settings.language?.identifier(.bcp47) {
        didSet { Settings.language = language.map(Locale.init(identifier:)) }
    }
    /// The picker's entries: one per language rather than one per regional variant.
    var languageChoices: [LanguageChoice] {
        LanguageChoice.choices(from: languages, selected: language)
    }
    /// Regional variants of the chosen language, when there's more than one to choose from.
    var languageVariants: [LanguageChoice.Variant] {
        let variants = languageChoices.first { $0.tag == language }?.variants ?? []
        return variants.count > 1 ? variants : []
    }
    var keepAudio = Settings.keepAudio {
        didSet { Settings.keepAudio = keepAudio }
    }

    let store = MeetingStore()
    @ObservationIgnored private var detector = MeetingDetector(gracePeriod: 20)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let notifications = NotificationController()
    /// Shared so the CoreML models stay loaded between meetings.
    @ObservationIgnored private let diarizer = FluidDiarizer()

    private static let alwaysRecordKey = "alwaysRecord"

    init() {
        alwaysRecord = Set(UserDefaults.standard.stringArray(forKey: Self.alwaysRecordKey) ?? [])
        notifications.onAction = { [weak self] action in self?.handle(action) }
        notifications.setUp()
        refreshRecentMeetings()
        startPolling()
        Task {
            languages = await AppleSpeechTranscriber.offeredLocales()
            resumeUnfinishedMeetings()
        }
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
            // Without a transcriber we still record; the final pass will report the problem.
            let transcriber = try? await AppleSpeechTranscriber.make(preferred: language.map(Locale.init(identifier:)))
            do {
                let session = try RecordingSession(store: store, app: app, transcriber: transcriber)
                try session.start()
                lastError = session.warnings.first
                status = .recording(session)
                refreshRecentMeetings()
                // Fetch the diarization models now (first time only) so they're ready at the end.
                Task { [diarizer] in try? await diarizer.prepare() }
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func stopRecording() {
        guard case .recording(let session) = status else { return }
        session.stop()
        lastError = session.warnings.last
        status = .idle
        refreshRecentMeetings()
        process(session.folder) { await session.finishLiveTranscription() }
    }

    // MARK: - Final pass

    /// Transcribes (what wasn't done live) and identifies speakers, then tidies up the folder.
    private func process(_ folder: URL, live: @escaping @MainActor () async -> [Track: [Phrase]] = { [:] }) {
        guard !processing.contains(folder) else { return }
        processing.insert(folder)
        let (language, keepAudio, diarizer) = (language, keepAudio, diarizer)
        Task {
            defer {
                processing.remove(folder)
                refreshRecentMeetings()
            }
            let phrases = await live()
            var outcome = MeetingMetadata.Status.failed
            defer { runHook(folder: folder, status: outcome) }
            do {
                let transcriber = try await AppleSpeechTranscriber.make(preferred: language.map(Locale.init(identifier:)))
                let processor = MeetingProcessor(transcriber: transcriber, diarizer: diarizer, keepAudio: keepAudio)
                let result = try await processor.process(folder: folder, live: phrases)
                if let warning = result.warnings.first { lastError = warning }
                outcome = .done
            } catch {
                lastError = "Transcription failed: \(error)"
            }
        }
    }

    /// Not awaited: a slow hook shouldn't keep the meeting showing as processing.
    private func runHook(folder: URL, status: MeetingMetadata.Status) {
        let hook = MeetingEndHook()
        Task {
            switch await hook.run(folder: folder, status: status) {
            case .notInstalled, .exited(0):
                break
            case .exited(let code):
                lastError = "on-meeting-end hook exited with status \(code). See \(hook.log.path)."
            case .couldNotLaunch(let reason):
                lastError = "Couldn't run the on-meeting-end hook: \(reason)"
            }
        }
    }

    /// Meetings interrupted by a quit or crash still have their audio: finish them now.
    /// Failed ones are left alone (re-run with `muesli transcribe`), so a bad file can't loop.
    private func resumeUnfinishedMeetings() {
        let unfinished: Set<MeetingMetadata.Status> = [.recording, .recorded, .transcribing]
        for folder in store.recentMeetings(limit: 20) {
            let md = folder.appendingPathComponent(MeetingFiles.transcript)
            guard let text = try? String(contentsOf: md, encoding: .utf8),
                  let metadata = MeetingMetadata(parsing: text), unfinished.contains(metadata.status),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingFiles.audio).path)
            else { continue }
            process(folder)
        }
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
        case .idle: processing.isEmpty ? "waveform" : "ellipsis.circle"
        case .detected: "mic.circle"
        case .recording: "record.circle.fill"
        }
    }

    /// Shown under the main status line while a final pass runs (it can overlap a new recording).
    var processingText: String? {
        switch processing.count {
        case 0: nil
        case 1: "Transcribing \(processing.first!.lastPathComponent)…"
        default: "Transcribing \(processing.count) meetings…"
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
