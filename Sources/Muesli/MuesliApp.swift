import AppKit
import MuesliCore
import SwiftUI

struct MuesliApp: App {
    @State private var model: AppModel
    @State private var updater: Updater

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _updater = State(initialValue: Updater { model.isBusy })
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, updater: updater)
        } label: {
            Image(systemName: model.statusSymbol)
        }
    }
}

private struct MenuContent: View {
    let model: AppModel
    let updater: Updater

    var body: some View {
        @Bindable var model = model
        @Bindable var updater = updater
        Text(model.statusText)
        if let ended = model.endedText {
            Text(ended)
        }
        if let processing = model.processingText {
            Text(processing)
        }
        if let moving = model.movingText {
            Text(moving)
        }

        switch model.status {
        case .idle:
            Button("Start Recording") { model.startRecording(app: nil) }
        case .detected(let app):
            Button("Record \(app.name) Meeting") { model.startRecording(app: app) }
        case .recording:
            Button("Stop Recording") { model.stopRecording() }
            Button("Start New Meeting") { model.startNewMeeting() }
        }
        if let ended = model.ended {
            Button("Continue \(AppModel.title(of: ended.session))") { model.continueMeeting() }
            Button("Finish \(AppModel.title(of: ended.session)) Now") { model.finishEndedMeeting() }
        }

        if let app = model.currentApp {
            Toggle("Always Record \(app.name)", isOn: Binding(
                get: { model.alwaysRecord.contains(app.id) },
                set: { model.setAlwaysRecord(app.id, $0) }
            ))
        }

        if let error = model.lastError {
            let summary = AppModel.menuSummary(of: error)
            if summary == error {
                Text(error)
            } else {
                Button(summary) { model.showLastError() }
            }
        }

        Divider()

        if !model.recentMeetings.isEmpty {
            Section("Recent") {
                ForEach(model.recentMeetings, id: \.self) { folder in
                    Button(folder.lastPathComponent) { NSWorkspace.shared.open(folder) }
                }
            }
        }
        Button("Open Meetings Folder") { model.openMeetingsFolder() }
        Button("Copy Prompt for Agent") { model.copyAgentPrompt() }

        Divider()

        Menu("Settings") {
            Picker("Language", selection: $model.language) {
                Text("System Default").tag(String?.none)
                ForEach(model.languageChoices, id: \.self) { choice in
                    Text(choice.name).tag(Optional(choice.tag))
                }
            }
            if !model.languageVariants.isEmpty {
                Picker("Variant", selection: $model.language) {
                    ForEach(model.languageVariants, id: \.self) { variant in
                        Text(variant.name).tag(Optional(variant.tag))
                    }
                }
            }
            Toggle("Keep Audio After Transcribing", isOn: $model.keepAudio)
            Toggle("Skip Silence While Recording", isOn: $model.skipSilence)
            Button("Meetings Folder: \(model.meetingsFolderName)…") { model.chooseMeetingsFolder() }
            Divider()
            Toggle("Check for Updates Automatically", isOn: $updater.checksAutomatically)
        }
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Quit Muesli") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
