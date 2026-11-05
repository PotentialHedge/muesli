import AppKit
import Foundation
import MuesliCore
import Observation
import os

@MainActor
@Observable
final class AppModel {
    enum Status {
        case idle
        /// A meeting app is on the mic and we've asked whether to record.
        case detected(MeetingApp)
        /// `following`: the meeting app whose leaving the mic ends the recording (nil: manual stop only).
        case recording(RecordingSession, following: MeetingApp?)
    }

    /// A meeting whose app left the mic less than `continueWindow` ago. Its capture is paused rather
    /// than finished, so if another meeting starts soon after (a dropped call, a meeting that moved
    /// to another link), it can continue in the same folder. Finished when the window runs out, or
    /// as soon as another recording starts.
    struct EndedMeeting {
        let session: RecordingSession
        let finishesAt: Date
    }

    private(set) var status: Status = .idle
    private(set) var ended: EndedMeeting?
    /// Some other app (meeting app or not) is using the mic.
    private(set) var micInUse = false
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
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    /// What the last poll saw, so only changes get logged.
    @ObservationIgnored private var lastMicUsers: [String] = []
    @ObservationIgnored private let log = Logger(subsystem: "dev.muesli.Muesli", category: "detection")
    @ObservationIgnored private let notifications = NotificationController()
    /// Shared so the CoreML models stay loaded between meetings.
    @ObservationIgnored private let diarizer = FluidDiarizer()

    private static let alwaysRecordKey = "alwaysRecord"
    static let continueWindow: TimeInterval = 5 * 60

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
        if micInUse != !processes.isEmpty { micInUse = !processes.isEmpty }
        // Persisted (notice level) so a meeting that didn't start or stop can be explained afterwards:
        // log show --last 1d --predicate 'subsystem == "dev.muesli.Muesli"'
        let micUsers = processes.map { "\($0.bundleID) (\($0.pid))" }.sorted()
        if micUsers != lastMicUsers {
            lastMicUsers = micUsers
            log.notice("Mic users: \(micUsers.isEmpty ? "none" : micUsers.joined(separator: ", "), privacy: .public)")
        }
        let apps = MeetingApps.active(in: processes)
        for event in detector.update(activeApps: apps, now: .now) {
            log.notice("Detector: \(String(describing: event), privacy: .public)")
            handle(event)
        }
    }

    private func handle(_ event: MeetingDetector.Event) {
        switch event {
        case .started(let app):
            if case .recording = status { return }
            // Shortly after a meeting ended, ask even for "always record" apps: this may be that
            // meeting carrying on.
            if alwaysRecord.contains(app.id), ended == nil {
                startRecording(app: app)
            } else {
                status = .detected(app)
                notifications.promptToRecord(app, previous: ended.map { Self.title(of: $0.session) })
            }

        case .ended(let app):
            notifications.removePrompt()
            switch status {
            case .recording(let session, let following) where following == app:
                pause(session)
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
        case .continueMeeting(let appID):
            guard case .detected(let app) = status, app.id == appID else { return }
            // The window may have run out since the prompt was shown: then record it anew.
            if ended != nil { continueMeeting() } else { startRecording(app: app) }
        }
    }

    // MARK: - Recording

    var currentApp: MeetingApp? {
        switch status {
        case .idle: nil
        case .detected(let app): app
        case .recording(_, let following): following
        }
    }

    func startRecording(app: MeetingApp?) {
        if case .recording = status { return }
        notifications.removePrompt()
        finishEndedMeeting()  // starting afresh: the ended meeting won't be continued
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
                status = .recording(session, following: app)
                refreshRecentMeetings()
                // Fetch the diarization models now (first time only) so they're ready at the end.
                Task { [diarizer] in try? await diarizer.prepare() }
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func stopRecording() {
        guard case .recording(let session, _) = status else { return }
        finish(session)
        // If the meeting app is still on the mic, offer to record it again (without a new prompt).
        status = detector.current.map(Status.detected) ?? .idle
    }

    /// Ends the current recording and starts another, for when one meeting runs into the next.
    func startNewMeeting() {
        stopRecording()
        startRecording(app: detector.current)
    }

    /// Carries on recording the meeting that ended in the last `continueWindow`.
    func continueMeeting() {
        guard let session = ended?.session, !isRecording else { return }
        notifications.removePrompt()
        clearEndedMeeting()
        do {
            try session.resume()
            log.notice("Continuing recording of \(session.folder.lastPathComponent, privacy: .public)")
            lastError = session.warnings.last
            status = .recording(session, following: detector.current)
        } catch {
            finish(session)
            startRecording(app: detector.current)
            lastError = "Couldn't continue the meeting, so this is a new one. \(error)"
        }
    }

    /// Finishes the ended meeting now instead of waiting for the window to run out.
    func finishEndedMeeting() {
        guard let session = ended?.session else { return }
        clearEndedMeeting()
        finish(session)
    }

    /// The meeting app left the mic: pause, and finish only if nothing continues it in time.
    private func pause(_ session: RecordingSession) {
        finishEndedMeeting()  // can't be set while recording, but never strand one
        log.notice("Pausing recording of \(session.folder.lastPathComponent, privacy: .public)")
        session.pause()
        status = .idle
        ended = EndedMeeting(session: session, finishesAt: .now + Self.continueWindow)
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.continueWindow))
            guard !Task.isCancelled, let self else { return }
            finishEndedMeeting()
            // An "always record" app that started meanwhile was only asked about; nobody answered.
            if case .detected(let app) = status, alwaysRecord.contains(app.id) { startRecording(app: app) }
        }
    }

    private func clearEndedMeeting() {
        finishTask?.cancel()
        finishTask = nil
        ended = nil
    }

    private func finish(_ session: RecordingSession) {
        log.notice("Stopping recording of \(session.folder.lastPathComponent, privacy: .public)")
        session.stop()
        lastError = session.warnings.last
        refreshRecentMeetings()
        process(session.folder) { await session.finishLiveTranscription() }
    }

    private var isRecording: Bool {
        if case .recording = status { true } else { false }
    }

    /// How menus and prompts name a meeting, e.g. "Zoom from 10:30".
    static func title(of session: RecordingSession) -> String {
        "\(session.appName ?? "Meeting") from \(session.startedAt.formatted(date: .omitted, time: .shortened))"
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

    func copyAgentPrompt() {
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentPrompt.text(binaryPath: binary), forType: .string)
    }

    // MARK: - Menu bar presentation

    var statusSymbol: String {
        switch status {
        case .idle: processing.isEmpty ? "waveform" : "ellipsis.circle"
        case .detected: "mic.circle"
        case .recording: "record.circle.fill"
        }
    }

    /// Shown under the main status line while an ended meeting can still be continued.
    var endedText: String? {
        guard let ended else { return nil }
        let until = ended.finishesAt.formatted(date: .omitted, time: .shortened)
        return "\(Self.title(of: ended.session)) ended; can be continued until \(until)"
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
            return micInUse ? "Microphone in use" : "No meeting detected"
        case .detected(let app):
            return "\(app.name) is using the microphone"
        case .recording(let session, _):
            let since = session.startedAt.formatted(date: .omitted, time: .shortened)
            return "Recording \(session.appName ?? "meeting") since \(since)"
        }
    }
}
