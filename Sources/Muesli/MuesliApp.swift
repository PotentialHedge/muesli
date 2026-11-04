import AppKit
import MuesliCore
import SwiftUI

struct MuesliApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.statusSymbol)
        }
    }
}

private struct MenuContent: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        Text(model.statusText)
        if let processing = model.processingText {
            Text(processing)
        }

        switch model.status {
        case .idle:
            Button("Start Recording") { model.startRecording(app: nil) }
        case .detected(let app):
            Button("Record \(app.name) Meeting") { model.startRecording(app: app) }
        case .recording:
            Button("Stop Recording") { model.stopRecording() }
        }

        if let app = model.currentApp {
            Toggle("Always Record \(app.name)", isOn: Binding(
                get: { model.alwaysRecord.contains(app.id) },
                set: { model.setAlwaysRecord(app.id, $0) }
            ))
        }

        if let error = model.lastError {
            Text(error)
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

        Divider()

        Button("Quit Muesli") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
